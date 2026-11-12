// GlucOS diagnostics: error reports from the iPhone and Mac apps (Sources/Core/Diagnostics.swift).
// Public, since every install sends them and none is signed in, so it checks what it's given:
// a valid shape, short fields, at most 20 reports a request and 60 an hour from one install.
//
//   GET  /health                       → "ok"
//   POST /v1/report   DiagnosticBatch  → {stored}
//
// JWT verification is off for this function (supabase/config.toml). Reports land in
// glucos.diagnostics; see docs/Diagnostics.md for how to read them.

import { connect } from "../relay/store.ts";
import postgres from "npm:postgres@3.4.5";

type SQL = ReturnType<typeof postgres>;

export interface DiagnosticDevice {
  installID: string;
  platform: string;
  app: string;
  appVersion: string;
  build: string;
  osVersion: string;
  model: string;
}

export interface DiagnosticEvent {
  id: string;
  occurredAt: number;
  feature: string;
  step: string;
  code?: string | null;
  message: string;
  detail?: string | null;
  context?: Record<string, string>;
  repeats?: number;
  userSent?: boolean;
  note?: string | null;
}

export interface DiagnosticBatch {
  device: DiagnosticDevice;
  events: DiagnosticEvent[];
}

export const limits = { eventsPerRequest: 20, perInstallPerHour: 60, bodyBytes: 64 * 1024 };

/// Where reports go. Postgres in production; a fake in tests.
export interface DiagnosticsStore {
  recentCount(installID: string): Promise<number>;
  insert(device: DiagnosticDevice, events: DiagnosticEvent[], receivedAt: number): Promise<number>;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slug = /^[a-z0-9][a-z0-9._-]{0,63}$/;

const str = (v: unknown, max: number): string | null =>
  typeof v === "string" ? (v.length > max ? v.slice(0, max) : v) : null;

/// The batch, cleaned up, or why it was refused.
export function parseBatch(body: unknown, now: number): DiagnosticBatch | string {
  if (!body || typeof body !== "object") return "body must be a JSON object";
  const b = body as Record<string, unknown>;
  const d = b.device as Record<string, unknown> | undefined;
  if (!d || typeof d !== "object") return "device is missing";
  const installID = str(d.installID, 64);
  if (!installID || !uuid.test(installID)) return "device.installID must be a UUID";
  const platform = str(d.platform, 16);
  if (!platform || !["ios", "macos", "other"].includes(platform)) return "device.platform is not recognised";
  const device: DiagnosticDevice = {
    installID: installID.toLowerCase(),
    platform,
    app: str(d.app, 100) ?? "unknown",
    appVersion: str(d.appVersion, 32) ?? "?",
    build: str(d.build, 32) ?? "?",
    osVersion: str(d.osVersion, 32) ?? "?",
    model: str(d.model, 64) ?? "?",
  };
  if (!Array.isArray(b.events) || b.events.length === 0) return "events must be a non-empty array";
  if (b.events.length > limits.eventsPerRequest) return `at most ${limits.eventsPerRequest} events a request`;
  const events: DiagnosticEvent[] = [];
  for (const raw of b.events) {
    if (!raw || typeof raw !== "object") return "each event must be an object";
    const e = raw as Record<string, unknown>;
    const id = str(e.id, 64);
    if (!id || !uuid.test(id)) return "event.id must be a UUID";
    const feature = str(e.feature, 64);
    const step = str(e.step, 64);
    if (!feature || !slug.test(feature)) return "event.feature must be a short lower-case name";
    if (!step || !slug.test(step)) return "event.step must be a short lower-case name";
    const message = str(e.message, 500);
    if (message === null) return "event.message is missing";
    let occurredAt = typeof e.occurredAt === "number" && Number.isFinite(e.occurredAt) ? e.occurredAt : now;
    // A device clock far off (or a queued report from long ago) is kept, but never in the future.
    if (occurredAt > now + 300 || occurredAt < now - 90 * 86400) occurredAt = now;
    const context: Record<string, string> = {};
    if (e.context && typeof e.context === "object" && !Array.isArray(e.context)) {
      for (const [k, v] of Object.entries(e.context as Record<string, unknown>).slice(0, 20)) {
        const val = str(v, 200);
        if (val !== null) context[k.slice(0, 40)] = val;
      }
    }
    events.push({
      id: id.toLowerCase(),
      occurredAt,
      feature,
      step,
      code: str(e.code, 64),
      message,
      detail: str(e.detail, 2000),
      context,
      repeats: typeof e.repeats === "number" && e.repeats > 0 ? Math.min(Math.floor(e.repeats), 100000) : 0,
      userSent: e.userSent === true,
      note: str(e.note, 1000),
    });
  }
  return { device, events };
}

export class PostgresDiagnosticsStore implements DiagnosticsStore {
  constructor(private sql: SQL) {}

  async recentCount(installID: string): Promise<number> {
    const [r] = await this.sql`
      select count(*)::int as n from glucos.diagnostics
      where install_id = ${installID} and received_at > now() - interval '1 hour'`;
    return r.n as number;
  }

  async insert(device: DiagnosticDevice, events: DiagnosticEvent[], receivedAt: number): Promise<number> {
    const rows = events.map((e) => ({
      id: e.id,
      received_at: new Date(receivedAt * 1000),
      occurred_at: new Date(e.occurredAt * 1000),
      install_id: device.installID,
      platform: device.platform,
      app: device.app,
      app_version: device.appVersion,
      build: device.build,
      os_version: device.osVersion,
      model: device.model,
      feature: e.feature,
      step: e.step,
      code: e.code ?? null,
      message: e.message,
      detail: e.detail ?? null,
      context: this.sql.json(e.context ?? {}),
      repeats: e.repeats ?? 0,
      user_sent: e.userSent ?? false,
      note: e.note ?? null,
    }));
    // A retried batch (the reply was lost) doesn't store anything twice.
    const stored = await this.sql`
      insert into glucos.diagnostics ${this.sql(rows)}
      on conflict (id) do nothing
      returning id`;
    return stored.length;
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

let cachedStore: DiagnosticsStore | null = null;
const defaultStore = () => (cachedStore ??= new PostgresDiagnosticsStore(connect()));

export async function handle(
  req: Request,
  store: () => DiagnosticsStore = defaultStore,
  clock: () => number = () => Date.now() / 1000,
): Promise<Response> {
  const path = new URL(req.url).pathname.replace(/^\/(functions\/v1\/)?diagnostics/, "") || "/";
  if (path === "/health" && req.method === "GET") return new Response("ok");
  if (path !== "/v1/report") return json({ error: "not found" }, 404);
  if (req.method !== "POST") return json({ error: "use POST" }, 405);

  const text = await req.text();
  if (text.length > limits.bodyBytes) return json({ error: "too large" }, 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const now = clock();
  const batch = parseBatch(body, now);
  if (typeof batch === "string") return json({ error: batch }, 400);

  const s = store();
  const recent = await s.recentCount(batch.device.installID);
  // Reports the person sent themselves always fit; automatic ones stop at the hourly limit.
  const room = Math.max(0, limits.perInstallPerHour - recent);
  const wanted = batch.events.filter((e) => e.userSent).concat(batch.events.filter((e) => !e.userSent).slice(0, room));
  if (wanted.length === 0) return json({ error: "too many reports, try later" }, 429);
  const stored = await s.insert(batch.device, wanted, now);
  return json({ stored, dropped: batch.events.length - wanted.length });
}

if (import.meta.main) {
  Deno.serve((req) =>
    handle(req).catch((e) => {
      console.error("diagnostics", e);
      return json({ error: "server error" }, 500);
    })
  );
}
