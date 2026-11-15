// The relay's own forecast ledger: the forecast its Lock Screen card and followers were shown,
// kept every 15 minutes in `glucos.forecast_checks` as device "relay" and scored by the database
// against `glucos.readings` (glucos.score_relay_forecasts). The Mac and the iPhone keep their own
// ledgers (Sources/Engine/ForecastLedger.swift), but only while the Mac is awake or the app is
// open; the relay runs every minute, so its rows cover the nights. See docs/ForecastAccuracy.md.
//
// Rows belong to the owner's Supabase user: the one the `account` function signs the apps in as,
// found from the LibreLinkUp user id (`syntheticEmail`). No such user (the apps never signed in
// to sync) means nothing is kept.

import { calibrationHorizons, type Calibration, type Forecast, isStandardTuning } from "./core.ts";
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
}

export interface ForecastLedger {
  /// The Supabase user for a LibreLinkUp user id, or null when there's none.
  owner(libreUserId: string): Promise<string | null>;
  /// Keeps the forecast unless the owner already has a relay forecast in its 15 minutes.
  record(owner: string, r: LedgerRecord): Promise<boolean>;
  /// Scores the owner's recent relay forecasts. Returns how many changed.
  score(owner: string): Promise<number>;
}

/// The forecast as a ledger record, or null when it's within `ledgerSpacing` of the last one or
/// reaches none of the checked horizons (ForecastLedger.note).
export function ledgerRecord(f: Forecast, calibration: Calibration | null, lastIssuedAt: number | null,
                             id: string = crypto.randomUUID()): LedgerRecord | null {
  if (lastIssuedAt !== null && f.issuedAt - lastIssuedAt < ledgerSpacing) return null;
  const points: LedgerPoint[] = [];
  for (const m of calibrationHorizons) {
    const target = f.issuedAt + m * 60;
    const s = f.samples.find((x) => Math.abs(x.t - target) < 30);
    if (s) points.push({ minutes: m, mgdl: s.mgdl, lower: s.lowerMgdl, upper: s.upperMgdl });
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
  constructor(private readonly sql: SQL) {}

  async owner(libreUserId: string): Promise<string | null> {
    const email = await syntheticEmail(libreUserId);
    const rows = await this.sql`select id::text from auth.users where email = ${email} limit 1`;
    return rows.length ? (rows[0].id as string) : null;
  }

  async record(owner: string, r: LedgerRecord): Promise<boolean> {
    const rows = await this.sql`
      insert into glucos.forecast_checks
        (user_id, id, issued_at, device, basis, start_mgdl, trend_per_minute, points, limitations, calibrated, tuned, morning)
      select ${owner}::uuid, ${r.id}::uuid, to_timestamp(${r.issuedAt}), ${ledgerDevice}, ${r.basis}, ${r.startMgdl},
             ${r.trendPerMinute}, ${this.sql.json(r.points as never)}, '{}', ${r.calibrated}, ${r.tuned}, false
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
}
