// The follower view's data (GET /v1/detail): everything a follower's app needs to show the
// owner's screen rather than just their Lock Screen card. Readings for the chart and time in
// range, and the owner's recent logbook for the chart markers, what's on board and the logbook
// list. See docs/Sharing.md "What followers see".
//
// Readings come from `glucos.readings` (the relay's 90 days), in 5-minute buckets. The app asks
// for what's new since the last bucket it has, so after the first load a request is a few rows.
//
// The logbook belongs to the owner's Supabase user: the one the relay's forecast ledger found from
// its LibreLinkUp login (`work.forecastLog.owner`, ledger.ts). Notes are blanked and the bolus
// calculator's working is left out: followers see what was taken and eaten, not what was written.

import type postgres from "npm:postgres@3.4.5";

type SQL = ReturnType<typeof postgres>;

/// How far back a follower can see readings.
export const detailReadingDays = 14;
/// How far back a follower sees the logbook: long enough for long-acting insulin's on-board tail.
export const detailLogbookHours = 48;
export const readingBucket = 5 * 60;
/// The logbook kinds a follower sees. Saved insulins, foods, presets and calculator settings stay private.
export const sharedLogKinds = ["dose", "meal", "siteChange", "context"];
export const maxLogEntries = 300;

/// One logbook entry as the apps sync it (`LogbookRecord` in Sources/App/Logbook/LogbookSync.swift).
export interface SharedLogEntry {
  id: string;
  kind: string;
  payload: Record<string, unknown>;
  deleted: false;
  modified: number;
}

export interface ShareDetail {
  /// [seconds since 1970, mg/dL] in 5-minute buckets after `since`, oldest first: each bucket's
  /// newest time and its average. The last bucket can be partial; asking again from its start
  /// replaces it.
  readings: [number, number][];
  /// The owner lets this link's followers see the logbook.
  showsLogbook: boolean;
  /// The last `detailLogbookHours` of shared entries, newest first. Null when hidden, or when the
  /// owner's apps have never signed in to logbook sync.
  logbook: SharedLogEntry[] | null;
  /// When this was made, seconds since 1970.
  generatedAt: number;
}

export interface DetailSource {
  readings(since: number): Promise<[number, number][]>;
  logbook(since: number): Promise<SharedLogEntry[] | null>;
}

/// `since` from the query: missing or nonsense means the whole window; never before it.
export function clampSince(raw: string | null, now: number): number {
  const earliest = now - detailReadingDays * 86_400;
  const v = raw === null ? NaN : Number(raw);
  if (!Number.isFinite(v)) return earliest;
  return Math.min(Math.max(v, earliest), now);
}

export async function shareDetail(source: DetailSource, showsLogbook: boolean, since: number, now: number): Promise<ShareDetail> {
  const [readings, logbook] = await Promise.all([
    source.readings(since),
    showsLogbook ? source.logbook(now - detailLogbookHours * 3600) : Promise.resolve(null),
  ]);
  return { readings, showsLogbook, logbook, generatedAt: now };
}

/// A synced payload as a follower may see it: no note, no calculator working.
export function followerPayload(p: Record<string, unknown>): Record<string, unknown> {
  const out = { ...p };
  // Blanked rather than removed: the apps' decoders expect the key.
  if ("note" in out) out.note = "";
  delete out.calculation;
  return out;
}

export class PostgresDetailSource implements DetailSource {
  constructor(private readonly sql: SQL) {}

  async readings(since: number): Promise<[number, number][]> {
    const rows = await this.sql`
      select floor(extract(epoch from at) / ${readingBucket}) as bucket,
             extract(epoch from max(at))::float8 as t, avg(mgdl)::float8 as mgdl
      from glucos.readings
      where at >= to_timestamp(${since})
      group by 1
      order by 1`;
    return rows.map((r) => [Math.round(Number(r.t)), Math.round(Number(r.mgdl))]);
  }

  async logbook(since: number): Promise<SharedLogEntry[] | null> {
    const owner = await this.sql`select work->'forecastLog'->>'owner' as owner from glucos.relay where id = 1`;
    const user = owner[0]?.owner as string | null | undefined;
    if (!user || !/^[0-9a-f-]{36}$/i.test(user)) return null;
    const rows = await this.sql`
      select id::text, kind, payload, extract(epoch from modified_at)::float8 as modified,
             case when jsonb_typeof(payload -> 'timestamp') = 'number' then (payload ->> 'timestamp')::float8 end as at
      from glucos.logbook
      where user_id = ${user}::uuid and not deleted and payload is not null and kind = any(${sharedLogKinds})
        and case when jsonb_typeof(payload -> 'timestamp') = 'number' then (payload ->> 'timestamp')::float8 end >= ${since}
      order by at desc
      limit ${maxLogEntries}`;
    return rows.map((r) => ({
      id: String(r.id), kind: String(r.kind), payload: followerPayload(r.payload as Record<string, unknown>),
      deleted: false, modified: Number(r.modified),
    }));
  }
}

/// For tests.
export class MemoryDetailSource implements DetailSource {
  points: [number, number][] = [];
  entries: SharedLogEntry[] | null = [];

  readings(since: number) {
    const buckets = new Map<number, { t: number; sum: number; n: number }>();
    for (const [t, v] of this.points) {
      if (t < since) continue;
      const k = Math.floor(t / readingBucket);
      const b = buckets.get(k) ?? { t, sum: 0, n: 0 };
      b.t = Math.max(b.t, t);
      b.sum += v;
      b.n += 1;
      buckets.set(k, b);
    }
    return Promise.resolve([...buckets.entries()].sort((a, b) => a[0] - b[0])
      .map(([, b]) => [Math.round(b.t), Math.round(b.sum / b.n)] as [number, number]));
  }

  logbook(since: number) {
    if (this.entries === null) return Promise.resolve(null);
    return Promise.resolve(this.entries
      .filter((e) => typeof e.payload.timestamp === "number" && (e.payload.timestamp as number) >= since)
      .sort((a, b) => (b.payload.timestamp as number) - (a.payload.timestamp as number))
      .map((e) => ({ ...e, payload: followerPayload(e.payload) })));
  }
}
