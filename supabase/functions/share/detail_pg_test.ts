// detail.ts's queries against a real Supabase Postgres with the migrations applied. Skipped unless
// GLUCOS_TEST_DB_URL points at one (CI runs it against the supabase/postgres image).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { connect } from "../relay/store.ts";
import { hashShareToken, newShareToken, PostgresShareStore } from "../relay/sharing.ts";
import { PostgresDetailSource } from "./detail.ts";

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres detail: buckets, owner's logbook, shows_logbook switch",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    const user = crypto.randomUUID();
    const other = crypto.randomUUID();
    const work = (await sql`select work from glucos.relay where id = 1`)[0]?.work ?? {};
    try {
      const now = Math.floor(Date.now() / 1000);
      await sql`delete from glucos.readings where at > now() - interval '1 hour'`;
      for (let back = 12; back >= 0; back--) {
        await sql`insert into glucos.readings (at, mgdl) values (to_timestamp(${now - back * 60}), ${100 + back})
                  on conflict (at) do update set mgdl = excluded.mgdl`;
      }
      const source = new PostgresDetailSource(sql);
      const rs = await source.readings(now - 600);
      assert(rs.length >= 2 && rs.length <= 3, JSON.stringify(rs));
      assertEquals(rs.at(-1)![0], now);
      for (const [t] of rs) assert(t >= now - 600);

      // No owner known yet.
      await sql`update glucos.relay set work = work - 'forecastLog' where id = 1`;
      assertEquals(await source.logbook(now - 3600), null);

      for (const u of [user, other]) {
        await sql`insert into auth.users (id, email) values (${u}::uuid, ${`${u}@users.glucos.invalid`})`;
      }
      await sql`update glucos.relay set work = jsonb_set(work, '{forecastLog}', ${sql.json({ owner: user } as never)}) where id = 1`;
      const add = async (u: string, kind: string, payload: Record<string, unknown> | null, deleted = false) =>
        await sql`insert into glucos.logbook (user_id, id, kind, payload, deleted, modified_at)
                  values (${u}::uuid, ${crypto.randomUUID()}::uuid, ${kind}, ${payload ? sql.json(payload as never) : null},
                          ${deleted}, now())`;
      await add(user, "dose", { timestamp: now - 1800, units: 3, note: "secret", calculation: { a: 1 } });
      await add(user, "meal", { timestamp: now - 600, carbs: 20, note: "" });
      await add(user, "meal", { timestamp: now - 72 * 3600, carbs: 5, note: "" });
      await add(user, "preset", { name: "x", timestamp: now });
      await add(user, "dose", null, true);
      await add(other, "meal", { timestamp: now - 60, carbs: 99, note: "" });
      const log = await source.logbook(now - 48 * 3600);
      assertEquals(log?.map((e) => e.kind), ["meal", "dose"]);
      assertEquals(log?.[1].payload.note, "");
      assertEquals(log?.[1].payload.calculation, undefined);
      assertEquals(log?.[0].payload.carbs, 20);

      const shares = new PostgresShareStore(sql);
      const s = await shares.createShare("Declan", await hashShareToken(newShareToken()), null);
      assertEquals(s.showsLogbook, true);
      const hidden = await shares.createShare("Hidden", await hashShareToken(newShareToken()), null, false);
      assertEquals(hidden.showsLogbook, false);
      assert(await shares.setShowsLogbook(s.id, false, now));
      assertEquals((await shares.listShares(now)).find((x) => x.id === s.id)?.showsLogbook, false);
      await shares.revokeShare(s.id, now);
      assertEquals(await shares.setShowsLogbook(s.id, true, now), false);
      await shares.revokeShare(hidden.id, now);
    } finally {
      await sql`delete from glucos.logbook where user_id in (${user}::uuid, ${other}::uuid)`;
      await sql`delete from auth.users where id in (${user}::uuid, ${other}::uuid)`;
      await sql`update glucos.relay set work = ${sql.json(work as never)} where id = 1`;
      await sql.end();
    }
  },
});
