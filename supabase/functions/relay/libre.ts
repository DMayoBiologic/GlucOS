// Abbott's (unofficial) LibreLinkUp follower API, ported from Sources/App/LibreLinkUpClient.swift.
// Login → region redirect if given → /llu/connections (current reading, sensor) →
// /llu/connections/{patientId}/graph (~12 h). Authenticated calls need `Authorization: Bearer`
// and `Account-Id: sha256(userId)`. The session is kept between runs (the edge function starts
// fresh each minute) so the relay logs in rarely, like the apps do.

import type { Reading, Sensor, Trend } from "./core.ts";

export interface Account {
  email: string;
  password: string;
  region: string;
  clientVersion: string;
  sensorLifetimeDays: number;
}

export interface LibreSession {
  /// Which account and settings this session belongs to.
  key: string;
  base: string;
  token: string;
  expires: number;
  accountId: string;
}

export interface FetchResult {
  current: Reading | null;
  history: Reading[];
  sensor: Sensor | null;
}

export class LibreError extends Error {}

export interface GlucoseFetcher {
  fetch(account: Account, session: LibreSession | null): Promise<{ result: FetchResult; session: LibreSession }>;
}

/// LibreLinkUp region codes: "au", "eu", "eu2", "us", … Anything else is refused, so neither a
/// caller nor a login redirect can point the client at a host outside libreview.io.
export function isRegion(region: string | null | undefined): boolean {
  const r = (region ?? "").trim().toLowerCase();
  return !r || r === "global" || /^[a-z]{2}[0-9]?$/.test(r);
}

export function baseURL(region: string | null | undefined): string {
  const r = (region ?? "").trim().toLowerCase();
  if (!isRegion(r)) throw new LibreError("Unexpected LibreLinkUp region.");
  return !r || r === "global" ? "https://api.libreview.io" : `https://api-${r}.libreview.io`;
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sessionKey(a: Account): Promise<string> {
  return await sha256Hex(JSON.stringify([a.email, a.password, baseURL(a.region), a.clientVersion]));
}

/// "M/d/yyyy h:mm:ss a", UTC.
export function parseFactoryTimestamp(s: string): number | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4}) (\d{1,2}):(\d{2}):(\d{2}) ([AP]M)$/i.exec(s.trim());
  if (!m) return null;
  let h = Number(m[4]) % 12;
  if (m[7].toUpperCase() === "PM") h += 12;
  return Date.UTC(Number(m[3]), Number(m[1]) - 1, Number(m[2]), h, Number(m[5]), Number(m[6])) / 1000;
}

function reading(d: unknown): Reading | null {
  if (!d || typeof d !== "object") return null;
  const o = d as Record<string, unknown>;
  const mgdl = typeof o.ValueInMgPerDl === "number" ? o.ValueInMgPerDl : null;
  const t = typeof o.FactoryTimestamp === "string" ? parseFactoryTimestamp(o.FactoryTimestamp) : null;
  if (mgdl === null || t === null) return null;
  const arrow = typeof o.TrendArrow === "number" ? o.TrendArrow : 0;
  return { t, mgdl, trend: (arrow >= 0 && arrow <= 5 ? arrow : 0) as Trend };
}

function sensorInfo(d: unknown, lifetimeDays: number): Sensor | null {
  if (!d || typeof d !== "object") return null;
  const o = d as Record<string, unknown>;
  if (typeof o.a !== "number") return null;
  return { serial: typeof o.sn === "string" ? o.sn : "?", activated: o.a, lifetimeDays };
}

export class LibreLinkUpFetcher implements GlucoseFetcher {
  constructor(private readonly http: typeof fetch = fetch) {}

  async fetch(account: Account, session: LibreSession | null) {
    const key = await sessionKey(account);
    let s = session && session.key === key && session.expires > Date.now() / 1000 + 300 ? session : null;
    if (!s) s = await this.login(account, key, baseURL(account.region), false);
    try {
      return { result: await this.data(account, s), session: s };
    } catch (e) {
      if (e instanceof HttpError && (e.status === 401 || e.status === 403)) {
        s = await this.login(account, key, baseURL(account.region), false);
        return { result: await this.data(account, s), session: s };
      }
      throw e;
    }
  }

  private headers(account: Account): Record<string, string> {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Cache-Control": "no-cache",
      "product": "llu.ios",
      "version": account.clientVersion,
      "User-Agent": `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LibreLinkUp/${account.clientVersion}`,
    };
  }

  private async json(res: Response, context: string): Promise<Record<string, unknown>> {
    const text = await res.text();
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new LibreError(`Unexpected response (${context}). The API may have changed.`);
    }
    if (!json || typeof json !== "object") throw new LibreError(`Unexpected response (${context}). The API may have changed.`);
    const o = json as Record<string, unknown>;
    const data = o.data as Record<string, unknown> | undefined;
    if (data && typeof data === "object" && typeof data.minimumVersion === "string") {
      throw new LibreError(`Abbott now requires client version ${data.minimumVersion}+. Update the version in Settings.`);
    }
    if (o.message === "RequiredHeaderMissing") {
      throw new LibreError("Unexpected response (required header missing — client version too old). The API may have changed.");
    }
    if (res.status !== 200) throw new HttpError(res.status, text);
    return o;
  }

  /// Logs in and returns the LibreLinkUp user id, which identifies the account whatever its
  /// email or region. Used by the `account` function to sign a device in to logbook sync.
  async identify(account: Account): Promise<string> {
    const s = await this.login(account, await sessionKey(account), baseURL(account.region), false);
    return s.userId;
  }

  private async login(account: Account, key: string, base: string, followingRedirect: boolean): Promise<LibreSession & { userId: string }> {
    const res = await this.http(`${base}/llu/auth/login`, {
      method: "POST",
      headers: this.headers(account),
      body: JSON.stringify({ email: account.email, password: account.password }),
      signal: AbortSignal.timeout(20_000),
    });
    const json = await this.json(res, "login");
    const status = typeof json.status === "number" ? json.status : -1;
    const data = (json.data ?? {}) as Record<string, unknown>;
    if (status === 2) throw new LibreError("LibreLinkUp rejected the email/password.");
    if (status === 4) throw new LibreError("Open the LibreLinkUp app on your phone and accept the updated terms, then retry.");
    if (status !== 0) throw new LibreError(`LibreLinkUp returned status ${status}.`);
    if (data.redirect === true && typeof data.region === "string") {
      if (followingRedirect) throw new LibreError("Unexpected response (redirect loop). The API may have changed.");
      return await this.login(account, key, baseURL(data.region), true);
    }
    const ticket = data.authTicket as Record<string, unknown> | undefined;
    const user = data.user as Record<string, unknown> | undefined;
    if (!ticket || typeof ticket.token !== "string" || !user || typeof user.id !== "string") {
      throw new LibreError("Unexpected response (missing authTicket/user). The API may have changed.");
    }
    return {
      key, base, token: ticket.token,
      expires: typeof ticket.expires === "number" ? ticket.expires : Date.now() / 1000 + 6 * 3600,
      accountId: await sha256Hex(user.id),
      userId: user.id,
    };
  }

  private async get(account: Account, s: LibreSession, path: string, context: string) {
    const res = await this.http(`${s.base}/${path}`, {
      headers: { ...this.headers(account), Authorization: `Bearer ${s.token}`, "Account-Id": s.accountId },
      signal: AbortSignal.timeout(20_000),
    });
    const json = await this.json(res, context);
    const status = typeof json.status === "number" ? json.status : 0;
    if (status !== 0) throw new LibreError(`LibreLinkUp returned status ${status}.`);
    return json;
  }

  private async data(account: Account, s: LibreSession): Promise<FetchResult> {
    const conn = await this.get(account, s, "llu/connections", "connections");
    const list = Array.isArray(conn.data) ? (conn.data as Record<string, unknown>[]) : [];
    const first = list[0];
    if (!first) throw new LibreError("This LibreLinkUp account isn't following anyone. Accept the invitation in the LibreLinkUp app.");
    if (typeof first.patientId !== "string") throw new LibreError("Unexpected response (patientId). The API may have changed.");
    let current = reading(first.glucoseMeasurement);
    let sensor = sensorInfo(first.sensor, account.sensorLifetimeDays);

    const graph = await this.get(account, s, `llu/connections/${first.patientId}/graph`, "graph");
    const g = (graph.data ?? {}) as Record<string, unknown>;
    const history = (Array.isArray(g.graphData) ? g.graphData : [])
      .map(reading).filter((r): r is Reading => r !== null).sort((a, b) => a.t - b.t);
    if (!current && g.connection && typeof g.connection === "object") {
      current = reading((g.connection as Record<string, unknown>).glucoseMeasurement);
    }
    if (!sensor && Array.isArray(g.activeSensors) && g.activeSensors[0]) {
      sensor = sensorInfo((g.activeSensors[0] as Record<string, unknown>).sensor, account.sensorLifetimeDays);
    }
    return { current, history, sensor };
  }
}

export class HttpError extends LibreError {
  constructor(readonly status: number, body: string) {
    super(`HTTP ${status}: ${body.slice(0, 200)}`);
  }
}
