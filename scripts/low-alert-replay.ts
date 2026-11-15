// Walk-forward replay of the relay's forecast-based low alerts, minute by minute the way the relay
// ticks: forecast from the last hour, relearn every 3 hours from the last 14 days, cut the drawn
// horizon from its own ledger (liveHorizon), then run the predicted-alert rules on each tick.
// Scores every low (readings under 70 mg/dL) for how early it was warned, and every alert for
// whether a low followed. See docs/ForecastAccuracy.md §13.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-replay.ts
//
// dir holds readings.json ([[unix seconds, mg/dL], …]) and log.json, as for relay-replay.ts.
// Knobs:
//   LOOK=drawn    predicted lows read only the drawn forecast, as before §13 (default: the shipped rule)
//   LEAD=min      how far ahead a crossing may be (default: the preference's default)
//   LIST=1        list each low and each alert
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
const lowMgdl = 70;
const display: core.Display = { unit: "mmol", lowMgdl, highMgdl: 180 };
const prefs: core.AlertPreferences = { ...core.defaultAlertPreferences(), predictedHigh: env("HIGHS") === "1" };
if (env("LEAD")) prefs.predictiveMinutes = Number(env("LEAD"));
const look: core.LowLookahead = env("LOOK") === "drawn" ? "drawn" : core.lowLookahead;
const afterLog = (from: number, to: number) => logs.some((l) => l > from && l < to);

// Only where readings come every minute or so: the 15-minute LinkUp history at the start can't be
// ticked through like the relay.
const dense = (i: number) => i > 0 && readings[i].t - readings[i - 1].t <= 5 * 60;

const planner = core.newPlanner();
const live: core.LivePoint[] = [];
let calibration: core.Calibration | null = null, learnedAt = -Infinity, lastIssued = -Infinity;
interface Alert { t: number; mgdl: number; kind: string }
const alerts: Alert[] = [];
const horizons: Record<string, number> = {};
let ticks = 0, highAlerts = 0;
const start = readings.findIndex((_, i) => dense(i) && readings[i].t - readings[0].t > 3 * 3600);

for (let i = start; i < readings.length; i++) {
  if (!dense(i)) continue;
  const now = readings[i].t;
  ticks++;
  if (now - learnedAt > 3 * 3600) {
    calibration = core.learnCalibration(series.slice(now - 14 * 86_400, now), now, 14);
    learnedAt = now;
  }
  for (const p of live) {
    const target = p.issuedAt + p.minutes * 60;
    if (p.actual !== null || target > now) continue;
    p.actual = series.value(target);
    p.afterLog = afterLog(p.issuedAt, target);
  }
  const recent = series.slice(now - 3600, now);
  const res = core.forecast(new core.Series(recent, true), calibration, now, undefined,
    calibration?.tuning ?? core.standardTuning, core.liveHorizon(live, now), core.effectiveRangeScale(null, calibration));
  const f = res.ok ? res.forecast : res.unshown;
  const drawnTo = res.ok ? `${Math.round((res.forecast.samples.at(-1)!.t - now) / 60)} min` : "none";
  horizons[drawnTo] = (horizons[drawnTo] ?? 0) + 1;
  if (f && now - lastIssued >= 15 * 60) {
    lastIssued = now;
    for (const m of core.calibrationHorizons) {
      const near = (x: { t: number }) => Math.abs(x.t - (now + m * 60)) < 30;
      const drawn = res.ok ? f.samples.find(near) : undefined;
      const at = drawn ?? f.unshown?.find(near);
      if (at) live.push({ issuedAt: now, minutes: m, mgdl: at.mgdl, startMgdl: f.startMgdl, actual: null, afterLog: false, shown: !!drawn });
    }
  }
  const snapshot = core.makeSnapshot(recent, readings[i], null, display, null);
  const n = core.evaluatePrediction(planner, snapshot, res.ok ? res.forecast : null, prefs, now, look);
  if (n && (n.kind === "predictedHigh" || n.kind === "predictedVeryHigh")) highAlerts++;
  if (n && (n.kind === "predictedLow" || n.kind === "predictedUrgentLow")) alerts.push({ t: now, mgdl: readings[i].mgdl, kind: n.kind });
}

// A low starts at the first reading under the line and ends once readings have stayed at or above
// it for 15 minutes.
interface Low { t: number; end: number; nadir: number; warnedAt: number | null }
const lows: Low[] = [];
let current: Low | null = null;
const from = readings[start].t;
for (const r of readings) {
  if (r.t < from) continue;
  if (r.mgdl < lowMgdl) {
    if (!current) current = { t: r.t, end: r.t, nadir: r.mgdl, warnedAt: null };
    current.end = r.t;
    current.nadir = Math.min(current.nadir, r.mgdl);
  } else if (current && r.t - current.end >= 15 * 60) {
    lows.push(current);
    current = null;
  }
}
if (current) lows.push(current);
// Warned: an alert in the hour before it started. A false alarm: no reading under the line in the
// 45 minutes after the alert.
for (const l of lows) l.warnedAt = alerts.find((a) => a.t <= l.t && a.t >= l.t - 3600)?.t ?? null;
const falseAlarms = alerts.filter((a) => !readings.some((r) => r.t > a.t && r.t <= a.t + 45 * 60 && r.mgdl < lowMgdl));

const hours = (readings[readings.length - 1].t - from) / 3600;
const warned = lows.filter((l) => l.warnedAt !== null);
const leads = warned.map((l) => (l.t - l.warnedAt!) / 60).sort((a, b) => a - b);
const median = leads.length ? leads[Math.floor((leads.length - 1) / 2)] : NaN;
const mean = leads.length ? leads.reduce((a, b) => a + b, 0) / leads.length : NaN;
const iso = (t: number) => new Date(t * 1000).toISOString().slice(5, 16).replace("T", " ");
console.log(`low-alert replay: ${hours.toFixed(0)} h ticked (${ticks} ticks from ${iso(from)} UTC), lows read ${look}, lead ${prefs.predictiveMinutes} min`);
console.log(`lows ${lows.length}  warned ${warned.length}  missed ${lows.length - warned.length}  ` +
  `warning median ${median.toFixed(0)} min, mean ${mean.toFixed(1)} min ahead  alerts ${alerts.length}  false alarms ${falseAlarms.length}`);
if (prefs.predictedHigh) console.log(`predicted-high alerts ${highAlerts}`);
console.log(`drawn forecast reaches: ${Object.entries(horizons).map(([k, v]) => `${k} ${(100 * v / ticks).toFixed(0)}%`).join(", ")}`);
if (env("LIST")) {
  for (const l of lows) console.log(`low   ${iso(l.t)}  nadir ${l.nadir}  ${((l.end - l.t) / 60).toFixed(0)} min  ` +
    (l.warnedAt ? `warned ${((l.t - l.warnedAt) / 60).toFixed(0)} min before` : "no warning"));
  for (const a of alerts) console.log(`alert ${iso(a.t)}  at ${a.mgdl}  ${a.kind}  ${falseAlarms.includes(a) ? "false alarm" : "borne out"}`);
}
