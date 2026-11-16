// Check-ins: a follower asks, the owner answers (or doesn't), and both Lock Screen cards follow.
// An in-memory store and fake APNs, like sharing_test.ts; checkins_pg_test.ts runs Postgres.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { PushRequest, PushSender } from "./apns.ts";
import { checkInAnswerShownFor, checkInOpenFor, checkInPingGap, checkInRemindAfter, cleanName } from "./checkins.ts";
import { newRow, RelayEngine, type RelayRow, type Store, type Tx } from "./engine.ts";
import { type AlertSnoozes, alertCategory, type CardState, cardSnooze, type Reading, silences, snoozeAlert } from "./core.ts";
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
      hasAccount: () => Promise.resolve(this.account !== null),
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

Deno.test("check-in: no answer tells everyone else following too, and then they hear the answer", async () => {
  const t = await setup();
  const otherPhone = "99ff99ff99ff99ff";
  const quietPhone = "77cc77cc77cc77cc";
  for (const [installation, deviceToken, alerts] of [["phone-5678", otherPhone, true], ["phone-9999", quietPhone, false]] as const) {
    const res = await t.share("/v1/follow", { installation, deviceToken, alertsEnabled: alerts });
    assertEquals(res.status, 200);
    await res.body?.cancel();
  }
  await t.engine.tick();
  (await t.share("/v1/checkin", { installation: "phone-1234", name: "Sam" })).body?.cancel();

  // Before the 5 minutes, nobody else hears anything.
  t.advance(60);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(t.to(otherPhone).filter((p) => p.type === "alert"), []);

  t.advance(checkInRemindAfter);
  t.sent.length = 0;
  await t.engine.tick();
  const told = t.to(otherPhone).filter((p) => p.type === "alert");
  assertEquals(told.length, 1);
  assertEquals(aps(told[0]).alert?.title, "No answer from Declan");
  assertEquals(aps(told[0]).alert?.body, "Sam checked in on Declan 5 minutes ago and hasn't heard back. If you can, call them.");
  // With a Check in button of their own.
  assertEquals(aps(told[0]).category, "glucos.follow.low");
  // The one who asked gets their own wording, once; a follower with alerts off isn't told.
  const asker = t.to(followerPhone).filter((p) => p.type === "alert");
  assertEquals(asker.length, 1);
  assert(aps(asker[0]).alert?.body.includes("your check-in"));
  assertEquals(t.to(quietPhone).filter((p) => p.type === "alert"), []);

  // Once only.
  t.advance(60);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(t.to(otherPhone).filter((p) => p.type === "alert"), []);

  t.sent.length = 0;
  await t.engine.answerCheckIns("okay");
  assertEquals(aps(t.to(followerPhone)[0]).alert?.title, "Declan is okay");
  const relief = t.to(otherPhone);
  assertEquals(relief.length, 1);
  assertEquals(aps(relief[0]).alert?.title, "Declan is okay");
  assertEquals(aps(relief[0]).alert?.body, "Declan answered the check-in you heard about.");
  assertEquals(t.to(quietPhone), []);
});

Deno.test("check-in: an answer within 5 minutes only goes to whoever asked", async () => {
  const t = await setup();
  const otherPhone = "99ff99ff99ff99ff";
  (await t.share("/v1/follow", { installation: "phone-5678", deviceToken: otherPhone, alertsEnabled: true })).body?.cancel();
  await t.engine.tick();
  (await t.share("/v1/checkin", { installation: "phone-1234", name: "Sam" })).body?.cancel();
  t.advance(120);
  t.sent.length = 0;
  await t.engine.answerCheckIns("help");
  assertEquals(t.to(followerPhone).length, 1);
  assertEquals(t.to(otherPhone), []);
});

// MARK: - Snooze and "I'm treating it" (docs/AlertActions.md)

Deno.test("snooze: the rules match AlertSnooze.swift", () => {
  const now = 1_000_000;
  const s: AlertSnoozes = {};
  // Urgent lows are never snoozable.
  assertEquals(snoozeAlert(s, "urgentLow", 30, now), false);
  assertEquals(snoozeAlert(s, "predictedUrgentLow", 30, now), false);
  assertEquals(snoozeAlert(s, "stale", 30, now), false);
  assertEquals(s, {});
  assert(snoozeAlert(s, "low", 30, now));
  assert(silences(s, "low", now + 1799));
  assert(silences(s, "predictedLow", now + 60));
  assert(!silences(s, "low", now + 1800));
  assert(!silences(s, "urgentLow", now + 60));
  assert(!silences(s, "predictedUrgentLow", now + 60));
  // A high snooze lets a very high through; a very high snooze quiets highs too.
  assert(snoozeAlert(s, "high", 30, now));
  assert(silences(s, "predictedHigh", now + 60));
  assert(!silences(s, "veryHigh", now + 60));
  const v: AlertSnoozes = {};
  snoozeAlert(v, "predictedVeryHigh", 30, now);
  assert(silences(v, "veryHigh", now + 60) && silences(v, "high", now + 60));
  assert(!silences(v, "low", now + 60));
  // Capped at an hour, and a shorter snooze never cuts a longer one.
  const c: AlertSnoozes = {};
  snoozeAlert(c, "low", 600, now);
  assertEquals(c.low, now + 3600);
  snoozeAlert(c, "low", 15, now);
  assertEquals(c.low, now + 3600);
  // Buttons: snooze and treat, urgent lows treat only, the rest none.
  assertEquals(alertCategory("low"), "glucos.alert");
  assertEquals(alertCategory("veryHigh"), "glucos.alert");
  assertEquals(alertCategory("urgentLow"), "glucos.alert.urgent");
  assertEquals(alertCategory("predictedUrgentLow"), "glucos.alert.urgent");
  assertEquals(alertCategory("rapidChange"), null);
  assertEquals(alertCategory("stale"), null);
});

/// A low that lasts 40 minutes, ticking every minute; the owner snoozes it after the first tick
/// when `snooze` is set. Returns the pushes.
async function longLow(snooze: boolean) {
  const t = await setup();
  t.setMgdl(120);
  await t.engine.tick();
  t.advance(60);
  t.setMgdl(62);
  t.sent.length = 0;
  await t.engine.tick();
  if (snooze) {
    const r = await t.engine.snoozeAlerts("low", 30);
    assert(r !== "not snoozable");
  }
  const start = t.clock();
  for (let i = 0; i < 40; i++) {
    t.advance(60);
    await t.engine.tick();
  }
  const alerts = (token: string) =>
    t.to(token).filter((p) => p.type === "alert" && (p.collapseId === "glucos.low" || p.collapseId?.startsWith("glucos.low.")));
  return { t, start, owner: alerts(ownerPhone), follower: alerts(followerPhone) };
}

Deno.test("snooze: the owner's low pushes stop for 30 minutes, then come straight back", async () => {
  const plain = await longLow(false);
  const quiet = await longLow(true);
  // Without a snooze: the first one and every 15 minutes.
  assertEquals(plain.owner.length, 3);
  // Snoozed: the first one, nothing for 30 minutes, then the very first tick after it.
  assertEquals(quiet.owner.length, 2);
  assertEquals(aps(quiet.owner[0]).category, "glucos.alert");
  // The second went out at the tick where the snooze ended (30 min), not a repeat timer later (45).
  // (An alert push expires 15 minutes after it's sent.)
  assertEquals(quiet.owner[1].expiration! - 15 * 60, quiet.start + 30 * 60);
});

Deno.test("snooze: followers get every low alert exactly as without a snooze", async () => {
  const plain = await longLow(false);
  const quiet = await longLow(true);
  assert(plain.follower.length > 0);
  assertEquals(quiet.follower.length, plain.follower.length);
  assert(quiet.follower.every((p) => aps(p).category === "glucos.follow.low"));
});

Deno.test("snooze: the owner's status carries the running snoozes, and resume ends them", async () => {
  const t = await setup();
  t.setMgdl(62);
  await t.engine.tick();
  assertEquals((await t.engine.status()).snoozes, {});
  const snoozed = await t.engine.snoozeAlerts("low", 30);
  assert(snoozed !== "not snoozable");
  assertEquals(snoozed.snoozes, { low: t.clock() + 30 * 60 });
  assertEquals((await t.engine.status()).snoozes, { low: t.clock() + 30 * 60 });
  // Ended snoozes drop out of the status even before a tick prunes them.
  t.advance(30 * 60);
  assertEquals((await t.engine.status()).snoozes, {});
  // Resume: the still-due low is pushed on the very next tick, not 30 minutes later.
  await t.engine.snoozeAlerts("low", 30);
  t.advance(60);
  t.sent.length = 0;
  await t.engine.tick();
  const lows = () => t.to(ownerPhone).filter((p) => p.type === "alert" && p.collapseId?.startsWith("glucos.low"));
  assertEquals(lows().length, 0);
  assertEquals((await t.engine.resumeAlerts()).snoozes, {});
  t.advance(60);
  await t.engine.tick();
  assertEquals(lows().length, 1);
});

Deno.test("snooze: an urgent low always gets through, and can't be snoozed", async () => {
  const t = await setup();
  t.setMgdl(62);
  await t.engine.tick();
  await t.engine.snoozeAlerts("low", 30);
  assertEquals(await t.engine.snoozeAlerts("urgentLow", 30), "not snoozable");
  assertEquals(await t.engine.snoozeAlerts("predictedUrgentLow", 30), "not snoozable");
  t.advance(60);
  t.setMgdl(50);
  t.sent.length = 0;
  await t.engine.tick();
  const urgent = t.to(ownerPhone).filter((p) => p.type === "alert" && p.collapseId === "glucos.urgentLow");
  assertEquals(urgent.length, 1);
  assertEquals(aps(urgent[0]).category, "glucos.alert.urgent");
});

Deno.test("snooze: a follower's check-in still reaches the owner, and its reminder too", async () => {
  const t = await setup();
  await t.engine.tick();
  await t.engine.snoozeAlerts("low", 30);
  t.sent.length = 0;
  (await t.share("/v1/checkin", { installation: "phone-1234", name: "Sam" })).body?.cancel();
  assertEquals(t.to(ownerPhone).filter((p) => p.collapseId === "glucos.checkin").length, 1);
  for (let i = 0; i < 6; i++) {
    t.advance(60);
    await t.engine.tick();
  }
  // Asked once, reminded once at 5 minutes, both to the owner; the follower told too.
  assertEquals(t.to(ownerPhone).filter((p) => p.collapseId === "glucos.checkin").length, 2);
  assert(t.to(followerPhone).some((p) => p.type === "alert" && aps(p).alert?.body.includes("your check-in")));
});

Deno.test("snooze: followers' high alerts carry none of the owner's buttons", async () => {
  const t = await setup();
  t.setMgdl(200);
  t.sent.length = 0;
  await t.engine.tick();
  const owner = t.to(ownerPhone).filter((p) => p.collapseId === "glucos.high");
  const follower = t.to(followerPhone).filter((p) => p.type === "alert" && p.collapseId?.includes("high"));
  assertEquals(owner.length, 1);
  assertEquals(aps(owner[0]).category, "glucos.alert");
  assert(follower.length > 0);
  assert(follower.every((p) => aps(p).category === undefined));
});

// MARK: - The snooze on the Lock Screen card (docs/AlertActions.md, "Snoozed on the Lock Screen")

Deno.test("snooze: the card's badge matches AlertSnoozes.badge in AlertSnooze.swift", () => {
  const now = 1_000_000;
  assertEquals(cardSnooze({}, now), undefined);
  assertEquals(cardSnooze(null, now), undefined);
  // Ended snoozes don't count.
  assertEquals(cardSnooze({ low: now }, now), undefined);
  assertEquals(cardSnooze({ low: now + 600 }, now), { until: now + 600, levels: ["low"] });
  // Soonest first; the badge names the last end.
  assertEquals(cardSnooze({ low: now + 1800, high: now + 600 }, now), { until: now + 1800, levels: ["high", "low"] });
  // A very-high snooze covers a high one ending no later, but not one that outlasts it.
  assertEquals(cardSnooze({ high: now + 600, veryHigh: now + 1200 }, now), { until: now + 1200, levels: ["veryHigh"] });
  assertEquals(cardSnooze({ high: now + 1800, veryHigh: now + 1200 }, now),
    { until: now + 1800, levels: ["veryHigh", "high"] });
});

/// The snooze on the last card pushed to `token`, and whether there was a card at all.
function cardSnoozeOn(t: Awaited<ReturnType<typeof setup>>, token: string) {
  const p = lastCard(t, token);
  assert(p, "no card pushed");
  return (aps(p)["content-state"] as CardState).snooze;
}

Deno.test("snooze: the owner's card shows it until it ends; followers' cards never do", async () => {
  const t = await setup();
  t.setMgdl(62);
  await t.engine.tick();
  assertEquals(cardSnoozeOn(t, ownerCard), undefined);
  await t.engine.snoozeAlerts("low", 30);
  const until = t.clock() + 30 * 60;
  t.sent.length = 0;
  t.advance(60);
  await t.engine.tick();
  // The card changed, so it's pushed on this tick rather than on the refresh timer.
  assertEquals(cardSnoozeOn(t, ownerCard), { until, levels: ["low"] });
  assertEquals(cardSnoozeOn(t, followerCard), undefined);
  for (let i = 0; i < 30; i++) {
    t.advance(60);
    await t.engine.tick();
  }
  assert(t.to(followerCard).every((p) => (aps(p)["content-state"] as CardState | undefined)?.snooze === undefined));
  // Past the end: the owner's next card has no snooze.
  assertEquals(cardSnoozeOn(t, ownerCard), undefined);
  // Resume takes it off on the next tick too.
  await t.engine.snoozeAlerts("low", 30);
  t.advance(60);
  await t.engine.tick();
  assert(cardSnoozeOn(t, ownerCard));
  await t.engine.resumeAlerts();
  t.advance(60);
  await t.engine.tick();
  assertEquals(cardSnoozeOn(t, ownerCard), undefined);
});
