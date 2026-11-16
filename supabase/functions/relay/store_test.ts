// The relay against a real Supabase Postgres with the migrations applied. Skipped unless
// GLUCOS_TEST_DB_URL points at one, e.g. `supabase start` locally or the supabase/postgres image.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { connect, PostgresStore } from "./store.ts";
import { RelayEngine } from "./engine.ts";
import type { PushRequest, PushSender } from "./apns.ts";
import type { Account, GlucoseFetcher, LibreSession } from "./libre.ts";
import type { Reading } from "./core.ts";

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
// It wipes the relay's tables, so never against a hosted project.
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres store: register, tick, status, sign-out",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    try {
      await sql`delete from glucos.readings`;
      await sql`update glucos.relay set prefs = '{}', work = '{}', activity = null, tick_lease_until = null where id = 1`;
      await sql`delete from vault.secrets where name in ('glucos_account', 'glucos_libre_session')`;
      const store = new PostgresStore(sql);
      let now = 1_790_000_000;
      const sent: PushRequest[] = [];
      const sender: PushSender = { send: (p) => { sent.push(p); return Promise.resolve({ kind: "delivered" }); } };
      let mgdl = 62;
      const fetcher: GlucoseFetcher = {
        fetch: (_a: Account, s: LibreSession | null) => {
          const history: Reading[] = [];
          for (let back = 60; back >= 5; back -= 5) history.push({ t: now - back * 60, mgdl, trend: 3 });
          return Promise.resolve({
            result: { current: { t: now - 30, mgdl, trend: 2 }, history, sensor: { serial: "X", activated: now - 86400, lifetimeDays: 15 } },
            session: s ?? { key: "k", base: "https://api-au.libreview.io", token: "tok", expires: now + 3600, accountId: "acc" },
          });
        },
      };
      const engine = new RelayEngine(store, sender, fetcher, { bundleId: "b", criticalAlerts: false }, () => now);

      let status = await engine.register({
        deviceToken: "dev", pushToStartToken: "p2s", activityID: "A1", activityToken: "act",
        account: { email: "a@b.c", password: "pw", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 },
        display: { unit: "mmol", lowMgdl: 70, highMgdl: 180 },
      });
      assert(status.hasAccount);
      assertEquals(status.activityID, "A1");

      assertEquals(await engine.tick(), "done");
      assertEquals(sent.filter((p) => p.type === "alert").map((p) => p.collapseId), ["glucos.low"]);
      assertEquals(sent.filter((p) => p.type === "liveactivity").length, 1);
      const rows = await sql`select count(*)::int as n from glucos.readings`;
      assertEquals(rows[0].n, 13);
      const secret = await sql`select decrypted_secret from vault.decrypted_secrets where name = 'glucos_account'`;
      assertEquals(JSON.parse(secret[0].decrypted_secret).email, "a@b.c");
      const raw = await sql`select secret from vault.secrets where name = 'glucos_account'`;
      assertFalse(String(raw[0].secret).includes("a@b.c"));

      // The cooldown is remembered between runs (a fresh engine, as each minute's call is).
      sent.length = 0;
      now += 60;
      const again = new RelayEngine(new PostgresStore(sql), sender, fetcher, { bundleId: "b", criticalAlerts: false }, () => now);
      assertEquals(await again.tick(), "done");
      assertEquals(sent.filter((p) => p.type === "alert"), []);

      status = await again.status();
      assertEquals(status.lastFetchAt, now);
      assertEquals(status.lastReadingAt, now - 30);

      // A status read doesn't wait for (or write) the row a tick holds while it sends pushes.
      const held = connect(url);
      try {
        let release = () => {};
        const holding = new Promise<void>((r) => { release = r; });
        let locked = () => {};
        const isLocked = new Promise<void>((r) => { locked = r; });
        const tx = held.begin(async (s) => {
          await s`select 1 from glucos.relay where id = 1 for update`;
          locked();
          await holding;
        });
        await isLocked;
        const before = (await sql`select updated_at::text as u from glucos.relay where id = 1`)[0].u;
        const read = await Promise.race([
          again.status(),
          new Promise<null>((r) => setTimeout(() => r(null), 3000)),
        ]);
        release();
        await tx;
        assertEquals(read?.lastFetchAt, now);
        assertEquals((await sql`select updated_at::text as u from glucos.relay where id = 1`)[0].u, before);
      } finally {
        await held.end();
      }

      assert(await store.cronToken());
      const cache = store.tokenCache();
      await cache.set({ token: "jwt", issuedAt: now });
      assertEquals(await cache.get(), { token: "jwt", issuedAt: now });

      status = await again.register({ signedOut: true });
      assertFalse(status.hasAccount);
      assertEquals((await sql`select count(*)::int as n from glucos.readings`)[0].n, 0);
    } finally {
      await sql.end();
    }
  },
});
