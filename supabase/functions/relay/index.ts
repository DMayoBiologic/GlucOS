// GlucOS push relay, as a Supabase Edge Function. Same HTTPS API as before (see
// Sources/Core/RelayProtocol.swift), under https://<project>.supabase.co/functions/v1/relay:
//
//   GET  /health                           → "ok"          (no secret)
//   GET  /v1/status                        → RelayStatus
//   POST /v1/claim      {email, password}  → {secret}      (no secret: the owner's LibreLinkUp login)
//   POST /v1/register   RelayRegistration  → RelayStatus
//   POST /v1/test                          → RelayStatus   (sends a test alert push)
//   POST /v1/tick                                          (pg_cron, every minute)
//   GET  /v1/shares                        → Share[]       (the owner's live share links)
//   POST /v1/shares     CreateShareRequest → CreatedShare
//   POST /v1/shares/revoke  {id}           → Share[]
//   POST /v1/checkins/answer {answer}      → RelayStatus   (the owner answers check-ins: "okay" | "help")
//
// The phone sends `Authorization: Bearer <RELAY_SECRET>`. The schedule sends `X-GlucOS-Cron`
// with a token the migration generated into Vault. JWT verification is off for this function
// (supabase/config.toml) because neither caller is a Supabase user.
//
// Secrets (supabase secrets set …): RELAY_SECRET, APNS_KEY_P8, APNS_KEY_ID, APPLE_TEAM_ID, and
// optionally APNS_BUNDLE_ID (default au.com.declanmayo.glucos.ios) and APNS_CRITICAL_ALERTS=true.

import { APNsSender } from "./apns.ts";
import { constantTimeEqual, type CreateShareRequest, RelayEngine, type RelayRegistration, ShareError } from "./engine.ts";
import { LibreLinkUpFetcher } from "./libre.ts";
import { connect, PostgresStore } from "./store.ts";
import { PostgresShareStore } from "./sharing.ts";

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

let cached: { store: PostgresStore; engine: RelayEngine } | null = null;

function services() {
  if (cached) return cached;
  const sql = connect();
  const store = new PostgresStore(sql);
  const keyPem = env("APNS_KEY_P8"), keyId = env("APNS_KEY_ID"), teamId = env("APPLE_TEAM_ID");
  const sender = keyPem && keyId && teamId ? new APNsSender({ keyPem, keyId, teamId }, store.tokenCache()) : null;
  const engine = new RelayEngine(store, sender, new LibreLinkUpFetcher(), {
    bundleId: env("APNS_BUNDLE_ID") ?? "au.com.declanmayo.glucos.ios",
    criticalAlerts: env("APNS_CRITICAL_ALERTS") === "true",
    shares: new PostgresShareStore(sql),
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

  if (path === "/v1/claim" && req.method === "POST") {
    const body = await req.json().catch(() => null);
    const result = await services().engine.claim(body?.email, body?.password);
    switch (result) {
      case "ok": return json({ secret });
      case "locked": return json({ error: "Too many tries. Wait 15 minutes." }, 429);
      case "no account": return json({ error: "This relay isn't signed in yet." }, 404);
      default: return json({ error: "That isn't the account this relay uses." }, 403);
    }
  }

  if (!constantTimeEqual(req.headers.get("authorization") ?? "", `Bearer ${secret}`)) {
    return json({ error: "unauthorized" }, 401);
  }
  const { engine } = services();
  if (path === "/v1/status" && req.method === "GET") return json(await engine.status());
  if (path === "/v1/test" && req.method === "POST") return json(await engine.sendTest());
  if (path === "/v1/checkins/answer" && req.method === "POST") {
    const body = await req.json().catch(() => null);
    if (body?.answer !== "okay" && body?.answer !== "help") return json({ error: "bad request" }, 400);
    try {
      return json(await engine.answerCheckIns(body.answer));
    } catch (e) {
      if (e instanceof ShareError) return json({ error: e.message }, e.status);
      throw e;
    }
  }
  if (path.startsWith("/v1/shares")) {
    try {
      if (path === "/v1/shares" && req.method === "GET") return json(await engine.listShares());
      const body = req.method === "POST" ? await req.json().catch(() => null) : null;
      if (path === "/v1/shares" && req.method === "POST") return json(await engine.createShare((body ?? {}) as CreateShareRequest));
      if (path === "/v1/shares/revoke" && req.method === "POST") {
        if (typeof body?.id !== "string") return json({ error: "bad request" }, 400);
        return json(await engine.revokeShare(body.id));
      }
    } catch (e) {
      if (e instanceof ShareError) return json({ error: e.message }, e.status);
      throw e;
    }
    return json({ error: "not found" }, 404);
  }
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
