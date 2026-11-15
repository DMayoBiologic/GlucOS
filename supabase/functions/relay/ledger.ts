// The relay's own forecast ledger: the forecast its Lock Screen card and followers were shown,
// kept every 15 minutes in `glucos.forecast_checks` as device "relay" and scored by the database
// against `glucos.readings` (glucos.score_relay_forecasts). The Mac and the iPhone keep their own
// ledgers (Sources/Engine/ForecastLedger.swift), but only while the Mac is awake or the app is
// open; the relay runs every minute, so its rows cover the nights. See docs/ForecastAccuracy.md.
//
// Rows belong to the owner's Supabase user: the one the `account` function signs the apps in as,
// found from the LibreLinkUp user id (`syntheticEmail`). No such user (the apps never signed in
// to sync) means nothing is kept.

import {
  calibrationHorizons, type Calibration, type Forecast, isStandardTuning, type LiveCut, type LivePoint, liveHorizonWindow,
  rangeFactor, type RangeScale, type ShownForecast,
} from "./core.ts";
import { syntheticEmail } from "./libre.ts";
import type postgres from "npm:postgres@3.4.5";

type SQL = ReturnType<typeof postgres>;

export const ledgerDevice = "relay";
/// At most one forecast per this long, like the apps (ForecastLedger.spacing).
export const ledgerSpacing = 15 * 60;
/// How often the relay's unsettled forecasts are scored.
export const ledgerScoreEvery = 5 * 60;
/// How often an owner who wasn't found is looked for again.
export const ledgerOwnerRetry = 3600;

export interface LedgerPoint {
  minutes: number;
  mgdl: number;
  lower: number;
  upper: number;
  /// How much the range was widened when shown (rangeFactor). Missing: not widened.
  scale?: number;
  /// Only ever false: a point past the drawn horizon, kept to go on scoring it.
  shown?: false;
}

export interface LedgerRecord {
  id: string;
  issuedAt: number;
  startMgdl: number;
  trendPerMinute: number;
  basis: "trend";
  points: LedgerPoint[];
  /// The range came from this user's accuracy checks rather than the default.
  calibrated: boolean;
  /// The trend timing or strength was tuned to this user.
  tuned: boolean;
}

/// What the relay keeps between ticks (`Work.forecastLog`).
export interface LedgerState {
  libreUserId: string;
  /// The owner's Supabase user id, or null when none was found at `checkedAt`.
  owner: string | null;
  checkedAt: number;
  lastIssuedAt: number | null;
  scoredAt: number;
  /// How much wider to draw the range, from the relay's own scored forecasts (rangeScaleFrom),
  /// worked out after each scoring. Missing or null: not widened.
  rangeScale?: RangeScale | null;
  /// How far the relay's own live checks let it draw the forecast, worked out when it scores
  /// (`liveHorizon`). Missing on old rows; null: no cut.
  live?: LiveCut | null;
}

export interface ForecastLedger {
  /// The Supabase user for a LibreLinkUp user id, or null when there's none.
  owner(libreUserId: string): Promise<string | null>;
  /// Keeps the forecast unless the owner already has a relay forecast in its 15 minutes.
  record(owner: string, r: LedgerRecord): Promise<boolean>;
  /// Scores the owner's recent relay forecasts. Returns how many changed.
  score(owner: string): Promise<number>;
  /// The owner's relay forecasts issued since `since` (unix seconds), as scored so far.
  shown(owner: string, since: number): Promise<ShownForecast[]>;
  /// The owner's relay ledger points from the last `liveHorizonWindow`, for `liveHorizon`.
  livePoints(owner: string): Promise<LivePoint[]>;
}

/// The forecast as a ledger record, or null when it's within `ledgerSpacing` of the last one or
/// reaches none of the checked horizons (ForecastLedger.note).
export function ledgerRecord(f: Forecast, calibration: Calibration | null, lastIssuedAt: number | null,
                             id: string = crypto.randomUUID(), rangeScale: RangeScale | null = null): LedgerRecord | null {
  if (lastIssuedAt !== null && f.issuedAt - lastIssuedAt < ledgerSpacing) return null;
  const points: LedgerPoint[] = [];
  for (const m of calibrationHorizons) {
    const target = f.issuedAt + m * 60;
    const near = (x: { t: number }) => Math.abs(x.t - target) < 30;
    const s = f.samples.find(near);
    const kept = s ? undefined : f.unshown?.find(near);
    const at = s ?? kept;
    if (!at) continue;
    const point: LedgerPoint = { minutes: m, mgdl: at.mgdl, lower: at.lowerMgdl, upper: at.upperMgdl };
    if (!s) point.shown = false;
    // Kept so the next widening is measured against the range before this one (no compounding).
    if (rangeScale) point.scale = rangeFactor(rangeScale, m, f.trendPerMinute);
    points.push(point);
  }
  if (!points.length) return null;
  return {
    id, issuedAt: f.issuedAt, startMgdl: f.startMgdl, trendPerMinute: f.trendPerMinute, basis: f.basis, points,
    // forecast() takes its range from the calibration when any horizon has enough checks.
    calibrated: calibration?.trend.some((s) => s.samples >= 30) ?? false,
    tuned: calibration?.tuning ? !isStandardTuning(calibration.tuning) : false,
  };
}

export class PostgresForecastLedger implements ForecastLedger {
  /// `appVersion` is the relay's own version, kept on each forecast so accuracy can be split by release.
  constructor(private readonly sql: SQL, private readonly appVersion: string | null = null) {}

  async owner(libreUserId: string): Promise<string | null> {
    const email = await syntheticEmail(libreUserId);
    const rows = await this.sql`select id::text from auth.users where email = ${email} limit 1`;
    return rows.length ? (rows[0].id as string) : null;
  }

  async record(owner: string, r: LedgerRecord): Promise<boolean> {
    const rows = await this.sql`
      insert into glucos.forecast_checks
        (user_id, id, issued_at, device, basis, start_mgdl, trend_per_minute, points, limitations, calibrated, tuned, morning,
         app_version)
      select ${owner}::uuid, ${r.id}::uuid, to_timestamp(${r.issuedAt}), ${ledgerDevice}, ${r.basis}, ${r.startMgdl},
             ${r.trendPerMinute}, ${this.sql.json(r.points as never)}, '{}', ${r.calibrated}, ${r.tuned}, false,
             ${this.appVersion}
      where not exists (
        select 1 from glucos.forecast_checks
        where user_id = ${owner}::uuid and device = ${ledgerDevice}
          and issued_at > to_timestamp(${r.issuedAt - ledgerSpacing}) and issued_at <= to_timestamp(${r.issuedAt}))
      on conflict (user_id, id) do nothing
      returning id`;
    return rows.length > 0;
  }

  async score(owner: string): Promise<number> {
    const rows = await this.sql`select glucos.score_relay_forecasts(${owner}::uuid) as n`;
    return Number(rows[0]?.n ?? 0);
  }

  async shown(owner: string, since: number): Promise<ShownForecast[]> {
    const rows = await this.sql`
      select extract(epoch from issued_at)::float8 as issued_at, trend_per_minute, points
      from glucos.forecast_checks
      where user_id = ${owner}::uuid and device = ${ledgerDevice} and issued_at >= to_timestamp(${since})
      order by issued_at`;
    return rows.map((r) => ({
      issuedAt: Number(r.issued_at),
      trendPerMinute: Number(r.trend_per_minute),
      points: ((r.points ?? []) as Record<string, unknown>[]).map((p) => ({
        minutes: Number(p.minutes), mgdl: Number(p.mgdl), lower: Number(p.lower), upper: Number(p.upper),
        actual: typeof p.actual === "number" ? p.actual : null,
        afterLog: p.after_log === true,
        scale: typeof p.scale === "number" ? p.scale : null,
      })),
    }));
  }

  async livePoints(owner: string): Promise<LivePoint[]> {
    const rows = await this.sql`
      select extract(epoch from f.issued_at)::float8 as issued, (p ->> 'minutes')::int as minutes,
             (p ->> 'mgdl')::float8 as mgdl, f.start_mgdl,
             case when jsonb_typeof(p -> 'actual') = 'number' then (p ->> 'actual')::float8 end as actual,
             coalesce((p ->> 'after_log')::boolean, false) as after_log,
             coalesce((p ->> 'shown')::boolean, true) as shown
      from glucos.forecast_checks f
      cross join lateral jsonb_array_elements(f.points) p
      where f.user_id = ${owner}::uuid and f.device = ${ledgerDevice}
        and f.issued_at > now() - make_interval(secs => ${liveHorizonWindow})`;
    return rows.map((r) => ({
      issuedAt: Number(r.issued), minutes: Number(r.minutes), mgdl: Number(r.mgdl), startMgdl: Number(r.start_mgdl),
      actual: r.actual === null ? null : Number(r.actual), afterLog: Boolean(r.after_log), shown: Boolean(r.shown),
    }));
  }
}
