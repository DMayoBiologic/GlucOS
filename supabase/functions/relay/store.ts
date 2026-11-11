// The relay's state in Postgres. Everything is in the `glucos` schema, which the Data API doesn't
// expose and row-level security locks down, so only this function (connected as the database
// owner) can read it. The LibreLinkUp login and session are kept in Supabase Vault, encrypted.
// See supabase/migrations for the tables and the every-minute schedule.

import postgres from "npm:postgres@3.4.5";
import { newRow, type RelayRow, type Store, type Tx } from "./engine.ts";
import type { Reading, Trend } from "./core.ts";
import type { Account, LibreSession } from "./libre.ts";
import type { TokenCache } from "./apns.ts";

type SQL = ReturnType<typeof postgres>;

const accountSecret = "glucos_account";
const sessionSecret = "glucos_libre_session";
const cronSecret = "glucos_cron_token";

export function connect(url = Deno.env.get("SUPABASE_DB_URL")): SQL {
  if (!url) throw new Error("SUPABASE_DB_URL is not set");
  // The pooler runs in transaction mode, which can't keep prepared statements.
  return postgres(url, { prepare: false, max: 2, idle_timeout: 5, connect_timeout: 10 });
}

/// Fills in anything a stored row lacks (a new field, or the empty row the migration inserts).
export function hydrate(stored: Partial<RelayRow> & Record<string, unknown>): RelayRow {
  const d = newRow();
  return {
    ...d,
    ...stored,
    prefs: {
      ...d.prefs, ...(stored.prefs ?? {}),
      display: { ...d.prefs.display, ...(stored.prefs?.display ?? {}) },
      alerts: { ...d.prefs.alerts, ...(stored.prefs?.alerts ?? {}) },
    },
    work: { ...d.work, ...(stored.work ?? {}), planner: { ...d.work.planner, ...(stored.work?.planner ?? {}) } },
  };
}

async function readSecret(sql: SQL, name: string): Promise<string | null> {
  const rows = await sql`select decrypted_secret from vault.decrypted_secrets where name = ${name} limit 1`;
  return rows.length ? (rows[0].decrypted_secret as string) : null;
}

async function writeSecret(sql: SQL, name: string, value: string | null) {
  if (value === null) {
    await sql`delete from vault.secrets where name = ${name}`;
    return;
  }
  const rows = await sql`select id from vault.secrets where name = ${name} limit 1`;
  if (rows.length) await sql`select vault.update_secret(${rows[0].id}::uuid, ${value})`;
  else await sql`select vault.create_secret(${value}, ${name}, 'GlucOS push relay')`;
}

export class PostgresStore implements Store {
  constructor(private readonly sql: SQL) {}

  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.sql.begin(async (sql) => {
      const rows = await sql`
        select prefs, account_generation, activity, pending_start, start_attempts, last_start_attempt, work
        from glucos.relay where id = 1 for update`;
      if (!rows.length) throw new Error("glucos.relay has no row; run the migrations");
      const r = rows[0];
      const row = hydrate({
        prefs: r.prefs, accountGeneration: Number(r.account_generation), activity: r.activity ?? null,
        pendingStart: r.pending_start, startAttempts: r.start_attempts, lastStartAttempt: r.last_start_attempt ?? null,
        work: r.work,
      } as Partial<RelayRow> & Record<string, unknown>);

      const tx: Tx = {
        row,
        account: async () => {
          const v = await readSecret(sql as unknown as SQL, accountSecret);
          return v ? (JSON.parse(v) as Account) : null;
        },
        setAccount: (a) => writeSecret(sql as unknown as SQL, accountSecret, a ? JSON.stringify(a) : null),
        libreSession: async () => {
          const v = await readSecret(sql as unknown as SQL, sessionSecret);
          return v ? (JSON.parse(v) as LibreSession) : null;
        },
        setLibreSession: (s) => writeSecret(sql as unknown as SQL, sessionSecret, s ? JSON.stringify(s) : null),
        readings: async (since) => {
          const rs = await sql`
            select extract(epoch from at)::float8 as t, mgdl, trend from glucos.readings
            where at >= to_timestamp(${since}) order by at`;
          return rs.map((x) => ({ t: Number(x.t), mgdl: Number(x.mgdl), trend: Number(x.trend) as Trend }));
        },
        addReadings: async (incoming: Reading[]) => {
          if (!incoming.length) return;
          await sql`
            insert into glucos.readings (at, mgdl, trend)
            select to_timestamp(u.t), u.m, u.tr
            from unnest(${incoming.map((r) => r.t)}::float8[], ${incoming.map((r) => r.mgdl)}::float8[],
                        ${incoming.map((r) => r.trend)}::int2[]) as u(t, m, tr)
            on conflict (at) do update set mgdl = excluded.mgdl, trend = excluded.trend`;
        },
        clearReadings: async () => {
          await sql`delete from glucos.readings`;
        },
        pruneReadings: async (before) => {
          await sql`delete from glucos.readings where at < to_timestamp(${before})`;
        },
      };

      const result = await fn(tx);
      await sql`
        update glucos.relay set
          prefs = ${sql.json(row.prefs as never)},
          account_generation = ${row.accountGeneration},
          activity = ${row.activity ? sql.json(row.activity as never) : null},
          pending_start = ${row.pendingStart},
          start_attempts = ${row.startAttempts},
          last_start_attempt = ${row.lastStartAttempt},
          work = ${sql.json(row.work as never)},
          updated_at = now()
        where id = 1`;
      return result;
    }) as Promise<T>;
  }

  async claimTick(_now: number, seconds: number): Promise<boolean> {
    const rows = await this.sql`
      update glucos.relay set tick_lease_until = now() + make_interval(secs => ${seconds})
      where id = 1 and (tick_lease_until is null or tick_lease_until < now())
      returning id`;
    return rows.length > 0;
  }

  async releaseTick(): Promise<void> {
    await this.sql`update glucos.relay set tick_lease_until = null where id = 1`;
  }

  async cronToken(): Promise<string | null> {
    return await readSecret(this.sql, cronSecret);
  }

  /// The APNs provider token, kept between runs so it's refreshed at most every 50 minutes. Its
  /// own table and connection: pushes are sent while a transaction holds the relay row.
  tokenCache(): TokenCache {
    return {
      get: async () => {
        const rows = await this.sql`select token, issued_at from glucos.apns_token where id = 1`;
        return rows.length ? { token: rows[0].token as string, issuedAt: Number(rows[0].issued_at) } : null;
      },
      set: async (v) => {
        await this.sql`
          insert into glucos.apns_token (id, token, issued_at) values (1, ${v.token}, ${v.issuedAt})
          on conflict (id) do update set token = excluded.token, issued_at = excluded.issued_at`;
      },
    };
  }
}
