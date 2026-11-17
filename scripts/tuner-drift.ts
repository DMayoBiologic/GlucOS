// §61: do the trend tuner's learned settings still beat the standard ones on the latest 7 days,
// and would a shorter learning window do better held out? See docs/ForecastAccuracy.md §61.
//
//   node --experimental-strip-types scripts/tuner-drift.ts DIR
//
// DIR holds readings.json ([[unix seconds, mg/dL, trend], …], live readings only) and log.json
// ([unix seconds, …]: meals and doses). A point is clean when nothing was logged from 3 hours
// before it was issued to the time it's checked. Forecasts are scored every 5 minutes.
import * as fs from "node:fs";
import * as core from "../supabase/functions/relay/core.ts";

const dir = process.argv[2] ?? ".";
const readings: core.Reading[] = JSON.parse(fs.readFileSync(`${dir}/readings.json`, "utf8"))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 3) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
const logs: number[] = JSON.parse(fs.readFileSync(`${dir}/log.json`, "utf8"));
const series = new core.Series(readings);
const end = series.last!.t;
const horizons = [15, 30, 60];
const clean = (o: number, m: number) => !logs.some((l) => l > o - 3 * 3600 && l <= o + m * 60);
const key = (t: core.Tuning) => `${t.trendFade / 60}/${t.trendWindow / 60}/${t.trendGain}`;

// Every 5 minutes from the first full hour: |actual − forecast| and |actual − start| per horizon.
type Pt = { o: number; m: number; err: number; naive: number; clean: boolean };
const cache = new Map<string, Map<string, Pt>>();
function points(t: core.Tuning): Map<string, Pt> {
  const k = key(t);
  if (cache.has(k)) return cache.get(k)!;
  const out = new Map<string, Pt>();
  let last = -Infinity;
  for (const r of series.readings) {
    if (r.t - last < 5 * 60 - 20 || r.t < series.readings[0].t + 3600) continue;
    const recent = new core.Series(series.slice(r.t - 3600, r.t), true);
    if (recent.slice(r.t - t.trendWindow, r.t).length < Math.trunc(t.trendWindow / 60 * 0.75)) continue;
    const res = core.forecast(recent, null, r.t, 60 * 60, t);
    if (!res.ok) continue;
    last = r.t;
    for (const m of horizons) {
      const target = r.t + m * 60;
      if (target > end) continue;
      const actual = series.value(target);
      const p = res.forecast.samples.find((s) => Math.abs(s.t - target) < 30);
      if (actual === null || !p) continue;
      out.set(`${r.t}/${m}`, { o: r.t, m, err: Math.abs(actual - p.mgdl), naive: Math.abs(actual - res.forecast.startMgdl), clean: clean(r.t, m) });
    }
  }
  cache.set(k, out);
  return out;
}
const std = core.standardTuning;
const tun = (g: number, f = 30, w = 20): core.Tuning => ({ trendFade: f * 60, trendWindow: w * 60, trendGain: g });
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length);
const perthDay = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(5, 10);

// 1. Fixed settings on the latest 7 days.
const from7 = end - 7 * 86_400;
const fixed: [string, core.Tuning][] = [["standard (gain 1)", std], ["gain 0.45 (relay/Mac)", tun(0.45)],
  ["gain 0.6", tun(0.6)], ["gain 0.7 (iPhone)", tun(0.7)], ["no change", tun(0)]];
console.log("1. Latest 7 days, every 5 min. MAE mg/dL (n). clean | all");
const base = points(std);
for (const [name, t] of fixed) {
  const p = points(t);
  const row = horizons.map((m) => {
    const sel = (c: boolean) => [...base.keys()].filter((k) => p.has(k) && base.get(k)!.m === m && base.get(k)!.o >= from7 && (!c || base.get(k)!.clean));
    const kc = sel(true), ka = sel(false);
    return `${m}m ${mean(kc.map((k) => p.get(k)!.err)).toFixed(1)} (${kc.length}) | ${mean(ka.map((k) => p.get(k)!.err)).toFixed(1)}`;
  });
  console.log(`  ${name.padEnd(24)} ${row.join("   ")}`);
}
// Per Perth day, clean, gain 0.45 vs standard, and best fixed gain per day.
console.log("  per Perth day, clean: standard / 0.45 / 0.7 at 30 and 60 min");
const days = [...new Set([...base.values()].filter((p) => p.o >= from7).map((p) => perthDay(p.o)))].sort();
for (const d of days) {
  const cells = [30, 60].map((m) => {
    const ks = [...base.keys()].filter((k) => { const b = base.get(k)!; return b.m === m && b.clean && perthDay(b.o) === d; });
    return `${m}m ` + [std, tun(0.45), tun(0.7)].map((t) => mean(ks.map((k) => points(t).get(k)?.err ?? base.get(k)!.err)).toFixed(1)).join("/") + ` (${ks.length})`;
  });
  console.log(`    ${d}  ${cells.join("   ")}`);
}

// 2. What the relay's tuner picks with different learning windows, relearning every 3 hours as it
// does, each 3-hour block scored with the tuning learned before it (held out).
console.log("\n2. Walk-forward: relearn every 3 h from the last W days, score the next 3 h (clean, latest 7 days)");
const windows = [2, 3, 5, 7, 14];
const blockStart = series.readings[0].t + 2 * 86_400;
const rows: Record<number, { o: number; m: number; err: number; base: number }[]> = {};
const picks: Record<number, Map<string, number>> = {};
for (const W of windows) {
  rows[W] = []; picks[W] = new Map();
  for (let T = blockStart; T < end; T += 3 * 3600) {
    const t = core.tuneTrend(series.slice(T - W * 86_400, T), T, W);
    picks[W].set(key(t), (picks[W].get(key(t)) ?? 0) + 1);
    const p = points(t);
    for (const [k, b] of base) {
      if (b.o < T || b.o >= T + 3 * 3600 || b.o < from7 || !b.clean || !p.has(k)) continue;
      rows[W].push({ o: b.o, m: b.m, err: p.get(k)!.err, base: b.err });
    }
  }
}
const ref = 14;
for (const W of windows) {
  const cells = horizons.map((m) => {
    const r = rows[W].filter((x) => x.m === m), rr = rows[ref].filter((x) => x.m === m);
    const e = mean(r.map((x) => x.err)), e14 = mean(rr.map((x) => x.err));
    return `${m}m ${e.toFixed(2)} (${(100 * (e / e14 - 1)).toFixed(1)}% vs 14 d, std ${mean(r.map((x) => x.base)).toFixed(2)})`;
  });
  const daysBetter = [30, 60].map((m) => days.filter((d) => {
    const r = rows[W].filter((x) => x.m === m && perthDay(x.o) === d), rr = rows[ref].filter((x) => x.m === m && perthDay(x.o) === d);
    return r.length > 0 && mean(r.map((x) => x.err)) < mean(rr.map((x) => x.err)) - 1e-9;
  }).length);
  console.log(`  W=${String(W).padStart(2)} d  ${cells.join("  ")}  days better than 14 d at 30/60: ${daysBetter.join("/")} of ${days.length}`);
  console.log(`         picks: ${[...picks[W].entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}×${n}`).join(", ")}`);
}
