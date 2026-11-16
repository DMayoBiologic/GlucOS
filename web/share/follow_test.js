// Tests for the share page's working-out (follow.js). Runs under `deno test web/` in CI, and under
// `node --test web/share/` too. Times are built from local dates, so they pass in any time zone.

import { test } from "node:test";
import assert from "node:assert/strict";
import * as F from "./follow.js";

const at = (y, mo, d, h = 0, mi = 0) => new Date(y, mo - 1, d, h, mi).getTime() / 1000;

/// Readings every 5 minutes from `from` to `to`, valued by `value(t)`.
function every5(from, to, value) {
  const out = [];
  for (let t = from; t <= to; t += 300) out.push({ t, mgdl: value(t) });
  return out;
}

test("today so far: nothing before an hour of the day has gone", () => {
  const now = at(2026, 11, 15, 0, 50);
  const rs = every5(at(2026, 11, 15, 0, 0), now, () => 120);
  assert.equal(F.todaySoFar(rs, 70, 180, now), null);
});

test("today so far: today alone until five earlier days have readings", () => {
  const now = at(2026, 11, 15, 9, 0);
  const today = every5(at(2026, 11, 15, 0, 0), now, (t) => t < at(2026, 11, 15, 3) ? 200 : 120);
  const earlier = [1, 2, 3].flatMap((k) => every5(at(2026, 11, 15 - k, 0), at(2026, 11, 15 - k, 9), () => 120));
  const t = F.todaySoFar(earlier.concat(today), 70, 180, now);
  assert.ok(t);
  assert.equal(t.usual, null);
  assert.equal(t.minute, 9 * 60);
  // Midnight to 3 am above range: 36 of the 109 buckets.
  assert.ok(Math.abs(t.today.timeInRange - 73 / 109) < 1e-9);
  const w = F.todayText(t, "mmol");
  assert.equal(w.period, "Midnight to 9 am");
  assert.match(w.headline, /^67% of today in range so far\.$/);
  assert.match(w.footnote, /joins in once there are 5 days/);
});

test("today so far: compared with the median usual day at the same hours", () => {
  const now = at(2026, 11, 15, 14, 30);
  const today = every5(at(2026, 11, 15, 0), now, () => 120);
  // Six earlier days, each with two hours above range in the morning; one of them has a low.
  const earlier = [1, 2, 3, 4, 5, 6].flatMap((k) => every5(at(2026, 11, 15 - k, 0), at(2026, 11, 15 - k, 23, 55), (t) => {
    const h = new Date(t * 1000).getHours();
    if (k === 2 && h === 4) return 60;
    return h >= 6 && h < 8 ? 220 : 120;
  }));
  const t = F.todaySoFar(earlier.concat(today), 70, 180, now);
  assert.ok(t.usual);
  assert.equal(t.usual.days, 6);
  assert.equal(t.usual.daysWithLows, 1);
  assert.equal(t.today.timeInRange, 1);
  assert.equal(F.rangeChange(t), "better");
  const w = F.todayText(t, "mgdl");
  assert.equal(w.headline, "More time in range than usual by now.");
  assert.equal(w.lows, "None");
  assert.equal(w.lowsCaption, "1 of 6 days by now");
  assert.equal(w.period, "Midnight to 2:30 pm");
  assert.match(w.spoken, /^Today so far, midnight to 2:30 pm\. More time in range than usual by now\. 100 percent in range, usually 86 percent\./);
  // Only what's happened by now counts on the earlier days: their evenings don't.
  assert.equal(w.meanCaption, `Usually ${Math.round(t.usual.meanMgdl)}`);
});

test("today so far: LinkUp's 15-minute history counts as full coverage", () => {
  const now = at(2026, 11, 15, 6, 0);
  const rs = [];
  for (let t = at(2026, 11, 15, 0); t <= now; t += 900) rs.push({ t, mgdl: 110 });
  assert.ok(F.todaySoFar(rs, 70, 180, now));
});

test("lows: 15 minutes or more below range, and a long gap ends a run", () => {
  const t0 = at(2026, 11, 15, 1);
  const pts = (vals) => vals.map((v, i) => [t0 + i * 300, v]);
  assert.equal(F.lowRuns(pts([100, 60, 60, 100]), 70), 0);      // 10 minutes
  assert.equal(F.lowRuns(pts([100, 60, 60, 60, 100]), 70), 1);  // 15 minutes
  assert.equal(F.lowRuns(pts([60, 60, 60]), 70), 1);            // still going, 15 minutes by its end
  assert.equal(F.lowRuns([[t0, 60], [t0 + 3600, 60]], 70), 0);  // two lone buckets an hour apart
});

test("chart summary: stale first, and no forecast once stale", () => {
  const rs = every5(1000, 1000 + 3600, (t) => t < 1000 + 1800 ? 60 : 200);
  const fresh = F.chartSummary({ readings: rs, lowMgdl: 70, highMgdl: 180, unit: "mgdl", hours: 3, stale: false,
    forecastEnd: { t: 1000 + 3600 + 1800, mgdl: 210 }, loggedCount: 2 });
  assert.equal(fresh, "Last 3 hours. Now 200, high. Lowest 60, highest 200. 0 percent in range. " +
    "Went below range once and above range once. Forecast, not a reading: about 210 in 30 minutes. 2 entries logged.");
  const stale = F.chartSummary({ readings: rs, lowMgdl: 70, highMgdl: 180, unit: "mmol", hours: 3, stale: true,
    forecastEnd: { t: 1000 + 3600 + 1800, mgdl: 210 }, loggedCount: 0 });
  assert.match(stale, /^Last 3 hours\. Stale: the last reading was 11\.1\./);
  assert.doesNotMatch(stale, /Forecast/);
  assert.equal(F.chartSummary({ readings: [], lowMgdl: 70, highMgdl: 180, unit: "mgdl", hours: 3 }), "Last 3 hours. No readings.");
});

test("chart readings: loaded buckets, then the card's newer readings", () => {
  const card = { readingAt: 10_000, mgdl: 130, history: [100, null, 120, 130] };
  assert.deepEqual(F.cardReadings(card), [{ t: 9100, mgdl: 100 }, { t: 9700, mgdl: 120 }, { t: 10_000, mgdl: 130 }]);
  // Nothing loaded: the card's own.
  assert.equal(F.chartReadings(card, [], 3, 10_000).length, 3);
  // Loaded up to 9100: the card's 9700 and 10 000 go on the end.
  const loaded = [{ t: 2000, mgdl: 90 }, { t: 9100, mgdl: 101 }];
  assert.deepEqual(F.chartReadings(card, loaded, 3, 10_000).map((r) => r.t), [2000, 9100, 9700, 10_000]);
});

test("detail merge: the first bucket again replaces the partial one", () => {
  const loaded = [{ t: 600, mgdl: 100 }, { t: 1150, mgdl: 110 }];
  assert.equal(F.nextSince(loaded), 900);
  const merged = F.mergeReadings(loaded, [[1190, 112], [1490, 115]], 900);
  assert.deepEqual(merged, [{ t: 600, mgdl: 100 }, { t: 1190, mgdl: 112 }, { t: 1490, mgdl: 115 }]);
  assert.equal(F.nextSince([]), null);
});

test("log markers: insulin, food and wake-ups only, never notes or food names", () => {
  const t = at(2026, 11, 15, 12, 56);
  const log = [
    { id: "a", kind: "dose", payload: { timestamp: t, units: 6, kind: "rapid", name: "NovoRapid", note: "" } },
    { id: "b", kind: "dose", payload: { timestamp: t, units: 1, kind: "long", name: "" } },
    { id: "c", kind: "meal", payload: { timestamp: t + 60, carbs: 45, food: "Secret sandwich", note: "" } },
    { id: "d", kind: "meal", payload: { timestamp: t + 60, carbs: 0, food: "Something" } },
    { id: "e", kind: "context", payload: { timestamp: t - 3600, tags: ["wokeUp"], note: "" } },
    { id: "f", kind: "context", payload: { timestamp: t, tags: ["exercise"] } },
    { id: "g", kind: "siteChange", payload: { timestamp: t } },
    { id: "h", kind: "meal", payload: { timestamp: t - 5 * 3600, carbs: 10 } },
  ];
  const m = F.logMarkers(log, t - 4 * 3600);
  assert.deepEqual(m.map((x) => [x.kind, x.lane, x.label]), [
    ["wake", 2, "Woke up at 11:56 am"],
    ["insulin", 0, "6 units NovoRapid at 12:56 pm"],
    ["insulin", 0, "1 unit Long-acting at 12:56 pm"],
    ["food", 1, "45 g carbs at 12:57 pm"],
    ["food", 1, "Food at 12:57 pm"],
  ]);
  assert.ok(!JSON.stringify(m).includes("Secret"));
  assert.deepEqual(F.logMarkers(null, 0), []);
});

test("monotone path never overshoots a flat stretch", () => {
  const d = F.monotonePath([[0, 10], [10, 10], [20, 0], [30, 0]]);
  // Every control point stays inside the data's y range.
  const ys = [...d.matchAll(/-?[\d.]+,(-?[\d.]+)/g)].map((m) => Number(m[1]));
  assert.ok(ys.every((y) => y >= 0 && y <= 10), d);
  assert.equal(F.monotonePath([[0, 1]]), "M0,1");
});

test("segments break at gaps; nearest ignores readings over 10 minutes away", () => {
  const rs = [{ t: 0, mgdl: 1 }, { t: 300, mgdl: 2 }, { t: 3000, mgdl: 3 }];
  assert.equal(F.segments(rs).length, 2);
  assert.equal(F.nearest(rs, 1500), null);
  assert.equal(F.nearest(rs, 500).t, 300);
  assert.equal(F.previous(rs, rs[1]).t, 0);
  assert.equal(F.previous(rs, rs[2]), null);
});

test("y ticks are round numbers in the person's units", () => {
  assert.deepEqual(F.yTicks(50, 210, "mgdl"), [50, 100, 150, 200]);
  const mmol = F.yTicks(50, 210, "mmol").map((v) => Math.round(v / F.MGDL_PER_MMOL));
  assert.deepEqual(mmol, [4, 6, 8, 10]);
  assert.equal(F.clock(0), "midnight");
  assert.equal(F.clock(720), "noon");
  assert.equal(F.clock(14 * 60 + 5), "2:05 pm");
});
