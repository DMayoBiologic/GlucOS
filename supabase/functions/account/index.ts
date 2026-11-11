// GlucOS account: signs a device in to logbook sync with the LibreLinkUp login it already has,
// so the Mac and the iPhone end up as the same Supabase user without a second account to make.
//
//   POST /v1/session  {email, password, region, clientVersion}
//     → 200 {access_token, refresh_token, expires_at, user_id}
//     → 401 {error} when LibreLinkUp refuses the login, 502 when it can't be reached
//
// The function logs in to LibreLinkUp once to learn the account's user id, then finds or makes
// the Supabase user for that id and returns a session for it. The password isn't stored. After
// that the apps refresh the session with Supabase Auth directly and never send it again.
//
// The user's email is made up (Supabase needs one) and never receives mail: a hash of the
// LibreLinkUp user id at a reserved domain. JWT verification is off for this function
// (supabase/config.toml) because the caller isn't signed in yet.

import { type Account, LibreError, LibreLinkUpFetcher } from "../relay/libre.ts";

const env = (k: string) => Deno.env.get(k)?.trim() || undefined;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export interface Session {
  access_token: string;
  refresh_token: string;
  expires_at: number;
  user_id: string;
}

/// Who a LibreLinkUp login belongs to.
export interface Identifier {
  identify(account: Account): Promise<string>;
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// The Supabase user's (never mailed) email for a LibreLinkUp user id.
export async function syntheticEmail(lluUserId: string): Promise<string> {
  return `llu-${(await sha256Hex(`glucos:llu:${lluUserId}`)).slice(0, 40)}@users.glucos.invalid`;
}

/// Supabase Auth's admin API: make the user if needed, then mint a session for it the way a
/// magic link would, without sending anything.
export class SupabaseAuth {
  constructor(
    /// Supabase Auth, e.g. https://<project>.supabase.co/auth/v1.
    private readonly authURL: string,
    private readonly serviceKey: string,
    private readonly anonKey: string,
    private readonly http: typeof fetch = fetch,
  ) {}

  private admin(path: string, body: unknown) {
    return this.http(`${this.authURL}/admin/${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: this.serviceKey,
        authorization: `Bearer ${this.serviceKey}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
  }

  async session(email: string): Promise<Session> {
    const created = await this.admin("users", {
      email,
      email_confirm: true,
      app_metadata: { glucos_identity: "librelinkup" },
    });
    // 422 (email_exists) is the usual case after the first device.
    if (!created.ok && created.status !== 422) {
      throw new Error(`create user: HTTP ${created.status} ${(await created.text()).slice(0, 200)}`);
    }
    await created.body?.cancel();

    const link = await this.admin("generate_link", { type: "magiclink", email });
    const linkText = await link.text();
    if (!link.ok) throw new Error(`generate_link: HTTP ${link.status} ${linkText.slice(0, 200)}`);
    const l = JSON.parse(linkText) as Record<string, unknown>;
    const props = (l.properties ?? l) as Record<string, unknown>;
    const hashed = props.hashed_token;
    if (typeof hashed !== "string") throw new Error("generate_link: no hashed_token");

    const verify = await this.http(`${this.authURL}/verify`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: this.anonKey },
      body: JSON.stringify({ type: "magiclink", token_hash: hashed }),
      signal: AbortSignal.timeout(15_000),
    });
    const vText = await verify.text();
    if (!verify.ok) throw new Error(`verify: HTTP ${verify.status} ${vText.slice(0, 200)}`);
    const v = JSON.parse(vText) as Record<string, unknown>;
    const user = v.user as Record<string, unknown> | undefined;
    if (typeof v.access_token !== "string" || typeof v.refresh_token !== "string" || typeof user?.id !== "string") {
      throw new Error("verify: no session in reply");
    }
    const expiresAt = typeof v.expires_at === "number"
      ? v.expires_at
      : Math.floor(Date.now() / 1000) + (typeof v.expires_in === "number" ? v.expires_in : 3600);
    return { access_token: v.access_token, refresh_token: v.refresh_token, expires_at: expiresAt, user_id: user.id };
  }
}

export interface Minter {
  session(email: string): Promise<Session>;
}

function readAccount(body: unknown): Account | null {
  if (!body || typeof body !== "object") return null;
  const o = body as Record<string, unknown>;
  const str = (k: string) => (typeof o[k] === "string" ? (o[k] as string) : "");
  const email = str("email").trim(), password = str("password");
  if (!email || !password || email.length > 320 || password.length > 1024) return null;
  return {
    email, password,
    region: str("region").slice(0, 16),
    clientVersion: str("clientVersion").slice(0, 16) || "4.16.0",
    sensorLifetimeDays: 15,
  };
}

export async function handle(req: Request, deps: { identifier: Identifier; minter: Minter }): Promise<Response> {
  const path = new URL(req.url).pathname.replace(/^\/(functions\/v1\/)?account/, "") || "/";
  if (path === "/health" && req.method === "GET") return new Response("ok");
  if (path !== "/v1/session" || req.method !== "POST") return json({ error: "not found" }, 404);

  let account: Account | null;
  try {
    account = readAccount(await req.json());
  } catch {
    account = null;
  }
  if (!account) return json({ error: "bad request" }, 400);

  let lluUserId: string;
  try {
    lluUserId = await deps.identifier.identify(account);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    const rejected = e instanceof LibreError && /rejected|terms/i.test(message);
    return json({ error: message }, rejected ? 401 : 502);
  }
  return json(await deps.minter.session(await syntheticEmail(lluUserId)));
}

if (import.meta.main) {
  const url = env("SUPABASE_URL"), service = env("SUPABASE_SERVICE_ROLE_KEY"), anon = env("SUPABASE_ANON_KEY");
  const deps = {
    identifier: new LibreLinkUpFetcher(),
    minter: url && service && anon ? new SupabaseAuth(`${url}/auth/v1`, service, anon) : null,
  };
  Deno.serve(async (req) => {
    try {
      if (!deps.minter) return json({ error: "Supabase keys are missing from the function's environment" }, 503);
      return await handle(req, { identifier: deps.identifier, minter: deps.minter });
    } catch (e) {
      console.error(e);
      return json({ error: "internal error" }, 500);
    }
  });
}
