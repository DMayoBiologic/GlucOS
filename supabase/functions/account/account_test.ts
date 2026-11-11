// The account function with LibreLinkUp and Supabase Auth faked, and the logbook tables and
// functions against a real Supabase Postgres (skipped unless GLUCOS_TEST_DB_URL is set).
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import postgres from "npm:postgres@3.4.5";
import { handle, type Identifier, type Minter, type Session, SupabaseAuth, syntheticEmail } from "./index.ts";
import { baseURL, LibreError } from "../relay/libre.ts";

const session = (email: string): Session => ({
  access_token: `token-for-${email}`, refresh_token: "r", expires_at: 1, user_id: `user-${email}`,
});

function call(body: unknown, identifier: Identifier, minted: string[] = []) {
  const minter: Minter = { session: (email) => { minted.push(email); return Promise.resolve(session(email)); } };
  return handle(
    new Request("https://x.supabase.co/functions/v1/account/v1/session", {
      method: "POST",
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
    { identifier, minter },
  );
}

const llu = (id: string): Identifier => ({ identify: () => Promise.resolve(id) });

Deno.test("signs in as the LibreLinkUp user, whatever email or region was used", async () => {
  const minted: string[] = [];
  const a = await call({ email: "me@example.com", password: "pw", region: "au" }, llu("abc"), minted);
  const b = await call({ email: "ME@example.com", password: "pw", region: "eu" }, llu("abc"), minted);
  assertEquals(a.status, 200);
  assertEquals(b.status, 200);
  assertEquals(minted[0], minted[1]);
  assertEquals(minted[0], await syntheticEmail("abc"));
  assert(minted[0].endsWith("@users.glucos.invalid"));
  assert(!minted[0].includes("abc"));
  assertNotEquals(await syntheticEmail("abd"), minted[0]);
  assertEquals((await a.json()).user_id, `user-${minted[0]}`);
});

Deno.test("refuses bad requests and bad logins, and says when LibreLinkUp is unreachable", async () => {
  const never: Identifier = { identify: () => Promise.reject(new Error("should not be called")) };
  assertEquals((await call("not json", never)).status, 400);
  assertEquals((await call({ email: "", password: "pw" }, never)).status, 400);
  assertEquals((await call({ email: "a@b.c" }, never)).status, 400);
  // A region that would move the login to another host never reaches LibreLinkUp.
  for (const region of ["x.evil.co/", "x.evil.co#", "au.evil", "../", "a b"]) {
    assertEquals((await call({ email: "a@b.c", password: "pw", region }, never)).status, 400, region);
  }

  const rejected: Identifier = { identify: () => Promise.reject(new LibreError("LibreLinkUp rejected the email/password.")) };
  const r = await call({ email: "a@b.c", password: "wrong" }, rejected);
  assertEquals(r.status, 401);
  assertEquals((await r.json()).error, "LibreLinkUp rejected the email/password.");

  const down: Identifier = { identify: () => Promise.reject(new TypeError("dns error")) };
  assertEquals((await call({ email: "a@b.c", password: "pw" }, down)).status, 502);

  const other = await handle(new Request("https://x/functions/v1/account/v1/other", { method: "POST" }),
    { identifier: never, minter: { session: () => Promise.reject(new Error()) } });
  assertEquals(other.status, 404);
});

Deno.test("Supabase Auth: makes the user once, then a session from a magic-link token", async () => {
  const calls: { url: string; body: Record<string, unknown>; apikey: string | null }[] = [];
  const fake: typeof fetch = (input, init) => {
    const url = String(input);
    const body = JSON.parse(String(init?.body ?? "{}"));
    calls.push({ url, body, apikey: new Headers(init?.headers).get("apikey") });
    if (url.endsWith("/admin/users")) return Promise.resolve(new Response('{"error_code":"email_exists"}', { status: 422 }));
    if (url.endsWith("/admin/generate_link")) {
      return Promise.resolve(new Response(JSON.stringify({ hashed_token: "h123", id: "u1" })));
    }
    if (url.endsWith("/verify")) {
      return Promise.resolve(new Response(JSON.stringify({
        access_token: "at", refresh_token: "rt", expires_in: 3600, expires_at: 1_800_000_000, user: { id: "u1" },
      })));
    }
    return Promise.resolve(new Response("", { status: 404 }));
  };
  const auth = new SupabaseAuth("https://p.supabase.co/auth/v1", "service", "anon", fake);
  const s = await auth.session("x@users.glucos.invalid");
  assertEquals(s, { access_token: "at", refresh_token: "rt", expires_at: 1_800_000_000, user_id: "u1" });
  assertEquals(calls.map((c) => c.url.replace("https://p.supabase.co/auth/v1", "")), ["/admin/users", "/admin/generate_link", "/verify"]);
  assertEquals(calls[0].body.email_confirm, true);
  assertEquals(calls[1].apikey, "service");
  assertEquals(calls[2].apikey, "anon");
  assertEquals(calls[2].body, { type: "magiclink", token_hash: "h123" });
});

// MARK: Database

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

type SQL = ReturnType<typeof postgres>;

/// Runs `fn` as a signed-in user, the way PostgREST does.
async function asUser<T>(sql: SQL, uid: string | null, fn: (tx: SQL) => Promise<T>): Promise<T> {
  return await sql.begin(async (tx) => {
    await tx`select set_config('role', ${uid ? "authenticated" : "anon"}, true)`;
    if (uid) {
      await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: uid, role: "authenticated" })}, true)`;
      // Older auth.uid() definitions read this one.
      await tx`select set_config('request.jwt.claim.sub', ${uid}, true)`;
    }
    return await fn(tx as unknown as SQL);
  }) as T;
}

Deno.test({
  name: "logbook: last edit wins, deletes are kept, each user sees only their own",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = postgres(url!, { prepare: false, max: 1, onnotice: () => {} });
    const a = crypto.randomUUID(), b = crypto.randomUUID();
    const e1 = crypto.randomUUID(), e2 = crypto.randomUUID();
    try {
      await sql`insert into auth.users (id, email) values (${a}, ${a + "@t.invalid"}), (${b}, ${b + "@t.invalid"})`;
      const push = (uid: string, entries: unknown[]) =>
        asUser(sql, uid, async (tx) => Number((await tx`select public.logbook_push(${tx.json(entries as never)}) as rev`)[0].rev));
      const pull = (uid: string, since = 0) =>
        asUser(sql, uid, (tx) => tx`select id, kind, payload, deleted, modified, rev from public.logbook_pull(${since}, 100)`);

      const rev1 = await push(a, [
        { id: e1, kind: "dose", payload: { units: 4 }, deleted: false, modified: 1000, device: "mac" },
        { id: e1, kind: "dose", payload: { units: 5 }, deleted: false, modified: 1001, device: "mac" },
        { id: e2, kind: "meal", payload: { carbs: 40 }, deleted: false, modified: 1000 },
      ]);
      let rows = await pull(a);
      assertEquals(rows.length, 2);
      assertEquals(rows.find((r) => r.id === e1)?.payload, { units: 5 });
      assertEquals(Math.max(...rows.map((r) => Number(r.rev))), rev1);

      // An older edit (a device that was offline) doesn't overwrite a newer one.
      assertEquals(await push(a, [{ id: e1, kind: "dose", payload: { units: 9 }, deleted: false, modified: 900 }]), rev1);
      assertEquals((await pull(a, rev1)).length, 0);

      // A newer delete wins and comes back as a tombstone.
      const rev2 = await push(a, [{ id: e2, kind: "meal", payload: { carbs: 40 }, deleted: true, modified: 2000 }]);
      rows = await pull(a, rev1);
      assertEquals(rows.length, 1);
      assertEquals(rows[0].id, e2);
      assertEquals(rows[0].deleted, true);
      assertEquals(rows[0].payload, null);
      assertEquals(Number(rows[0].rev), rev2);

      // A clock far in the future can't win forever.
      await push(a, [{ id: crypto.randomUUID(), kind: "context", payload: {}, deleted: false, modified: 99_999_999_999 }]);
      const future = (await pull(a, rev2))[0];
      assert(Number(future.modified) < Date.now() / 1000 + 600);

      // Another user sees none of it, and the same entry id stays separate.
      assertEquals((await pull(b)).length, 0);
      await push(b, [{ id: e1, kind: "dose", payload: { units: 66 }, deleted: false, modified: 5000 }]);
      assertEquals((await pull(b)).length, 1);
      assertEquals((await pull(a)).find((r) => r.id === e1)?.payload, { units: 5 });
      const direct = await asUser(sql, b, (tx) => tx`select count(*)::int as n from glucos.logbook`);
      assertEquals(direct[0].n, 1);

      // Signed out: nothing.
      let refused = false;
      try {
        await asUser(sql, null, (tx) => tx`select * from public.logbook_pull(0, 10)`);
      } catch {
        refused = true;
      }
      assert(refused);
    } finally {
      await sql`delete from auth.users where id in (${a}, ${b})`;
      await sql.end();
    }
  },
});

Deno.test("LibreLinkUp hosts stay on libreview.io, redirects included", () => {
  assertEquals(baseURL("AU"), "https://api-au.libreview.io");
  assertEquals(baseURL("eu2"), "https://api-eu2.libreview.io");
  assertEquals(baseURL(""), "https://api.libreview.io");
  assertEquals(baseURL("global"), "https://api.libreview.io");
  for (const bad of ["x.evil.co/", "evil.co#", "au/..", "au.x"]) {
    let threw = false;
    try {
      baseURL(bad);
    } catch (e) {
      threw = e instanceof LibreError;
    }
    assert(threw, bad);
  }
});
