// The share store against a real Supabase Postgres with the migrations applied. Skipped unless
// GLUCOS_TEST_DB_URL points at one (CI runs it against the supabase/postgres image).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { connect } from "./store.ts";
import { hashShareToken, maxFollowersPerShare, newShareToken, PostgresShareStore } from "./sharing.ts";

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres share store: create, view, follow, expire, revoke",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    try {
      await sql`delete from glucos.shares`;
      const store = new PostgresShareStore(sql);
      const now = Date.now() / 1000;
      const token = newShareToken();
      const s = await store.createShare("Declan", await hashShareToken(token), now + 3600);
      assertEquals(s.label, "Declan");
      assert(Math.abs(s.expiresAt! - (now + 3600)) < 1);
      const forever = await store.createShare("Forever", await hashShareToken(newShareToken()), null);
      assertEquals(forever.expiresAt, null);
      assertEquals((await store.listShares(now)).map((x) => x.label), ["Forever", "Declan"]);

      const viewed = await store.shareByToken(await hashShareToken(token), now);
      assertEquals(viewed?.id, s.id);
      assert(viewed?.lastViewedAt);
      assertEquals(await store.shareByToken(await hashShareToken(newShareToken()), now), null);
      assertEquals(await store.shareByToken(await hashShareToken(token), now + 7200), null);

      const f = await store.registerFollower(s.id, {
        installation: "phone-1", apnsEnvironment: "sandbox", activityID: "A", activityToken: "abcd", pushToStartToken: "p2s",
      }, now);
      assert(f);
      assertEquals(f.sandbox, true);
      assertEquals(f.activityStartedAt, now);
      const again = await store.registerFollower(s.id, { installation: "phone-1", liveActivityEnabled: false }, now + 5);
      assertEquals(again?.id, f.id);
      assertEquals(again?.activityToken, "abcd");
      assertEquals(again?.liveActivityEnabled, false);
      assertEquals(again?.alertsEnabled, true);
      assertEquals(again?.deviceToken, null);
      const alerting = await store.registerFollower(s.id, { installation: "phone-1", deviceToken: "dddd", alertsEnabled: false }, now + 5);
      assertEquals(alerting?.deviceToken, "dddd");
      assertEquals(alerting?.alertsEnabled, false);
      // Only the token APNs refused is cleared.
      await store.clearFollowerDeviceToken(f.id, "other");
      assertEquals((await store.followers(now))[0].deviceToken, "dddd");
      await store.clearFollowerDeviceToken(f.id, "dddd");
      assertEquals((await store.followers(now))[0].deviceToken, null);
      await store.registerFollower(s.id, { installation: "phone-1", deviceToken: "eeee" }, now + 5);

      const all = await store.followers(now);
      assertEquals(all.length, 1);
      assertEquals(all[0].label, "Declan");
      assertEquals(all[0].active, true);
      assertEquals((await store.followers(now + 7200))[0].active, false);

      all[0].lastCard = { mgdl: 100, trend: 3, readingAt: now, unit: "mmol", lowMgdl: 70, highMgdl: 180, history: [100], forecast: [], source: "relay" };
      all[0].lastPushedAt = now;
      await store.saveFollower(all[0], { activityToken: "abcd", pushToStartToken: "p2s" });
      assertEquals((await store.followers(now))[0].lastCard?.mgdl, 100);
      // The phone registered a new card meanwhile: the relay's stale save is dropped.
      await store.registerFollower(s.id, { installation: "phone-1", activityID: "B", activityToken: "beef" }, now + 6);
      all[0].lastCard = null;
      await store.saveFollower(all[0], { activityToken: "abcd", pushToStartToken: "p2s" });
      const after = (await store.followers(now))[0];
      assertEquals(after.activityToken, "beef");
      assertEquals(after.liveActivityEnabled, false);
      // The relay's save leaves the phone's alert settings alone.
      assertEquals(after.deviceToken, "eeee");
      assertEquals(after.alertsEnabled, false);
      // A save never brings back a deleted follower.
      const gone1 = await store.removeFollower(s.id, "phone-1");
      assert(gone1);
      await store.saveFollower(after, { activityToken: "beef", pushToStartToken: "p2s" });
      assertEquals((await store.followers(now)).length, 0);

      assert(await store.registerFollower(s.id, { installation: "phone-1", activityID: "A", activityToken: "abcd" }, now));
      for (let i = 2; i <= maxFollowersPerShare; i++) assert(await store.registerFollower(s.id, { installation: `phone-${i}` }, now));
      assertEquals(await store.registerFollower(s.id, { installation: "phone-over" }, now), null);
      assertEquals((await store.listShares(now)).find((x) => x.id === s.id)?.followers, maxFollowersPerShare);

      assert(await store.removeFollower(s.id, "phone-2"));
      const gone = await store.revokeShare(s.id, now);
      assertEquals(gone?.length, maxFollowersPerShare - 1);
      assert(gone?.some((x) => x.activityToken === "abcd"));
      assertEquals(await store.revokeShare(s.id, now), null);
      assertEquals(await store.shareByToken(await hashShareToken(token), now), null);
      assertEquals((await store.listShares(now)).map((x) => x.label), ["Forever"]);

      await sql`update glucos.relay set work = jsonb_set(work, '{latestCard}', ${sql.json({ card: { mgdl: 99 }, at: now } as never)}) where id = 1`;
      assertEquals((await store.latestCard())?.card.mgdl, 99);
      await sql`delete from glucos.shares`;
    } finally {
      await sql.end();
    }
  },
});
