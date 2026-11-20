// When the trend arrow and the 15-minute slope point opposite ways: how the forecast line and the
// predicted-low and predicted-high alerts behave, and one held-out tweak (docs/ForecastAccuracy.md
// §105). Follows §32 (trend-arrow.py: the arrow is LibreLinkUp's, passed through), §59 and §71
// (reversals and turns), and replays the relay tick by tick exactly as §79 and §104 do.
//
// At each relay tick the arrow is the latest live reading's (LinkUp trend 1-5, from the last 5
// minutes; 0 = a 15-minute history point, which carries none). The 15-minute slope is (reading now -
// reading 15 minutes ago) / 15, read one reading a minute, live preferred (§74). They disagree when
// the arrow is rising (4, 5) and the slope is SLOPE (0.3) mg/dL a minute or more downward, or the
// arrow is falling (1, 2) and the slope is SLOPE or more upward. The line itself follows the relay's
// 20-minute regression trend, so it is also recorded which of the two the line went with.
//
// Every tick's line is scored at 15, 30 and 60 minutes (the trend fades out by 30, so 60 is where it
// settles), drawn or unshown, as a replay with maxHorizon 60 computes it: the same central line, no
// widening. Bias = actual - line (positive = line ran low). Alerts run on the shipped forecast.
// A predicted-low is false when no reading is under 70 in the 45 minutes after; a predicted-high
// when none is over 180 (250 for very high) in the 60 minutes after.
//
// Tweak tried (trend forecast only, nothing about insulin, carbs or doses): when they disagree, the
// line's move from the reading is scaled by w (1 = shipped). Leave one Perth day out: on the other
// days take the w with the lowest error (15, 30 and 60 pooled) among those that warn no low and no
// high later than shipped (ties keep the larger w), then score the day left out.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/arrow-slope-disagree.ts
//
// dir holds readings.json ([[unix, mg/dL, trend], ...], all of glucos.readings) and log.json (unix
// times of meals and doses), exported as in §18 and §79. Knobs: SLOPE, AGAINST=line, LIST=1, GAIN=1 (also score at
// the app's fitted gain 0.45: the line's move ×0.45).
import * as core from "../supabase/functions/relay/core.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const readings: core.Reading[] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`))
  .map(([t, mgdl, trend]: number[]) => ({ t, mgdl, trend: (trend ?? 0) as core.Trend }))
  .sort((a: core.Reading, b: core.Reading) => a.t - b.t);
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const series = new core.Series(readings);
const lowMgdl = 70, highMgdl = 180, veryHighMgdl = 250;
const SLOPE = Number(env("SLOPE") || 0.3);
// AGAINST=line compares the arrow with the line's own trend (the relay's 20-minute regression slope)
// instead of the 15-minute slope: the disagreement someone actually sees on the chart.
const AGAINST_LINE = env("AGAINST") === "line";
const display: core.Display = { unit: "mmol", lowMgdl, highMgdl };
const logged = (from: number, to: number) => logs.some((l) => l >= from && l <= to);
const dense = (i: number) => i > 0 && readings[i].t - readings[i - 1].t <= 5 * 60;
const start = readings.findIndex((_, i) => dense(i) && readings[i].t - readings[0].t > 3 * 3600);
const dayOf = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(0, 10);
const perthTime = (t: number) => new Date((t + 8 * 3600) * 1000).toISOString().slice(5, 16).replace("T", " ");
const lastT = readings[readings.length - 1].t;

// One reading a minute, live preferred; and the live readings alone for the arrow.
const perMinute = new Map<number, core.Reading>();
for (const r of readings) {
  const k = Math.floor(r.t / 60), had = perMinute.get(k);
  if (!had || (had.trend === 0 && r.trend !== 0)) perMinute.set(k, r);
}
const rs = new core.Series([...perMinute.values()].sort((a, b) => a.t - b.t), true);
const liveOnly = readings.filter((r) => r.trend !== 0);
function arrowAt(t: number): number {
  let lo = 0, hi = liveOnly.length;
  while (lo < hi) { const m = (lo + hi) >> 1; if (liveOnly[m].t <= t) lo = m + 1; else hi = m; }
  const r = liveOnly[lo - 1];
  return r && t - r.t <= 5 * 60 ? r.trend : 0;
}

type Kind = "disagree" | "agree" | "steady" | "flat" | "none";
interface Tick {
  i: number; now: number; f: core.Forecast | null; line: core.Forecast | null; kind: Kind;
  arrow: number; s15: number; trend: number; lineWithArrow: boolean;
}
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
    const recent = new core.Series(series.slice(now - 3600, now), true);
    const tuning = calibration?.tuning ?? core.standardTuning;
    const res = core.forecast(recent, calibration, now, undefined, tuning, core.liveHorizon(live, now),
      core.effectiveRangeScale(null, calibration));
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
    const long = core.forecast(recent, calibration, now, 3600, tuning);
    const line = long.ok ? long.forecast : null;
    const arrow = arrowAt(now);
    // Only readings up to now: Series.value bridges gaps up to 20 min, so it could reach past `now`.
    const known = rs.upTo(now);
    const back = known.value(now - 15 * 60), cur = known.last?.mgdl ?? readings[i].mgdl;
    const s15 = AGAINST_LINE ? (line?.trendPerMinute ?? NaN) : back === null ? NaN : (cur - back) / 15;
    let kind: Kind = "none";
    if (arrow && !Number.isNaN(s15)) {
      const up = arrow >= 4, down = arrow <= 2;
      if ((up && s15 <= -SLOPE) || (down && s15 >= SLOPE)) kind = "disagree";
      else if ((up && s15 >= SLOPE) || (down && s15 <= -SLOPE)) kind = "agree";
      else if (arrow === 3) kind = "steady";
      else kind = "flat";
    }
    const trend = line?.trendPerMinute ?? NaN;
    ticks.push({ i, now, f: res.ok ? res.forecast : null, line, kind, arrow, s15, trend,
      lineWithArrow: arrow >= 4 ? trend > 0 : trend < 0 });
  }
}

function scaled(f: core.Forecast, w: number): core.Forecast {
  const s = (x: core.ForecastSample) => ({
    ...x, mgdl: f.startMgdl + w * (x.mgdl - f.startMgdl),
    lowerMgdl: f.startMgdl + w * (x.lowerMgdl - f.startMgdl), upperMgdl: f.startMgdl + w * (x.upperMgdl - f.startMgdl),
  });
  return { ...f, samples: f.samples.map(s), unshown: f.unshown?.map(s), lowLookahead: f.lowLookahead?.map(s) };
}
const lineAt = (f: core.Forecast, t: number) => f.samples.find((x) => Math.abs(x.t - t) < 30);

// Forecast error.
const H = [15, 30, 60];
interface Pt { day: string; tick: Tick; h: number; actual: number; move: number; start: number; afterLog: boolean }
const pts: Pt[] = [];
for (const k of ticks) {
  const f = k.line;
  if (!f) continue;
  for (const h of H) {
    const target = k.now + h * 60;
    const a = series.value(target), x = lineAt(f, target);
    if (a === null || a === undefined || !x) continue;
    pts.push({ day: dayOf(k.now), tick: k, h, actual: a, move: x.mgdl - f.startMgdl, start: f.startMgdl, afterLog: logged(k.now, target) });
  }
}
const err = (p: Pt, w: number, g = 1) => p.actual - (p.start + (p.tick.kind === "disagree" ? w : 1) * g * p.move);
const mean = (xs: number[]) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN;
const fmt = (x: number) => (x >= 0 ? "+" : "") + x.toFixed(1);
function row(name: string, sub: Pt[], w = 1, g = 1) {
  const cells = H.map((h) => {
    const s = sub.filter((p) => p.h === h), e = s.map((p) => err(p, w, g));
    return `${h}m n=${String(s.length).padStart(5)} mae ${mean(e.map(Math.abs)).toFixed(1).padStart(5)} ` +
      `nc ${mean(s.map((p) => Math.abs(p.actual - p.start))).toFixed(1).padStart(5)} bias ${fmt(mean(e))}`;
  });
  console.log(`  ${name.padEnd(30)} ${cells.join(" | ")}`);
}

// Alerts.
interface Alert { t: number; kind: string }
function alertsFor(w: number): Alert[] {
  const planner = core.newPlanner();
  const prefs: core.AlertPreferences = core.defaultAlertPreferences();
  const out: Alert[] = [];
  for (const k of ticks) {
    const g = k.f && k.kind === "disagree" && w !== 1 ? scaled(k.f, w) : k.f;
    const snapshot = core.makeSnapshot(series.slice(k.now - 3600, k.now), readings[k.i], null, display, null);
    const n = core.evaluatePrediction(planner, snapshot, g, prefs, k.now);
    if (n && n.kind.startsWith("predicted")) out.push({ t: k.now, kind: n.kind });
  }
  return out;
}
const isLow = (a: Alert) => a.kind === "predictedLow" || a.kind === "predictedUrgentLow";
const within = (a: number, s: number) => readings.filter((r) => r.t > a && r.t <= a + s);
function falseAlarm(a: Alert): boolean | null {
  if (isLow(a)) return a.t + 45 * 60 > lastT ? null : !within(a.t, 45 * 60).some((r) => r.mgdl < lowMgdl);
  const thr = a.kind === "predictedVeryHigh" ? veryHighMgdl : highMgdl;
  return a.t + 3600 > lastT ? null : !within(a.t, 3600).some((r) => r.mgdl > thr);
}

// Excursions: lows under 70 and highs over 180, each ending once 15 min back across.
interface Ex { t: number; low: boolean; peak: number }
const excursions: Ex[] = [];
for (const low of [true, false]) {
  let cur: Ex | null = null, end = 0;
  for (const r of readings) {
    if (r.t < readings[start].t) continue;
    const out = low ? r.mgdl < lowMgdl : r.mgdl > highMgdl;
    if (out) { if (!cur) cur = { t: r.t, low, peak: r.mgdl }; end = r.t; cur.peak = low ? Math.min(cur.peak, r.mgdl) : Math.max(cur.peak, r.mgdl); }
    else if (cur && r.t - end >= 900) { excursions.push(cur); cur = null; }
  }
  if (cur) excursions.push(cur);
}
const firstWarning = (al: Alert[], x: Ex) =>
  al.find((a) => isLow(a) === x.low && a.t <= x.t && a.t >= x.t - (x.low ? 45 : 60) * 60)?.t;

const days = [...new Set(pts.map((p) => p.day))].sort();
const counted = ticks.filter((k) => k.kind !== "none");
const dis = ticks.filter((k) => k.kind === "disagree");
console.log(`arrow-slope-disagree${AGAINST_LINE ? " (against the line's trend)" : ""}: ${readings.length} readings, ${ticks.length} ticks, ${days.length} Perth days ` +
  `(${days[0]} to ${days[days.length - 1]}), SLOPE ${SLOPE}`);
console.log(`ticks with a live arrow and a 15-min slope: ${counted.length}; disagree ${dis.length} ` +
  `(${(100 * dis.length / counted.length).toFixed(1)}%): arrow up/slope down ${dis.filter((k) => k.arrow >= 4).length}, ` +
  `arrow down/slope up ${dis.filter((k) => k.arrow <= 2).length}; the line went the arrow's way on ` +
  `${dis.filter((k) => k.lineWithArrow).length}, the slope's on ${dis.filter((k) => !k.lineWithArrow && k.trend !== 0).length}`);
{
  // Episodes: disagreement ticks no more than 5 min apart.
  const eps: Tick[][] = [];
  for (const k of dis) { const e = eps[eps.length - 1]; if (e && k.now - e[e.length - 1].now <= 300) e.push(k); else eps.push([k]); }
  const len = eps.map((e) => (e[e.length - 1].now - e[0].now) / 60 + 1).sort((a, b) => a - b);
  console.log(`  ${eps.length} episodes on ${new Set(dis.map((k) => dayOf(k.now))).size} days, median ${len[len.length >> 1]?.toFixed(0)} min, ` +
    `longest ${len[len.length - 1]?.toFixed(0)}; ${eps.filter((e) => logged(e[0].now - 3 * 3600, e[0].now)).length} with something logged in the 3 h before`);
  console.log(`  arrows: ${[1, 2, 4, 5].map((a) => `${a}:${dis.filter((k) => k.arrow === a).length}`).join(" ")}; ` +
    `median |slope15| ${[...dis.map((k) => Math.abs(k.s15))].sort((a, b) => a - b)[dis.length >> 1]?.toFixed(2)}/min, ` +
    `median |line trend| ${[...dis.map((k) => Math.abs(k.trend))].filter((x) => !Number.isNaN(x)).sort((a, b) => a - b)[dis.length >> 1]?.toFixed(2)}/min`);
  if (env("LIST")) for (const e of eps) console.log(`  ${perthTime(e[0].now)} ${e.length} ticks, arrow ${e[0].arrow}, ` +
    `slope ${e[0].s15.toFixed(2)}, line trend ${e[0].trend.toFixed(2)}, reading ${readings[e[0].i].mgdl}`);
}
// Which way did glucose go next, after a disagreement?
for (const h of [15, 30]) {
  const s = pts.filter((p) => p.tick.kind === "disagree" && p.h === h);
  const arrowWay = s.filter((p) => (p.tick.arrow >= 4 ? 1 : -1) * (p.actual - p.start) > 0).length;
  console.log(`  after ${h} min glucose had gone the arrow's way on ${arrowWay} of ${s.length} (${(100 * arrowWay / s.length).toFixed(0)}%)`);
}

console.log("\nForecast error by tick (bias = actual - line; positive = line ran low):");
row("all ticks", pts);
row("disagree", pts.filter((p) => p.tick.kind === "disagree"));
row("  arrow up, slope down", pts.filter((p) => p.tick.kind === "disagree" && p.tick.arrow >= 4));
row("  arrow down, slope up", pts.filter((p) => p.tick.kind === "disagree" && p.tick.arrow <= 2));
row("  line went the arrow's way", pts.filter((p) => p.tick.kind === "disagree" && p.tick.lineWithArrow));
row("  line went the slope's way", pts.filter((p) => p.tick.kind === "disagree" && !p.tick.lineWithArrow));
row("  nothing logged after", pts.filter((p) => p.tick.kind === "disagree" && !p.afterLog));
row("agree (arrow + slope moving)", pts.filter((p) => p.tick.kind === "agree"));
row("arrow steady", pts.filter((p) => p.tick.kind === "steady"));
row("arrow moving, slope flat", pts.filter((p) => p.tick.kind === "flat"));
if (env("GAIN")) {
  console.log("  at the app's fitted gain 0.45:");
  row("  all ticks", pts, 1, 0.45);
  row("  disagree", pts.filter((p) => p.tick.kind === "disagree"), 1, 0.45);
  row("  rest", pts.filter((p) => p.tick.kind !== "disagree"), 1, 0.45);
}

const shipped = alertsFor(1);
const scorable = shipped.filter((a) => falseAlarm(a) !== null);
const inDis = (a: Alert) => dis.some((k) => k.now === a.t);
console.log(`\nPredicted alerts (shipped): ${scorable.length} scorable, false ${scorable.filter((a) => falseAlarm(a)).length}; ` +
  `fired on a disagreement tick ${scorable.filter(inDis).length}, false ${scorable.filter((a) => inDis(a) && falseAlarm(a)).length}`);
for (const low of [true, false]) {
  const s = scorable.filter((a) => isLow(a) === low);
  console.log(`  ${low ? "lows " : "highs"}: ${s.length}, false ${s.filter((a) => falseAlarm(a)).length}; on disagreement ` +
    `${s.filter(inDis).length}, false ${s.filter((a) => inDis(a) && falseAlarm(a)).length}`);
}
for (const a of scorable.filter(inDis)) {
  const k = ticks.find((x) => x.now === a.t)!;
  console.log(`    ${perthTime(a.t)} ${a.kind} reading ${readings[k.i].mgdl} arrow ${k.arrow} slope ${k.s15.toFixed(2)} ` +
    `line trend ${k.trend.toFixed(2)} ${falseAlarm(a) ? "FALSE" : "real"}`);
}
const lowsCount = excursions.filter((x) => x.low).length, highsCount = excursions.length - lowsCount;
console.log(`  ${lowsCount} lows and ${highsCount} highs; warned by shipped: lows ${excursions.filter((x) => x.low && firstWarning(shipped, x) !== undefined).length}, ` +
  `highs ${excursions.filter((x) => !x.low && firstWarning(shipped, x) !== undefined).length}`);

// The tweak, held out.
const ws = [1, 0.75, 0.5, 0.25, 0];
const runs = new Map(ws.map((w) => [w, alertsFor(w)]));
function score(w: number, keep: (d: string) => boolean) {
  const sub = pts.filter((p) => keep(p.day));
  const byH = H.map((h) => mean(sub.filter((p) => p.h === h).map((p) => Math.abs(err(p, w)))));
  const dsub = sub.filter((p) => p.tick.kind === "disagree");
  const dH = H.map((h) => mean(dsub.filter((p) => p.h === h).map((p) => Math.abs(err(p, w)))));
  const sum = sub.reduce((a, p) => a + Math.abs(err(p, w)), 0), count = sub.length;
  const al = runs.get(w)!;
  let later = 0, lost = 0, fa = 0, n = 0;
  for (const x of excursions) {
    if (!keep(dayOf(x.t))) continue;
    const base = firstWarning(shipped, x), got = firstWarning(al, x);
    if (base === undefined) continue;
    if (got === undefined || got > base) { later++; lost += ((got ?? x.t) - base) / 60; }
  }
  for (const a of al) { if (!keep(dayOf(a.t))) continue; const f = falseAlarm(a); if (f === null) continue; n++; if (f) fa++; }
  return { byH, dH, sum, count, later, lost, fa, n };
}
console.log("\nTweak: scale the line's move by w when arrow and 15-min slope disagree (all days):");
for (const w of ws) {
  const s = score(w, () => true);
  console.log(`  w ${w.toFixed(2)}: all mae ${s.byH.map((x) => x.toFixed(2)).join(" / ")}; disagree ${s.dH.map((x) => x.toFixed(1)).join(" / ")}; ` +
    `alerts ${s.n}, false ${s.fa}; lows/highs warned later ${s.later} (${s.lost.toFixed(0)} min)`);
}
let hoErr = 0, baseErr = 0, hoN = 0, hoLater = 0, hoFA = 0, baseFA = 0, better = 0;
const hoH = H.map(() => [0, 0, 0]);
for (const d of days) {
  let best = 1, bestE = Infinity;
  for (const w of ws) {
    const s = score(w, (x) => x !== d);
    const e = s.sum / s.count;
    if (s.later === 0 && e < bestE - 1e-9) { best = w; bestE = e; }
  }
  const got = score(best, (x) => x === d), base = score(1, (x) => x === d);
  hoErr += got.sum; baseErr += base.sum; hoN += got.count;
  hoLater += got.later; hoFA += got.fa; baseFA += base.fa;
  if (got.sum < base.sum - 1e-9) better++;
  const sub = pts.filter((p) => p.day === d);
  H.forEach((h, j) => {
    const s = sub.filter((p) => p.h === h);
    hoH[j][0] += s.reduce((a, p) => a + Math.abs(err(p, best)), 0); hoH[j][1] += s.reduce((a, p) => a + Math.abs(err(p, 1)), 0); hoH[j][2] += s.length;
  });
  console.log(`  day ${d}: chose w ${best.toFixed(2)}  mae ${(got.sum / got.count).toFixed(2)} (shipped ${(base.sum / base.count).toFixed(2)}, n ${got.count}), ` +
    `false ${got.fa} (${base.fa}), warned later ${got.later}`);
}
console.log(`held out: mae (15/30/60 pooled) ${(hoErr / hoN).toFixed(3)} against shipped ${(baseErr / hoN).toFixed(3)} ` +
  `(${(100 * (hoErr - baseErr) / baseErr).toFixed(2)}%), better on ${better} of ${days.length} days; by horizon ` +
  `${hoH.map(([a, b], j) => `${H[j]}: ${(100 * (a - b) / b).toFixed(2)}%`).join(", ")}; false alarms ${hoFA} against ${baseFA}; warned later ${hoLater}`);
