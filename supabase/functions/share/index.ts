// GlucOS share: what someone with a share link can see and do. Public (no Supabase login and no
// relay secret): the share token in the link is the credential, sent as `Authorization: Bearer
// <token>`. Only the token's hash is stored, and a revoked or expired share answers 404 like a
// token that never existed.
//
//   GET  /health                              → "ok"
//   GET  /v1/snapshot                         → ShareSnapshot   (the web view, and the app)
//   POST /v1/follow     FollowRegistration    → FollowStatus    (a follower phone's push tokens)
//   POST /v1/unfollow   {installation}        → {ok}
//
// Browsers call it from the web view on GitHub Pages, so it answers CORS preflights. JWT
// verification is off for this function (supabase/config.toml). See docs/Sharing.md.

import type { CardState } from "../relay/core.ts";
import { connect } from "../relay/store.ts";
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
}

export interface FollowStatus {
  followID: string;
  label: string;
  expiresAt: number | null;
  liveActivityEnabled: boolean;
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

const ended = () => json({ error: "This share has ended or the link is wrong." }, 404);

let cachedStore: ShareStore | null = null;
const defaultStore = () => (cachedStore ??= new PostgresShareStore(connect()));

export async function handle(
  req: Request,
  store: () => ShareStore = defaultStore,
  clock: () => number = () => Date.now() / 1000,
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
    return json(body);
  }

  if ((path === "/v1/follow" || path === "/v1/unfollow") && req.method === "POST") {
    let body: FollowRegistration;
    try {
      body = await req.json();
    } catch {
      return json({ error: "bad request" }, 400);
    }
    if (typeof body?.installation !== "string" || !/^[A-Za-z0-9-]{8,64}$/.test(body.installation)) {
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
    const f = await s.registerFollower(share.id, clean, now);
    if (!f) return json({ error: "This share already has as many followers as it can." }, 409);
    const status: FollowStatus = {
      followID: share.id, label: share.label, expiresAt: share.expiresAt, liveActivityEnabled: f.liveActivityEnabled,
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
