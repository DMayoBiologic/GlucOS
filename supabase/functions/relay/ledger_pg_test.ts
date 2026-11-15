// The forecast ledger against a real Supabase Postgres with the migrations applied: the relay's
// rows land in forecast_checks, get scored from glucos.readings, and show in forecast_accuracy.
// Skipped unless GLUCOS_TEST_DB_URL points at a local test database.
import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import { connect } from "./store.ts";
import { PostgresForecastLedger } from "./ledger.ts";
import { syntheticEmail } from "./libre.ts";

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres forecast ledger: owner, record once per 15 minutes, score from readings and logs",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    try {
      const user = crypto.randomUUID();
      const email = await syntheticEmail(`ledger-test-${user}`);
      await sql`insert into auth.users (id, email) values (${user}::uuid, ${email})`;
      await sql`delete from glucos.readings`;
      const ledger = new PostgresForecastLedger(sql);
      assertEquals(await ledger.owner(`ledger-test-${user}`), user);
      assertEquals(await ledger.owner("nobody"), null);

      // Readings every 5 minutes over the last hour and a half, rising 1 mg/dL a minute, with a
      // gap of 25 minutes where the 30-minute point of the second forecast falls.
      const now = Math.floor(Date.now() / 1000);
      const start = now - 90 * 60;
      const ts: number[] = [], vs: number[] = [];
      for (let m = 0; m <= 90; m += 5) {
        if (m > 60 && m < 85) continue;
        ts.push(start + m * 60);
        vs.push(100 + m);
      }
      await sql`
        insert into glucos.readings (at, mgdl, trend)
        select to_timestamp(u.t), u.m, 3 from unnest(${ts}::float8[], ${vs}::float8[]) as u(t, m)`;

      const points = (base: number) => [
        { minutes: 15, mgdl: base + 10, lower: base, upper: base + 20 },
        { minutes: 30, mgdl: base + 20, lower: base + 5, upper: base + 35 },
      ];
      const first = { id: crypto.randomUUID(), issuedAt: start, startMgdl: 100, trendPerMinute: 1, basis: "trend" as const,
                      points: points(100), calibrated: false, tuned: true };
      assert(await ledger.record(user, first));
      // Another inside the same 15 minutes isn't kept.
      assertEquals(await ledger.record(user, { ...first, id: crypto.randomUUID(), issuedAt: start + 600 }), false);
      const second = { ...first, id: crypto.randomUUID(), issuedAt: start + 40 * 60, startMgdl: 140, points: points(140) };
      assert(await ledger.record(user, second));
      // Not yet due: the third forecast's points are in the future.
      // Its 30-minute point was past the drawn horizon (live cut), kept only to be scored.
      const third = { ...first, id: crypto.randomUUID(), issuedAt: now - 60, startMgdl: 189,
                      points: [points(189)[0], { ...points(189)[1], shown: false as const }] };
      assert(await ledger.record(user, third));

      // A meal logged 20 minutes after the second forecast: its 30-minute point comes after it.
      await sql`
        insert into glucos.logbook (user_id, id, kind, payload, modified_at, device)
        values (${user}::uuid, gen_random_uuid(), 'meal', ${sql.json({ timestamp: second.issuedAt + 20 * 60, carbs: 30 })}, now(), 'Mac'),
               (${user}::uuid, gen_random_uuid(), 'context', ${sql.json({ timestamp: first.issuedAt + 5 * 60, tags: ["wokeUp"] })}, now(), 'Mac')`;

      assertEquals(await ledger.score(user), 2);
      // Nothing new: nothing changes.
      assertEquals(await ledger.score(user), 0);

      const rows = await sql`
        select id::text, points from glucos.forecast_checks where user_id = ${user}::uuid and device = 'relay'`;
      const byId = new Map(rows.map((r) => [r.id as string, r.points as Record<string, unknown>[]]));
      const p1 = byId.get(first.id)!, p2 = byId.get(second.id)!, p3 = byId.get(third.id)!;
      // Exact readings; waking up isn't a log that counts.
      assertEquals(p1.map((p) => [p.actual, p.after_log]), [[115, false], [130, false]]);
      // 15 min (55): exact. 30 min (70) sits in a 25-minute gap, too wide to bridge, with no reading
      // within 5 minutes: no actual. The meal at 60 comes before it.
      assertEquals(p2[0].actual, 155);
      assertEquals(p2[0].after_log, false);
      assertEquals("actual" in p2[1], false);
      assertEquals(p2[1].after_log, true);
      assertEquals(p3.some((p) => "actual" in p), false);

      // Summed over weeks: the view's weeks are Perth weeks, and a run late on a Sunday (UTC)
      // puts these forecasts either side of Monday 00:00 in Perth.
      const acc = await sql`
        select minutes, clean, sum(checks) as checks, (sum(mae_mgdl * checks) / sum(checks))::float8 as mae
        from glucos.forecast_accuracy
        where user_id = ${user}::uuid and device = 'relay' group by minutes, clean order by minutes`;
      assertEquals(acc.map((a) => [a.minutes, a.clean, Number(a.checks)]), [[15, true, 2], [30, true, 1]]);
      assertAlmostEquals(Number(acc[0].mae), 5, 0.01);

      // What the live horizon is worked out from: every point of the last week, scored or not.
      const live = (await ledger.livePoints(user)).sort((a, b) => a.issuedAt - b.issuedAt || a.minutes - b.minutes);
      assertEquals(live.map((p) => [p.minutes, p.actual, p.afterLog, p.shown]), [
        [15, 115, false, true], [30, 130, false, true],
        [15, 155, false, true], [30, null, true, true],
        [15, null, false, true], [30, null, false, false],
      ]);
      assertEquals(live[0].startMgdl, 100);
      assertEquals(live[0].mgdl, 110);
      assertEquals(live[0].issuedAt, start);

      // Interpolation between readings up to 20 minutes apart.
      const mid = await sql`select glucos.reading_at(to_timestamp(${start + 150})) as v`;
      assertAlmostEquals(Number(mid[0].v), 102.5, 1e-9);
      await sql`delete from auth.users where id = ${user}::uuid`;
    } finally {
      await sql.end();
    }
  },
});
