// GlucOS share: what someone with a share link can see and do. Public (no Supabase login and no
// relay secret): the share token in the link is the credential, sent as `Authorization: Bearer
// <token>`. Only the token's hash is stored, and a revoked or expired share answers 404 like a
// token that never existed.
//
//   GET  /health                              → "ok"
//   GET  /v1/snapshot                         → ShareSnapshot   (the web view, and the app)
//   POST /v1/follow     FollowRegistration    → FollowStatus    (a follower phone's push tokens, alert switch)
//   POST /v1/unfollow   {installation}        → {ok}
//   POST /v1/checkin    {installation, name}  → CheckInCard     (ask the owner if they're okay)
//
// GET /v1/snapshot?installation=<id> also returns that follower's latest check-in, so the app's
// own update of its Lock Screen card keeps it.
//
// Browsers call it from the web view on Vercel, so it answers CORS preflights. JWT
// verification is off for this function (supabase/config.toml). See docs/Sharing.md.

import { APNsSender, type PushSender } from "../relay/apns.ts";
import { askCheckIn, type CheckInCard, cleanName, followerCheckInCard } from "../relay/checkins.ts";
import type { CardState } from "../relay/core.ts";
import { connect, PostgresStore } from "../relay/store.ts";
import {
  type FollowRegistration, hashShareToken, isShareToken, PostgresShareStore, type Share, type ShareStore,
} from "../relay/sharing.ts";

export interface ShareSnapshot {
  label: string;
  expiresAt: number | null;
  /// The owner's latest Lock Screen card (their units and range), or null before the first reading.
  card: CardState | null;
  /// When the relay made `card`, seconds since 1970.
  updatedAt: number | null;
  /// Used as the follower's Live Activity `followID`.
  followID: string;
  /// With `?installation=`: that follower's latest check-in, while it's current.
  checkIn?: CheckInCard;
}

export interface FollowStatus {
  followID: string;
  label: string;
  expiresAt: number | null;
  liveActivityEnabled: boolean;
  alertsEnabled: boolean;
}

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-max-age": "86400",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "content-type": "application/json", "cache-control": "no-store" },
  });

const isInstallation = (s: string) => /^[A-Za-z0-9-]{8,64}$/.test(s);

const ended = () => json({ error: "This share has ended or the link is wrong." }, 404);

let cachedStore: ShareStore | null = null;
let cachedSender: PushSender | null | undefined;
const env = (k: string) => Deno.env.get(k)?.trim() || undefined;
let sql: ReturnType<typeof connect> | null = null;
const db = () => (sql ??= connect());
const defaultStore = () => (cachedStore ??= new PostgresShareStore(db()));
/// The same APNs key and cached provider token as the relay (Supabase secrets are per project).
function defaultSender(): PushSender | null {
  if (cachedSender !== undefined) return cachedSender;
  const keyPem = env("APNS_KEY_P8"), keyId = env("APNS_KEY_ID"), teamId = env("APPLE_TEAM_ID");
  cachedSender = keyPem && keyId && teamId ? new APNsSender({ keyPem, keyId, teamId }, new PostgresStore(db()).tokenCache()) : null;
  return cachedSender;
}
const checkInConfig = () => ({
  bundleId: env("APNS_BUNDLE_ID") ?? "au.com.declanmayo.glucos.ios",
  criticalAlerts: env("APNS_CRITICAL_ALERTS") === "true",
});

export async function handle(
  req: Request,
  store: () => ShareStore = defaultStore,
  clock: () => number = () => Date.now() / 1000,
  sender: () => PushSender | null = defaultSender,
): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/(functions\/v1\/)?share/, "") || "/";
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (path === "/health" && req.method === "GET") return new Response("ok", { headers: cors });

  const auth = req.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!isShareToken(token)) return ended();
  const now = clock();
  const s = store();
  const share: Share | null = await s.shareByToken(await hashShareToken(token), now);
  if (!share) return ended();

  if (path === "/v1/snapshot" && req.method === "GET") {
    const latest = await s.latestCard();
    const body: ShareSnapshot = {
      label: share.label, expiresAt: share.expiresAt, card: latest?.card ?? null, updatedAt: latest?.at ?? null,
      followID: share.id,
    };
    const installation = url.searchParams.get("installation");
    if (installation && isInstallation(installation)) {
      const f = await s.followerByInstallation(share.id, installation, now);
      if (f) {
        const mine = (await s.checkIns(now)).find((c) => c.followerId === f.id);
        const c = followerCheckInCard(mine, now);
        if (c) body.checkIn = c;
      }
    }
    return json(body);
  }

  if (path === "/v1/checkin" && req.method === "POST") {
    const body = await req.json().catch(() => null);
    if (typeof body?.installation !== "string" || !isInstallation(body.installation)) {
      return json({ error: "bad installation" }, 400);
    }
    const f = await s.followerByInstallation(share.id, body.installation, now);
    if (!f) return json({ error: "Follow first, then you can check in." }, 409);
    return json(await askCheckIn(s, sender(), checkInConfig(), f, cleanName(body.name), now));
  }

  if ((path === "/v1/follow" || path === "/v1/unfollow") && req.method === "POST") {
    let body: FollowRegistration;
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad request" }, 400);
    }
    if (typeof body?.installation !== "string" || !isInstallation(body.installation)) {
      return json({ error: "bad installation" }, 400);
    }
    if (path === "/v1/unfollow") {
      await s.removeFollower(share.id, body.installation);
      return json({ ok: true });
    }
    const clean: FollowRegistration = { installation: body.installation };
    const hex = (v: unknown) => (typeof v === "string" && /^[0-9a-fA-F]{16,400}$/.test(v) ? v : undefined);
    const id = (v: unknown) => (typeof v === "string" && v.length > 0 && v.length <= 100 ? v : undefined);
    if (body.apnsEnvironment === "sandbox" || body.apnsEnvironment === "production") clean.apnsEnvironment = body.apnsEnvironment;
    if (hex(body.pushToStartToken)) clean.pushToStartToken = body.pushToStartToken;
    if (id(body.activityID) && hex(body.activityToken)) {
      clean.activityID = body.activityID;
      clean.activityToken = body.activityToken;
    }
    if (id(body.endedActivityID)) clean.endedActivityID = body.endedActivityID;
    if (typeof body.liveActivityEnabled === "boolean") clean.liveActivityEnabled = body.liveActivityEnabled;
    if (hex(body.deviceToken)) clean.deviceToken = body.deviceToken;
    if (typeof body.alertsEnabled === "boolean") clean.alertsEnabled = body.alertsEnabled;
    const f = await s.registerFollower(share.id, clean, now);
    if (!f) return json({ error: "This share already has as many followers as it can." }, 409);
    const status: FollowStatus = {
      followID: share.id, label: share.label, expiresAt: share.expiresAt, liveActivityEnabled: f.liveActivityEnabled,
      alertsEnabled: f.alertsEnabled,
    };
    return json(status);
  }

  return json({ error: "not found" }, 404);
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    try {
      return await handle(req);
    } catch (e) {
      console.error(e);
      return json({ error: "internal error" }, 500);
    }
  });
}
