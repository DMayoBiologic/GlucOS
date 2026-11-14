// Check-ins: a follower asks, the owner answers (or doesn't), and both Lock Screen cards follow.
// An in-memory store and fake APNs, like sharing_test.ts; checkins_pg_test.ts runs Postgres.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { PushRequest, PushSender } from "./apns.ts";
import { checkInAnswerShownFor, checkInOpenFor, checkInPingGap, checkInRemindAfter, cleanName } from "./checkins.ts";
import { newRow, RelayEngine, type RelayRow, type Store, type Tx } from "./engine.ts";
import type { Reading } from "./core.ts";
import type { Account, GlucoseFetcher, LibreSession } from "./libre.ts";
import { MemoryShareStore } from "./sharing.ts";
import { handle as shareHandle } from "../share/index.ts";

class MemoryStore implements Store {
  row: RelayRow = newRow();
  account: Account | null = null;
  readings: Reading[] = [];
  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    const tx: Tx = {
      row: this.row,
      account: () => Promise.resolve(this.account),
      setAccount: (a) => { this.account = a; return Promise.resolve(); },
      libreSession: () => Promise.resolve(null),
      setLibreSession: () => Promise.resolve(),
      readings: (since) => Promise.resolve(this.readings.filter((r) => r.t >= since).sort((a, b) => a.t - b.t)),
      addReadings: (rs) => {
        const m = new Map(this.readings.map((r) => [r.t, r]));
        for (const r of rs) m.set(r.t, r);
        this.readings = [...m.values()];
        return Promise.resolve();
      },
      clearReadings: () => { this.readings = []; return Promise.resolve(); },
      pruneReadings: () => Promise.resolve(),
      ownsLease: () => Promise.resolve(true),
    };
    return fn(tx);
  }
  claimTick() { return Promise.resolve("l"); }
  releaseTick() { return Promise.resolve(); }
}

const followerPhone = "abcdef0123456789";
const followerCard = "0123456789abcdef";
const ownerPhone = "00ee00ee00ee00ee";
const ownerCard = "11aa11aa11aa11aa";

async function setup() {
  let now = 1_790_000_000;
  const clock = () => now;
  const store = new MemoryStore();
  const shares = new MemoryShareStore();
  shares.latestCard = () => Promise.resolve(store.row.work.latestCard);
  // In Postgres this reads the relay row.
  shares.ownerTarget = () => Promise.resolve({
    deviceToken: store.row.prefs.deviceToken ?? null, sandbox: store.row.prefs.sandbox,
    card: store.row.work.latestCard?.card ?? null,
  });
  const sent: PushRequest[] = [];
  const sender: PushSender = { send: (p) => { sent.push(p); return Promise.resolve({ kind: "delivered" }); } };
  let mgdl = 62;
  const fetcher: GlucoseFetcher = {
    fetch: (_a: Account, s: LibreSession | null) => {
      const history: Reading[] = [];
      for (let back = 60; back >= 5; back -= 5) history.push({ t: now - back * 60, mgdl, trend: 3 });
      return Promise.resolve({
        result: { current: { t: now - 30, mgdl, trend: 3 }, history, sensor: null },
        session: s ?? { key: "k", base: "b", token: "t", expires: now + 3600, accountId: "a" },
      });
    },
  };
  const engine = new RelayEngine(store, sender, fetcher, { bundleId: "app", criticalAlerts: true, shares }, clock);
  store.account = { email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 };
  await engine.register({ deviceToken: ownerPhone, activityID: "O1", activityToken: ownerCard });
  const { token } = await engine.createShare({ label: "Declan" });
  const t = {
    engine, shares, sent, clock, token,
    advance: (s: number) => { now += s; },
    setMgdl: (v: number) => { mgdl = v; },
    share: (path: string, body?: unknown) =>
      shareHandle(new Request(`https://x.supabase.co/share${path}`, {
        method: body === undefined ? "GET" : "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      }), () => shares, clock, () => sender),
    /// The pushes to one token, newest last.
    to: (deviceToken: string) => sent.filter((p) => p.deviceToken === deviceToken),
  };
  const res = await t.share("/v1/follow", {
    installation: "phone-1234", activityID: "F1", activityToken: followerCard, deviceToken: followerPhone,
  });
  assertEquals(res.status, 200);
  await res.body?.cancel();
  return t;
}

type Aps = Record<string, unknown> & { alert?: { title: string; body: string } };
const aps = (p: PushRequest) => p.payload.aps as Aps;
const contentCheckIn = (p: PushRequest | undefined) =>
  ((aps(p!)["content-state"] ?? {}) as Record<string, unknown>).checkIn as Record<string, unknown> | undefined;
const lastCard = (t: Awaited<ReturnType<typeof setup>>, token: string) =>
  t.to(token).filter((p) => p.type === "liveactivity").at(-1);

Deno.test("check-in: the owner is asked at once, both cards show it, and the answer goes back", async () => {
  const t = await setup();
  await t.engine.tick();
  t.sent.length = 0;

  const res = await t.share("/v1/checkin", { installation: "phone-1234", name: "  Sam\n" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "asked", askedAt: t.clock() });
  // The owner hears straight away, not on the next tick, with the reading and the two buttons.
  const ask = t.to(ownerPhone);
  assertEquals(ask.length, 1);
  assertEquals(aps(ask[0]).category, "glucos.checkin");
  assertEquals(aps(ask[0])["interruption-level"], "time-sensitive");
  assertEquals(aps(ask[0]).alert?.title, "Sam checking in");
  assert(aps(ask[0]).alert?.body.includes("3.4 mmol/L"));

  // The follower app's own refresh keeps the check-in on its card.
  const snap = await (await t.share("/v1/snapshot?installation=phone-1234")).json();
  assertEquals(snap.checkIn, { status: "asked", askedAt: t.clock() });
  assertEquals((await (await t.share("/v1/snapshot")).json()).checkIn, undefined);

  const askedAt = t.clock();
  t.advance(60);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(contentCheckIn(lastCard(t, ownerCard)), { status: "asked", askedAt, count: 1, who: "Sam" });
  assertEquals(lastCard(t, ownerCard)!.priority, 10);
  assertEquals(contentCheckIn(lastCard(t, followerCard)), { status: "asked", askedAt });
  assertEquals((await t.engine.status()).checkIn, { status: "asked", askedAt, count: 1, who: "Sam" });

  t.advance(60);
  t.sent.length = 0;
  const status = await t.engine.answerCheckIns("okay");
  assertEquals(status.checkIn, undefined);
  const reply = t.to(followerPhone);
  assertEquals(reply.length, 1);
  assertEquals(aps(reply[0]).alert?.title, "Declan is okay");
  assertEquals(aps(reply[0])["interruption-level"], "active");

  t.sent.length = 0;
  t.advance(60);
  await t.engine.tick();
  assertEquals(contentCheckIn(lastCard(t, followerCard)), { status: "okay", askedAt, answeredAt: askedAt + 120 });
  assertEquals(contentCheckIn(lastCard(t, ownerCard)), undefined);
  assertEquals(lastCard(t, followerCard)!.priority, 10);

  // The answer comes off the follower's card after a while.
  t.advance(checkInAnswerShownFor);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(contentCheckIn(lastCard(t, followerCard)), undefined);
  assert(lastCard(t, followerCard));
});

Deno.test("check-in: no answer reminds the owner (critical) and tells the follower, once", async () => {
  const t = await setup();
  await t.engine.tick();
  (await t.share("/v1/checkin", { installation: "phone-1234", name: "Sam" })).body?.cancel();
  const askedAt = t.clock();
  t.advance(checkInRemindAfter);
  t.sent.length = 0;
  await t.engine.tick();
  const reminder = t.to(ownerPhone).filter((p) => p.type === "alert" && aps(p).category === "glucos.checkin");
  assertEquals(reminder.length, 1);
  assertEquals(aps(reminder[0]).alert?.title, "Sam still waiting");
  assertEquals(aps(reminder[0])["interruption-level"], "critical");
  const told = t.to(followerPhone);
  assertEquals(told.length, 1);
  assertEquals(aps(told[0]).alert?.title, "No answer from Declan");
  assertEquals(contentCheckIn(lastCard(t, followerCard)), { status: "noAnswer", askedAt });
  assertEquals(contentCheckIn(lastCard(t, ownerCard))?.status, "noAnswer");

  t.advance(60);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(t.sent.filter((p) => p.type === "alert" && String(aps(p).alert?.title).includes("waiting")), []);
  assertEquals(t.to(followerPhone), []);

  // "I need help" reaches the follower loudly.
  t.sent.length = 0;
  await t.engine.answerCheckIns("help");
  const help = t.to(followerPhone)[0];
  assertEquals(aps(help).alert?.title, "Declan needs help");
  assertEquals(aps(help)["interruption-level"], "critical");
});

Deno.test("check-in: tapping again re-notifies at most every 2 minutes; it gives up after an hour", async () => {
  const t = await setup();
  await t.engine.tick();
  t.sent.length = 0;
  (await t.share("/v1/checkin", { installation: "phone-1234" })).body?.cancel();
  (await t.share("/v1/checkin", { installation: "phone-1234" })).body?.cancel();
  assertEquals(t.to(ownerPhone).length, 1);
  assertEquals(aps(t.to(ownerPhone)[0]).alert?.title, "Someone who follows you checking in");
  t.advance(checkInPingGap);
  (await t.share("/v1/checkin", { installation: "phone-1234", name: "Sam" })).body?.cancel();
  assertEquals(t.to(ownerPhone).length, 2);
  assertEquals(t.shares.checkInRows.length, 1);
  assertEquals(t.shares.checkInRows[0].name, "Sam");

  t.advance(checkInOpenFor);
  assertEquals((await t.engine.status()).checkIn, undefined);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(contentCheckIn(lastCard(t, followerCard)), undefined);
  // Nothing left to answer.
  t.sent.length = 0;
  await t.engine.answerCheckIns("okay");
  assertEquals(t.to(followerPhone), []);
});

Deno.test("check-in: only a follower can ask", async () => {
  const t = await setup();
  const res = await t.share("/v1/checkin", { installation: "phone-9999" });
  assertEquals(res.status, 409);
  await res.body?.cancel();
  const bad = await t.share("/v1/checkin", { installation: "x" });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  assertEquals(t.to(ownerPhone), []);
});

Deno.test("check-in: a follower's low alert has a Check in button", async () => {
  const t = await setup();
  t.setMgdl(120);
  await t.engine.tick();
  t.advance(300);
  t.setMgdl(50);
  t.sent.length = 0;
  await t.engine.tick();
  const lows = t.to(followerPhone).filter((p) => p.type === "alert");
  assert(lows.length > 0);
  assert(lows.every((p) => aps(p).category === "glucos.follow.low"));
});

Deno.test("check-in names are tidied", () => {
  assertEquals(cleanName("  Sam\u0007 "), "Sam");
  assertEquals(cleanName(42), "");
  assertEquals([...cleanName("x".repeat(80))].length, 30);
});
