// Held-out check of the predicted-low alert settings (docs/ForecastAccuracy.md §30). Replays the
// relay tick by tick exactly as scripts/low-alert-replay.ts does, once per candidate setting, then
// scores each Perth day apart: for every day, the setting is chosen on the other days and scored on
// the day left out, against the shipped setting.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/low-alert-heldout.ts
//
// dir holds readings.json and log.json, as for low-alert-replay.ts. Candidates vary:
//   lead    how far ahead a crossing may be (the "warn me ahead" preference), minutes
//   fall    how fast the trend must fall before a low is looked for, mg/dL per minute (shipped -0.3)
//   margin  warn when the forecast crosses this far above the line (shipped 0)
// A low counts as warned if a predicted-low alert came in the 45 minutes before it started, and an
// alert is a false alarm if no reading went under 70 in the 45 minutes after it (the same window
// both ways, so one alert can't be both). A day scores the minutes of warning, capped at 30 per low,
// minus PENALTY (default 10) minutes per false alarm.
// Knobs: PENALTY=min, LIST=1 (each candidate's totals), FROM=unix seconds (score only lows and
// alerts from then on, e.g. since a release).
import * as core from "../supabase/functions/relay/core.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const readings: core.Reading[] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 0) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const penalty = Number(env("PENALTY") || 10);
const scoreFrom = Number(env("FROM") || 0);
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

interface Candidate { lead: number; fall: number; margin: number }
const name = (c: Candidate) => `lead ${c.lead}, fall ${c.fall}, margin ${c.margin}`;
const shipped: Candidate = { lead: core.defaultAlertPreferences().predictiveMinutes, fall: shippedFall, margin: 0 };

// The shipped rules, with the forecast shifted down by the margin and the trend gate moved by
// adjusting what the rules see as the trend.
function alertsFor(c: Candidate): number[] {
  const planner = core.newPlanner();
  const prefs: core.AlertPreferences = { ...core.defaultAlertPreferences(), predictedHigh: false, predictiveMinutes: c.lead };
  const out: number[] = [];
  const shift = (s: core.ForecastSample) => ({ ...s, mgdl: s.mgdl - c.margin });
  for (const { i, now, f } of ticks) {
    let g = f;
    if (f) {
      const trendPerMinute = f.trendPerMinute <= c.fall ? Math.min(f.trendPerMinute, shippedFall) : Math.max(f.trendPerMinute, 0);
      g = { ...f, trendPerMinute, samples: f.samples.map(shift), unshown: f.unshown?.map(shift), lowLookahead: f.lowLookahead?.map(shift) };
    }
    const snapshot = core.makeSnapshot(series.slice(now - 3600, now), readings[i], null, display, null);
    const n = core.evaluatePrediction(planner, snapshot, g, prefs, now);
    if (n && (n.kind === "predictedLow" || n.kind === "predictedUrgentLow")) out.push(now);
  }
  return out;
}

const perthDay = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(0, 10);
const days = [...new Set(ticks.map((t) => perthDay(t.now)))];
interface DayScore { lows: number; warned: number; leads: number[]; alerts: number; falseAlarms: number; score: number }
function score(alerts: number[]): Map<string, DayScore> {
  const byDay = new Map<string, DayScore>(days.map((d) => [d, { lows: 0, warned: 0, leads: [], alerts: 0, falseAlarms: 0, score: 0 }]));
  for (const l of lows) {
    if (l.t < scoreFrom) continue;
    const d = byDay.get(perthDay(l.t))!;
    d.lows++;
    const a = alerts.find((t) => t <= l.t && t >= l.t - window);
    if (a !== undefined) {
      d.warned++;
      d.leads.push((l.t - a) / 60);
      d.score += Math.min(30, (l.t - a) / 60);
    }
  }
  for (const a of alerts) {
    if (a < scoreFrom) continue;
    const d = byDay.get(perthDay(a))!;
    d.alerts++;
    if (!readings.some((r) => r.t > a && r.t <= a + window && r.mgdl < lowMgdl)) {
      d.falseAlarms++;
      d.score -= penalty;
    }
  }
  return byDay;
}

const candidates: Candidate[] = [];
for (const lead of [15, 20, 25, 30]) for (const fall of [-0.2, -0.3, -0.4, -0.5]) for (const margin of [0, 4, 8]) candidates.push({ lead, fall, margin });
const scored = candidates.map((c) => ({ c, days: score(alertsFor(c)) }));
const shippedScore = scored.find((s) => name(s.c) === name(shipped))!;
const total = (m: Map<string, DayScore>, skip?: string) => [...m].filter(([d]) => d !== skip).reduce((a, [, s]) => a + s.score, 0);
const sum = (m: Map<string, DayScore>, k: "lows" | "warned" | "alerts" | "falseAlarms") => [...m.values()].reduce((a, s) => a + s[k], 0);
const leadsOf = (m: Map<string, DayScore>) => [...m.values()].flatMap((s) => s.leads).sort((a, b) => a - b);
const describe = (m: Map<string, DayScore>) => {
  const l = leadsOf(m);
  const median = l.length ? l[Math.floor((l.length - 1) / 2)] : NaN;
  const mean = l.length ? l.reduce((a, b) => a + b, 0) / l.length : NaN;
  return `lows ${sum(m, "lows")}, warned ${sum(m, "warned")}, median ${median.toFixed(0)} / mean ${mean.toFixed(1)} min, ` +
    `alerts ${sum(m, "alerts")}, false alarms ${sum(m, "falseAlarms")}, score ${total(m).toFixed(0)}`;
};

console.log(`low-alert held-out check: ${ticks.length} ticks, ${days.length} Perth days, penalty ${penalty} min per false alarm` +
  (scoreFrom ? `, scored from ${new Date(scoreFrom * 1000).toISOString()}` : ""));
console.log(`shipped (${name(shipped)}): ${describe(shippedScore.days)}`);
if (env("LIST")) {
  for (const s of [...scored].sort((a, b) => total(b.days) - total(a.days))) console.log(`  ${name(s.c).padEnd(32)} ${describe(s.days)}`);
}
// Leave one day out: choose on the other days (ties keep the shipped setting), score the day left out.
let heldOut = 0, heldShipped = 0, heldFA = 0, heldShippedFA = 0, heldWarned = 0, heldShippedWarned = 0;
for (const day of days) {
  let best = shippedScore;
  for (const s of scored) if (total(s.days, day) > total(best.days, day)) best = s;
  const got = best.days.get(day)!, base = shippedScore.days.get(day)!;
  heldOut += got.score; heldShipped += base.score;
  heldFA += got.falseAlarms; heldShippedFA += base.falseAlarms;
  heldWarned += got.warned; heldShippedWarned += base.warned;
  console.log(`${day}: chose ${name(best.c).padEnd(32)} held out ${got.score.toFixed(0).padStart(4)} ` +
    `(warned ${got.warned}/${got.lows}, false ${got.falseAlarms})  shipped ${base.score.toFixed(0).padStart(4)} (warned ${base.warned}/${base.lows}, false ${base.falseAlarms})`);
}
console.log(`held out: chosen ${heldOut.toFixed(0)} (warned ${heldWarned}, false alarms ${heldFA})  ` +
  `shipped ${heldShipped.toFixed(0)} (warned ${heldShippedWarned}, false alarms ${heldShippedFA})`);
