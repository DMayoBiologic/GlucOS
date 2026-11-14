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
  predictedLow: true, predictedHigh: true, predictiveMinutes: 20, cooldownMinutes: 15,
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

/// The relay has no logbook, so only the trend basis is ever learnt.
export interface Calibration {
  trend: HorizonStats[];
  origins: number;
  computedAt: number;
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
}

export type ForecastResult = { ok: true; forecast: Forecast } | { ok: false; reason: string };

const unavailable = {
  noReading: "No reading yet.",
  stale: "No forecast while the latest reading is old.",
  outOfSensorRange: "No forecast while the reading is outside the sensor's range.",
  notEnoughRecentReadings: "Needs a few readings from the last 20 minutes to see the trend.",
  notAccurateEnough: "Past forecasts haven't been accurate enough to show one.",
};

const step = 5 * 60;
const trendFade = 30 * 60;
const trendWindow = 20 * 60;
const maxTrendPerMinute = 4;
const trendHorizon = 30 * 60;
const sensorLow = 40, sensorHigh = 400;

export function trendAt(series: Series, at: number): number | null {
  const recent = series.slice(at - trendWindow, at);
  if (recent.length === 0) return null;
  const first = recent[0], last = recent[recent.length - 1];
  if (last.t - first.t < 9 * 60) return null;
  const s = slope(recent.map((r) => (r.t - at) / 60), recent.map((r) => r.mgdl));
  if (s === null) return null;
  return Math.min(Math.max(s, -maxTrendPerMinute), maxTrendPerMinute);
}

/// The relay's forecast: the recent trend fading to level over half an hour (no insulin or carbs,
/// since the logbook lives on the Mac).
export function forecast(series: Series, calibration: Calibration | null, now: number, maxHorizon?: number): ForecastResult {
  const latest = series.last;
  if (!latest) return { ok: false, reason: unavailable.noReading };
  if (now - latest.t > staleAfter) return { ok: false, reason: unavailable.stale };
  if (!(latest.mgdl >= sensorLow && latest.mgdl <= sensorHigh)) return { ok: false, reason: unavailable.outOfSensorRange };
  const trend = trendAt(series, latest.t);
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

  const band = (minutes: number) => (stats ? interpolateBand(stats, minutes) : null) ?? defaultBand(minutes);
  const samples: ForecastSample[] = [{ t: t0, mgdl: latest.mgdl, lowerMgdl: latest.mgdl, upperMgdl: latest.mgdl }];
  let g = latest.mgdl;
  let minute = 0;
  const totalMinutes = horizon / 60;
  while (minute < totalMinutes) {
    const mid = minute + 0.5;
    const w = Math.max(0, 1 - (mid * 60) / trendFade);
    g += w * trend;
    minute += 1;
    if (Math.trunc(minute) % (step / 60) === 0) {
      const central = Math.min(Math.max(g, sensorLow - 1), sensorHigh + 1);
      const b = band(minute);
      samples.push({
        t: t0 + minute * 60, mgdl: central,
        lowerMgdl: Math.max(sensorLow - 1, central + b.lower),
        upperMgdl: Math.min(sensorHigh + 1, central + b.upper),
      });
    }
  }
  return { ok: true, forecast: { issuedAt: t0, startMgdl: latest.mgdl, basis: "trend", trendPerMinute: trend, samples } };
}

/// Replays the stored readings to see how good the forecast has been (see ForecastBacktest.swift).
export function learnCalibration(readings: Reading[], now: number, days = 30): Calibration | null {
  const series = new Series(readings);
  const start = now - days * 86_400;
  const maxH = Math.max(...calibrationHorizons) * 60;
  const residuals = new Map<number, number[]>();
  const naive = new Map<number, number[]>();
  let origins = 0;
  let lastOrigin = -Infinity;
  for (const r of series.readings) {
    if (!(r.t >= start && r.t + 15 * 60 <= now)) continue;
    if (r.t - lastOrigin < 30 * 60) continue;
    const res = forecast(series.upTo(r.t), null, r.t, maxH);
    if (!res.ok) continue;
    const f = res.forecast;
    lastOrigin = r.t;
    origins += 1;
    for (const h of calibrationHorizons) {
      const target = r.t + h * 60;
      if (target > now) continue;
      const actual = series.value(target);
      if (actual === null) continue;
      const p = f.samples.find((s) => Math.abs(s.t - target) < 30);
      if (!p) continue;
      if (!residuals.has(h)) residuals.set(h, []);
      if (!naive.has(h)) naive.set(h, []);
      residuals.get(h)!.push(actual - p.mgdl);
      naive.get(h)!.push(actual - f.startMgdl);
    }
  }
  if (origins === 0) return null;
  const trend: HorizonStats[] = [];
  for (const h of calibrationHorizons) {
    const res = residuals.get(h);
    if (!res || res.length === 0) continue;
    const sorted = [...res].sort((a, b) => a - b);
    const nv = naive.get(h) ?? [];
    trend.push({
      minutes: h, samples: res.length,
      meanAbsoluteError: res.reduce((a, b) => a + Math.abs(b), 0) / res.length,
      naiveError: nv.length === 0 ? Infinity : nv.reduce((a, b) => a + Math.abs(b), 0) / nv.length,
      bias: res.reduce((a, b) => a + b, 0) / res.length,
      lower: quantile(sorted, 0.1), upper: quantile(sorted, 0.9),
    });
  }
  return { trend, origins, computedAt: now };
}

// MARK: - Outlook snapshot

export interface OutlookSnapshot {
  issuedAt: number;
  forecast: ForecastSample[];
  lowExpectedAt: number | null;
}

export function outlookSnapshot(result: ForecastResult, now: number, lowMgdl: number): OutlookSnapshot {
  if (!result.ok) return { issuedAt: now, forecast: [], lowExpectedAt: null };
  const f = result.forecast;
  return { issuedAt: f.issuedAt, forecast: f.samples, lowExpectedAt: f.samples.find((s) => s.mgdl < lowMgdl)?.t ?? null };
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

const urgentLowMgdl = 54;
const veryHighMgdl = 250;
const minimumFall = -0.3;
const minimumRise = 0.3;
const highLeadFactor = 1.5;

interface Excursion {
  kind: "urgentLow" | "low" | "high" | "veryHigh";
  expectedAt: number;
  thresholdMgdl: number;
}

function predictedExcursion(f: Forecast, prefs: AlertPreferences, low: number, high: number, now: number): Excursion | null {
  if (now - f.issuedAt > staleAfter) return null;
  const start = f.startMgdl;
  const lead = prefs.predictiveMinutes * 60;
  const below = (thr: number, within: number) => f.samples.find((s) => s.t - f.issuedAt <= within && s.mgdl < thr);
  const above = (thr: number, within: number) => f.samples.find((s) => s.t - f.issuedAt <= within && s.mgdl > thr);
  if (prefs.predictedLow && f.trendPerMinute <= minimumFall) {
    let s;
    if (start >= urgentLowMgdl && (s = below(urgentLowMgdl, lead))) return { kind: "urgentLow", expectedAt: s.t, thresholdMgdl: urgentLowMgdl };
    if (start >= low && (s = below(low, lead))) return { kind: "low", expectedAt: s.t, thresholdMgdl: low };
  }
  if (prefs.predictedHigh && f.trendPerMinute >= minimumRise) {
    const hl = lead * highLeadFactor;
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
                                   now: number): AlertNotice | null {
  if (!prefs.enabled || !(prefs.predictedLow || prefs.predictedHigh)) return null;
  const r = s.current;
  if (!r || isStale(s, now) || !f) {
    clearPredictions(p, now);
    return null;
  }
  const d = predictedExcursion(f, prefs, s.lowMgdl, s.highMgdl, now);
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
  source: string;
  /// A check-in on this card (checkins.ts). Never set by `makeCard`: the relay adds it per card.
  checkIn?: CheckInCard;
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
  now: number;
}): TickResult {
  const { stored, now } = args;
  const snapshot = makeSnapshot(stored, args.current, args.sensor, args.display, args.lastError);
  const recent = stored.filter((r) => now - r.t <= 3600);
  const result = forecast(new Series(recent), args.calibration, now);
  if (snapshot.current) snapshot.outlook = outlookSnapshot(result, now, snapshot.lowMgdl);
  const notices = evaluateAlerts(args.planner, snapshot, args.prefs, now);
  const p = evaluatePrediction(args.planner, snapshot, result.ok ? result.forecast : null, args.prefs, now);
  if (p) notices.push(p);
  const card = makeCard(snapshot, stored, "relay", now);
  return { snapshot, forecast: result, notices, card };
}
