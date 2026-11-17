// Held-out check of the predicted-high alert settings (docs/ForecastAccuracy.md §64), the mirror of
// scripts/low-alert-heldout.ts (§30). Replays the relay tick by tick, once per candidate setting,
// then scores each Perth day apart: for every day, the setting is chosen on the other days and
// scored on the day left out, against the shipped setting.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/high-alert-heldout.ts
//
// dir holds readings.json (with the trend column) and log.json, as for low-alert-heldout.ts.
// Candidates vary:
//   look    drawn: only the drawn forecast (shipped); trend: also its cut-off part and the trend
//           carried on to 30 minutes, as predicted lows read since §13
//   lead    how far ahead a crossing may be, minutes (shipped: min(30 × 1.5, 30) = 30)
//   rise    how fast the trend must rise before a high is looked for, mg/dL per minute (shipped 0.3)
//   margin  warn when the forecast crosses this far below the line (shipped 0)
// A high is a run of readings over 180 that starts after 15 minutes at or under it. It counts as
// warned if a predicted-high (or very-high) alert came in the 45 minutes before it started, while
// the reading was still at or under 180; such an alert is a false alarm if no reading went over 180
// in the 45 minutes after it. A day scores the minutes of warning, capped at 30 per high, minus
// PENALTY (default 10) minutes per false alarm.
// Knobs: PENALTY=min, LIST=1 (each candidate's totals), FROM=unix seconds.
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
const highMgdl = 180, window = 45 * 60, shippedRise = 0.3, highLeadFactor = 1.5;
const display: core.Display = { unit: "mmol", lowMgdl: 70, highMgdl };
const afterLog = (from: number, to: number) => logs.some((l) => l > from && l < to);
const dense = (i: number) => i > 0 && readings[i].t - readings[i - 1].t <= 5 * 60;
const start = readings.findIndex((_, i) => dense(i) && readings[i].t - readings[0].t > 3 * 3600);

// The forecasts don't depend on the alert settings, so they're worked out once (as §30).
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

// Highs: first reading over the line after 15 minutes at or under it.
interface High { t: number; end: number; peak: number }
const highs: High[] = [];
{
  let current: High | null = null;
  for (const r of readings) {
    if (r.mgdl > highMgdl) {
      if (!current) current = { t: r.t, end: r.t, peak: r.mgdl };
      current.end = r.t;
      current.peak = Math.max(current.peak, r.mgdl);
    } else if (current && r.t - current.end >= 15 * 60) {
      if (current.t >= readings[start].t) highs.push(current);
      current = null;
    }
  }
  if (current && current.t >= readings[start].t) highs.push(current);
}

type Look = "drawn" | "trend";
interface Candidate { look: Look; lead: number; rise: number; margin: number }
const name = (c: Candidate) => `${c.look}, lead ${c.lead}, rise ${c.rise}, margin ${c.margin}`;
const shippedPrefs = core.defaultAlertPreferences();
const shipped: Candidate = { look: "drawn", lead: Math.min(shippedPrefs.predictiveMinutes * highLeadFactor, 30),
                             rise: shippedRise, margin: 0 };

// The shipped rules on a forecast shifted up by the margin, with the trend gate moved by adjusting
// what the rules see as the trend, and the lead set through the preference (lead = pref × 1.5,
// capped at 30). "trend" hands the rules every sample out to 30 minutes as if drawn.
function alertsFor(c: Candidate): number[] {
  const planner = core.newPlanner();
  // Lows are checked first and take precedence, so on each tick the shipped low rule runs on the
  // original forecast (a throwaway planner copy says whether it finds a low). If it does, the real
  // planner sees exactly the shipped low call; otherwise it sees the candidate high rule alone.
  const lowPrefs: core.AlertPreferences = { ...shippedPrefs, predictedHigh: false };
  const highPrefs: core.AlertPreferences = { ...shippedPrefs, predictedLow: false, predictiveMinutes: c.lead / highLeadFactor };
  const out: number[] = [];
  const shift = (s: core.ForecastSample) => ({ ...s, mgdl: s.mgdl + c.margin });
  for (const { i, now, f } of ticks) {
    const snapshot = core.makeSnapshot(series.slice(now - 3600, now), readings[i], null, display, null);
    const probe = structuredClone(planner);
    core.evaluatePrediction(probe, snapshot, f, lowPrefs, now);
    if (f && probe.quietSince === null) {
      core.evaluatePrediction(planner, snapshot, f, lowPrefs, now);
      continue;
    }
    let g = f;
    if (f) {
      const trendPerMinute = f.trendPerMinute >= c.rise ? Math.max(f.trendPerMinute, shippedRise) : Math.min(f.trendPerMinute, 0);
      const all = c.look === "trend" && f.basis === "trend" ? [...f.samples, ...(f.unshown ?? []), ...(f.lowLookahead ?? [])] : f.samples;
      g = { ...f, trendPerMinute, samples: all.map(shift), unshown: undefined, lowLookahead: undefined };
    }
    const n = core.evaluatePrediction(planner, snapshot, g, highPrefs, now);
    if (n && (n.kind === "predictedHigh" || n.kind === "predictedVeryHigh") && readings[i].mgdl <= highMgdl) out.push(now);
  }
  return out;
}

const perthDay = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(0, 10);
const days = [...new Set(ticks.map((t) => perthDay(t.now)))];
interface DayScore { highs: number; warned: number; leads: number[]; alerts: number; falseAlarms: number; score: number;
                    /** Penalty from false alarms whose follow-up window reaches into the next Perth day. */ spill: number;
                    /** Warning credit from alerts on the Perth day before. */ borrowed: number }
const lastReading = readings[readings.length - 1].t;
// The follow-up was seen if it ends before the export does and has no gap over 15 minutes.
function followUpSeen(a: number): boolean {
  if (a + window > lastReading) return false;
  let prev = a;
  for (const r of readings) {
    if (r.t <= a) continue;
    if (r.t - prev > 15 * 60) return false;
    if (r.t > a + window) return true;
    prev = r.t;
  }
  return false;
}
function score(alerts: number[]): Map<string, DayScore> {
  const byDay = new Map<string, DayScore>(days.map((d) => [d, { highs: 0, warned: 0, leads: [], alerts: 0, falseAlarms: 0, score: 0, spill: 0, borrowed: 0 }]));
  for (const h of highs) {
    if (h.t < scoreFrom || !byDay.has(perthDay(h.t))) continue;
    const d = byDay.get(perthDay(h.t))!;
    d.highs++;
    const a = alerts.find((t) => t <= h.t && t >= h.t - window);
    if (a !== undefined) {
      d.warned++;
      d.leads.push((h.t - a) / 60);
      d.score += Math.min(30, (h.t - a) / 60);
      if (perthDay(a) !== perthDay(h.t)) {
        // Without the day before, the earliest alert on the high's own day (if any) would count.
        const own = alerts.find((t) => t <= h.t && t >= h.t - window && perthDay(t) === perthDay(h.t));
        d.borrowed += Math.min(30, (h.t - a) / 60) - (own === undefined ? 0 : Math.min(30, (h.t - own) / 60));
      }
    }
  }
  for (const a of alerts) {
    if (a < scoreFrom || !followUpSeen(a)) continue;
    const d = byDay.get(perthDay(a))!;
    d.alerts++;
    if (!readings.some((r) => r.t > a && r.t <= a + window && r.mgdl > highMgdl)) {
      d.falseAlarms++;
      d.score -= penalty;
      if (perthDay(a + window) !== perthDay(a)) d.spill += penalty;
    }
  }
  return byDay;
}

const candidates: Candidate[] = [];
for (const look of ["drawn", "trend"] as Look[]) for (const lead of [15, 20, 25, 30])
  for (const rise of [0.2, 0.3, 0.4, 0.5]) for (const margin of [0, 4, 8, 12]) candidates.push({ look, lead, rise, margin });
const scored = candidates.map((c) => ({ c, days: score(alertsFor(c)) }));
const shippedScore = scored.find((s) => name(s.c) === name(shipped))!;
// Training on the other days leaves out what the held-out day decided: false-alarm penalties its
// readings settled for the evening before, and warning credit its alerts gave the morning after.
const total = (m: Map<string, DayScore>, skip?: string) => [...m].filter(([d]) => d !== skip)
  .reduce((a, [d, s]) => a + s.score + (skip !== undefined && days[days.indexOf(d) + 1] === skip ? s.spill : 0)
    - (skip !== undefined && days[days.indexOf(d) - 1] === skip ? s.borrowed : 0), 0);
const sum = (m: Map<string, DayScore>, k: "highs" | "warned" | "alerts" | "falseAlarms") => [...m.values()].reduce((a, s) => a + s[k], 0);
const leadsOf = (m: Map<string, DayScore>) => [...m.values()].flatMap((s) => s.leads).sort((a, b) => a - b);
const describe = (m: Map<string, DayScore>) => {
  const l = leadsOf(m);
  const median = l.length ? l[Math.floor((l.length - 1) / 2)] : NaN;
  const mean = l.length ? l.reduce((a, b) => a + b, 0) / l.length : NaN;
  return `highs ${sum(m, "highs")}, warned ${sum(m, "warned")}, median ${median.toFixed(0)} / mean ${mean.toFixed(1)} min, ` +
    `alerts ${sum(m, "alerts")}, false alarms ${sum(m, "falseAlarms")}, score ${total(m).toFixed(0)}`;
};

console.log(`high-alert held-out check: ${ticks.length} ticks, ${days.length} Perth days, penalty ${penalty} min per false alarm` +
  (scoreFrom ? `, scored from ${new Date(scoreFrom * 1000).toISOString()}` : ""));
console.log(`shipped (${name(shipped)}): ${describe(shippedScore.days)}`);
if (env("LIST")) {
  for (const s of [...scored].sort((a, b) => total(b.days) - total(a.days))) console.log(`  ${name(s.c).padEnd(40)} ${describe(s.days)}`);
  for (const h of highs) {
    const a = alertsFor(shipped).find((t) => t <= h.t && t >= h.t - window);
    console.log(`  high ${new Date((h.t + 8 * 3600) * 1000).toISOString().slice(5, 16)} peak ${h.peak} ` +
      (a ? `warned ${((h.t - a) / 60).toFixed(0)} min` : "not warned"));
  }
}
// Leave one day out: choose on the other days (ties keep the shipped setting), score the day left out.
let heldOut = 0, heldShipped = 0, heldFA = 0, heldShippedFA = 0, heldWarned = 0, heldShippedWarned = 0, heldMin = 0, heldShippedMin = 0;
for (const day of days) {
  let best = shippedScore;
  for (const s of scored) if (total(s.days, day) > total(best.days, day)) best = s;
  const got = best.days.get(day)!, base = shippedScore.days.get(day)!;
  heldOut += got.score; heldShipped += base.score;
  heldFA += got.falseAlarms; heldShippedFA += base.falseAlarms;
  heldWarned += got.warned; heldShippedWarned += base.warned;
  heldMin += got.leads.reduce((a, b) => a + Math.min(30, b), 0); heldShippedMin += base.leads.reduce((a, b) => a + Math.min(30, b), 0);
  console.log(`${day}: chose ${name(best.c).padEnd(40)} held out ${got.score.toFixed(0).padStart(4)} ` +
    `(warned ${got.warned}/${got.highs}, false ${got.falseAlarms})  shipped ${base.score.toFixed(0).padStart(4)} (warned ${base.warned}/${base.highs}, false ${base.falseAlarms})`);
}
console.log(`held out: chosen ${heldOut.toFixed(0)} (warned ${heldWarned}, ${heldMin.toFixed(0)} warning min, false alarms ${heldFA})  ` +
  `shipped ${heldShipped.toFixed(0)} (warned ${heldShippedWarned}, ${heldShippedMin.toFixed(0)} warning min, false alarms ${heldShippedFA})`);
