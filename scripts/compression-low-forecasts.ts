// Overnight compression lows: how the forecast line and predicted-low alerts behave through them,
// and one held-out tweak (docs/ForecastAccuracy.md §104). Follows §17 (compression-lows.ts) and §79
// (night-low-alerts.ts), and replays the relay tick by tick exactly as those do.
//
// A compression low: a reading between 22:00 and 07:00 Perth that is the lowest within 10 minutes,
// at least DROP mg/dL (20) under the highest of the 15 minutes before it, reached at RATE (2) mg/dL
// a minute or faster, that comes back by at least two thirds of the drop within 30 minutes, with
// nothing logged from 3 h before to 30 min after. Detection reads one reading a minute, preferring
// the live feed (the 15-minute history twins disagree with it, §74).
//
// Through each one (from the top of the drop to 30 minutes after the nadir) every relay tick's line
// is scored at 15 and 30 minutes, drawn or unshown, as the relay ledger does, against the other
// overnight ticks. Bias = actual - line (positive = line ran low). Predicted-low alerts that fire in
// those windows are listed with whether glucose went under 70 in the 45 minutes after.
//
// Tweak tried (trend forecast only, nothing about insulin, carbs or doses): at night, with nothing
// logged for 3 h, when the reading is DROP or more under the highest of the last 15 minutes at RATE
// a minute or faster, the line's move from the reading is scaled by w (1 = shipped). It is causal:
// it only knows the drop so far, not that the dip will come back. Leave one Perth day out: on the
// other days take the w with the lowest overnight error (15 and 30 minutes pooled) among those that warn no low
// later than shipped (ties keep the larger w), then score the day left out.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/compression-low-forecasts.ts
//
// dir holds readings.json ([[unix, mg/dL, trend], ...], all of glucos.readings) and log.json (unix
// times of meals and doses), exported as in §79. Knobs: DROP, RATE, LIST=1, LOGGED=1 (also count dips
// with something logged near them; the tweak's trigger still needs 3 h with nothing logged).
import * as core from "../supabase/functions/relay/core.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const readings: core.Reading[] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 0) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const series = new core.Series(readings);
const lowMgdl = 70, window = 45 * 60;
const DROP = Number(env("DROP") || 20), RATE = Number(env("RATE") || 2), ANY_LOG = !!env("LOGGED");
const display: core.Display = { unit: "mmol", lowMgdl, highMgdl: 180 };
const logged = (from: number, to: number) => logs.some((l) => l >= from && l <= to);
const dense = (i: number) => i > 0 && readings[i].t - readings[i - 1].t <= 5 * 60;
const start = readings.findIndex((_, i) => dense(i) && readings[i].t - readings[0].t > 3 * 3600);
const perthHour = (t: number) => new Date((t + 8 * 3600) * 1000).getUTCHours();
const overnight = (t: number) => { const h = perthHour(t); return h >= 22 || h < 7; };
// A night belongs to the Perth day it ends on (22:00 counts with the next morning).
const nightOf = (t: number) => new Date((t + 8 * 3600 + 2 * 3600) * 1000).toISOString().slice(0, 10);
const perthTime = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(5, 16).replace("T", " ");
const lastT = readings[readings.length - 1].t;

// One reading a minute, live preferred.
const perMinute = new Map<number, core.Reading>();
for (const r of readings) {
  const k = Math.floor(r.t / 60), had = perMinute.get(k);
  if (!had || (had.trend === 0 && r.trend !== 0)) perMinute.set(k, r);
}
const rs = [...perMinute.values()].sort((a, b) => a.t - b.t);

// Compression lows.
interface Dip { top: number; topAt: number; t: number; nadir: number; rate: number; back: number }
const dips: Dip[] = [];
for (let i = 0; i < rs.length; i++) {
  const { t, mgdl: v } = rs[i];
  if (!overnight(t) || t < readings[start].t) continue;
  if (rs.some((r) => Math.abs(r.t - t) <= 600 && (r.mgdl < v || (r.mgdl === v && r.t < t)))) continue;
  const before = rs.filter((r) => t - r.t > 0 && t - r.t <= 900), after = rs.filter((r) => r.t - t > 0 && r.t - t <= 1800);
  if (before.length < 8 || after.length < 10) continue;
  const top = Math.max(...before.map((r) => r.mgdl)), topAt = before.find((r) => r.mgdl === top)!.t;
  const rate = (top - v) / Math.max(1, (t - topAt) / 60), back = Math.max(...after.map((r) => r.mgdl)) - v;
  if (top - v >= DROP && rate >= RATE && back >= (2 / 3) * (top - v) && (ANY_LOG || !logged(t - 3 * 3600, t + 1800))) {
    dips.push({ top, topAt, t, nadir: v, rate, back });
  }
}
const inDip = (t: number) => dips.find((d) => t >= d.topAt && t <= d.t + 1800);

// Relay ticks, as in night-low-alerts.ts.
interface Tick { i: number; now: number; f: core.Forecast | null; scored: core.Forecast | null; trigger: boolean }
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
      p.afterLog = logged(p.issuedAt, target);
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
    // The tweak's trigger: only what's known at `now`.
    const last15 = rs.filter((r) => r.t <= now && now - r.t <= 900);
    let trigger = false;
    if (overnight(now) && last15.length >= 5 && !logged(now - 3 * 3600, now)) {
      const top = Math.max(...last15.map((r) => r.mgdl)), topAt = last15.find((r) => r.mgdl === top)!.t;
      const drop = top - readings[i].mgdl;
      trigger = drop >= DROP && drop / Math.max(1, (now - topAt) / 60) >= RATE;
    }
    ticks.push({ i, now, f: res.ok ? res.forecast : null, scored: f ?? null, trigger });
  }
}

function scaled(f: core.Forecast, w: number): core.Forecast {
  const s = (x: core.ForecastSample) => ({
    ...x, mgdl: f.startMgdl + w * (x.mgdl - f.startMgdl),
    lowerMgdl: f.startMgdl + w * (x.lowerMgdl - f.startMgdl), upperMgdl: f.startMgdl + w * (x.upperMgdl - f.startMgdl),
  });
  return { ...f, samples: f.samples.map(s), unshown: f.unshown?.map(s), lowLookahead: f.lowLookahead?.map(s) };
}
const lineAt = (f: core.Forecast, t: number) =>
  [...f.samples, ...(f.unshown ?? [])].find((x) => Math.abs(x.t - t) < 30);

// Forecast error.
interface Pt { night: string; dip: boolean; trigger: boolean; h: number; err: (w: number) => number; nc: number }
const pts: Pt[] = [];
for (const k of ticks) {
  const f = k.scored;
  if (!f || !overnight(k.now)) continue;
  for (const h of [15, 30]) {
    const target = k.now + h * 60;
    const a = series.value(target), x = lineAt(f, target);
    if (a === null || a === undefined || !x) continue;
    pts.push({
      night: nightOf(k.now), dip: !!inDip(k.now), trigger: k.trigger, h,
      err: (w) => a - (k.trigger ? f.startMgdl + w * (x.mgdl - f.startMgdl) : x.mgdl), nc: Math.abs(a - f.startMgdl),
    });
  }
}
const mean = (xs: number[]) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN;
function row(name: string, sub: Pt[], w = 1) {
  const cells = [15, 30].map((h) => {
    const s = sub.filter((p) => p.h === h), e = s.map((p) => p.err(w));
    return `${h}m n=${String(s.length).padStart(5)} mae ${mean(e.map(Math.abs)).toFixed(1).padStart(5)} ` +
      `nc ${mean(s.map((p) => p.nc)).toFixed(1).padStart(5)} bias ${(mean(e) >= 0 ? "+" : "") + mean(e).toFixed(1)}`;
  });
  console.log(`  ${name.padEnd(28)} ${cells.join(" | ")}`);
}

// Alerts.
function alertsFor(w: number): number[] {
  const planner = core.newPlanner();
  const prefs: core.AlertPreferences = { ...core.defaultAlertPreferences(), predictedHigh: false };
  const out: number[] = [];
  for (const { i, now, f, trigger } of ticks) {
    const g = f && trigger && w !== 1 ? scaled(f, w) : f;
    const snapshot = core.makeSnapshot(series.slice(now - 3600, now), readings[i], null, display, null);
    const n = core.evaluatePrediction(planner, snapshot, g, prefs, now);
    if (n && (n.kind === "predictedLow" || n.kind === "predictedUrgentLow")) out.push(now);
  }
  return out;
}

interface Low { t: number; end: number; nadir: number }
const lows: Low[] = [];
{
  let cur: Low | null = null;
  for (const r of readings) {
    if (r.t < readings[start].t) continue;
    if (r.mgdl < lowMgdl) { if (!cur) cur = { t: r.t, end: r.t, nadir: r.mgdl }; cur.end = r.t; cur.nadir = Math.min(cur.nadir, r.mgdl); }
    else if (cur && r.t - cur.end >= 900) { lows.push(cur); cur = null; }
  }
  if (cur) lows.push(cur);
}
const scorable = (a: number) => a + window <= lastT;
const falseAlarm = (a: number) => scorable(a) && !readings.some((r) => r.t > a && r.t <= a + window && r.mgdl < lowMgdl);
const nadirAfter = (a: number) => Math.min(...readings.filter((r) => r.t > a && r.t <= a + window).map((r) => r.mgdl));
const firstWarning = (al: number[], l: Low) => al.find((t) => t <= l.t && t >= l.t - window);

const nights = [...new Set(ticks.filter((k) => overnight(k.now)).map((k) => nightOf(k.now)))];
console.log(`compression-low-forecasts: ${readings.length} readings, ${ticks.length} ticks, ${nights.length} nights (22:00-07:00 Perth), ` +
  `DROP ${DROP} RATE ${RATE}`);
console.log(`${dips.length} compression lows on ${new Set(dips.map((d) => nightOf(d.t))).size} nights; under 70: ${dips.filter((d) => d.nadir < lowMgdl).length}; ` +
  `under 80: ${dips.filter((d) => d.nadir < 80).length}`);
const shipped = alertsFor(1);
for (const d of dips) {
  const al = shipped.filter((a) => a >= d.topAt && a <= d.t + 1800);
  console.log(`  ${perthTime(d.t)} ${d.top}→${d.nadir} at ${d.rate.toFixed(1)}/min, back +${d.back}` +
    (al.length ? `; predicted-low alerts ${al.map((a) => `${perthTime(a).slice(6)} ${falseAlarm(a) ? `FALSE (nadir ${nadirAfter(a)})` : "real"}`).join(", ")}` : ""));
}

console.log("\nForecast error overnight (bias = actual - line; positive = line ran low):");
const night = pts;
row("all overnight", night);
row("through compression lows", night.filter((p) => p.dip));
row("  of those, trigger on", night.filter((p) => p.dip && p.trigger));
row("other overnight", night.filter((p) => !p.dip));
row("trigger on, not a dip", night.filter((p) => !p.dip && p.trigger));
console.log(`  trigger ticks: ${new Set(ticks.filter((k) => k.trigger).map((k) => k.now)).size}, ` +
  `in a compression low ${ticks.filter((k) => k.trigger && inDip(k.now)).length}`);

const nightAlerts = shipped.filter((a) => overnight(a) && scorable(a));
const dipAlerts = nightAlerts.filter((a) => inDip(a));
console.log(`\nPredicted-low alerts overnight: ${nightAlerts.length}, false ${nightAlerts.filter(falseAlarm).length}; ` +
  `in compression lows ${dipAlerts.length}, false ${dipAlerts.filter(falseAlarm).length}`);
if (env("LIST")) for (const a of nightAlerts) console.log(`  alert ${perthTime(a)} reading ${series.value(a)?.toFixed(0)} ` +
  `${falseAlarm(a) ? `FALSE (nadir ${nadirAfter(a)})` : "real"}${inDip(a) ? " in a compression low" : ""}`);

// The tweak, held out.
const ws = [1, 0.75, 0.5, 0.25, 0];
const runs = new Map(ws.map((w) => [w, alertsFor(w)]));
function score(w: number, keep: (n: string) => boolean) {
  const sub = pts.filter((p) => keep(p.night));
  const e15 = mean(sub.filter((p) => p.h === 15).map((p) => Math.abs(p.err(w))));
  const e30 = mean(sub.filter((p) => p.h === 30).map((p) => Math.abs(p.err(w))));
  const sum = sub.reduce((a, p) => a + Math.abs(p.err(w)), 0), count = sub.length;
  const al = runs.get(w)!;
  let later = 0, lost = 0, fa = 0, n = 0;
  for (const l of lows) {
    if (!keep(nightOf(l.t))) continue;
    const base = firstWarning(shipped, l), got = firstWarning(al, l);
    if (base === undefined) continue;
    if (got === undefined || got > base) { later++; lost += ((got ?? l.t) - base) / 60; }
  }
  for (const a of al) if (overnight(a) && keep(nightOf(a)) && scorable(a)) { n++; if (falseAlarm(a)) fa++; }
  return { e15, e30, sum, count, later, lost, fa, n };
}
console.log("\nTweak: scale the line's move by w on a fast unlogged overnight drop (all nights):");
for (const w of ws) {
  const s = score(w, () => true);
  const dip = pts.filter((p) => p.dip), other = pts.filter((p) => !p.dip && p.trigger);
  console.log(`  w ${w.toFixed(2)}: overnight mae 15 ${s.e15.toFixed(2)} 30 ${s.e30.toFixed(2)}; ` +
    `in dips 30m ${mean(dip.filter((p) => p.h === 30).map((p) => Math.abs(p.err(w)))).toFixed(1)}, ` +
    `triggered non-dips 30m ${mean(other.filter((p) => p.h === 30).map((p) => Math.abs(p.err(w)))).toFixed(1)}; ` +
    `night alerts ${s.n}, false ${s.fa}; lows warned later ${s.later} (${s.lost.toFixed(0)} min)`);
}
let hoErr = 0, baseErr = 0, hoN = 0, hoLater = 0, hoFA = 0, baseFA = 0;
for (const n of nights) {
  let best = 1, bestE = Infinity;
  for (const w of ws) {
    const s = score(w, (x) => x !== n);
    const e = s.sum / s.count;
    if (s.later === 0 && e < bestE - 1e-9) { best = w; bestE = e; }
  }
  const got = score(best, (x) => x === n), base = score(1, (x) => x === n);
  hoErr += got.sum; baseErr += base.sum; hoN += got.count;
  hoLater += got.later; hoFA += got.fa; baseFA += base.fa;
  console.log(`  night ending ${n}: chose w ${best.toFixed(2)}  mae ${(got.sum / got.count).toFixed(2)} (shipped ${(base.sum / base.count).toFixed(2)}, n ${got.count}), ` +
    `night false ${got.fa} (${base.fa}), lows warned later ${got.later}`);
}
console.log(`held out: overnight mae (15 and 30 pooled) ${(hoErr / hoN).toFixed(2)} against shipped ${(baseErr / hoN).toFixed(2)}; ` +
  `night false alarms ${hoFA} against ${baseFA}; lows warned later ${hoLater}`);
