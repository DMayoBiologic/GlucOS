// The push relay's share of GlucOS's rules: alert planning, the trend-only forecast with its
// learnt accuracy band, and the Live Activity card. A line-by-line port of the Swift code the
// apps run (Sources/Core/AlertPlanner.swift, Sources/Engine/GlucoseForecaster.swift,
// Sources/Engine/ForecastBacktest.swift, Sources/Engine/PredictiveAlerts.swift,
// Sources/Shared/GlucoseActivityState.swift), so every device alerts on the same readings with
// the same wording. `core_test.ts` replays testdata/parity.json, which the Swift test
// RelayParityTests writes, so the two can't drift apart unnoticed.
//
// Times are seconds since 1970 throughout, like the Swift code's `timeIntervalSince1970`.

import type { CheckInCard } from "./checkins.ts";

// MARK: - Models

export type Trend = 0 | 1 | 2 | 3 | 4 | 5;
export const TrendValue = { unknown: 0, fallingQuickly: 1, falling: 2, flat: 3, rising: 4, risingQuickly: 5 } as const;

export interface Reading {
  t: number;
  mgdl: number;
  trend: Trend;
}

export interface Sensor {
  serial: string;
  activated: number;
  lifetimeDays: number;
}

export type Unit = "mmol" | "mgdl";

export interface Display {
  unit: string;
  lowMgdl: number;
  highMgdl: number;
}

export interface AlertPreferences {
  enabled: boolean;
  high: boolean;
  rapidChange: boolean;
  stale: boolean;
  sensorExpiry: boolean;
  predictedLow: boolean;
  predictedHigh: boolean;
  predictiveMinutes: number;
  cooldownMinutes: number;
}

export const defaultAlertPreferences = (): AlertPreferences => ({
  enabled: true, high: true, rapidChange: true, stale: true, sensorExpiry: true,
  predictedLow: true, predictedHigh: true, predictiveMinutes: 30, cooldownMinutes: 15,
});

export const staleAfter = 6 * 60;
const mgdlPerMmol = 18.0182;

// MARK: - Formatting (matches Swift's String(format:))

/// `%.Nf` the way C's printf does it. `toFixed` is exact too, but breaks exact ties away from
/// zero where printf rounds them to even (2.25 → "2.3" vs "2.2"), so ties are redone here.
export function fixed(v: number, digits: number): string {
  const s = v.toFixed(digits);
  if (!Number.isFinite(v) || Math.abs(v) >= 1e15) return s;
  // A double's exact decimal expansion is finite: 60 more places is plenty at these magnitudes.
  const exact = Math.abs(v).toFixed(Math.min(100, digits + 60));
  const point = exact.indexOf(".");
  const rest = exact.slice(point + 1 + digits);
  if (!/^50*$/.test(rest)) return s;
  // An exact tie: keep the even last digit, i.e. round down when the digit before is even.
  const truncated = exact.slice(0, point + 1 + digits).replace(/\.$/, "");
  const lastDigit = Number(truncated[truncated.length - 1]);
  if (lastDigit % 2 === 1) return s; // odd: rounding away from zero gives the even digit, as toFixed did
  return (v < 0 ? "-" : "") + truncated;
}

export function unitOf(raw: string): Unit {
  return raw === "mgdl" ? "mgdl" : "mmol";
}

function unitValue(unit: Unit, mgdl: number): number {
  return unit === "mmol" ? mgdl / mgdlPerMmol : mgdl;
}

export function formatGlucose(unit: Unit, mgdl: number, withUnit = false): string {
  const v = unitValue(unit, mgdl);
  const s = unit === "mmol" ? fixed(v, 1) : fixed(v, 0);
  return withUnit ? `${s} ${unit === "mmol" ? "mmol/L" : "mg/dL"}` : s;
}

export function formatDelta(unit: Unit, mgdl: number): string {
  const v = unitValue(unit, mgdl);
  const sign = v >= 0 ? "+" : "−";
  return sign + (unit === "mmol" ? fixed(Math.abs(v), 1) : fixed(Math.abs(v), 0));
}

export function formatAge(interval: number): string {
  if (interval < 60) return "now";
  const m = Math.trunc(interval / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.trunc(m / 60);
  if (h < 24) return `${h}h ${m % 60}m ago`;
  return `${Math.trunc(h / 24)}d ago`;
}

export function formatDays(d: number): string {
  if (d >= 2) return `${fixed(Math.floor(d), 0)} days`;
  if (d >= 1) return "1 day";
  const h = Math.trunc(d * 24);
  return h <= 1 ? "<1 hour" : `${h} hours`;
}

export const trendDescription = (t: Trend): string =>
  ["Unknown", "Falling quickly", "Falling", "Steady", "Rising", "Rising quickly"][t] ?? "Unknown";
export const trendArrow = (t: Trend): string => ["?", "↓", "↘", "→", "↗", "↑"][t] ?? "?";
const trendIsRapid = (t: Trend) => t === 1 || t === 5;

export type Range = "urgentLow" | "low" | "inRange" | "high" | "veryHigh";

export function classify(mgdl: number, low: number, high: number): Range {
  if (mgdl < 54) return "urgentLow";
  if (mgdl < low) return "low";
  if (mgdl > 250) return "veryHigh";
  if (mgdl > high) return "high";
  return "inRange";
}

// MARK: - Snapshot

export interface Snapshot {
  current: Reading | null;
  /// Oldest first, before `current`, the last 12 hours.
  history: Reading[];
  sensor: Sensor | null;
  unit: Unit;
  lowMgdl: number;
  highMgdl: number;
  lastError: string | null;
  outlook: OutlookSnapshot | null;
}

export function isStale(s: Snapshot, now: number): boolean {
  if (!s.current) return true;
  return now - s.current.t > staleAfter;
}

export function deltaMgdl(s: Snapshot): number | null {
  const c = s.current;
  if (!c) return null;
  let previous: Reading | null = null;
  for (let i = s.history.length - 1; i >= 0; i--) {
    if (c.t - s.history[i].t >= 240) {
      previous = s.history[i];
      break;
    }
  }
  return previous ? c.mgdl - previous.mgdl : null;
}

/// The snapshot the relay works from: the stored readings and the latest fetch.
export function makeSnapshot(stored: Reading[], current: Reading | null, sensor: Sensor | null, display: Display,
                             lastError: string | null): Snapshot {
  const history = current
    ? stored.filter((r) => r.t >= current.t - 12 * 3600 && r.t < current.t)
    : [];
  return {
    current, history, sensor, unit: unitOf(display.unit), lowMgdl: display.lowMgdl, highMgdl: display.highMgdl,
    lastError, outlook: null,
  };
}

/// Adds readings to the stored ones by time (newer values win) and drops anything older than
/// `retention` seconds. Oldest first.
export function mergeReadings(stored: Reading[], incoming: Reading[], now: number, retention: number): Reading[] {
  const byTime = new Map<number, Reading>();
  for (const r of stored) if (!byTime.has(r.t)) byTime.set(r.t, r);
  for (const r of incoming) byTime.set(r.t, r);
  const cutoff = now - retention;
  return [...byTime.values()].filter((r) => r.t >= cutoff).sort((a, b) => a.t - b.t);
}

// MARK: - Series

export class Series {
  readonly readings: Reading[];
  static readonly maxBridge = 20 * 60;
  static readonly nearestTolerance = 5 * 60;

  constructor(readings: Reading[], sorted = false) {
    this.readings = sorted ? readings : [...readings].sort((a, b) => a.t - b.t);
  }

  get last(): Reading | undefined {
    return this.readings[this.readings.length - 1];
  }

  lowerBound(t: number): number {
    let lo = 0, hi = this.readings.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.readings[mid].t < t) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  value(at: number): number | null {
    const i = this.lowerBound(at);
    const after = i < this.readings.length ? this.readings[i] : undefined;
    const before = i > 0 ? this.readings[i - 1] : undefined;
    if (after && after.t === at) return after.mgdl;
    if (before && after && after.t - before.t <= Series.maxBridge) {
      const f = (at - before.t) / (after.t - before.t);
      return before.mgdl + (after.mgdl - before.mgdl) * f;
    }
    let best: Reading | undefined;
    for (const c of [before, after]) {
      if (!c || Math.abs(c.t - at) > Series.nearestTolerance) continue;
      if (!best || Math.abs(c.t - at) < Math.abs(best.t - at)) best = c;
    }
    return best ? best.mgdl : null;
  }

  slice(from: number, through: number): Reading[] {
    const lo = this.lowerBound(from);
    let hi = lo;
    while (hi < this.readings.length && this.readings[hi].t <= through) hi++;
    return this.readings.slice(lo, hi);
  }

  upTo(t: number): Series {
    return new Series(this.readings.slice(0, this.lowerBound(t + 0.001)), true);
  }
}

function slope(x: number[], y: number[]): number | null {
  if (x.length !== y.length || x.length < 2) return null;
  const n = x.length;
  const mx = x.reduce((a, b) => a + b, 0) / n, my = y.reduce((a, b) => a + b, 0) / n;
  let sxx = 0, sxy = 0;
  for (let i = 0; i < n; i++) {
    sxx += (x[i] - mx) * (x[i] - mx);
    sxy += (x[i] - mx) * (y[i] - my);
  }
  if (!(sxx > 1e-9)) return null;
  return sxy / sxx;
}

function quantile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  if (sorted.length === 1) return sorted[0];
  const pos = Math.min(Math.max(p, 0), 1) * (sorted.length - 1);
  const lo = Math.floor(pos), hi = Math.min(lo + 1, sorted.length - 1);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

// MARK: - Forecast accuracy

export interface HorizonStats {
  minutes: number;
  samples: number;
  meanAbsoluteError: number;
  naiveError: number;
  bias: number;
  lower: number;
  upper: number;
}

/// The forecast's trend timing and strength (ForecastTuning in GlucoseForecaster.swift), tuned
/// to the user's history by `tuneTrend`. Standard values are Loop's.
export interface Tuning {
  trendFade: number;
  trendWindow: number;
  /// How much of the recent trend is carried forward, 0–1.
  trendGain: number;
}

export const standardTuning: Tuning = { trendFade: 30 * 60, trendWindow: 20 * 60, trendGain: 1 };
export const isStandardTuning = (t: Tuning) =>
  t.trendFade === standardTuning.trendFade && t.trendWindow === standardTuning.trendWindow &&
  t.trendGain === standardTuning.trendGain;

/// The relay has no logbook, so only the trend basis is ever learnt.
export interface Calibration {
  trend: HorizonStats[];
  origins: number;
  computedAt: number;
  /// The timing the figures were measured with and the forecast uses. Missing on rows saved
  /// before tuning existed: standard.
  tuning?: Tuning;
  /// How much wider the range needed to be to hold 4 in 5 readings in the same replay, worked out
  /// the way the ledger's is (`replayRangeScale`). Stands in until the relay's own ledger has
  /// enough scored forecasts. Missing on rows saved before it existed, null with too few.
  rangeScale?: RangeScale | null;
}

export const calibrationHorizons = [15, 30, 45, 60, 90, 120, 150, 180];
const minimumSamples = 30;
const requiredImprovement = 0.95;

const beatsNaive = (s: HorizonStats) => s.meanAbsoluteError <= s.naiveError * requiredImprovement;

export function allowedHorizon(stats: HorizonStats[] | undefined): number | null {
  if (!stats || stats.length === 0) return null;
  const sorted = [...stats].sort((a, b) => a.minutes - b.minutes);
  if (sorted[0].samples < minimumSamples) return null;
  let allowed = 0;
  for (const s of sorted) {
    if (s.samples < minimumSamples || !beatsNaive(s)) break;
    allowed = s.minutes;
  }
  return allowed * 60;
}

export function defaultBand(minutes: number): { lower: number; upper: number } {
  const half = 6 + 0.6 * minutes;
  return { lower: -half, upper: half };
}

export function interpolateBand(stats: HorizonStats[], minutes: number): { lower: number; upper: number } | null {
  const usable = stats.filter((s) => s.samples >= minimumSamples).sort((a, b) => a.minutes - b.minutes);
  if (usable.length === 0) return null;
  const floor = defaultBand(minutes);
  const widen = (lo: number, hi: number) => ({
    lower: Math.min(lo, floor.lower * 0.6),
    upper: Math.max(hi, floor.upper * 0.6),
  });
  const first = usable[0];
  if (minutes <= first.minutes) {
    const f = minutes / first.minutes;
    return widen(first.lower * f, first.upper * f);
  }
  for (let i = 0; i + 1 < usable.length; i++) {
    const a = usable[i], b = usable[i + 1];
    if (minutes <= b.minutes) {
      const f = (minutes - a.minutes) / (b.minutes - a.minutes);
      return widen(a.lower + (b.lower - a.lower) * f, a.upper + (b.upper - a.upper) * f);
    }
  }
  const last = usable[usable.length - 1];
  const f = minutes / last.minutes;
  return widen(last.lower * f, last.upper * f);
}

// MARK: - Range widening

// A port of ForecastLedger.rangeScale (Sources/Engine/ForecastLedger.swift): how much wider the
// relay's range needs to be to have held 4 in 5 of the readings that followed the forecasts it
// showed, from its own ledger (device "relay"). A steady figure per checked horizon over 14 days,
// a separate figure for forecasts that started with glucose moving fast, and a correction from
// the last 12 hours alone so a bad day widens the range that day. Widen-only.

/// One scored relay forecast, as kept in glucos.forecast_checks.
export interface ShownForecast {
  issuedAt: number;
  trendPerMinute: number;
  points: {
    minutes: number; mgdl: number; lower: number; upper: number;
    actual?: number | null; afterLog?: boolean;
    /// How much the point's range was widened when shown.
    scale?: number | null;
    /// How much further its upper side alone was widened (lowStartUpper).
    upperScale?: number | null;
  }[];
}

export interface RangeScale {
  /// The steady widening by minutes ahead, for horizons with enough points of their own.
  byHorizon: Record<number, number>;
  /// The steady widening across all horizons.
  overall: number;
  /// Extra widening when the forecast starts from glucose moving at least `fastTrendPerMinute`.
  fastTrend: number;
  /// Extra widening while the last 12 hours missed more than the last two weeks.
  recent: number;
  checks: number;
  recentChecks: number;
}

export const rangeWindow = 14 * 86_400;
export const recentRangeWindow = 12 * 3600;
const minimumForRange = 40, minimumForHorizon = 25, minimumRecent = 20;
export const rangeMaximum = 2.5, rangeTotalMaximum = 4, fastTrendPerMinute = 1.5;

const clampScale = (x: number) => Math.min(rangeMaximum, Math.max(1, x));

/// The steady widening `minutes` ahead: interpolated between horizons that have their own
/// figure, held flat outside them, the overall figure without any.
function steadyFactor(s: RangeScale, minutes: number): number {
  const pts = Object.entries(s.byHorizon).map(([m, v]) => [Number(m), v] as const).sort((a, b) => a[0] - b[0]);
  if (pts.length === 0) return clampScale(s.overall);
  if (minutes <= pts[0][0]) return clampScale(pts[0][1]);
  const last = pts[pts.length - 1];
  if (minutes >= last[0]) return clampScale(last[1]);
  for (let i = 0; i + 1 < pts.length; i++) {
    const [am, av] = pts[i], [bm, bv] = pts[i + 1];
    if (minutes <= bm) return clampScale(av + (bv - av) * ((minutes - am) / (bm - am)));
  }
  return clampScale(last[1]);
}

/// The widening `minutes` ahead of a forecast starting from `trendPerMinute`. 1 without a scale.
export function rangeFactor(s: RangeScale | null | undefined, minutes: number, trendPerMinute: number): number {
  if (!s) return 1;
  const fast = Math.abs(trendPerMinute) >= fastTrendPerMinute ? s.fastTrend : 1;
  return Math.min(rangeTotalMaximum, steadyFactor(s, minutes) * clampScale(fast) * clampScale(s.recent));
}

/// Below this (4.4 mmol/L) the range's upper side is widened further, because glucose usually
/// comes back up from there faster than the trend draws (docs/ForecastAccuracy.md §40). Port of
/// `ForecastRangeScale.lowStartUpper`; the relay never sees logged treatments.
export const lowStartMgdl = 80;
const lowStartUpperByMinutes: [number, number][] = [[0, 1], [15, 2.8], [30, 3.3], [60, 3.6]];

/// The upper side's extra widening `minutes` ahead for a forecast starting at `startMgdl`.
export function lowStartUpper(startMgdl: number, minutes: number): number {
  if (!(startMgdl < lowStartMgdl) || minutes <= 0) return 1;
  const pts = lowStartUpperByMinutes;
  for (let i = 0; i + 1 < pts.length; i++) {
    const [am, av] = pts[i], [bm, bv] = pts[i + 1];
    if (minutes <= bm) return av + (bv - av) * ((minutes - am) / (bm - am));
  }
  return pts[pts.length - 1][1];
}

interface RangeMiss { minutes: number; ratio: number; fast: boolean; recent: boolean }

export function rangeScaleFrom(shown: ShownForecast[], now: number): RangeScale | null {
  const steady: RangeMiss[] = [], fast: RangeMiss[] = [], recent: RangeMiss[] = [];
  for (const r of shown) {
    if (r.issuedAt < now - rangeWindow || r.issuedAt > now) continue;
    const isFast = Math.abs(r.trendPerMinute) >= fastTrendPerMinute;
    const isRecent = r.issuedAt >= now - recentRangeWindow;
    for (const p of r.points) {
      if (p.afterLog || typeof p.actual !== "number") continue;
      const k = Math.max(1, p.scale ?? 1);
      // The low-start widening is its own correction: taken out, so it isn't learnt twice.
      let above = (p.upper - p.mgdl) / (k * Math.max(1, p.upperScale ?? 1)), below = (p.mgdl - p.lower) / k;
      const cutHigh = p.upper >= sensorHigh + 0.5, cutLow = p.lower <= sensorLow - 0.5;
      if (cutHigh && cutLow) continue;
      if (cutHigh) above = below;
      if (cutLow) below = above;
      if (!(above > 0.5 && below > 0.5)) continue;
      const e = p.actual - p.mgdl;
      const m: RangeMiss = { minutes: p.minutes, ratio: e >= 0 ? e / above : -e / below, fast: isFast, recent: isRecent };
      (isFast ? fast : steady).push(m);
      if (isRecent) recent.push(m);
    }
  }
  if (steady.length < minimumForRange) return null;
  const needed = (xs: number[]) => clampScale(quantile([...xs].sort((a, b) => a - b), 0.8));
  const byHorizon: Record<number, number> = {};
  const groups = new Map<number, number[]>();
  for (const m of steady) groups.set(m.minutes, [...(groups.get(m.minutes) ?? []), m.ratio]);
  for (const [m, xs] of groups) if (xs.length >= minimumForHorizon) byHorizon[m] = needed(xs);
  const scale: RangeScale = {
    byHorizon, overall: needed(steady.map((m) => m.ratio)), fastTrend: 1, recent: 1,
    checks: steady.length + fast.length, recentChecks: 0,
  };
  if (fast.length >= minimumForHorizon) {
    scale.fastTrend = needed(fast.map((m) => m.ratio / steadyFactor(scale, m.minutes)));
  }
  if (recent.length >= minimumRecent) {
    scale.recent = needed(recent.map((m) => m.ratio / (steadyFactor(scale, m.minutes) * (m.fast ? scale.fastTrend : 1))));
    scale.recentChecks = recent.length;
  }
  return scale;
}

// MARK: - Forecast

export interface ForecastSample {
  t: number;
  mgdl: number;
  lowerMgdl: number;
  upperMgdl: number;
}

export interface Forecast {
  issuedAt: number;
  startMgdl: number;
  basis: "trend";
  trendPerMinute: number;
  samples: ForecastSample[];
  /// The part past the drawn horizon that the live checks cut off (GlucoseForecast.unshown):
  /// never drawn or shared, kept in the ledger so those horizons go on being scored, and read only
  /// by predicted lows.
  unshown?: ForecastSample[];
  /// The trend carried on past the calibrated horizon to the trend's full 30 minutes
  /// (GlucoseForecast.lowLookahead): never drawn, shared or scored, read only by predicted lows.
  lowLookahead?: ForecastSample[];
  /// Set when the live checks cut the forecast short (ForecastLimitation.liveHorizon).
  liveCut?: LiveCut;
}

/// When the live checks cut the forecast back to nothing, `unshown` is the forecast that wasn't
/// drawn, for the ledger only (ForecastFailure.unshown).
export type ForecastResult = { ok: true; forecast: Forecast } | { ok: false; reason: string; unshown?: Forecast };

const unavailable = {
  noReading: "No reading yet.",
  stale: "No forecast while the latest reading is old.",
  outOfSensorRange: "No forecast while the reading is outside the sensor's range.",
  notEnoughRecentReadings: "Needs a few readings from the last 20 minutes to see the trend.",
  notAccurateEnough: "Past forecasts haven't been accurate enough to show one.",
};

const step = 5 * 60;
const maxTrendPerMinute = 4;
const trendHorizon = 30 * 60;
const sensorLow = 40, sensorHigh = 400;

export function trendAt(series: Series, at: number, window = standardTuning.trendWindow): number | null {
  const recent = series.slice(at - Math.max(window, 10 * 60), at);
  if (recent.length === 0) return null;
  const first = recent[0], last = recent[recent.length - 1];
  if (last.t - first.t < 9 * 60) return null;
  const s = slope(recent.map((r) => (r.t - at) / 60), recent.map((r) => r.mgdl));
  if (s === null) return null;
  return Math.min(Math.max(s, -maxTrendPerMinute), maxTrendPerMinute);
}

/// The relay's forecast: the recent trend, at the strength it has earned, fading to level over
/// half an hour or the tuned time (no insulin or carbs, since the logbook lives on the Mac).
export function forecast(series: Series, calibration: Calibration | null, now: number, maxHorizon?: number,
                         tuning: Tuning = calibration?.tuning ?? standardTuning,
                         live: LiveCut | null = null,
                         rangeScale: RangeScale | null = null): ForecastResult {
  const latest = series.last;
  if (!latest) return { ok: false, reason: unavailable.noReading };
  if (now - latest.t > staleAfter) return { ok: false, reason: unavailable.stale };
  if (!(latest.mgdl >= sensorLow && latest.mgdl <= sensorHigh)) return { ok: false, reason: unavailable.outOfSensorRange };
  const trend = trendAt(series, latest.t, tuning.trendWindow);
  if (trend === null) return { ok: false, reason: unavailable.notEnoughRecentReadings };

  const t0 = latest.t;
  let horizon = trendHorizon;
  const stats = calibration && calibration.trend.length > 0 ? calibration.trend : undefined;
  if (maxHorizon !== undefined) {
    horizon = maxHorizon;
  } else {
    const allowed = calibration ? allowedHorizon(calibration.trend) : null;
    if (allowed !== null) {
      horizon = Math.min(horizon, allowed);
      if (horizon <= 0) return { ok: false, reason: unavailable.notAccurateEnough };
    }
  }

  // How far it's drawn: the relay's own live checks can cut it shorter, never longer. The rest is
  // still worked out, for the ledger to score.
  let shownHorizon = horizon;
  const cut = maxHorizon === undefined && live && live.failedAt * 60 <= horizon ? live : null;
  if (cut) shownHorizon = cut.shownMinutes * 60;

  // Widened from the relay's own shown forecasts, or its replay until it has enough of those
  // (effectiveRangeScale), never in a replay itself.
  const widen = (minutes: number) => (maxHorizon === undefined ? rangeFactor(rangeScale, minutes, trend) : 1);
  const band = (minutes: number) => {
    const b = (stats ? interpolateBand(stats, minutes) : null) ?? defaultBand(minutes);
    const k = widen(minutes);
    const up = maxHorizon === undefined ? lowStartUpper(latest.mgdl, minutes) : 1;
    return { lower: b.lower * k, upper: b.upper * k * up };
  };
  const samples: ForecastSample[] = [{ t: t0, mgdl: latest.mgdl, lowerMgdl: latest.mgdl, upperMgdl: latest.mgdl }];
  // Predicted lows look the trend's full 30 minutes ahead even when the calibrated horizon is
  // shorter (docs/ForecastAccuracy.md §13): the rest is worked out for them alone.
  const lookahead: ForecastSample[] = [];
  let g = latest.mgdl;
  let minute = 0;
  const totalMinutes = horizon / 60;
  const lookMinutes = maxHorizon === undefined ? Math.max(totalMinutes, trendHorizon / 60) : totalMinutes;
  const fade = Math.max(60, tuning.trendFade);
  const gain = Math.min(1, Math.max(0, tuning.trendGain));
  while (minute < lookMinutes) {
    const mid = minute + 0.5;
    const w = Math.max(0, 1 - (mid * 60) / fade);
    g += w * gain * trend;
    minute += 1;
    if (Math.trunc(minute) % (step / 60) === 0) {
      const central = Math.min(Math.max(g, sensorLow - 1), sensorHigh + 1);
      if (minute > totalMinutes) {
        lookahead.push({ t: t0 + minute * 60, mgdl: central, lowerMgdl: central, upperMgdl: central });
        continue;
      }
      const b = band(minute);
      samples.push({
        t: t0 + minute * 60, mgdl: central,
        lowerMgdl: Math.max(sensorLow - 1, central + b.lower),
        upperMgdl: Math.min(sensorHigh + 1, central + b.upper),
      });
    }
  }
  const f: Forecast = { issuedAt: t0, startMgdl: latest.mgdl, basis: "trend", trendPerMinute: trend, samples };
  if (lookahead.length) f.lowLookahead = lookahead;
  if (!cut) return { ok: true, forecast: f };
  const drawn = { ...f, samples: samples.filter((s) => s.t <= t0 + shownHorizon),
                  unshown: samples.filter((s) => s.t > t0 + shownHorizon), liveCut: cut };
  if (shownHorizon <= 0) return { ok: false, reason: unavailable.notAccurateEnough, unshown: drawn };
  return { ok: true, forecast: drawn };
}

// MARK: - Live horizon (ForecastLedger.liveHorizon)

/// How far the forecast is drawn (the checked horizon before `failedAt`, or 0), after the first
/// checked horizon that lost to no change.
export interface LiveCut {
  shownMinutes: number;
  failedAt: number;
}

/// One point of the relay's own ledger. `actual` is null until scored.
export interface LivePoint {
  issuedAt: number;
  minutes: number;
  mgdl: number;
  startMgdl: number;
  actual: number | null;
  afterLog: boolean;
  shown: boolean;
}

export const liveHorizonWindow = 7 * 86_400;
export const liveMinimumChecks = 30;
/// A drawn horizon is cut once its error reaches this share of no change's...
export const liveCutRatio = 1.05;
/// ...and drawn again once it's back to this share. In between it stays as it is.
export const liveRestoreRatio = requiredImprovement;

/// How far ahead the relay may draw its forecast, from how its own forecasts in the last week did
/// against no change on points with nothing logged in between (ForecastLedger.liveHorizon): a drawn
/// horizon is cut when clearly worse, a cut one comes back once clearly better and stays cut while
/// it has too few checks, and everything past the first cut goes with it. Null: no cut.
export function liveHorizon(points: LivePoint[], now: number): LiveCut | null {
  const mine = points.filter((p) => p.issuedAt >= now - liveHorizonWindow && p.issuedAt <= now);
  let shown = 0;
  for (const h of [...calibrationHorizons].sort((a, b) => a - b)) {
    const at = mine.filter((p) => p.minutes === h);
    const latest = at.reduce<LivePoint | null>((a, p) => (!a || p.issuedAt > a.issuedAt ? p : a), null);
    const cutNow = latest !== null && !latest.shown;
    const clean = at.filter((p) => !p.afterLog && p.actual !== null);
    let isCut: boolean;
    if (clean.length >= liveMinimumChecks) {
      const mae = clean.reduce((s, p) => s + Math.abs(p.actual! - p.mgdl), 0) / clean.length;
      const nc = clean.reduce((s, p) => s + Math.abs(p.actual! - p.startMgdl), 0) / clean.length;
      const ratio = nc > 0 ? mae / nc : (mae > 0 ? Infinity : 1);
      isCut = cutNow ? ratio > liveRestoreRatio : ratio >= liveCutRatio;
    } else {
      isCut = cutNow;
    }
    if (isCut) return { shownMinutes: shown, failedAt: h };
    shown = h;
  }
  return null;
}

/// One replayed forecast point compared with what happened (ForecastBacktest.Check).
export interface Check {
  origin: number;
  minutes: number;
  /// actual − forecast, mg/dL.
  residual: number;
  /// actual − starting reading: the error of assuming no change.
  naive: number;
  /// The trend came from live readings, one at least every 5 minutes.
  dense: boolean;
  /// The forecast's own value and starting trend, for `replayRangeScale`.
  mgdl: number;
  trendPerMinute: number;
}

/// Origins are at least this far apart, as often as the apps log their forecasts.
export const backtestSpacing = 15 * 60;
const denseSpacing = 5 * 60;

/// Replays a forecast every 15 minutes over the last `days` (ForecastBacktest.checks). Stretches
/// filled in from the 15-minute history are left out when live readings are most of what there is.
export function backtestChecks(readings: Reading[], now: number, days: number, tuning: Tuning): { checks: Check[]; origins: number } {
  const series = new Series(readings);
  const start = now - days * 86_400;
  const maxH = Math.max(...calibrationHorizons) * 60;
  const out: Check[] = [];
  let origins = 0, denseOrigins = 0;
  let lastOrigin = -Infinity;
  for (const r of series.readings) {
    if (!(r.t >= start && r.t + 15 * 60 <= now)) continue;
    if (r.t - lastOrigin < backtestSpacing) continue;
    // The forecast only looks at the last few readings, so the last hour is enough.
    const recent = new Series(series.slice(r.t - 3600, r.t), true);
    const res = forecast(recent, null, r.t, maxH, tuning);
    if (!res.ok) continue;
    const f = res.forecast;
    lastOrigin = r.t;
    origins += 1;
    const dense = recent.slice(r.t - tuning.trendWindow, r.t).length >= Math.trunc(tuning.trendWindow / denseSpacing);
    if (dense) denseOrigins += 1;
    for (const h of calibrationHorizons) {
      const target = r.t + h * 60;
      if (target > now) continue;
      const actual = series.value(target);
      if (actual === null) continue;
      const p = f.samples.find((s) => Math.abs(s.t - target) < 30);
      if (!p) continue;
      out.push({ origin: r.t, minutes: h, residual: actual - p.mgdl, naive: actual - f.startMgdl, dense,
                 mgdl: p.mgdl, trendPerMinute: f.trendPerMinute });
    }
  }
  if (denseOrigins * 2 >= origins && denseOrigins > 0) return { checks: out.filter((c) => c.dense), origins: denseOrigins };
  return { checks: out, origins };
}

// MARK: - Tuning (ForecastTuner.swift)

const tunerFades = [15, 20, 30, 45].map((m) => m * 60);
const tunerWindows = [15, 20].map((m) => m * 60);
const tunerCandidates: Tuning[] = tunerFades.flatMap((f) => tunerWindows.map((w) => ({ trendFade: f, trendWindow: w, trendGain: 1 })));
/// The trend forecast is shown 30 minutes ahead, so it's judged there.
const tunerHorizons = new Set([15, 30]);
export const tunerMinimumChecks = 120;
const tunerRequiredImprovement = 0.97;

type Keyed = Map<string, { origin: number; minutes: number; value: number }>;
const keyOf = (origin: number, minutes: number) => `${origin}:${minutes}`;

function median(values: number[]): number {
  return quantile([...values].sort((a, b) => a - b), 0.5);
}

/// The share of the trend that carried on: a least-squares slope of what happened on the trend's
/// part of each forecast, fitted on each half of the history and the larger taken, rounded to 5%.
/// Null with too few points, or when it's within 5% of all of it.
export function fittedGain(withTrend: Keyed, withoutTrend: Keyed): number | null {
  const keys = [...withTrend.keys()].filter((k) => withoutTrend.has(k));
  if (keys.length < tunerMinimumChecks) return null;
  const mid = median(keys.map((k) => withTrend.get(k)!.origin));
  const xy = [0, 0], xx = [0, 0];
  for (const k of keys) {
    const half = withTrend.get(k)!.origin < mid ? 0 : 1;
    const r0 = withoutTrend.get(k)!.value;
    const part = r0 - withTrend.get(k)!.value;
    xy[half] += r0 * part;
    xx[half] += part * part;
  }
  if (!(xx[0] > 0 && xx[1] > 0)) return null;
  const gain = Math.max(xy[0] / xx[0], xy[1] / xx[1]);
  const rounded = Math.round(Math.min(1, Math.max(0.25, gain)) * 20) / 20;
  return rounded < 0.95 ? rounded : null;
}

/// The candidate's error as a share of the baseline's on the points both made, each horizon
/// counting equally. Null unless there are enough points, it's at least `required` of the
/// baseline, and it's no worse in either half of the history.
export function tuningRatio(theirs: Keyed, base: Keyed, required = tunerRequiredImprovement): number | null {
  const shared = [...base.keys()].filter((k) => tunerHorizons.has(base.get(k)!.minutes) && theirs.has(k));
  if (shared.length < tunerMinimumChecks) return null;
  const per = new Map<number, { sum: number; n: number }>();
  for (const k of shared) {
    const b = base.get(k)!;
    const e = per.get(b.minutes) ?? { sum: 0, n: 0 };
    e.sum += b.value;
    e.n += 1;
    per.set(b.minutes, e);
  }
  const weight = (m: number) => {
    const e = per.get(m);
    return e && e.sum > 0 ? e.n / e.sum : 0;
  };
  const mid = median(shared.map((k) => base.get(k)!.origin));
  const sums = [0, 0], baseSums = [0, 0], counts = [0, 0];
  for (const k of shared) {
    const b = base.get(k)!;
    const half = b.origin < mid ? 0 : 1;
    const w = weight(b.minutes);
    sums[half] += theirs.get(k)!.value * w;
    baseSums[half] += b.value * w;
    counts[half] += 1;
  }
  const total = baseSums[0] + baseSums[1];
  if (!(counts[0] > 0 && counts[1] > 0) || !(total > 0)) return null;
  const ratio = (sums[0] + sums[1]) / total;
  if (!(ratio <= required && sums[0] <= baseSums[0] && sums[1] <= baseSums[1] && ratio < 1)) return null;
  return ratio;
}

/// Picks the trend's strength and then its timing from the user's history (ForecastTuner.tune):
/// standard unless the replay clearly says otherwise.
export function tuneTrend(readings: Reading[], now: number, days = 30): Tuning {
  const run = (t: Tuning, abs: boolean): Keyed => {
    const out: Keyed = new Map();
    for (const c of backtestChecks(readings, now, days, t).checks) {
      if (!tunerHorizons.has(c.minutes)) continue;
      out.set(keyOf(c.origin, c.minutes), { origin: c.origin, minutes: c.minutes, value: abs ? Math.abs(c.residual) : c.residual });
    }
    return out;
  };
  const standard = run(standardTuning, true);
  if (standard.size < tunerMinimumChecks) return standardTuning;
  let base = { tuning: standardTuning, errors: standard };
  const gain = fittedGain(run(standardTuning, false), run({ ...standardTuning, trendGain: 0 }, false));
  if (gain !== null) {
    const candidate = { ...standardTuning, trendGain: gain };
    const theirs = run(candidate, true);
    if (tuningRatio(theirs, standard, 1) !== null) base = { tuning: candidate, errors: theirs };
  }
  let chosen = base.tuning;
  let bestRatio = 1;
  for (const timing of tunerCandidates) {
    if (isStandardTuning(timing)) continue;
    const candidate = { ...timing, trendGain: base.tuning.trendGain };
    const ratio = tuningRatio(run(candidate, true), base.errors);
    if (ratio !== null && ratio < bestRatio) {
      bestRatio = ratio;
      chosen = candidate;
    }
  }
  return chosen;
}

/// Tunes the trend, then replays the stored readings with it to see how good the forecast has
/// been (OutlookEngine.learn with no logbook).
export function learnCalibration(readings: Reading[], now: number, days = 30): Calibration | null {
  const tuning = tuneTrend(readings, now, days);
  const { checks, origins } = backtestChecks(readings, now, days, tuning);
  if (origins === 0) return null;
  const trend: HorizonStats[] = [];
  for (const h of calibrationHorizons) {
    const cs = checks.filter((c) => c.minutes === h);
    if (cs.length === 0) continue;
    const res = cs.map((c) => c.residual);
    const sorted = [...res].sort((a, b) => a - b);
    trend.push({
      minutes: h, samples: res.length,
      meanAbsoluteError: res.reduce((a, b) => a + Math.abs(b), 0) / res.length,
      naiveError: cs.reduce((a, c) => a + Math.abs(c.naive), 0) / cs.length,
      bias: res.reduce((a, b) => a + b, 0) / res.length,
      lower: quantile(sorted, 0.1), upper: quantile(sorted, 0.9),
    });
  }
  return { trend, origins, computedAt: now, tuning, rangeScale: replayRangeScale(checks, trend, now) };
}

/// The range widening the replay says the relay's forecast needs (`rangeScaleFrom`), from the
/// replayed forecasts at the horizons the relay draws, each with the range `forecast` would have
/// drawn around it from `stats`. The relay replays every 15 minutes over its one-minute readings,
/// so this is there from the first day and after any gap in the ledger, and its last-12-hours and
/// fast-trend parts react the same day. Null with too few points.
export function replayRangeScale(checks: Check[], stats: HorizonStats[], now: number): RangeScale | null {
  const byOrigin = new Map<number, ShownForecast>();
  for (const c of checks) {
    if (c.minutes * 60 > trendHorizon) continue;
    const b = interpolateBand(stats, c.minutes) ?? defaultBand(c.minutes);
    const lower = Math.max(sensorLow - 1, c.mgdl + b.lower), upper = Math.min(sensorHigh + 1, c.mgdl + b.upper);
    const shown = byOrigin.get(c.origin) ?? { issuedAt: c.origin, trendPerMinute: c.trendPerMinute, points: [] };
    shown.points.push({ minutes: c.minutes, mgdl: c.mgdl, lower, upper, actual: c.mgdl + c.residual });
    byOrigin.set(c.origin, shown);
  }
  return rangeScaleFrom([...byOrigin.values()], now);
}

// MARK: - Back in range (Sources/Engine/BackInRange.swift)

/// How the relay's own "back in range" estimates have done (BackInRangeCheck). Its forecasts are
/// its own, so it never borrows the apps' checks: until its own ledger has enough, it sends none.
export interface BackInRangeCheck {
  checks: number;
  /// Median |estimate − actual|, minutes. Null with no checks.
  medianMissMinutes: number | null;
  /// Share of checks within `backInRangeMaxMiss`, 0...1.
  withinTolerance: number | null;
}

export const backInRangeMaxMiss = 15;
export const backInRangeMinimumChecks = 5;
export const backInRangeWindow = 30 * 86_400;
export const backInRangeLookAhead = 6 * 3600;
export const backInRangeConfirmWithin = 20 * 60;

export const backInRangeShows = (c: BackInRangeCheck | null | undefined): boolean =>
  !!c && c.checks >= backInRangeMinimumChecks && c.medianMissMinutes !== null && c.medianMissMinutes <= backInRangeMaxMiss;

/// Minutes until a line starting at `start` (above `high`) first comes back to `high`, linear
/// between `points` (minutes ahead, in order). Null when it starts in range or doesn't come back.
export function minutesBack(start: number, points: { minutes: number; mgdl: number }[], high: number): number | null {
  if (!(start > high)) return null;
  let m0 = 0, v0 = start;
  for (const p of points) {
    if (p.mgdl <= high) {
      const drop = v0 - p.mgdl;
      return drop > 0 ? m0 + ((v0 - high) / drop) * (p.minutes - m0) : p.minutes;
    }
    m0 = p.minutes;
    v0 = p.mgdl;
  }
  return null;
}

/// Minutes from `start` until glucose was back in range: the first in-range reading whose next
/// reading (within 20 minutes) is too, looked for up to 6 hours. Null when not seen or the readings
/// stop first. `readings` oldest first.
export function actualMinutesBack(readings: Reading[], start: number, low: number, high: number): number | null {
  const r = readings.filter((x) => x.t > start && x.t <= start + backInRangeLookAhead + backInRangeConfirmWithin);
  for (let i = 0; i + 1 < r.length; i++) {
    const a = r[i], b = r[i + 1];
    if (a.t - start > backInRangeLookAhead) break;
    const inA = a.mgdl >= low && a.mgdl <= high, inB = b.mgdl >= low && b.mgdl <= high;
    if (inA && inB && b.t - a.t <= backInRangeConfirmWithin) return (a.t - start) / 60;
  }
  return null;
}

/// One settled relay forecast, as the back-in-range check reads it.
export interface BackInRangeRecord {
  issuedAt: number;
  startMgdl: number;
  /// The drawn points only.
  points: { minutes: number; mgdl: number }[];
}

/// Scores the relay's settled forecasts from the last 30 days that started above range and came
/// back within their drawn points (BackInRange.check). `readings` oldest first.
export function backInRangeCheck(records: BackInRangeRecord[], readings: Reading[], low: number, high: number,
                                 now: number): BackInRangeCheck {
  const misses: number[] = [];
  const last = readings[readings.length - 1];
  for (const r of records) {
    if (r.issuedAt < now - backInRangeWindow || r.startMgdl <= high) continue;
    const points = [...r.points].sort((a, b) => a.minutes - b.minutes);
    const estimate = minutesBack(r.startMgdl, points, high);
    if (estimate === null) continue;
    const actual = actualMinutesBack(readings, r.issuedAt, low, high);
    if (actual !== null) misses.push(Math.abs(estimate - actual));
    else if (last && last.t >= r.issuedAt + backInRangeLookAhead) misses.push(backInRangeLookAhead / 60 - estimate);
  }
  if (!misses.length) return { checks: 0, medianMissMinutes: null, withinTolerance: null };
  return {
    checks: misses.length,
    medianMissMinutes: median(misses),
    withinTolerance: misses.filter((m) => m <= backInRangeMaxMiss).length / misses.length,
  };
}

// MARK: - Outlook snapshot

export interface OutlookSnapshot {
  issuedAt: number;
  forecast: ForecastSample[];
  lowExpectedAt: number | null;
  /// From above range: when the forecast's central line comes back down to the high threshold,
  /// only while the relay's own checks of that keep it within 15 minutes. Null otherwise.
  backInRangeAt: number | null;
}

export function outlookSnapshot(result: ForecastResult, now: number, lowMgdl: number, highMgdl = Infinity,
                                check: BackInRangeCheck | null = null): OutlookSnapshot {
  if (!result.ok) return { issuedAt: now, forecast: [], lowExpectedAt: null, backInRangeAt: null };
  const f = result.forecast;
  const lowExpectedAt = f.samples.find((s) => s.mgdl < lowMgdl)?.t ?? null;
  let backInRangeAt: number | null = null;
  if (lowExpectedAt === null && backInRangeShows(check)) {
    const points = f.samples.map((s) => ({ minutes: (s.t - f.issuedAt) / 60, mgdl: s.mgdl })).filter((p) => p.minutes > 0.01);
    const m = minutesBack(f.startMgdl, points, highMgdl);
    if (m !== null) backInRangeAt = f.issuedAt + m * 60;
  }
  return { issuedAt: f.issuedAt, forecast: f.samples, lowExpectedAt, backInRangeAt };
}

// MARK: - Alerts

export type AlertKind =
  | "urgentLow" | "low" | "high" | "veryHigh" | "rapidChange" | "stale" | "sensorExpiring" | "apiBroken"
  | "predictedUrgentLow" | "predictedLow" | "predictedHigh" | "predictedVeryHigh";

const predictedKinds: AlertKind[] = ["predictedUrgentLow", "predictedLow", "predictedHigh", "predictedVeryHigh"];

export interface AlertNotice {
  kind: AlertKind;
  title: string;
  body: string;
  critical: boolean;
}

export const noticeIdentifier = (n: AlertNotice) => `glucos.${n.kind}`;

// MARK: - Episodes (Sources/Core/AlertEpisodes.swift, docs/AlertEpisodes.md)

/// Alerts from one low (or one high) share a collapse id, so a newer push replaces the older one
/// on the phone instead of stacking; it still sounds. Back in range, a quiet summary replaces it.
export type EpisodeSide = "low" | "high";
export interface EpisodeShown { kind: AlertKind; at: number }
export interface Episode {
  side: EpisodeSide;
  /// The first reading out of range, or the first heads-up before one. Names the notification.
  key: number;
  outSince: number | null;
  lastOutAt: number | null;
  extremeMgdl: number | null;
  lastAlertAt: number | null;
  shown: EpisodeShown[];
}
export interface EpisodesState { low: Episode | null; high: Episode | null }
export interface BackInRangeSummary {
  side: EpisodeSide;
  identifier: string;
  minutes: number;
  extremeMgdl: number;
  nowMgdl: number;
  shown: EpisodeShown[];
}

export const newEpisodes = (): EpisodesState => ({ low: null, high: null });
export const episodeGapLimit = 30 * 60;
export const episodeHeadsUpFor = 45 * 60;
export const episodeShownLimit = 12;

export function episodeSide(kind: AlertKind): EpisodeSide | null {
  switch (kind) {
    case "urgentLow": case "low": case "predictedUrgentLow": case "predictedLow": return "low";
    case "high": case "veryHigh": case "predictedHigh": case "predictedVeryHigh": return "high";
    default: return null;
  }
}

export const episodeIdentifier = (e: Episode) => `glucos.${e.side}.${Math.trunc(e.key)}`;

function markEpisode(st: EpisodesState, side: EpisodeSide, r: Reading) {
  const e: Episode = st[side] ?? { side, key: r.t, outSince: null, lastOutAt: null, extremeMgdl: null, lastAlertAt: null, shown: [] };
  if (e.outSince === null) e.outSince = r.t;
  e.lastOutAt = r.t;
  const x = e.extremeMgdl ?? r.mgdl;
  e.extremeMgdl = side === "low" ? Math.min(x, r.mgdl) : Math.max(x, r.mgdl);
  st[side] = e;
}

function endEpisode(st: EpisodesState, side: EpisodeSide, r: Reading, now: number): BackInRangeSummary | null {
  const e = st[side];
  if (!e) return null;
  if (e.outSince === null || e.lastOutAt === null || e.extremeMgdl === null) {
    if (e.lastAlertAt !== null && now - e.lastAlertAt < episodeHeadsUpFor) return null;
    st[side] = null;
    return null;
  }
  st[side] = null;
  if (!e.shown.length || r.t - e.lastOutAt > episodeGapLimit) return null;
  const minutes = Math.max(1, roundHalfAway((r.t - e.outSince) / 60));
  return { side, identifier: episodeIdentifier(e), minutes, extremeMgdl: e.extremeMgdl, nowMgdl: r.mgdl, shown: e.shown };
}

/// Call with every tick's snapshot, before `recordEpisodeAlert`. The episodes this reading ended
/// that had an alert shown, as summaries to push. Mutates `st`.
export function observeEpisodes(st: EpisodesState, s: Snapshot, now: number): BackInRangeSummary[] {
  const r = s.current;
  if (!r || isStale(s, now)) return [];
  switch (classify(r.mgdl, s.lowMgdl, s.highMgdl)) {
    case "urgentLow": case "low":
      st.high = null;
      markEpisode(st, "low", r);
      return [];
    case "high": case "veryHigh":
      st.low = null;
      markEpisode(st, "high", r);
      return [];
    default:
      return (["low", "high"] as EpisodeSide[]).map((side) => endEpisode(st, side, r, now))
        .filter((b): b is BackInRangeSummary => b !== null);
  }
}

/// An alert about to be pushed: its episode's id (opening one if none is going) and the alerts it
/// replaces. Null for alerts outside episodes. Mutates `st`.
export function recordEpisodeAlert(st: EpisodesState, kind: AlertKind, now: number):
  { identifier: string; earlier: EpisodeShown[] } | null {
  const side = episodeSide(kind);
  if (!side) return null;
  const e: Episode = st[side] ?? { side, key: now, outSince: null, lastOutAt: null, extremeMgdl: null, lastAlertAt: null, shown: [] };
  const earlier = [...e.shown];
  e.shown.push({ kind, at: now });
  if (e.shown.length > episodeShownLimit) e.shown.splice(0, e.shown.length - episodeShownLimit);
  e.lastAlertAt = now;
  st[side] = e;
  return { identifier: episodeIdentifier(e), earlier };
}

export function episodeDuration(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

export function backInRangeText(b: BackInRangeSummary, unit: Unit): { title: string; body: string } {
  const word = b.side === "low" ? "Lowest" : "Highest";
  return {
    title: `Back in range after ${episodeDuration(b.minutes)}`,
    body: `${word} ${formatGlucose(unit, b.extremeMgdl, true)}, now ${formatGlucose(unit, b.nowMgdl, true)}.`,
  };
}

/// `[[kind, seconds]]`, as the apps read it (`AlertEpisodes.Shown.list`).
export const earlierPayload = (shown: EpisodeShown[]) => shown.map((e) => [e.kind, Math.trunc(e.at)]);

export interface PlannerState {
  lastFired: Partial<Record<AlertKind, number>>;
  quietSince: number | null;
}

export const newPlanner = (): PlannerState => ({ lastFired: {}, quietSince: null });

function fire(p: PlannerState, kind: AlertKind, title: string, body: string, cooldown: number, now: number,
              out: AlertNotice[], critical = false) {
  const last = p.lastFired[kind];
  if (last !== undefined && now - last < cooldown) return;
  p.lastFired[kind] = now;
  out.push({ kind, title, body, critical });
}

export function evaluateAlerts(p: PlannerState, s: Snapshot, prefs: AlertPreferences, now: number): AlertNotice[] {
  if (!prefs.enabled) return [];
  const out: AlertNotice[] = [];
  const unit = s.unit;
  const cooldown = prefs.cooldownMinutes * 60;
  const stale = isStale(s, now);

  const r = s.current;
  if (r && !stale) {
    const v = formatGlucose(unit, r.mgdl, true);
    switch (classify(r.mgdl, s.lowMgdl, s.highMgdl)) {
      case "urgentLow":
        fire(p, "urgentLow", `URGENT LOW — ${v}`, `${trendDescription(r.trend)}. Treat now and confirm on your phone.`,
             5 * 60, now, out, true);
        break;
      case "low":
        fire(p, "low", `Low glucose — ${v}`, trendDescription(r.trend), cooldown, now, out);
        break;
      case "veryHigh":
        fire(p, "veryHigh", `Very high glucose — ${v}`, trendDescription(r.trend), cooldown, now, out);
        break;
      case "high":
        if (prefs.high) fire(p, "high", `High glucose — ${v}`, trendDescription(r.trend), cooldown, now, out);
        break;
      case "inRange":
        for (const k of ["low", "high", "urgentLow", "veryHigh"] as AlertKind[]) delete p.lastFired[k];
        break;
    }
    if (prefs.rapidChange && trendIsRapid(r.trend)) {
      const d = deltaMgdl(s);
      fire(p, "rapidChange", `${trendDescription(r.trend)} — ${v}`,
           d === null ? "" : `${formatDelta(unit, d)} since last reading`, cooldown, now, out);
    } else if (!trendIsRapid(r.trend)) {
      delete p.lastFired.rapidChange;
    }
  }

  if (prefs.stale && stale && s.current) {
    const age = formatAge(now - s.current.t);
    fire(p, "stale", "No recent glucose data", `Last reading ${age}. Check your phone has signal and LibreLink is running.`,
         30 * 60, now, out);
  } else {
    delete p.lastFired.stale;
  }

  if (prefs.sensorExpiry && s.sensor) {
    const days = Math.max(0, (s.sensor.activated + s.sensor.lifetimeDays * 86_400 - now) / 86_400);
    if (days < 1) {
      fire(p, "sensorExpiring", "Sensor expires soon", `About ${formatDays(days)} left on sensor ${s.sensor.serial}.`,
           6 * 3600, now, out);
    }
  }

  const err = s.lastError;
  if (err && (err.includes("version") || err.includes("API may have changed"))) {
    fire(p, "apiBroken", "GlucOS needs attention", err, 6 * 3600, now, out);
  }
  return out;
}

// MARK: - Snooze and "I'm treating it" (Sources/Core/AlertSnooze.swift, docs/AlertActions.md)

export type SnoozeLevel = "low" | "high" | "veryHigh";
export type AlertTreatment = "low" | "high";
/// When each level's snooze ends, seconds since 1970. Only quiets the owner's own pushes.
export interface AlertSnoozes {
  low?: number;
  high?: number;
  veryHigh?: number;
}

export const snoozeMinutes = 30;
export const snoozeMaximumMinutes = 60;
export const snoozeAndTreatCategory = "glucos.alert";
export const treatOnlyCategory = "glucos.alert.urgent";

/// Urgent lows are never snoozable (null), nor are alerts without buttons.
export function snoozeLevel(k: AlertKind): SnoozeLevel | null {
  switch (k) {
    case "low": case "predictedLow": return "low";
    case "high": case "predictedHigh": return "high";
    case "veryHigh": case "predictedVeryHigh": return "veryHigh";
    default: return null;
  }
}

export function alertTreatment(k: AlertKind): AlertTreatment | null {
  switch (k) {
    case "urgentLow": case "predictedUrgentLow": case "low": case "predictedLow": return "low";
    case "high": case "predictedHigh": case "veryHigh": case "predictedVeryHigh": return "high";
    default: return null;
  }
}

/// The notification category the iPhone app registers with this alert's buttons.
export function alertCategory(k: AlertKind): string | null {
  if (alertTreatment(k) === null) return null;
  return snoozeLevel(k) === null ? treatOnlyCategory : snoozeAndTreatCategory;
}

/// The small chart on a low, high or forecast alert (AlertChart.swift): the card's last 3 hours and
/// forecast, under `chart` in the push. The iPhone's notification content extension draws it.
/// Null for alerts without buttons, or with fewer than 2 readings. Relay 2.18.0 on.
export interface AlertChart {
  readingAt: number;
  unit: string;
  lowMgdl: number;
  highMgdl: number;
  history: (number | null)[];
  forecast: number[];
  forecastLower?: number;
  forecastUpper?: number;
}

export function alertChart(k: AlertKind, card: CardState | null | undefined): AlertChart | null {
  if (!card || alertTreatment(k) === null) return null;
  if (card.history.filter((v) => v !== null).length < 2) return null;
  const chart: AlertChart = {
    readingAt: card.readingAt, unit: card.unit, lowMgdl: card.lowMgdl, highMgdl: card.highMgdl,
    history: card.history, forecast: card.forecast,
  };
  if (card.forecastLower !== undefined) chart.forecastLower = card.forecastLower;
  if (card.forecastUpper !== undefined) chart.forecastUpper = card.forecastUpper;
  return chart;
}

/// A very-high snooze quiets highs too; a high snooze lets a very high through.
export function silences(s: AlertSnoozes | null | undefined, k: AlertKind, now: number): boolean {
  const level = snoozeLevel(k);
  if (!s || level === null) return false;
  const covering: SnoozeLevel[] = level === "high" ? ["high", "veryHigh"] : [level];
  return covering.some((l) => (s[l] ?? 0) > now);
}

/// Snoozes `k`'s level for `minutes` (at most snoozeMaximumMinutes), keeping a longer one. False
/// for an alert that can't be snoozed.
export function snoozeAlert(s: AlertSnoozes, k: AlertKind, minutes: number, now: number): boolean {
  const level = snoozeLevel(k);
  if (level === null || !(minutes > 0)) return false;
  const end = now + Math.min(Math.trunc(minutes), snoozeMaximumMinutes) * 60;
  s[level] = Math.max(s[level] ?? 0, end);
  return true;
}

export function pruneSnoozes(s: AlertSnoozes, now: number) {
  for (const l of ["low", "high", "veryHigh"] as SnoozeLevel[]) if ((s[l] ?? 0) <= now) delete s[l];
}

/// A copy of the snoozes still running at `now`, for the owner's status (`{}` when none).
export function runningSnoozes(s: AlertSnoozes | null | undefined, now: number): AlertSnoozes {
  const out: AlertSnoozes = {};
  for (const l of ["low", "high", "veryHigh"] as SnoozeLevel[]) {
    const end = s?.[l];
    if (typeof end === "number" && end > now) out[l] = end;
  }
  return out;
}

/// A running snooze, as the owner's Live Activity shows it (`SnoozeBadge` in
/// Sources/Shared/GlucoseActivityState.swift, built there by `AlertSnoozes.badge(at:)`).
export interface CardSnooze {
  /// When the last running snooze ends, seconds since 1970.
  until: number;
  /// The snoozed levels, soonest end first.
  levels: SnoozeLevel[];
}

/// The card's snooze, or undefined when nothing is snoozed at `now`. A very-high snooze covers
/// highs, so a high snooze that ends no later isn't named.
export function cardSnooze(s: AlertSnoozes | null | undefined, now: number): CardSnooze | undefined {
  const order: SnoozeLevel[] = ["low", "high", "veryHigh"];
  let active = order
    .map((level) => ({ level, until: s?.[level] }))
    .filter((a): a is { level: SnoozeLevel; until: number } => typeof a.until === "number" && a.until > now)
    .sort((a, b) => a.until - b.until || order.indexOf(a.level) - order.indexOf(b.level));
  const vh = active.find((a) => a.level === "veryHigh");
  if (vh) active = active.filter((a) => !(a.level === "high" && a.until <= vh.until));
  if (active.length === 0) return undefined;
  return { until: Math.max(...active.map((a) => a.until)), levels: active.map((a) => a.level) };
}

/// The owner's card with its snooze on it (or not).
export function withSnooze(card: CardState, snooze: CardSnooze | undefined): CardState {
  if (!snooze) return card;
  return { ...card, snooze };
}

/// The owner's alerts this tick, from the owner's own planner, minus the snoozed ones. A snoozed
/// alert's repeat timer is cleared, so it fires on the first tick after the snooze if still due.
/// Followers keep the shared planner (`processTick`), so their alerts and check-ins never change.
export function ownerNotices(p: PlannerState, snoozes: AlertSnoozes | null | undefined, tick: TickResult,
                             prefs: AlertPreferences, now: number): AlertNotice[] {
  const due = evaluateAlerts(p, tick.snapshot, prefs, now);
  const pre = evaluatePrediction(p, tick.snapshot, tick.forecast.ok ? tick.forecast.forecast : null, prefs, now);
  if (pre) due.push(pre);
  return due.filter((n) => {
    if (!silences(snoozes, n.kind, now)) return true;
    delete p.lastFired[n.kind];
    return false;
  });
}

const urgentLowMgdl = 54;
const veryHighMgdl = 250;
const minimumFall = -0.3;
const minimumRise = 0.3;
const highLeadFactor = 1.5;
/// Highs look no further than they did at the old 20-minute default (§13 moved it to 30 for lows).
const highLeadMaximum = 30 * 60;

/// How far ahead predicted lows look (PredictiveAlertRules.lowLookahead). `drawn`: only the drawn
/// forecast, as before §13; `trend`: also its cut-off part and the trend's full 30 minutes.
export type LowLookahead = "drawn" | "trend";
export const lowLookahead: LowLookahead = "trend";

interface Excursion {
  kind: "urgentLow" | "low" | "high" | "veryHigh";
  expectedAt: number;
  thresholdMgdl: number;
}

function predictedExcursion(f: Forecast, prefs: AlertPreferences, low: number, high: number, now: number,
                            look: LowLookahead): Excursion | null {
  if (now - f.issuedAt > staleAfter) return null;
  const start = f.startMgdl;
  const lead = prefs.predictiveMinutes * 60;
  const lowSamples = look === "trend" ? [...f.samples, ...(f.unshown ?? []), ...(f.lowLookahead ?? [])] : f.samples;
  const below = (thr: number, within: number) => lowSamples.find((s) => s.t - f.issuedAt <= within && s.mgdl < thr);
  const above = (thr: number, within: number) => f.samples.find((s) => s.t - f.issuedAt <= within && s.mgdl > thr);
  if (prefs.predictedLow && f.trendPerMinute <= minimumFall) {
    let s;
    if (start >= urgentLowMgdl && (s = below(urgentLowMgdl, lead))) return { kind: "urgentLow", expectedAt: s.t, thresholdMgdl: urgentLowMgdl };
    if (start >= low && (s = below(low, lead))) return { kind: "low", expectedAt: s.t, thresholdMgdl: low };
  }
  if (prefs.predictedHigh && f.trendPerMinute >= minimumRise) {
    const hl = Math.min(lead * highLeadFactor, highLeadMaximum);
    let s;
    if (start <= veryHighMgdl && (s = above(veryHighMgdl, hl))) return { kind: "veryHigh", expectedAt: s.t, thresholdMgdl: veryHighMgdl };
    if (prefs.high && start <= high && (s = above(high, hl))) return { kind: "high", expectedAt: s.t, thresholdMgdl: high };
  }
  return null;
}

/// Swift's `.rounded()`: halves away from zero.
const roundHalfAway = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x));

function clearPredictions(p: PlannerState, now: number) {
  if (p.quietSince === null) p.quietSince = now;
  if (now - p.quietSince < 15 * 60) return;
  for (const k of predictedKinds) delete p.lastFired[k];
}

export function evaluatePrediction(p: PlannerState, s: Snapshot, f: Forecast | null, prefs: AlertPreferences,
                                   now: number, look: LowLookahead = lowLookahead): AlertNotice | null {
  if (!prefs.enabled || !(prefs.predictedLow || prefs.predictedHigh)) return null;
  const r = s.current;
  if (!r || isStale(s, now) || !f) {
    clearPredictions(p, now);
    return null;
  }
  const d = predictedExcursion(f, prefs, s.lowMgdl, s.highMgdl, now, look);
  if (!d) {
    clearPredictions(p, now);
    return null;
  }
  p.quietSince = null;
  const cooldown = prefs.cooldownMinutes * 60;
  const highCooldown = Math.max(cooldown, 30 * 60);
  const severer: AlertKind | null = d.kind === "low" ? "predictedUrgentLow" : d.kind === "high" ? "predictedVeryHigh" : null;
  const holdFor = severer === "predictedVeryHigh" ? highCooldown : cooldown;
  if (severer) {
    const last = p.lastFired[severer];
    if (last !== undefined && now - last < holdFor) return null;
  }
  const unit = s.unit;
  const minutes = Math.max(0, Math.trunc(roundHalfAway((d.expectedAt - now) / 60)));
  const when = minutes <= 1 ? "any minute" : `in about ${minutes} min`;
  const current = `Now ${formatGlucose(unit, r.mgdl, true)} ${trendArrow(r.trend)}.`;
  const threshold = formatGlucose(unit, d.thresholdMgdl, true);
  const note = "Forecast, not a reading: check before acting.";
  const out: AlertNotice[] = [];
  switch (d.kind) {
    case "urgentLow":
      fire(p, "predictedUrgentLow", `Urgent low predicted ${when}`, `${current} Heading below ${threshold}. ${note}`,
           Math.min(cooldown, 10 * 60), now, out, true);
      break;
    case "low":
      fire(p, "predictedLow", `Low predicted ${when}`, `${current} Heading below ${threshold}. ${note}`, cooldown, now, out);
      break;
    case "high":
      fire(p, "predictedHigh", `High predicted ${when}`, `${current} Heading above ${threshold}. ${note}`, highCooldown, now, out);
      break;
    case "veryHigh":
      fire(p, "predictedVeryHigh", `Very high predicted ${when}`, `${current} Heading above ${threshold}. ${note}`,
           highCooldown, now, out);
      break;
  }
  return out[0] ?? null;
}

// MARK: - Live Activity card

/// GlucoseActivityState, encoded exactly as Swift's JSONEncoder does: nil optionals are left out,
/// `forecast` and `source` are always present (ActivityKit's decoder requires them).
export interface CardState {
  mgdl: number;
  trend: number;
  readingAt: number;
  deltaMgdl?: number;
  unit: string;
  lowMgdl: number;
  highMgdl: number;
  history: (number | null)[];
  forecast: number[];
  forecastLower?: number;
  forecastUpper?: number;
  insulinOnBoard?: number;
  lowExpectedAt?: number;
  /// From above range: when the forecast says glucose is back in range, while the sender's own
  /// checks of that estimate keep it within 15 minutes. Never on a low or a low expected.
  backInRangeAt?: number;
  source: string;
  /// A check-in on this card (checkins.ts). Never set by `makeCard`: the relay adds it per card.
  checkIn?: CheckInCard;
  /// The owner's alerts are snoozed (`cardSnooze`): a bell-slash and "until 2:30 pm". Owner's
  /// card only, never a follower's; never set by `makeCard`. Relay 2.16.0 on.
  snooze?: CardSnooze;
}

const cardStep = 5 * 60;
const cardHistoryHours = 3;
const cardForecastMinutes = 60;

export function cardRange(c: CardState): Range {
  return classify(c.mgdl, c.lowMgdl, c.highMgdl);
}

export const cardStaleDate = (c: CardState) => c.readingAt + staleAfter;

export function makeCard(s: Snapshot, readings: Reading[], source: string, now: number): CardState | null {
  const current = s.current;
  if (!current) return null;
  const all = [...(readings.length === 0 ? s.history : readings), current];
  const slots = Math.trunc((cardHistoryHours * 3600) / cardStep) + 1;
  const window = all.filter((r) => {
    const age = current.t - r.t;
    return age >= -60 && age <= cardHistoryHours * 3600 + cardStep;
  });
  const history: (number | null)[] = [];
  for (let i = 0; i < slots; i++) {
    const centre = current.t - (slots - 1 - i) * cardStep;
    let nearest: Reading | undefined;
    for (const r of window) {
      if (!nearest || Math.abs(r.t - centre) < Math.abs(nearest.t - centre)) nearest = r;
    }
    history.push(nearest && Math.abs(nearest.t - centre) <= cardStep / 2 ? roundHalfAway(nearest.mgdl) : null);
  }
  history[slots - 1] = roundHalfAway(current.mgdl);

  const card: CardState = {
    mgdl: current.mgdl, trend: current.trend, readingAt: current.t, unit: s.unit,
    lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, history, forecast: [], source,
  };
  const d = deltaMgdl(s);
  if (d !== null) card.deltaMgdl = d;
  const o = s.outlook;
  if (o && !isStale(s, now) && now - o.issuedAt <= staleAfter) {
    const ahead = o.forecast.filter((p) => {
      const m = p.t - current.t;
      return m > 60 && m <= cardForecastMinutes * 60 + 60;
    });
    const points: ForecastSample[] = [];
    for (let stepIndex = 1; stepIndex <= cardForecastMinutes / 5; stepIndex++) {
      const target = current.t + stepIndex * cardStep;
      let best: ForecastSample | undefined;
      for (const p of ahead) if (!best || Math.abs(p.t - target) < Math.abs(best.t - target)) best = p;
      if (!best || Math.abs(best.t - target) > 150) break;
      points.push(best);
    }
    card.forecast = points.map((p) => roundHalfAway(p.mgdl));
    const last = points[points.length - 1];
    if (last) {
      card.forecastLower = roundHalfAway(last.lowerMgdl);
      card.forecastUpper = roundHalfAway(last.upperMgdl);
    }
    if (o.lowExpectedAt !== null) card.lowExpectedAt = o.lowExpectedAt;
    else if (o.backInRangeAt !== null && current.mgdl > s.highMgdl && o.backInRangeAt > current.t) {
      card.backInRangeAt = o.backInRangeAt;
    }
  }
  return card;
}

/// Same content, field for field (Swift's synthesized Hashable equality).
export function sameCard(a: CardState | null | undefined, b: CardState | null | undefined): boolean {
  if (!a || !b) return a === b;
  return JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
}

function sortKeys(o: CardState): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(o).sort()) out[k] = (o as unknown as Record<string, unknown>)[k];
  return out;
}

// MARK: - One fetch's worth of work

export interface TickResult {
  snapshot: Snapshot;
  forecast: ForecastResult;
  notices: AlertNotice[];
  card: CardState | null;
}

/// The widening the relay draws with: its own ledger's once that has enough scored forecasts, the
/// replay's until then.
export function effectiveRangeScale(ledger: RangeScale | null | undefined, calibration: Calibration | null | undefined): RangeScale | null {
  return ledger ?? calibration?.rangeScale ?? null;
}

/// What the relay does with the readings after each fetch: forecast, alerts, then the card.
/// `stored` already includes this fetch's readings. Mutates `planner`.
export function processTick(args: {
  stored: Reading[];
  current: Reading | null;
  sensor: Sensor | null;
  lastError: string | null;
  display: Display;
  prefs: AlertPreferences;
  planner: PlannerState;
  calibration: Calibration | null;
  /// The relay's range widening from its own ledger. Missing: the replay's (Calibration.rangeScale).
  rangeScale?: RangeScale | null;
  /// How far its own live checks let the relay draw the forecast (liveHorizon). Missing: no cut.
  live?: LiveCut | null;
  /// How the relay's own back-in-range estimates have done. Missing: none is sent.
  backInRange?: BackInRangeCheck | null;
  now: number;
}): TickResult {
  const { stored, now } = args;
  const snapshot = makeSnapshot(stored, args.current, args.sensor, args.display, args.lastError);
  const recent = stored.filter((r) => now - r.t <= 3600);
  const result = forecast(new Series(recent), args.calibration, now, undefined,
    args.calibration?.tuning ?? standardTuning, args.live ?? null, effectiveRangeScale(args.rangeScale, args.calibration));
  if (snapshot.current) snapshot.outlook = outlookSnapshot(result, now, snapshot.lowMgdl, snapshot.highMgdl, args.backInRange ?? null);
  const notices = evaluateAlerts(args.planner, snapshot, args.prefs, now);
  const p = evaluatePrediction(args.planner, snapshot, result.ok ? result.forecast : null, args.prefs, now);
  if (p) notices.push(p);
  const card = makeCard(snapshot, stored, "relay", now);
  return { snapshot, forecast: result, notices, card };
}
