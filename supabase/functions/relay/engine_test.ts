// The relay's behaviour, with an in-memory store and fake LibreLinkUp and APNs. Ported from the
// Swift relay's tests.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { type PushRequest, type PushResult, type PushSender, importAPNsKey, payloads, providerToken } from "./apns.ts";
import { cardPriority, claimWindow, newRow, type RelayRow, RelayEngine, type Store, type Tx, rotateAfter, startRetry, urgentPushEvery, urgentPushGap } from "./engine.ts";
import type { CardState, Reading, Trend } from "./core.ts";
import type { Account, FetchResult, GlucoseFetcher, LibreSession } from "./libre.ts";
import { parseFactoryTimestamp } from "./libre.ts";
import { handle } from "./index.ts";

class MemoryStore implements Store {
  row: RelayRow = newRow();
  account: Account | null = null;
  session: LibreSession | null = null;
  readings: Reading[] = [];
  lease: string | null = null;
  private leases = 0;
  private queue: Promise<unknown> = Promise.resolve();

  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    const run = async () => {
      const row = structuredClone(this.row);
      const tx: Tx = {
        row,
        account: () => Promise.resolve(this.account),
        setAccount: (a) => { this.account = a; return Promise.resolve(); },
        libreSession: () => Promise.resolve(this.session),
        setLibreSession: (s) => { this.session = s; return Promise.resolve(); },
        readings: (since) => Promise.resolve(this.readings.filter((r) => r.t >= since).sort((a, b) => a.t - b.t)),
        addReadings: (rs) => {
          const m = new Map(this.readings.map((r) => [r.t, r]));
          for (const r of rs) m.set(r.t, r);
          this.readings = [...m.values()];
          return Promise.resolve();
        },
        clearReadings: () => { this.readings = []; return Promise.resolve(); },
        pruneReadings: (before) => { this.readings = this.readings.filter((r) => r.t >= before); return Promise.resolve(); },
        ownsLease: (lease) => Promise.resolve(this.lease === lease),
      };
      const result = await fn(tx);
      this.row = row;
      return result;
    };
    const p = this.queue.then(run, run);
    this.queue = p.catch(() => {});
    return p;
  }

  claimTick() {
    if (this.lease) return Promise.resolve(null);
    this.lease = `lease-${++this.leases}`;
    return Promise.resolve(this.lease);
  }

  releaseTick(lease: string) {
    if (this.lease === lease) this.lease = null;
    return Promise.resolve();
  }
}

class FakeSender implements PushSender {
  sent: PushRequest[] = [];
  results: Record<string, PushResult> = {};
  send(p: PushRequest) {
    this.sent.push(p);
    return Promise.resolve(this.results[p.deviceToken] ?? { kind: "delivered" as const });
  }
}

class FakeFetcher implements GlucoseFetcher {
  mgdl = 120;
  trend: Trend = 3;
  readingAt: number | null = null;
  calls = 0;
  duringFetch: (() => Promise<void>) | null = null;
  constructor(private readonly clock: () => number) {}
  async fetch(_a: Account, s: LibreSession | null) {
    this.calls++;
    if (this.duringFetch) await this.duringFetch();
    const now = this.readingAt ?? this.clock();
    const history: Reading[] = [];
    for (let back = 180; back >= 5; back -= 5) history.push({ t: now - back * 60, mgdl: this.mgdl, trend: 3 });
    const result: FetchResult = { current: { t: now - 30, mgdl: this.mgdl, trend: this.trend }, history, sensor: null };
    return { result, session: s ?? { key: "k", base: "b", token: "t", expires: now + 3600, accountId: "a" } };
  }
}

function setup() {
  let now = 1_790_000_000;
  const clock = () => now;
  const store = new MemoryStore();
  const sender = new FakeSender();
  const fetcher = new FakeFetcher(clock);
  const engine = new RelayEngine(store, sender, fetcher, { bundleId: "au.com.declanmayo.glucos.ios", criticalAlerts: false }, clock);
  const advance = (s: number) => { now += s; };
  return { store, sender, fetcher, engine, advance, clock };
}

async function registered() {
  const t = setup();
  await t.engine.register({
    deviceToken: "device", pushToStartToken: "p2s",
    account: { email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 },
    display: { unit: "mmol", lowMgdl: 70, highMgdl: 180 },
  });
  return t;
}

Deno.test("a low reading sends one alert push, then waits for the cooldown", async () => {
  const t = await registered();
  t.fetcher.mgdl = 62;
  await t.engine.tick();
  const alerts = t.sender.sent.filter((p) => p.type === "alert");
  assertEquals(alerts.length, 1);
  assertEquals(alerts[0].collapseId, "glucos.low");
  assertEquals(alerts[0].priority, 10);
  const aps = alerts[0].payload.aps as Record<string, unknown>;
  assertEquals((aps.alert as Record<string, string>).title, "Low glucose — 3.4 mmol/L");
  t.sender.sent = [];
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.sender.sent.filter((p) => p.type === "alert").length, 0);
});

Deno.test("in range: no alert, and no activity without one", async () => {
  const t = await registered();
  await t.engine.tick();
  assertEquals(t.sender.sent, []);
});

Deno.test("a registered activity gets updates that decode as the card", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.tick();
  const push = t.sender.sent.find((p) => p.type === "liveactivity")!;
  assertEquals(push.deviceToken, "act");
  assertEquals(push.topic, "au.com.declanmayo.glucos.ios");
  const aps = push.payload.aps as Record<string, unknown>;
  assertEquals(aps.event, "update");
  const card = aps["content-state"] as Record<string, unknown>;
  assertEquals(card.mgdl, 120);
  assertEquals(card.source, "relay");
  assertEquals((card.history as unknown[]).length, 37);
  assert(Array.isArray(card.forecast));

  // No new reading a minute later: nothing new to send.
  t.sender.sent = [];
  t.fetcher.readingAt = t.clock();
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.sender.sent, []);
});

Deno.test("the activity is replaced before iOS's 8-hour limit", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.tick();
  t.sender.sent = [];
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  const events = t.sender.sent.map((p) => `${p.deviceToken}:${(p.payload.aps as Record<string, unknown>).event}`);
  assertEquals(events, ["act:end", "p2s:start"]);
  const start = t.sender.sent[1].payload.aps as Record<string, unknown>;
  assertEquals(start["attributes-type"], "GlucoseActivityAttributes");
  assert(start.alert);

  t.sender.sent = [];
  await t.engine.register({ activityID: "A2", activityToken: "act2" });
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.sender.sent.map((p) => p.deviceToken), ["act2"]);
});

Deno.test("a delivered start isn't sent again while the new card's registration is late", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.tick();
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  t.sender.sent = [];
  // Two retry windows pass without the phone registering the card iOS started.
  for (let i = 0; i < 3; i++) {
    t.advance(startRetry + 60);
    await t.engine.tick();
  }
  assertEquals(t.sender.sent.filter((p) => p.deviceToken === "p2s"), []);
});

Deno.test("a start APNs didn't take is tried again", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.tick();
  t.sender.results["p2s"] = { kind: "failed", reason: "500 InternalServerError" };
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  t.sender.results = {};
  t.advance(startRetry + 60);
  await t.engine.tick();
  assertEquals(t.sender.sent.filter((p) => p.deviceToken === "p2s").length, 2);
});

Deno.test("an ended card's late registration doesn't win it back", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A2", activityToken: "act2" });
  // A1's token upload was stuck behind a timeout and lands after A2's. The phone keeps A2, ends
  // A1 and names A2 in the same request: A2 is adopted again, A1 never.
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.register({ endedActivityID: "A1", activityID: "A2", activityToken: "act2" });
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.register({ endedActivityID: "A3" });
  await t.engine.register({ activityID: "A3", activityToken: "act3" });
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.sender.sent.filter((p) => p.type === "liveactivity").map((p) => p.deviceToken), ["act2"]);

  // The card the relay itself ended at the 8-hour limit stays ended too.
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  await t.engine.register({ activityID: "A2", activityToken: "act2" });
  assertEquals((await t.engine.status()).activityID, undefined);
});

Deno.test("a card whose end push failed can be registered again", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.tick();
  t.sender.results["act"] = { kind: "failed", reason: "500 InternalServerError" };
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  assertEquals((await t.engine.status()).activityID, "A1");
});

Deno.test("a dismissed activity isn't restarted", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  await t.engine.register({ endedActivityID: "A1" });
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.sender.sent, []);
});

Deno.test("an invalid device token is forgotten", async () => {
  const t = await registered();
  t.sender.results["device"] = { kind: "tokenInvalid", reason: "Unregistered" };
  t.fetcher.mgdl = 60;
  await t.engine.tick();
  const status = await t.engine.status();
  assertFalse(status.hasDeviceToken);
  assert(status.lastPushError);
});

Deno.test("sign-out forgets the account and its readings", async () => {
  const t = await registered();
  await t.engine.tick();
  const status = await t.engine.register({ signedOut: true });
  assertFalse(status.hasAccount);
  assertEquals(t.store.readings, []);
  assertEquals(await t.engine.tick(), "no account");
});

Deno.test("a sign-out during a fetch discards that fetch's readings", async () => {
  const t = await registered();
  t.fetcher.mgdl = 62;
  t.fetcher.duringFetch = async () => { await t.engine.register({ signedOut: true }); };
  assertEquals(await t.engine.tick(), "account changed");
  const status = await t.engine.status();
  assertFalse(status.hasAccount);
  assertEquals(status.lastReadingAt, undefined);
  assertEquals(t.store.readings, []);
  assertEquals(t.sender.sent.filter((p) => p.type === "alert"), []);
});

Deno.test("status says the relay is delivering once it has fetched", async () => {
  const t = await registered();
  await t.engine.tick();
  const s = await t.engine.status();
  assert(s.hasAccount && s.hasDeviceToken && s.alertsEnabled);
  assertEquals(s.lastFetchAt, t.clock());
  assertEquals(s.lastError, undefined);
  assertEquals(s.version, "2.2.0");
});

Deno.test("the LibreLinkUp session is kept between ticks", async () => {
  const t = await registered();
  await t.engine.tick();
  assert(t.store.session);
  const first = t.store.session;
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.store.session, first);
});

Deno.test("only one tick runs at a time", async () => {
  const t = await registered();
  t.store.lease = "someone else's";
  assertEquals(await t.engine.tick(), "busy");
  assertEquals(t.fetcher.calls, 0);
});

Deno.test("provider token is a valid ES256 JWT", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  // Secrets often arrive with literal "\n" in place of newlines.
  const key = await importAPNsKey(pem.replaceAll("\n", "\\n"));
  const token = await providerToken(key, "KEY123", "TEAM456", 1_790_000_000);
  const [h, c, s] = token.split(".");
  const dec = (x: string) => Uint8Array.from(atob(x.replaceAll("-", "+").replaceAll("_", "/") + "==".slice(0, (4 - x.length % 4) % 4)), (ch) => ch.charCodeAt(0));
  assertEquals(JSON.parse(new TextDecoder().decode(dec(h))), { alg: "ES256", kid: "KEY123" });
  assertEquals(JSON.parse(new TextDecoder().decode(dec(c))), { iss: "TEAM456", iat: 1_790_000_000 });
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, dec(s), new TextEncoder().encode(`${h}.${c}`)));
});

Deno.test("critical sound only when entitled", () => {
  const n = { kind: "urgentLow" as const, title: "URGENT LOW", body: "Treat now", critical: true };
  const plain = payloads.alert(n, false).aps as Record<string, unknown>;
  assertEquals(plain.sound, "default");
  assertEquals(plain["interruption-level"], "time-sensitive");
  assertEquals((payloads.alert(n, true).aps as Record<string, unknown>)["interruption-level"], "critical");
});

Deno.test("LibreLinkUp timestamps are read as UTC", () => {
  assertEquals(parseFactoryTimestamp("11/11/2026 1:05:09 PM"), Date.UTC(2026, 10, 11, 13, 5, 9) / 1000);
  assertEquals(parseFactoryTimestamp("1/2/2026 12:00:00 AM"), Date.UTC(2026, 0, 2, 0, 0, 0) / 1000);
  assertEquals(parseFactoryTimestamp("1/2/2026 12:30:00 PM"), Date.UTC(2026, 0, 2, 12, 30, 0) / 1000);
  assertEquals(parseFactoryTimestamp("nonsense"), null);
});

Deno.test("health needs no secret; everything else does", async () => {
  const ok = await handle(new Request("https://x.supabase.co/relay/health"));
  assertEquals(await ok.text(), "ok");
  Deno.env.set("RELAY_SECRET", "s3cret");
  const denied = await handle(new Request("https://x.supabase.co/relay/v1/status"));
  assertEquals(denied.status, 401);
  await denied.body?.cancel();
});

Deno.test("a tick that overran its lease leaves the newer tick's state alone", async () => {
  const t = await registered();
  t.fetcher.mgdl = 62;
  // While this tick waits on LibreLinkUp its lease lapses and another tick claims the relay.
  t.fetcher.duringFetch = () => { t.store.lease = "a later tick"; return Promise.resolve(); };
  assertEquals(await t.engine.tick(), "superseded");
  assertEquals(t.store.lease, "a later tick");
  assertEquals(t.sender.sent, []);
  assertEquals((await t.engine.status()).lastReadingAt, undefined);
});

Deno.test("the owner's LibreLinkUp login claims the secret; wrong tries are limited", async () => {
  const t = await registered();
  assertEquals(await t.engine.claim("A@B.C ", "x"), "ok");
  assertEquals(await t.engine.claim("a@b.c", "wrong"), "denied");
  assertEquals(await t.engine.claim("someone@else.com", "x"), "denied");
  assertEquals(await t.engine.claim(undefined, null), "denied");
  assertEquals(await t.engine.claim("a@b.c", "w"), "denied");
  assertEquals(await t.engine.claim("a@b.c", "w"), "denied");
  // Five wrong: locked, even with the right password.
  assertEquals(await t.engine.claim("a@b.c", "x"), "locked");
  t.advance(claimWindow);
  assertEquals(await t.engine.claim("a@b.c", "x"), "ok");
  assertEquals(t.store.row.work.claimFailures, null);
});

Deno.test("a relay without an account can't be claimed", async () => {
  const t = setup();
  assertEquals(await t.engine.claim("a@b.c", "x"), "no account");
});

// MARK: - Live Activity push priority (docs/Redesign.md §6.4)

const cardOf = (mgdl: number, trend = 3, readingAt = 1_000_000): CardState => ({
  mgdl, trend, readingAt, unit: "mmol", lowMgdl: 70, highMgdl: 180, history: [mgdl], forecast: [], source: "relay",
});

Deno.test("priority: the first card, an alert, a range change and out of range send now", () => {
  const now = 2_000_000;
  assertEquals(cardPriority(cardOf(110), null, null, false, now), 10);
  assertEquals(cardPriority(cardOf(110), cardOf(110), now - 30, true, now), 10);
  assertEquals(cardPriority(cardOf(185), cardOf(175), now - 30, false, now), 10);
  assertEquals(cardPriority(cardOf(200), cardOf(199), now - 30, false, now), 10);
  assertEquals(cardPriority(cardOf(65), cardOf(64), now - 30, false, now), 10);
});

Deno.test("priority: in range, a visible change sends now once the last urgent push is old enough", () => {
  const now = 2_000_000;
  // 6.1 → 6.3 mmol/L: visible.
  assertEquals(cardPriority(cardOf(114), cardOf(110), now - urgentPushGap, false, now), 10);
  assertEquals(cardPriority(cardOf(114), cardOf(110), now - urgentPushGap + 1, false, now), 5);
  // A trend change is visible too.
  assertEquals(cardPriority(cardOf(110, 4), cardOf(110, 3), now - urgentPushGap, false, now), 10);
});

Deno.test("priority: in range, an invisible change waits, but never past urgentPushEvery", () => {
  const now = 2_000_000;
  // 108 and 109 mg/dL are both 6.0 mmol/L.
  assertEquals(cardPriority(cardOf(109, 3, 1_000_060), cardOf(108), now - urgentPushGap, false, now), 5);
  assertEquals(cardPriority(cardOf(109, 3, 1_000_060), cardOf(108), now - urgentPushEvery, false, now), 10);
});

Deno.test("an in-range card is pushed at priority 10 at least every few minutes", async () => {
  const t = await registered();
  await t.engine.register({ activityID: "A1", activityToken: "act" });
  t.fetcher.mgdl = 110;
  await t.engine.tick();
  const priorities: number[] = [];
  for (let i = 0; i < 8; i++) {
    t.sender.sent = [];
    t.advance(60);
    t.fetcher.mgdl = 108 + (i % 2); // 6.0 mmol/L either way: nothing visible changes
    await t.engine.tick();
    const update = t.sender.sent.find((p) => p.type === "liveactivity");
    if (update) priorities.push(update.priority);
  }
  assert(priorities.length >= 7, `pushed ${priorities.length} times`);
  assert(priorities.includes(10), "never sent at priority 10");
  assert(priorities.includes(5), "never let iOS batch an invisible change");
  // Never three minutes of priority 5 in a row.
  assertFalse(priorities.join("").includes("555"), priorities.join(","));
});
