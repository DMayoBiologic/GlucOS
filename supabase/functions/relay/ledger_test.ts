// The relay's forecast ledger: which forecasts it keeps, and how a tick uses it.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import {
  type Calibration, type Forecast, forecast, type LivePoint, rangeFactor, type RangeScale, rangeScaleFrom, rangeWindow, type Reading,
  Series, type ShownForecast, standardTuning,
} from "./core.ts";
import { type ForecastLedger, type LedgerRecord, ledgerRecord, ledgerScoreEvery, ledgerSpacing } from "./ledger.ts";
import { newRow, type RelayRow, RelayEngine, type Store, type Tx } from "./engine.ts";
import { type Account, LibreLinkUpFetcher, type LibreSession } from "./libre.ts";

const t0 = 1_790_000_000;

function trendForecast(issuedAt = t0, minutes = 30): Forecast {
  const samples = [];
  for (let m = 0; m <= minutes; m += 5) {
    samples.push({ t: issuedAt + m * 60, mgdl: 120 + m, lowerMgdl: 110 + m, upperMgdl: 130 + m });
  }
  return { issuedAt, startMgdl: 120, basis: "trend", trendPerMinute: 1, samples };
}

Deno.test("a record keeps the checked horizons the forecast reaches", () => {
  const r = ledgerRecord(trendForecast(), null, null, "id")!;
  assertEquals(r.points, [
    { minutes: 15, mgdl: 135, lower: 125, upper: 145 },
    { minutes: 30, mgdl: 150, lower: 140, upper: 160 },
  ]);
  assertEquals(r.startMgdl, 120);
  assertFalse(r.calibrated);
  assertFalse(r.tuned);
});

Deno.test("one record per 15 minutes, and none short of the first horizon", () => {
  assertEquals(ledgerRecord(trendForecast(t0 + ledgerSpacing - 60), null, t0), null);
  assert(ledgerRecord(trendForecast(t0 + ledgerSpacing), null, t0));
  assertEquals(ledgerRecord(trendForecast(t0, 10), null, null), null);
});

Deno.test("calibrated and tuned follow the calibration", () => {
  const stats = (samples: number) => [{ minutes: 15, samples, meanAbsoluteError: 8, naiveError: 10, bias: 0, lower: -10, upper: 10 }];
  const cal = (samples: number, tuning = standardTuning): Calibration => ({ trend: stats(samples), origins: 50, computedAt: t0, tuning });
  assertFalse(ledgerRecord(trendForecast(), cal(10), null)!.calibrated);
  assert(ledgerRecord(trendForecast(), cal(40), null)!.calibrated);
  assertFalse(ledgerRecord(trendForecast(), cal(40), null)!.tuned);
  assert(ledgerRecord(trendForecast(), cal(40, { ...standardTuning, trendGain: 0.6 }), null)!.tuned);
});

// MARK: In a tick

class FakeLedger implements ForecastLedger {
  owners: Record<string, string> = { "llu-1": "user-1" };
  lookups = 0;
  records: { owner: string; r: LedgerRecord }[] = [];
  scores = 0;
  fail = false;
  owner(id: string) {
    this.lookups++;
    return Promise.resolve(this.owners[id] ?? null);
  }
  record(owner: string, r: LedgerRecord) {
    if (this.fail) return Promise.reject(new Error("db down"));
    this.records.push({ owner, r });
    return Promise.resolve(true);
  }
  score() {
    this.scores++;
    return Promise.resolve(0);
  }
  shownSince: number[] = [];
  shownForecasts: ShownForecast[] = [];
  shown(_owner: string, since: number) {
    this.shownSince.push(since);
    return Promise.resolve(this.shownForecasts);
  }
  points: LivePoint[] = [];
  livePoints() {
    return Promise.resolve(this.points);
  }
}

class Memory implements Store {
  row: RelayRow = newRow();
  account: Account | null = { email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 };
  session: LibreSession | null = null;
  readings: Reading[] = [];
  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    const row = structuredClone(this.row);
    const tx: Tx = {
      row,
      account: () => Promise.resolve(this.account),
      hasAccount: () => Promise.resolve(this.account !== null),
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
      pruneReadings: () => Promise.resolve(),
      ownsLease: () => Promise.resolve(true),
    };
    return fn(tx).then((v) => { this.row = row; return v; });
  }
  claimTick() { return Promise.resolve("lease"); }
  releaseTick() { return Promise.resolve(); }
}

function ticking(userId: string | undefined) {
  let now = t0;
  const store = new Memory();
  const ledger = new FakeLedger();
  const fetcher = {
    fetch(_a: Account, s: LibreSession | null) {
      // A gently rising minute-by-minute history, so there's always a trend to forecast.
      const history: Reading[] = [];
      for (let back = 60; back >= 1; back--) history.push({ t: now - back * 60, mgdl: 120 + (60 - back) * 0.5, trend: 3 });
      return Promise.resolve({
        result: { current: { t: now - 20, mgdl: 150, trend: 3 as const }, history, sensor: null },
        session: s ?? { key: "k", base: "b", token: "t", expires: now + 86_400, accountId: "a", userId },
      });
    },
  };
  const engine = new RelayEngine(store, null, fetcher, { bundleId: "x", criticalAlerts: false, ledger }, () => now);
  return { store, ledger, engine, advance: (s: number) => { now += s; } };
}

Deno.test("ticks keep one forecast per 15 minutes for the owner, and score every 5", async () => {
  const t = ticking("llu-1");
  for (let i = 0; i < 31; i++) {
    assertEquals(await t.engine.tick(), "done");
    t.advance(60);
  }
  assertEquals(t.ledger.records.length, 3);
  assert(t.ledger.records.every((x) => x.owner === "user-1"));
  const issued = t.ledger.records.map((x) => x.r.issuedAt);
  assert(issued[1] - issued[0] >= ledgerSpacing && issued[2] - issued[1] >= ledgerSpacing);
  assertEquals(t.ledger.scores, Math.ceil(31 * 60 / ledgerScoreEvery));
  // The owner is looked up once, not every tick.
  assertEquals(t.ledger.lookups, 1);
});

Deno.test("no owner found: nothing kept, looked for again an hour later", async () => {
  const t = ticking("llu-2");
  for (let i = 0; i < 61; i++) {
    await t.engine.tick();
    t.advance(60);
  }
  assertEquals(t.ledger.records.length, 0);
  assertEquals(t.ledger.scores, 0);
  assertEquals(t.ledger.lookups, 2);
});

Deno.test("a session without the LibreLinkUp user id keeps nothing", async () => {
  const t = ticking(undefined);
  await t.engine.tick();
  assertEquals(t.ledger.lookups, 0);
  assertEquals(t.ledger.records.length, 0);
});

Deno.test("a ledger failure doesn't fail the tick, and the slot is tried again", async () => {
  const t = ticking("llu-1");
  t.ledger.fail = true;
  assertEquals(await t.engine.tick(), "done");
  assertEquals(t.store.row.work.forecastLog?.lastIssuedAt, null);
  t.ledger.fail = false;
  t.advance(60);
  await t.engine.tick();
  assertEquals(t.ledger.records.length, 1);
});

// MARK: LibreLinkUp user id

Deno.test("a saved session without the user id logs in once more to learn it", async () => {
  const calls: string[] = [];
  const http = (input: string | URL | Request) => {
    const url = String(input);
    calls.push(url.replace(/^https:\/\/[^/]+\//, ""));
    const body = url.endsWith("/llu/auth/login")
      ? { status: 0, data: { authTicket: { token: "new", expires: Date.now() / 1000 + 86_400 }, user: { id: "llu-1" } } }
      : url.endsWith("/graph")
      ? { status: 0, data: { graphData: [] } }
      : { status: 0, data: [{ patientId: "p" }] };
    return Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
  };
  const fetcher = new LibreLinkUpFetcher(http as typeof fetch);
  const account: Account = { email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 };
  const { session: first } = await fetcher.fetch(account, null);
  assertEquals(first.userId, "llu-1");
  const old: LibreSession = { ...first, token: "old" };
  delete old.userId;
  calls.length = 0;
  const { session } = await fetcher.fetch(account, old);
  assertEquals(calls[0], "llu/auth/login");
  assertEquals(session.userId, "llu-1");
  calls.length = 0;
  await fetcher.fetch(account, session);
  assertFalse(calls.includes("llu/auth/login"));
});


// MARK: Widening the range from the relay's own forecasts

/// A shown 30-minute relay forecast whose reading landed `miss` × its 20 mg/dL half-width away.
function shownAt(i: number, hoursAgo: number, miss: number, trend = 0, scale?: number): ShownForecast {
  const half = 20 * (scale ?? 1);
  return {
    issuedAt: t0 - hoursAgo * 3600, trendPerMinute: trend,
    points: [{ minutes: 30, mgdl: 120, lower: 120 - half, upper: 120 + half, actual: 120 + (i % 2 ? -1 : 1) * miss * 20, scale }],
  };
}

Deno.test("the relay widens its range like the apps: steady, fast-moving, and the last 12 hours", () => {
  const close = (a: number, b: number) => assert(Math.abs(a - b) < 0.01, `${a} vs ${b}`);
  assertEquals(rangeScaleFrom(Array.from({ length: 20 }, (_, i) => shownAt(i, 13 + i, 2)), t0), null);

  // Two weeks on the edge, fast-moving ones twice as far out, and the last 12 hours 1.8 out.
  const shown = [
    ...Array.from({ length: 100 }, (_, i) => shownAt(i, 13 + i * 3, 1)),
    ...Array.from({ length: 30 }, (_, i) => shownAt(i, 14 + i * 5, 2, i % 2 ? 2 : -2)),
    ...Array.from({ length: 20 }, (_, i) => shownAt(i, 0.5 + i * 0.5, 1.8)),
  ];
  const s = rangeScaleFrom(shown, t0)!;
  close(rangeFactor(s, 30, 0), 1.8);
  close(s.fastTrend, 2);
  close(s.recent, 1.8);
  close(rangeFactor(s, 30, -2), 3.6);
  // Twelve hours later the bad stretch no longer counts on its own.
  close(rangeFactor(rangeScaleFrom(shown, t0 + 13 * 3600)!, 30, 0), 1);
  // Shown already widened, landing at the edge of what was shown: settles, doesn't compound.
  close(rangeFactor(rangeScaleFrom(Array.from({ length: 50 }, (_, i) => shownAt(i, 13 + i, 1.6, 0, 1.6)), t0)!, 30, 0), 1.6);
  assertEquals(rangeFactor(null, 30, 3), 1);
});

Deno.test("the forecast draws the wider range and the ledger records what each point was shown with", () => {
  const readings: Reading[] = [];
  for (let back = 30; back >= 0; back--) readings.push({ t: t0 - back * 60, mgdl: 150 - back, trend: 3 });
  const scale: RangeScale = { byHorizon: { 15: 1.5, 30: 2 }, overall: 1.5, fastTrend: 1, recent: 1, checks: 60, recentChecks: 0 };
  const plain = forecast(new Series(readings), null, t0);
  const wider = forecast(new Series(readings), null, t0, undefined, undefined, null, scale);
  assert(plain.ok && wider.ok);
  const half = (f: Forecast, m: number) => { const p = f.samples.find((x) => x.t === f.issuedAt + m * 60)!; return p.upperMgdl - p.mgdl; };
  assert(Math.abs(half(wider.forecast, 15) - half(plain.forecast, 15) * 1.5) < 0.01);
  assert(Math.abs(half(wider.forecast, 30) - half(plain.forecast, 30) * 2) < 0.01);
  const r = ledgerRecord(wider.forecast, null, null, "id", scale)!;
  assertEquals(r.points.map((p) => p.scale), [1.5, 2]);
});

Deno.test("ticks work the range out after scoring and widen the next forecasts", async () => {
  const t = ticking("llu-1");
  t.ledger.shownForecasts = Array.from({ length: 50 }, (_, i) => shownAt(i, 13 + i, 1.5));
  await t.engine.tick();
  assertEquals(t.ledger.shownSince, [t0 - rangeWindow]);
  near(t.store.row.work.forecastLog?.rangeScale?.overall ?? 0, 1.5);
  t.advance(ledgerSpacing);
  await t.engine.tick();
  const [first, second] = t.ledger.records.map((x) => x.r);
  assertEquals(first.points[0].scale, undefined, "The first tick's forecast came before any widening");
  assertEquals(second.points.map((p) => p.scale), [1.5, 1.5]);
  assert(second.points[0].upper - second.points[0].mgdl > first.points[0].upper - first.points[0].mgdl);
});

function near(a: number, b: number) { assert(Math.abs(a - b) < 0.01, `${a} vs ${b}`); }

// MARK: Live horizon

Deno.test("a forecast cut short keeps its undrawn points, marked", () => {
  const f = trendForecast();
  const cut: Forecast = { ...f, samples: f.samples.slice(0, 4), unshown: f.samples.slice(4) };
  assertEquals(ledgerRecord(cut, null, null, "id")!.points, [
    { minutes: 15, mgdl: 135, lower: 125, upper: 145 },
    { minutes: 30, mgdl: 150, lower: 140, upper: 160, shown: false },
  ]);
});

/// Relay points where the 30-minute forecast was 20 off while glucose moved 15: worse than no change.
function losingAt30(now: number, count = 40): LivePoint[] {
  const out: LivePoint[] = [];
  for (let i = 0; i < count; i++) {
    const issuedAt = now - 3600 - i * 900;
    out.push({ issuedAt, minutes: 15, mgdl: 120, startMgdl: 120, actual: 125, afterLog: false, shown: true });
    out.push({ issuedAt, minutes: 30, mgdl: 115, startMgdl: 120, actual: 135, afterLog: false, shown: true });
  }
  return out;
}

Deno.test("ticks learn the live cut when they score, and the Lock Screen forecast follows it", async () => {
  const t = ticking("llu-1");
  t.ledger.points = losingAt30(t0);
  for (let i = 0; i < 16; i++) {
    await t.engine.tick();
    t.advance(60);
  }
  assertEquals(t.store.row.work.forecastLog?.live, { shownMinutes: 15, failedAt: 30 });
  const later = t.ledger.records[t.ledger.records.length - 1].r;
  assertEquals(later.points.map((p) => [p.minutes, p.shown ?? true]), [[15, true], [30, false]]);
});

Deno.test("cut to nothing: no forecast drawn, but it's still kept", async () => {
  const t = ticking("llu-1");
  t.ledger.points = losingAt30(t0).map((p) => p.minutes === 15 ? { ...p, mgdl: 100 } : p);
  for (let i = 0; i < 16; i++) {
    await t.engine.tick();
    t.advance(60);
  }
  assertEquals(t.store.row.work.forecastLog?.live, { shownMinutes: 0, failedAt: 15 });
  const last = t.ledger.records[t.ledger.records.length - 1].r;
  assertEquals(last.points.map((p) => p.shown ?? true), [false, false]);
});

Deno.test("forecast() draws only to the live cut", () => {
  const readings: Reading[] = [];
  for (let back = 30; back >= 0; back--) readings.push({ t: t0 - back * 60, mgdl: 120 - back, trend: 3 });
  const s = new Series(readings);
  const full = forecast(s, null, t0);
  const cut = forecast(s, null, t0, undefined, standardTuning, { shownMinutes: 15, failedAt: 30 });
  assert(full.ok && cut.ok);
  assertEquals(cut.forecast.samples, full.forecast.samples.slice(0, 4));
  assertEquals(cut.forecast.unshown, full.forecast.samples.slice(4));
  // A cut past the trend forecast's 30 minutes changes nothing.
  const past = forecast(s, null, t0, undefined, standardTuning, { shownMinutes: 45, failedAt: 60 });
  assertEquals(past, full);
  const none = forecast(s, null, t0, undefined, standardTuning, { shownMinutes: 0, failedAt: 15 });
  assert(!none.ok);
  assertEquals(none.reason, "Past forecasts haven't been accurate enough to show one.");
  assertEquals(none.unshown?.samples.length, 1);
});
