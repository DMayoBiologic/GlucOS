// Apple Push Notification service: token auth (an ES256 JWT from the .p8 key) over HTTP/2.
// Payload shapes follow Apple's "Sending notification requests to APNs" and "Starting and
// updating Live Activities with ActivityKit push notifications".

import { type AlertNotice, type CardState, cardRange, cardStaleDate } from "./core.ts";

export interface PushRequest {
  deviceToken: string;
  type: "alert" | "liveactivity";
  /// The app's bundle id; Live Activity pushes get `.push-type.liveactivity` added.
  topic: string;
  /// 10 sends now; 5 lets APNs batch it to save the phone's battery.
  priority: 5 | 10;
  payload: Record<string, unknown>;
  collapseId?: string;
  /// Seconds since 1970. Past this APNs gives up rather than delivering late.
  expiration?: number;
  sandbox: boolean;
}

export type PushResult =
  | { kind: "delivered" }
  /// The token will never work again (app deleted, activity ended): forget it.
  | { kind: "tokenInvalid"; reason: string }
  | { kind: "failed"; reason: string };

export interface PushSender {
  send(push: PushRequest): Promise<PushResult>;
}

// MARK: - Payloads

/// The relay starts activities by this type name; it must match the Swift struct.
export const activityAttributesType = "GlucoseActivityAttributes";

export const payloads = {
  alert(n: AlertNotice, criticalSound: boolean) {
    const aps: Record<string, unknown> = {
      alert: { title: n.title, body: n.body },
      "thread-id": "glucos.alerts",
      "interruption-level": n.critical ? (criticalSound ? "critical" : "time-sensitive") : "active",
      "relevance-score": n.critical ? 1.0 : 0.8,
      sound: n.critical && criticalSound ? { critical: 1, name: "default", volume: 1.0 } : "default",
    };
    return { aps, kind: n.kind };
  },

  /// The owner's alert, on a follower's phone: named for whose readings they are, and grouped
  /// per person.
  followerAlert(n: AlertNotice, label: string, shareId: string, criticalSound: boolean) {
    const base = payloads.alert(n, criticalSound);
    // The owner's urgent-low text tells them to treat it; a follower should check on them.
    const body = n.kind === "urgentLow" ? n.body.replace("Treat now and confirm on your phone.", `Check on ${label} now.`) : n.body;
    base.aps.alert = { title: `${label}: ${n.title}`, body };
    base.aps["thread-id"] = `glucos.follow.${shareId}`;
    return { ...base, followID: shareId };
  },

  test() {
    return {
      aps: {
        alert: { title: "GlucOS test alert", body: "Sent by your GlucOS relay. Alerts will reach you even when the app is closed." },
        sound: "default", "thread-id": "glucos.alerts",
      },
    };
  },

  /// `attributes` for a start: the owner's own card by default, or a follower's card
  /// ({name: whose readings, followID: the share}).
  activity(event: "update" | "start" | "end", state: CardState | null, now: number,
           attributes: Record<string, unknown> = { name: "GlucOS" }) {
    const aps: Record<string, unknown> = { timestamp: Math.trunc(now), event };
    if (state) {
      aps["content-state"] = state;
      aps["stale-date"] = Math.trunc(cardStaleDate(state));
      // Out of range sorts above other Live Activities.
      aps["relevance-score"] = cardRange(state) === "inRange" ? 50 : 100;
    }
    if (event === "start") {
      aps["attributes-type"] = activityAttributesType;
      aps["attributes"] = attributes;
      // Required to start an activity. No sound, so a restart in the night is silent.
      aps["alert"] = attributes.followID
        ? { title: "GlucOS", body: `${attributes.name}'s glucose is on your Lock Screen.` }
        : { title: "GlucOS", body: "Live glucose is on your Lock Screen." };
    }
    if (event === "end") aps["dismissal-date"] = Math.trunc(now);
    return { aps };
  },
};

// MARK: - Provider token

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
const b64urlJSON = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

export async function importAPNsKey(pem: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey("pkcs8", pemToDer(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/// A signed provider token. Apple refuses ones older than an hour and throttles ones refreshed
/// more often than every 20 minutes, so callers keep it (in the database) for 50 minutes.
export async function providerToken(key: CryptoKey, keyId: string, teamId: string, now: number): Promise<string> {
  const input = `${b64urlJSON({ alg: "ES256", kid: keyId })}.${b64urlJSON({ iss: teamId, iat: Math.trunc(now) })}`;
  // WebCrypto's ECDSA signature is already the raw r‖s form JWS wants.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)));
  return `${input}.${b64url(sig)}`;
}

export interface TokenCache {
  get(): Promise<{ token: string; issuedAt: number } | null>;
  set(v: { token: string; issuedAt: number }): Promise<void>;
}

export class APNsSender implements PushSender {
  private key?: Promise<CryptoKey>;

  constructor(
    private readonly config: { keyPem: string; keyId: string; teamId: string },
    private readonly cache: TokenCache,
    private readonly http: typeof fetch = fetch,
  ) {}

  private async token(force: boolean): Promise<string> {
    const now = Date.now() / 1000;
    const cached = await this.cache.get();
    if (!force && cached && now - cached.issuedAt < 50 * 60) return cached.token;
    this.key ??= importAPNsKey(this.config.keyPem);
    const token = await providerToken(await this.key, this.config.keyId, this.config.teamId, now);
    await this.cache.set({ token, issuedAt: now });
    return token;
  }

  async send(push: PushRequest): Promise<PushResult> {
    try {
      const first = await this.attempt(push, false);
      // A provider token can be refused as expired around a clock skew: refresh once.
      if (first.kind === "failed" && first.reason.includes("ExpiredProviderToken")) return await this.attempt(push, true);
      return first;
    } catch (e) {
      return { kind: "failed", reason: String(e instanceof Error ? e.message : e) };
    }
  }

  private async attempt(push: PushRequest, force: boolean): Promise<PushResult> {
    const host = push.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const headers: Record<string, string> = {
      authorization: `bearer ${await this.token(force)}`,
      "apns-push-type": push.type,
      "apns-topic": push.type === "liveactivity" ? `${push.topic}.push-type.liveactivity` : push.topic,
      "apns-priority": String(push.priority),
      "content-type": "application/json",
    };
    if (push.collapseId) headers["apns-collapse-id"] = push.collapseId;
    if (push.expiration !== undefined) headers["apns-expiration"] = String(Math.trunc(push.expiration));
    const res = await this.http(`https://${host}/3/device/${push.deviceToken}`, {
      method: "POST", headers, body: JSON.stringify(push.payload), signal: AbortSignal.timeout(10_000),
    });
    const text = await res.text();
    if (res.status === 200) return { kind: "delivered" };
    let reason = `HTTP ${res.status}`;
    try {
      const r = JSON.parse(text)?.reason;
      if (typeof r === "string") reason = r;
    } catch { /* not JSON */ }
    if (res.status === 410 || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(reason)) {
      return { kind: "tokenInvalid", reason };
    }
    return { kind: "failed", reason: `${res.status} ${reason}` };
  }
}
