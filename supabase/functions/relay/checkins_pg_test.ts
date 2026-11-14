// The check-in store against a real Supabase Postgres with the migrations applied. Skipped unless
// GLUCOS_TEST_DB_URL points at one (CI runs it against the supabase/postgres image).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { connect } from "./store.ts";
import { checkInAnswerShownFor, checkInOpenFor, checkInPingGap } from "./checkins.ts";
import { hashShareToken, newShareToken, PostgresShareStore } from "./sharing.ts";

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres check-ins: ask, ask again, answer, expire",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    try {
      await sql`delete from glucos.shares`;
      const store = new PostgresShareStore(sql);
      const now = Math.trunc(Date.now() / 1000);
      const s = await store.createShare("Declan", await hashShareToken(newShareToken()), null);
      await store.registerFollower(s.id, { installation: "phone-1", deviceToken: "dddd", apnsEnvironment: "sandbox" }, now);
      await store.registerFollower(s.id, { installation: "phone-2" }, now);
      const f1 = (await store.followerByInstallation(s.id, "phone-1", now))!;
      const f2 = (await store.followerByInstallation(s.id, "phone-2", now))!;
      assertEquals(f1.deviceToken, "dddd");
      assertEquals(f1.label, "Declan");
      assertEquals(await store.followerByInstallation(s.id, "phone-3", now), null);

      const first = await store.askCheckIn(f1, "Sam", now);
      assert(first.ping);
      assertEquals(first.checkIn.name, "Sam");
      assertEquals(first.checkIn.answer, null);
      // Again at once: the same check-in, no new notification, name kept.
      const again = await store.askCheckIn(f1, "", now + 10);
      assertEquals(again.ping, false);
      assertEquals(again.checkIn.id, first.checkIn.id);
      assertEquals(again.checkIn.name, "Sam");
      const later = await store.askCheckIn(f1, "", now + checkInPingGap);
      assert(later.ping);
      assertEquals(later.checkIn.lastAskedAt, now + checkInPingGap);
      await store.askCheckIn(f2, "", now + 20);
      assertEquals((await store.checkIns(now + 30)).length, 2);

      await store.markReminded([first.checkIn.id], now + 300);
      assertEquals((await store.checkIns(now + 301)).find((c) => c.id === first.checkIn.id)?.remindedAt, now + 300);

      const answered = await store.answerCheckIns("okay", now + 400);
      assertEquals(answered.length, 2);
      const a1 = answered.find((a) => a.checkIn.followerId === f1.id)!;
      assertEquals(a1.deviceToken, "dddd");
      assertEquals(a1.sandbox, true);
      assertEquals(a1.label, "Declan");
      assertEquals(a1.checkIn.answer, "okay");
      // Nothing left open.
      assertEquals((await store.answerCheckIns("help", now + 401)).length, 0);
      assertEquals((await store.checkIns(now + 402)).map((c) => c.answer), ["okay", "okay"]);
      assertEquals(await store.checkIns(now + 400 + checkInAnswerShownFor), []);

      // A new check-in after an answer is a new row; an unanswered one lapses after an hour.
      const next = await store.askCheckIn(f1, "Sam", now + 500);
      assert(next.ping);
      assert(next.checkIn.id !== first.checkIn.id);
      assertEquals(await store.checkIns(now + 500 + checkInOpenFor), []);

      await sql`update glucos.relay set prefs = prefs || ${sql.json({ deviceToken: "owner", sandbox: true } as never)} where id = 1`;
      const owner = await store.ownerTarget();
      assertEquals(owner.deviceToken, "owner");
      assertEquals(owner.sandbox, true);

      // Unfollowing takes the follower's check-ins with it.
      await store.removeFollower(s.id, "phone-1");
      assertEquals((await sql`select count(*)::int as n from glucos.check_ins where follower_id = ${f1.id}::uuid`)[0].n, 0);
      await sql`delete from glucos.shares`;
      await sql`update glucos.relay set prefs = prefs - 'deviceToken' - 'sandbox' where id = 1`;
    } finally {
      await sql.end();
    }
  },
});
