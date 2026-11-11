// Replays testdata/parity.json (written by the Swift test RelayParityTests) through the
// TypeScript port and checks every alert, forecast and Live Activity card matches the Swift code.
import { assertEquals } from "jsr:@std/assert@1";
import {
  type AlertPreferences, type Calibration, fixed, formatGlucose, learnCalibration, mergeReadings, newPlanner,
  processTick, type Reading, type Sensor, type Trend,
} from "./core.ts";

interface FixtureTick {
  now: number;
  history: [number, number, number][];
  current?: [number, number, number];
  sensor?: Sensor;
  error?: string;
  learn: boolean;
  record: boolean;
}

interface Fixture {
  name: string;
  unit: string;
  lowMgdl: number;
  highMgdl: number;
  prefs: AlertPreferences;
  ticks: FixtureTick[];
  expected: Record<string, unknown>[];
  calibration?: { minutes: number; samples: number; lower: number; upper: number; mae: number; naive: number }[];
}

const fixture = JSON.parse(await Deno.readTextFile(new URL("./testdata/parity.json", import.meta.url))) as {
  scenarios: Fixture[];
};

const reading = ([t, mgdl, trend]: [number, number, number]): Reading => ({ t, mgdl, trend: trend as Trend });

function close(a: unknown, b: unknown, path: string, problems: string[]) {
  if (typeof a === "number" && typeof b === "number") {
    if (Math.abs(a - b) > 1e-6 * Math.max(1, Math.abs(a))) problems.push(`${path}: ${a} vs ${b}`);
  } else if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) problems.push(`${path}: ${a.length} vs ${b.length} items`);
    else a.forEach((x, i) => close(x, b[i], `${path}[${i}]`, problems));
  } else if (a && b && typeof a === "object" && typeof b === "object") {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of [...keys].sort()) {
      const av = (a as Record<string, unknown>)[k], bv = (b as Record<string, unknown>)[k];
      if (av === undefined || bv === undefined) problems.push(`${path}.${k}: missing on one side`);
      else close(av, bv, `${path}.${k}`, problems);
    }
  } else if (typeof a === "boolean" && typeof b === "number") {
    // Swift's JSONSerialization can write booleans as 0/1.
    if (Number(a) !== b) problems.push(`${path}: ${a} vs ${b}`);
  } else if (typeof b === "boolean" && typeof a === "number") {
    if (Number(b) !== a) problems.push(`${path}: ${a} vs ${b}`);
  } else if (a !== b) {
    problems.push(`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  }
}

for (const sc of fixture.scenarios) {
  Deno.test(`parity: ${sc.name}`, () => {
    const planner = newPlanner();
    let calibration: Calibration | null = null;
    let stored: Reading[] = [];
    let current: Reading | null = null;
    let sensor: Sensor | null = null;
    const problems: string[] = [];

    sc.ticks.forEach((t, i) => {
      if (t.learn && stored.length > 24) calibration = learnCalibration(stored, t.now);
      let lastError: string | null = null;
      if (t.error !== undefined) {
        lastError = t.error;
      } else {
        const incoming = t.history.map(reading);
        if (t.current) {
          current = reading(t.current);
          incoming.push(current);
        }
        stored = mergeReadings(stored, incoming, t.now, 48 * 3600);
        if (t.sensor) sensor = t.sensor;
      }
      const r = processTick({
        stored, current, sensor, lastError, planner, calibration, now: t.now,
        display: { unit: sc.unit, lowMgdl: sc.lowMgdl, highMgdl: sc.highMgdl }, prefs: sc.prefs,
      });
      if (!t.record) return;
      const got: Record<string, unknown> = {
        now: t.now,
        notices: r.notices.map((n) => ({ kind: n.kind, title: n.title, body: n.body, critical: n.critical })),
      };
      if (r.forecast.ok) {
        const f = r.forecast.forecast;
        got.forecast = {
          basis: f.basis, trendPerMinute: f.trendPerMinute,
          samples: f.samples.map((s) => [s.t, s.mgdl, s.lowerMgdl, s.upperMgdl]),
        };
      } else {
        got.forecastUnavailable = r.forecast.reason;
      }
      if (r.card) got.card = r.card;
      close(sc.expected[i], got, `${sc.name}[${i}]`, problems);
    });

    if (sc.calibration) {
      const c = calibration as Calibration | null;
      close(sc.calibration, c?.trend.map((s) => ({
        minutes: s.minutes, samples: s.samples, lower: s.lower, upper: s.upper, mae: s.meanAbsoluteError,
        naive: s.naiveError,
      })), `${sc.name}.calibration`, problems);
    }
    assertEquals(problems.slice(0, 15), []);
  });
}

Deno.test("formatting matches printf, ties included", () => {
  assertEquals(fixed(2.25, 1), "2.2");
  assertEquals(fixed(2.35, 1), "2.4"); // 2.35 is just above the tie in binary
  assertEquals(fixed(0.15, 1), "0.1"); // …and 0.15 just below
  assertEquals(fixed(2.5, 0), "2");
  assertEquals(fixed(3.5, 0), "4");
  assertEquals(fixed(-0.25, 1), "-0.2");
  assertEquals(formatGlucose("mmol", 65, true), "3.6 mmol/L");
  assertEquals(formatGlucose("mgdl", 65, true), "65 mg/dL");
});
