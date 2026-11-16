// Walk-forward replay of the push relay's Lock Screen forecast, lived through the way the relay
// does: every 15 minutes it forecasts from the readings so far, relearns every 3 hours from the last
// 14 days, and widens and cuts its forecast from its own ledger of what it showed (scored here as
// the database would). See docs/ForecastAccuracy.md §11.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/relay-replay.ts
//
// dir holds readings.json ([[unix seconds, mg/dL], …]) and log.json ([unix seconds, …]: doses, meals
// and events other than waking, which make a point "after a log" and leave it out).
// Knobs:
//   LEDGER_FROM=t  the ledger starts at t (default: a day in), as when it first went live
//   WIDEN=ledger|replay|both|none  which widening is drawn (default both: the relay's own)
//   UNGATED=1      draw every horizon at every origin, to judge the forecast itself
//   GAIN=x         force the trend's strength
//   LIST=1         list each 15-minute point from LIST_FROM (default the last day)
//   ONE_PER_MINUTE=1 keep one of each pair of readings under 30 s apart, the live one (trend known) first.
//                  Needs the trend as a third column ([[t, mg/dL, trend], …]); see docs/ForecastAccuracy.md §18
import * as core from "../supabase/functions/relay/core.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const exported: core.Reading[] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 0) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
// LinkUp's 15-minute graph points (trend 0) land a second or so from the live reading.
const readings: core.Reading[] = env("ONE_PER_MINUTE") ? exported.reduce((out: core.Reading[], r) => {
  const prev = out[out.length - 1];
  if (!prev || r.t - prev.t >= 30) out.push(r);
  else if (prev.trend === 0 && r.trend !== 0) out[out.length - 1] = r;
  return out;
}, []) : exported;
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const series = new core.Series(readings);
const end = series.last!.t;
const ledgerFrom = Number(env("LEDGER_FROM") || series.readings[0].t + 86_400);
const widenMode = env("WIDEN") || "both";
const afterLog = (from: number, to: number) => logs.some((l) => l > from && l < to);

interface Row { t: number; minutes: number; shown: boolean; clean: boolean; error: number; naive: number; inside: boolean; width: number }
const rows: Row[] = [];
const shown: core.ShownForecast[] = [];
const live: core.LivePoint[] = [];
let calibration: core.Calibration | null = null, learnedAt = -Infinity, lastIssued = -Infinity;

for (const r of series.readings) {
  const now = r.t;
  if (now < ledgerFrom) continue;
  if (now - learnedAt > 3 * 3600) {
    calibration = core.learnCalibration(series.slice(now - 14 * 86_400, now), now, 14);
    learnedAt = now;
  }
  if (now - lastIssued < 15 * 60) continue;
  const score = (issuedAt: number, p: { minutes: number; actual?: number | null; afterLog?: boolean }) => {
    const target = issuedAt + p.minutes * 60;
    if (p.actual != null || target > now) return;
    p.actual = series.value(target);
    p.afterLog = afterLog(issuedAt, target);
  };
  for (const s of shown) for (const p of s.points) score(s.issuedAt, p);
  for (const p of live) score(p.issuedAt, p);

  let cal = calibration;
  if (cal && env("GAIN")) cal = { ...cal, tuning: { ...(cal.tuning ?? core.standardTuning), trendGain: Number(env("GAIN")) } };
  if (cal && env("UNGATED")) cal = { ...cal, trend: cal.trend.map((h) => ({ ...h, naiveError: 1e9 })) };
  const ledgerScale = core.rangeScaleFrom(shown, now);
  const scale = widenMode === "none" ? null : widenMode === "ledger" ? ledgerScale
    : widenMode === "replay" ? (calibration?.rangeScale ?? null) : core.effectiveRangeScale(ledgerScale, calibration);
  const cut = env("UNGATED") ? null : core.liveHorizon(live, now);
  const res = core.forecast(new core.Series(series.slice(now - 3600, now), true), cal, now, undefined,
    cal?.tuning ?? core.standardTuning, cut, scale);
  const f = res.ok ? res.forecast : res.unshown;
  if (!f) continue;
  lastIssued = now;
  const record: core.ShownForecast = { issuedAt: now, trendPerMinute: f.trendPerMinute, points: [] };
  for (const m of core.calibrationHorizons) {
    const near = (x: { t: number }) => Math.abs(x.t - (now + m * 60)) < 30;
    const drawn = res.ok ? f.samples.find(near) : undefined;
    const at = drawn ?? f.unshown?.find(near);
    if (!at) continue;
    if (drawn) record.points.push({ minutes: m, mgdl: at.mgdl, lower: at.lowerMgdl, upper: at.upperMgdl, scale: core.rangeFactor(scale, m, f.trendPerMinute) });
    live.push({ issuedAt: now, minutes: m, mgdl: at.mgdl, startMgdl: f.startMgdl, actual: null, afterLog: false, shown: !!drawn });
    const target = now + m * 60;
    const actual = target <= end ? series.value(target) : null;
    if (actual === null) continue;
    rows.push({ t: now, minutes: m, shown: !!drawn, clean: !afterLog(now, target), error: Math.abs(actual - at.mgdl),
                naive: Math.abs(actual - f.startMgdl), inside: actual >= at.lowerMgdl && actual <= at.upperMgdl, width: at.upperMgdl - at.lowerMgdl });
  }
  shown.push(record);
}

const line = (label: string, xs: Row[]) => {
  if (!xs.length) return;
  const avg = (f: (x: Row) => number) => xs.reduce((a, x) => a + f(x), 0) / xs.length;
  console.log(`${label.padEnd(24)} ${String(xs.length).padStart(4)} points  error ${avg((x) => x.error).toFixed(1).padStart(5)}` +
    `  no change ${avg((x) => x.naive).toFixed(1).padStart(5)}  inside ${(100 * avg((x) => +x.inside)).toFixed(0).padStart(3)}%` +
    `  range ${avg((x) => x.width).toFixed(0)} mg/dL`);
};
const lastDay = end - 86_400;
console.log(`relay replay, widening: ${widenMode}${env("UNGATED") ? ", every horizon drawn" : ""}; final tuning ${JSON.stringify(calibration?.tuning)}`);
for (const m of [15, 30]) {
  const clean = rows.filter((x) => x.clean && x.minutes === m && x.shown);
  line(`${m} min, all`, clean);
  line(`${m} min, last day`, clean.filter((x) => x.t >= lastDay));
}
if (env("LIST")) {
  const from = Number(env("LIST_FROM") || lastDay);
  for (const x of rows.filter((x) => x.t >= from && x.minutes === 15)) {
    console.log(new Date(x.t * 1000).toISOString().slice(0, 16), x.clean ? "clean" : "after log", x.error.toFixed(0), x.naive.toFixed(0), x.inside ? "inside" : "outside");
  }
}
