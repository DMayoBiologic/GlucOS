// GlucOS push relay, as a Supabase Edge Function. Same HTTPS API as before (see
// Sources/Core/RelayProtocol.swift), under https://<project>.supabase.co/functions/v1/relay:
//
//   GET  /health                           → "ok"          (no secret)
//   GET  /v1/status                        → RelayStatus
//   POST /v1/register   RelayRegistration  → RelayStatus
//   POST /v1/test                          → RelayStatus   (sends a test alert push)
//   POST /v1/tick                                          (pg_cron, every minute)
//
// The phone sends `Authorization: Bearer <RELAY_SECRET>`. The schedule sends `X-GlucOS-Cron`
// with a token the migration generated into Vault. JWT verification is off for this function
// (supabase/config.toml) because neither caller is a Supabase user.
//
// Secrets (supabase secrets set …): RELAY_SECRET, APNS_KEY_P8, APNS_KEY_ID, APPLE_TEAM_ID, and
// optionally APNS_BUNDLE_ID (default au.com.declanmayo.glucos.ios) and APNS_CRITICAL_ALERTS=true.

import { APNsSender } from "./apns.ts";
import { RelayEngine, type RelayRegistration } from "./engine.ts";
import { LibreLinkUpFetcher } from "./libre.ts";
import { connect, PostgresStore } from "./store.ts";

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

let cached: { store: PostgresStore; engine: RelayEngine } | null = null;

function services() {
  if (cached) return cached;
  const store = new PostgresStore(connect());
  const keyPem = env("APNS_KEY_P8"), keyId = env("APNS_KEY_ID"), teamId = env("APPLE_TEAM_ID");
  const sender = keyPem && keyId && teamId ? new APNsSender({ keyPem, keyId, teamId }, store.tokenCache()) : null;
  const engine = new RelayEngine(store, sender, new LibreLinkUpFetcher(), {
    bundleId: env("APNS_BUNDLE_ID") ?? "au.com.declanmayo.glucos.ios",
    criticalAlerts: env("APNS_CRITICAL_ALERTS") === "true",
  });
  cached = { store, engine };
  return cached;
}

export async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  // The gateway passes the path with the function's name in front: /relay/v1/status.
  const path = url.pathname.replace(/^\/(functions\/v1\/)?relay/, "") || "/";
  if (path === "/health" && req.method === "GET") return new Response("ok");

  const secret = env("RELAY_SECRET");
  if (!secret) return json({ error: "RELAY_SECRET is not set on the relay" }, 503);

  if (path === "/v1/tick" && req.method === "POST") {
    const { store, engine } = services();
    const cron = req.headers.get("x-glucos-cron") ?? "";
    const expected = await store.cronToken();
    const ok = (expected !== null && constantTimeEqual(cron, expected))
      || constantTimeEqual(req.headers.get("authorization") ?? "", `Bearer ${secret}`);
    if (!ok) return json({ error: "unauthorized" }, 401);
    return json({ result: await engine.tick() });
  }

  if (!constantTimeEqual(req.headers.get("authorization") ?? "", `Bearer ${secret}`)) {
    return json({ error: "unauthorized" }, 401);
  }
  const { engine } = services();
  if (path === "/v1/status" && req.method === "GET") return json(await engine.status());
  if (path === "/v1/test" && req.method === "POST") return json(await engine.sendTest());
  if (path === "/v1/register" && req.method === "POST") {
    let body: RelayRegistration;
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad request" }, 400);
    }
    return json(await engine.register(body));
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
