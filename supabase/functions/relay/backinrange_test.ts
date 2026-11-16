// The relay's "back in range" estimate on the Lock Screen card (Sources/Engine/BackInRange.swift):
// highs only, inside the drawn forecast, and only once its own checks keep it within 15 minutes.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  actualMinutesBack, type BackInRangeCheck, backInRangeCheck, backInRangeShows, type Forecast, makeCard, minutesBack,
  outlookSnapshot, type Reading, type Snapshot,
} from "./core.ts";

const t0 = 1_790_000_000;
const open: BackInRangeCheck = { checks: 6, medianMissMinutes: 8, withinTolerance: 0.8 };

Deno.test("minutes back: linear to the high line, nothing from in range or past the drawn points", () => {
  assertEquals(minutesBack(220, [{ minutes: 15, mgdl: 160 }, { minutes: 30, mgdl: 140 }], 180), 10);
  assertEquals(minutesBack(220, [{ minutes: 15, mgdl: 200 }, { minutes: 30, mgdl: 180 }], 180), 30);
  assertEquals(minutesBack(170, [{ minutes: 15, mgdl: 150 }], 180), null);
  assertEquals(minutesBack(220, [{ minutes: 15, mgdl: 210 }, { minutes: 30, mgdl: 200 }], 180), null);
});

Deno.test("actual return needs the next reading in range too, and stops when the readings do", () => {
  const r = (m: number, mgdl: number): Reading => ({ t: t0 + m * 60, mgdl, trend: 3 });
  assertEquals(actualMinutesBack([r(5, 200), r(10, 175), r(15, 190), r(20, 170), r(25, 160)], t0, 70, 180), 20);
  assertEquals(actualMinutesBack([r(5, 200), r(10, 175)], t0, 70, 180), null);
});

Deno.test("the gate: five checks with a median miss within 15 minutes", () => {
  const rec = (i: number) => ({ issuedAt: t0 + i * 3600, startMgdl: 220, points: [{ minutes: 15, mgdl: 160 }] });
  const readings: Reading[] = [];
  const back = (i: number, minutes: number) => {
    for (let m = 1; m <= 60; m++) readings.push({ t: t0 + i * 3600 + m * 60, mgdl: m < minutes ? 200 : 150, trend: 3 });
  };
  [12, 15, 8, 20, 10].forEach((m, i) => back(i, m));
  const now = t0 + 10 * 3600;
  const five = backInRangeCheck([0, 1, 2, 3, 4].map(rec), readings, 70, 180, now);
  assertEquals(five.checks, 5);
  assertEquals(five.medianMissMinutes, 2);
  assert(backInRangeShows(five));
  assert(!backInRangeShows(backInRangeCheck([0, 1, 2, 3].map(rec), readings, 70, 180, now)));
  // Older than 30 days: not counted.
  assertEquals(backInRangeCheck([0, 1, 2, 3, 4].map(rec), readings, 70, 180, now + 31 * 86_400).checks, 0);
  assert(!backInRangeShows({ checks: 9, medianMissMinutes: 16, withinTolerance: 0.3 }));
});

Deno.test("a forecast still out of range six hours on counts as a big miss", () => {
  const readings: Reading[] = [];
  for (let m = 1; m <= 7 * 60; m += 5) readings.push({ t: t0 + m * 60, mgdl: 230, trend: 3 });
  const c = backInRangeCheck([{ issuedAt: t0, startMgdl: 220, points: [{ minutes: 15, mgdl: 160 }] }], readings, 70, 180,
    t0 + 8 * 3600);
  assertEquals(c.checks, 1);
  assertEquals(c.medianMissMinutes, 350);
});

function falling(start: number, perStep: number): Forecast {
  const samples = [];
  for (let m = 0; m <= 30; m += 5) {
    const v = start + (perStep * m) / 5;
    samples.push({ t: t0 + m * 60, mgdl: v, lowerMgdl: v - 10, upperMgdl: v + 10 });
  }
  return { issuedAt: t0, startMgdl: start, basis: "trend", trendPerMinute: perStep / 5, samples };
}

function snapshot(mgdl: number, f: Forecast, check: BackInRangeCheck | null, low = 70): Snapshot {
  return {
    current: { t: t0, mgdl, trend: 2 }, history: [], sensor: null, unit: "mmol", lowMgdl: low, highMgdl: 180,
    lastError: null, outlook: outlookSnapshot({ ok: true, forecast: f }, t0, low, 180, check),
  };
}

Deno.test("the card carries back-in-range only from a high, with the gate open and no low expected", () => {
  // 220 falling 10 every 5 minutes: back to 180 at 20 minutes.
  const card = makeCard(snapshot(220, falling(220, -10), open), [], "relay", t0 + 30)!;
  assertEquals(card.backInRangeAt, t0 + 20 * 60);
  assertEquals(makeCard(snapshot(220, falling(220, -10), null), [], "relay", t0 + 30)!.backInRangeAt, undefined);
  assertEquals(makeCard(snapshot(220, falling(220, -10), { ...open, checks: 4 }), [], "relay", t0 + 30)!.backInRangeAt,
    undefined);
  // Not coming back within the drawn 30 minutes.
  assertEquals(makeCard(snapshot(220, falling(220, -1), open), [], "relay", t0 + 30)!.backInRangeAt, undefined);
  // A low expected along the way wins (a range low of 175 here, so the line crosses it).
  const withLow = makeCard(snapshot(220, falling(220, -10), open, 175), [], "relay", t0 + 30)!;
  assert(withLow.lowExpectedAt !== undefined);
  assertEquals(withLow.backInRangeAt, undefined);
  // Stale: no forecast at all.
  assertEquals(makeCard(snapshot(220, falling(220, -10), open), [], "relay", t0 + 7 * 60)!.backInRangeAt, undefined);
});
