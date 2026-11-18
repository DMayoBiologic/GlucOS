// Night against day for predicted-low alerts, and one night-only margin (docs/ForecastAccuracy.md §79).
// Replays the relay tick by tick exactly as scripts/low-alert-heldout.ts does, then:
//   1. splits the shipped alerts and lows into night (00:00-06:00 Perth, by the alert's or low's
//      start time) and day: alerts, false alarms, alerts per hour ticked, warning lead per low;
//   2. tries one night-only tweak: a margin BELOW the line, i.e. at night the forecast must cross
//      `margin` mg/dL under 70 (or 54) before a predicted low fires. It can only drop or delay
//      alerts, so the rule it must pass is that no real low anywhere is first warned later than
//      today. Leave one Perth day out: on the other days, take the largest margin that keeps every
//      low's first warning where shipped has it and drops the most night false alarms (ties keep
//      the smaller margin, 0 = shipped), then score the day left out.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/night-low-alerts.ts
//
// dir holds readings.json (with the trend column) and log.json, exported as in §30.
// Knobs: LIST=1 (every alert and low), NIGHT_END=hour (default 6).
import * as core from "../supabase/functions/relay/core.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const readings: core.Reading[] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 0) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const series = new core.Series(readings);
const lowMgdl = 70, window = 45 * 60, shippedFall = -0.3;
const display: core.Display = { unit: "mmol", lowMgdl, highMgdl: 180 };
const afterLog = (from: number, to: number) => logs.some((l) => l > from && l < to);
const dense = (i: number) => i > 0 && readings[i].t - readings[i - 1].t <= 5 * 60;
const start = readings.findIndex((_, i) => dense(i) && readings[i].t - readings[0].t > 3 * 3600);

// The forecasts don't depend on the alert settings, so they're worked out once.
interface Tick { i: number; now: number; f: core.Forecast | null }
const ticks: Tick[] = [];
{
  const live: core.LivePoint[] = [];
  let calibration: core.Calibration | null = null, learnedAt = -Infinity, lastIssued = -Infinity;
  for (let i = start; i < readings.length; i++) {
    if (!dense(i)) continue;
    const now = readings[i].t;
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
    if (f && now - lastIssued >= 15 * 60) {
      lastIssued = now;
      for (const m of core.calibrationHorizons) {
        const near = (x: { t: number }) => Math.abs(x.t - (now + m * 60)) < 30;
        const drawn = res.ok ? f.samples.find(near) : undefined;
        const at = drawn ?? f.unshown?.find(near);
        if (at) live.push({ issuedAt: now, minutes: m, mgdl: at.mgdl, startMgdl: f.startMgdl, actual: null, afterLog: false, shown: !!drawn });
      }
    }
    ticks.push({ i, now, f: res.ok ? res.forecast : null });
  }
}

// Lows: first reading under the line, ending after 15 minutes back at or above it.
interface Low { t: number; end: number; nadir: number }
const lows: Low[] = [];
{
  let current: Low | null = null;
  for (const r of readings) {
    if (r.t < readings[start].t) continue;
    if (r.mgdl < lowMgdl) {
      if (!current) current = { t: r.t, end: r.t, nadir: r.mgdl };
      current.end = r.t;
      current.nadir = Math.min(current.nadir, r.mgdl);
    } else if (current && r.t - current.end >= 15 * 60) {
      lows.push(current);
      current = null;
    }
  }
  if (current) lows.push(current);
}

const nightEnd = Number(env("NIGHT_END") || 6);
const perthHour = (t: number) => new Date((t + 8 * 3600) * 1000).getUTCHours();
const isNight = (t: number) => perthHour(t) < nightEnd;
const perthDay = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(0, 10);
const perthTime = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(5, 16).replace("T", " ");
const lastT = readings[readings.length - 1].t;

// The shipped rules; at night the forecast is lifted by `margin`, so it must cross that far under the line.
function alertsFor(nightMargin: number): number[] {
  const planner = core.newPlanner();
  const prefs: core.AlertPreferences = { ...core.defaultAlertPreferences(), predictedHigh: false };
  const out: number[] = [];
  for (const { i, now, f } of ticks) {
    let g = f;
    if (f && nightMargin && isNight(now)) {
      const lift = (s: core.ForecastSample) => ({ ...s, mgdl: s.mgdl + nightMargin });
      g = { ...f, samples: f.samples.map(lift), unshown: f.unshown?.map(lift), lowLookahead: f.lowLookahead?.map(lift) };
    }
    const snapshot = core.makeSnapshot(series.slice(now - 3600, now), readings[i], null, display, null);
    const n = core.evaluatePrediction(planner, snapshot, g, prefs, now);
    if (n && (n.kind === "predictedLow" || n.kind === "predictedUrgentLow")) out.push(now);
  }
  return out;
}

const scorable = (a: number) => a + window <= lastT;
const falseAlarm = (a: number) => scorable(a) && !readings.some((r) => r.t > a && r.t <= a + window && r.mgdl < lowMgdl);
const nadirAfter = (a: number) => Math.min(...readings.filter((r) => r.t > a && r.t <= a + window).map((r) => r.mgdl));
const firstWarning = (alerts: number[], l: Low) => alerts.find((t) => t <= l.t && t >= l.t - window);

// Hours ticked, night and day.
let nightTicks = 0, dayTicks = 0;
for (const t of ticks) (isNight(t.now) ? nightTicks++ : dayTicks++);

const shipped = alertsFor(0);
const side = (night: boolean) => {
  const al = shipped.filter((a) => isNight(a) === night && scorable(a));
  const fa = al.filter(falseAlarm);
  const ls = lows.filter((l) => isNight(l.t) === night);
  const leads = ls.map((l) => firstWarning(shipped, l)).map((a, k) => a === undefined ? null : (ls[k].t - a) / 60);
  const got = leads.filter((x): x is number => x !== null).sort((a, b) => a - b);
  const hours = (night ? nightTicks : dayTicks) / 60;
  return `${night ? "night" : "day  "}: ${hours.toFixed(0)} h ticked, ${al.length} alerts (${(al.length / hours * 24).toFixed(1)} per 24 h), ` +
    `${fa.length} false (${al.length ? (100 * fa.length / al.length).toFixed(0) : "-"}%, ${(fa.length / hours * 24).toFixed(1)} per 24 h); ` +
    `${ls.length} lows, ${got.length} warned, lead median ${got.length ? got[Math.floor((got.length - 1) / 2)].toFixed(0) : "-"} / mean ` +
    `${got.length ? (got.reduce((a, b) => a + b, 0) / got.length).toFixed(1) : "-"} min [${got.map((x) => x.toFixed(0)).join(" ")}]`;
};
console.log(`night-low-alerts: ${ticks.length} ticks, ${readings.length} readings, night = 00:00-${String(nightEnd).padStart(2, "0")}:00 Perth`);
console.log(side(true));
console.log(side(false));
if (env("LIST")) {
  for (const a of shipped) console.log(`  alert ${perthTime(a)} ${isNight(a) ? "night" : "day  "} reading ${series.value(a)?.toFixed(0)} ` +
    `${!scorable(a) ? "unscored" : falseAlarm(a) ? `FALSE (nadir ${nadirAfter(a)})` : "real"}`);
  for (const l of lows) { const a = firstWarning(shipped, l);
    console.log(`  low ${perthTime(l.t)} ${isNight(l.t) ? "night" : "day  "} nadir ${l.nadir} lead ${a === undefined ? "none" : ((l.t - a) / 60).toFixed(1)}`); }
}

// The night margin, held out by Perth day.
const margins = [0, 2, 4, 6, 8, 10, 12];
const runs = new Map(margins.map((m) => [m, alertsFor(m)]));
const days = [...new Set(ticks.map((t) => perthDay(t.now)))];
interface Cmp { nightFA: number; nightAlerts: number; later: number; earlier: number; lostLead: number; missed: number }
function compare(m: number, inDay: (d: string) => boolean): Cmp {
  const al = runs.get(m)!;
  const c: Cmp = { nightFA: 0, nightAlerts: 0, later: 0, earlier: 0, lostLead: 0, missed: 0 };
  for (const a of al) if (isNight(a) && inDay(perthDay(a)) && scorable(a)) { c.nightAlerts++; if (falseAlarm(a)) c.nightFA++; }
  for (const l of lows) {
    if (!inDay(perthDay(l.t))) continue;
    const base = firstWarning(shipped, l), got = firstWarning(al, l);
    if (base === undefined) continue;
    if (got === undefined) { c.missed++; c.later++; c.lostLead += (l.t - base) / 60; }
    else if (got > base) { c.later++; c.lostLead += (got - base) / 60; }
    else if (got < base) c.earlier++;
  }
  return c;
}
for (const m of margins) {
  const c = compare(m, () => true);
  console.log(`  night margin ${String(m).padStart(2)}: night alerts ${c.nightAlerts}, night false ${c.nightFA}; lows warned later ${c.later} ` +
    `(missed ${c.missed}, ${c.lostLead.toFixed(0)} min lost), earlier ${c.earlier}`);
}
let hoFA = 0, baseFA = 0, hoLater = 0, hoLost = 0, hoMissed = 0;
for (const day of days) {
  let best = 0, bestFA = compare(0, (d) => d !== day).nightFA;
  for (const m of margins) {
    const c = compare(m, (d) => d !== day);
    if (c.later === 0 && c.nightFA < bestFA) { best = m; bestFA = c.nightFA; }
  }
  const got = compare(best, (d) => d === day), base = compare(0, (d) => d === day);
  hoFA += got.nightFA; baseFA += base.nightFA; hoLater += got.later; hoLost += got.lostLead; hoMissed += got.missed;
  console.log(`${day}: chose night margin ${String(best).padStart(2)}  night false ${got.nightFA} (shipped ${base.nightFA}), ` +
    `night alerts ${got.nightAlerts} (${base.nightAlerts}), lows warned later ${got.later} (missed ${got.missed}, ${got.lostLead.toFixed(0)} min)`);
}
console.log(`held out: night false alarms ${hoFA} against shipped ${baseFA}; lows warned later ${hoLater} (missed ${hoMissed}, ${hoLost.toFixed(0)} min lost)`);
