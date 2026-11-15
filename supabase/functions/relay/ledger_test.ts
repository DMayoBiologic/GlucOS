// The relay's forecast ledger: which forecasts it keeps, and how a tick uses it.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { type Calibration, type Forecast, type Reading, standardTuning } from "./core.ts";
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

