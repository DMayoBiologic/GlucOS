// Sharing live readings with followers: share links the owner makes (and can revoke, and that
// can expire), and the follower phones that have opened one. Used by the relay (the owner's
// endpoints, and fanning each new reading out to followers' Live Activities) and by the public
// `share` function (the web view and follower registration). See docs/Sharing.md.
//
// A share's token is the only thing that grants access, so it's 32 random bytes and only its
// SHA-256 is stored: the owner's phone keeps the link, the database can't give it back.

import postgres from "npm:postgres@3.4.5";
import type { CardState } from "./core.ts";
import { type CheckIn, type CheckInAnswer, checkInAnswerShownFor, checkInOpenFor, checkInPingGap, isCurrent, isOpen,
  type OwnerTarget } from "./checkins.ts";

type SQL = ReturnType<typeof postgres>;

/// At most this many live share links, and followers per link: GlucOS sharing is for family.
export const maxShares = 20;
export const maxFollowersPerShare = 10;
/// The longest a link can last before it has to be made again, if it has an expiry at all.
export const maxShareLifetime = 90 * 86_400;
export const labelLength = 40;

export interface Share {
  id: string;
  label: string;
  /// Seconds since 1970.
  createdAt: number;
  /// null: until revoked.
  expiresAt: number | null;
  lastViewedAt: number | null;
  followers: number;
}

export interface Follower {
  id: string;
  shareId: string;
  /// The share's label, shown on the follower's Lock Screen.
  label: string;
  /// The share is still live (not revoked, not expired).
  active: boolean;
  /// A random id per follower phone, so a phone that follows again replaces its old entry.
  installation: string;
  sandbox: boolean;
  liveActivityEnabled: boolean;
  pushToStartToken: string | null;
  activityId: string | null;
  activityToken: string | null;
  activityStartedAt: number | null;
  lastCard: CardState | null;
  lastPushedAt: number | null;
  pendingStart: boolean;
  startAttempts: number;
  lastStartAttempt: number | null;
  /// The phone's APNs device token, for the owner's alerts.
  deviceToken: string | null;
  /// Send this phone the owner's glucose alerts.
  alertsEnabled: boolean;
}

/// What a follower phone tells the share function. Every field but `installation` is optional:
/// missing means unchanged. Mirrors `FollowRegistration` in Sources/iOS/Sharing/ShareProtocol.swift.
export interface FollowRegistration {
  installation: string;
  apnsEnvironment?: string;
  pushToStartToken?: string;
  activityID?: string;
  activityToken?: string;
  endedActivityID?: string;
  liveActivityEnabled?: boolean;
  deviceToken?: string;
  alertsEnabled?: boolean;
}

export interface ShareStore {
  createShare(label: string, tokenHash: string, expiresAt: number | null): Promise<Share>;
  /// Live shares, newest first.
  listShares(now: number): Promise<Share[]>;
  /// Ends a share and forgets its followers, returning them so their Lock Screen cards can be
  /// ended. Null when there's no such live share.
  revokeShare(id: string, now: number): Promise<Follower[] | null>;
  /// The live share with this token hash, marked as just viewed.
  shareByToken(tokenHash: string, now: number): Promise<Share | null>;
  /// Null when the share already has as many followers as it may.
  registerFollower(shareId: string, r: FollowRegistration, now: number): Promise<Follower | null>;
  removeFollower(shareId: string, installation: string): Promise<Follower | null>;
  /// Every follower, live share or not, so the relay can end the cards of expired ones.
  followers(now: number): Promise<Follower[]>;
  /// The relay's side of a follower after a tick: only the columns the relay owns, only if the
  /// row still exists, and only if the phone hasn't registered new tokens since `seen` was read
  /// (then the next tick works from the new ones).
  saveFollower(f: Follower, seen: { activityToken: string | null; pushToStartToken: string | null }): Promise<void>;
  deleteFollowers(ids: string[]): Promise<void>;
  /// APNs said this device token is no longer valid: forget it, unless the phone has sent a new one.
  clearFollowerDeviceToken(id: string, token: string): Promise<void>;
  /// The relay's latest card, for the web view and for a follower starting its card.
  latestCard(): Promise<{ card: CardState; at: number } | null>;

  // Check-ins (checkins.ts)

  /// The follower this phone is, on this share.
  followerByInstallation(shareId: string, installation: string, now: number): Promise<Follower | null>;
  /// Opens a check-in for `f`, or asks again in its open one. `ping`: notify the owner (a new
  /// check-in, or the last notification was `checkInPingGap` ago).
  askCheckIn(f: Follower, name: string, now: number): Promise<{ checkIn: CheckIn; ping: boolean }>;
  /// Answers every open check-in, returning them with where to tell each follower.
  answerCheckIns(answer: CheckInAnswer, now: number): Promise<AnsweredCheckIn[]>;
  /// Each follower's latest check-in that's still current (`isCurrent`).
  checkIns(now: number): Promise<CheckIn[]>;
  /// The reminder went out for these.
  markReminded(ids: string[], now: number): Promise<void>;
  /// The owner's device token and latest card, from the relay row.
  ownerTarget(): Promise<OwnerTarget>;
}

export interface AnsweredCheckIn {
  checkIn: CheckIn;
  /// The follower phone's APNs token, if it gave one.
  deviceToken: string | null;
  sandbox: boolean;
  /// The share's label: the owner's name, as the follower sees it.
  label: string;
}

// MARK: - Tokens

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

export function newShareToken(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function hashShareToken(token: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`glucos:share:${token}`));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Plausible tokens only, so nonsense never reaches the database.
export const isShareToken = (t: string) => /^[A-Za-z0-9_-]{43}$/.test(t);

/// The link that goes in the message. The token is in the fragment, so it never reaches the web
/// server's logs (or Messages' link preview fetch, which drops the fragment).
export const shareViewerURL = "https://gluc-os-seven.vercel.app/share/";
export const shareURL = (token: string, base = shareViewerURL) => `${base}#${token}`;

export function cleanLabel(raw: unknown): string {
  const s = typeof raw === "string" ? raw.replace(/[\u0000-\u001f\u007f]/g, "").trim() : "";
  return [...s].slice(0, labelLength).join("") || "GlucOS";
}

// MARK: - Postgres

const epoch = (v: unknown) => (v === null || v === undefined ? null : Number(v));

function followerOf(r: Record<string, unknown>): Follower {
  return {
    id: String(r.id), shareId: String(r.share_id), label: String(r.label ?? ""), active: r.active === true,
    installation: String(r.installation), sandbox: r.sandbox === true, liveActivityEnabled: r.live_activity_enabled !== false,
    pushToStartToken: (r.push_to_start_token as string | null) ?? null,
    activityId: (r.activity_id as string | null) ?? null, activityToken: (r.activity_token as string | null) ?? null,
    activityStartedAt: epoch(r.activity_started_at), lastCard: (r.last_card as CardState | null) ?? null,
    lastPushedAt: epoch(r.last_pushed_at), pendingStart: r.pending_start === true,
    startAttempts: Number(r.start_attempts ?? 0), lastStartAttempt: epoch(r.last_start_attempt),
    deviceToken: (r.device_token as string | null) ?? null, alertsEnabled: r.alerts_enabled !== false,
  };
}

const shareOf = (r: Record<string, unknown>): Share => ({
  id: String(r.id), label: String(r.label), createdAt: Number(r.created_at), expiresAt: epoch(r.expires_at),
  lastViewedAt: epoch(r.last_viewed_at), followers: Number(r.followers ?? 0),
});

export class PostgresShareStore implements ShareStore {
  constructor(private readonly sql: SQL) {}

  async createShare(label: string, tokenHash: string, expiresAt: number | null): Promise<Share> {
    const rows = await this.sql`
      insert into glucos.shares (token_hash, label, expires_at)
      values (${tokenHash}, ${label}, ${expiresAt === null ? null : this.sql`to_timestamp(${expiresAt})`})
      returning id, label, extract(epoch from created_at)::float8 as created_at,
                extract(epoch from expires_at)::float8 as expires_at, null::float8 as last_viewed_at, 0 as followers`;
    return shareOf(rows[0]);
  }

  async listShares(now: number): Promise<Share[]> {
    const rows = await this.sql`
      select s.id, s.label, extract(epoch from s.created_at)::float8 as created_at,
             extract(epoch from s.expires_at)::float8 as expires_at,
             extract(epoch from s.last_viewed_at)::float8 as last_viewed_at,
             (select count(*) from glucos.followers f where f.share_id = s.id)::int as followers
      from glucos.shares s
      where s.revoked_at is null and (s.expires_at is null or s.expires_at > to_timestamp(${now}))
      order by s.created_at desc`;
    return rows.map(shareOf);
  }

  async revokeShare(id: string, now: number): Promise<Follower[] | null> {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    return await this.sql.begin(async (sql) => {
      const done = await sql`
        update glucos.shares set revoked_at = to_timestamp(${now})
        where id = ${id}::uuid and revoked_at is null returning id`;
      if (!done.length) return null;
      const rows = await sql`
        delete from glucos.followers f where f.share_id = ${id}::uuid
        returning f.*, '' as label, false as active`;
      return rows.map(followerOf);
    }) as Follower[] | null;
  }

  async shareByToken(tokenHash: string, now: number): Promise<Share | null> {
    const rows = await this.sql`
      update glucos.shares s set last_viewed_at = to_timestamp(${now})
      where s.token_hash = ${tokenHash} and s.revoked_at is null
        and (s.expires_at is null or s.expires_at > to_timestamp(${now}))
      returning s.id, s.label, extract(epoch from s.created_at)::float8 as created_at,
                extract(epoch from s.expires_at)::float8 as expires_at,
                extract(epoch from s.last_viewed_at)::float8 as last_viewed_at,
                (select count(*) from glucos.followers f where f.share_id = s.id)::int as followers`;
    return rows.length ? shareOf(rows[0]) : null;
  }

  async registerFollower(shareId: string, r: FollowRegistration, now: number): Promise<Follower | null> {
    return await this.sql.begin(async (sql) => {
      // Serialise registrations for one share, so the follower cap holds.
      await sql`select id from glucos.shares where id = ${shareId}::uuid for update`;
      const existing = await sql`
        select f.*, s.label, true as active
        from glucos.followers f join glucos.shares s on s.id = f.share_id
        where f.share_id = ${shareId}::uuid and f.installation = ${r.installation}`;
      let f: Follower;
      if (existing.length) {
        f = followerOf(existing[0]);
      } else {
        const count = await sql`select count(*)::int as n from glucos.followers where share_id = ${shareId}::uuid`;
        if (Number(count[0].n) >= maxFollowersPerShare) return null;
        f = {
          id: crypto.randomUUID(), shareId, label: "", active: true, installation: r.installation, sandbox: false,
          liveActivityEnabled: true, pushToStartToken: null, activityId: null, activityToken: null,
          activityStartedAt: null, lastCard: null, lastPushedAt: null, pendingStart: false, startAttempts: 0,
          lastStartAttempt: null, deviceToken: null, alertsEnabled: true,
        };
      }
      applyRegistration(f, r, now);
      await saveFollower(sql as unknown as SQL, f);
      return f;
    }) as Follower | null;
  }

  async removeFollower(shareId: string, installation: string): Promise<Follower | null> {
    const rows = await this.sql`
      delete from glucos.followers f where f.share_id = ${shareId}::uuid and f.installation = ${installation}
      returning f.*, '' as label, false as active`;
    return rows.length ? followerOf(rows[0]) : null;
  }

  async followers(now: number): Promise<Follower[]> {
    const rows = await this.sql`
      select f.*, s.label,
             (s.revoked_at is null and (s.expires_at is null or s.expires_at > to_timestamp(${now}))) as active
      from glucos.followers f join glucos.shares s on s.id = f.share_id`;
    return rows.map(followerOf);
  }

  async saveFollower(f: Follower, seen: { activityToken: string | null; pushToStartToken: string | null }): Promise<void> {
    await this.sql`
      update glucos.followers set
        activity_id = ${f.activityId}, activity_token = ${f.activityToken},
        activity_started_at = ${f.activityStartedAt}, push_to_start_token = ${f.pushToStartToken},
        last_card = ${f.lastCard ? this.sql.json(f.lastCard as never) : null}, last_pushed_at = ${f.lastPushedAt},
        pending_start = ${f.pendingStart}, start_attempts = ${f.startAttempts},
        last_start_attempt = ${f.lastStartAttempt}, updated_at = now()
      where id = ${f.id}::uuid
        and activity_token is not distinct from ${seen.activityToken}
        and push_to_start_token is not distinct from ${seen.pushToStartToken}`;
  }

  async deleteFollowers(ids: string[]): Promise<void> {
    if (!ids.length) return;
    await this.sql`delete from glucos.followers where id = any(${ids}::uuid[])`;
  }

  async clearFollowerDeviceToken(id: string, token: string): Promise<void> {
    await this.sql`
      update glucos.followers set device_token = null, updated_at = now()
      where id = ${id}::uuid and device_token = ${token}`;
  }

  async latestCard(): Promise<{ card: CardState; at: number } | null> {
    const rows = await this.sql`select work->'latestCard' as latest from glucos.relay where id = 1`;
    const v = rows[0]?.latest as { card?: CardState; at?: number } | null | undefined;
    return v?.card && typeof v.at === "number" ? { card: v.card, at: v.at } : null;
  }

  // MARK: Check-ins

  async followerByInstallation(shareId: string, installation: string, now: number): Promise<Follower | null> {
    const rows = await this.sql`
      select f.*, s.label,
             (s.revoked_at is null and (s.expires_at is null or s.expires_at > to_timestamp(${now}))) as active
      from glucos.followers f join glucos.shares s on s.id = f.share_id
      where f.share_id = ${shareId}::uuid and f.installation = ${installation}`;
    return rows.length ? followerOf(rows[0]) : null;
  }

  async askCheckIn(f: Follower, name: string, now: number): Promise<{ checkIn: CheckIn; ping: boolean }> {
    return await this.sql.begin(async (sql) => {
      // One open check-in per follower, however fast they tap.
      await sql`select id from glucos.followers where id = ${f.id}::uuid for update`;
      const open = await sql`
        select * from glucos.check_ins
        where follower_id = ${f.id}::uuid and answer is null and asked_at > ${now - checkInOpenFor}
        order by asked_at desc limit 1`;
      if (open.length) {
        const c = checkInOf(open[0]);
        const ping = now - c.lastAskedAt >= checkInPingGap;
        const rows = await sql`
          update glucos.check_ins set
            name = case when ${name} = '' then name else ${name} end,
            last_asked_at = case when ${ping} then ${now} else last_asked_at end
          where id = ${c.id}::uuid returning *`;
        return { checkIn: checkInOf(rows[0]), ping };
      }
      const rows = await sql`
        insert into glucos.check_ins (follower_id, share_id, name, asked_at, last_asked_at)
        values (${f.id}::uuid, ${f.shareId}::uuid, ${name}, ${now}, ${now}) returning *`;
      return { checkIn: checkInOf(rows[0]), ping: true };
    }) as { checkIn: CheckIn; ping: boolean };
  }

  async answerCheckIns(answer: CheckInAnswer, now: number): Promise<AnsweredCheckIn[]> {
    const rows = await this.sql`
      with done as (
        update glucos.check_ins set answer = ${answer}, answered_at = ${now}
        where answer is null and asked_at > ${now - checkInOpenFor}
        returning *
      )
      select done.*, f.device_token as follower_device_token, f.sandbox as follower_sandbox, s.label as share_label
      from done join glucos.followers f on f.id = done.follower_id join glucos.shares s on s.id = done.share_id`;
    return rows.map((r) => ({
      checkIn: checkInOf(r), deviceToken: (r.follower_device_token as string | null) ?? null,
      sandbox: r.follower_sandbox === true, label: String(r.share_label ?? ""),
    }));
  }

  async checkIns(now: number): Promise<CheckIn[]> {
    const keep = Math.max(checkInOpenFor, checkInAnswerShownFor);
    // Old ones are no use to anyone.
    await this.sql`delete from glucos.check_ins where asked_at < ${now - 7 * 86_400}`;
    const rows = await this.sql`
      select distinct on (follower_id) * from glucos.check_ins
      where asked_at > ${now - keep} or answered_at > ${now - checkInAnswerShownFor}
      order by follower_id, asked_at desc`;
    return rows.map(checkInOf).filter((c) => isCurrent(c, now));
  }

  async markReminded(ids: string[], now: number): Promise<void> {
    if (!ids.length) return;
    await this.sql`update glucos.check_ins set reminded_at = ${now} where id = any(${ids}::uuid[]) and reminded_at is null`;
  }

  async ownerTarget(): Promise<OwnerTarget> {
    const rows = await this.sql`
      select prefs->>'deviceToken' as token, coalesce((prefs->>'sandbox')::boolean, false) as sandbox,
             work->'latestCard'->'card' as card
      from glucos.relay where id = 1`;
    const r = rows[0];
    return {
      deviceToken: (r?.token as string | null) ?? null, sandbox: r?.sandbox === true,
      card: (r?.card as CardState | null) ?? null,
    };
  }
}

function checkInOf(r: Record<string, unknown>): CheckIn {
  return {
    id: String(r.id), followerId: String(r.follower_id), shareId: String(r.share_id), name: String(r.name ?? ""),
    askedAt: Number(r.asked_at), lastAskedAt: Number(r.last_asked_at), remindedAt: epoch(r.reminded_at),
    answer: r.answer === "okay" || r.answer === "help" ? r.answer : null, answeredAt: epoch(r.answered_at),
  };
}

async function saveFollower(sql: SQL, f: Follower) {
  await sql`
    insert into glucos.followers (id, share_id, installation, sandbox, live_activity_enabled, push_to_start_token,
      activity_id, activity_token, activity_started_at, last_card, last_pushed_at, pending_start, start_attempts,
      last_start_attempt, device_token, alerts_enabled, updated_at)
    values (${f.id}::uuid, ${f.shareId}::uuid, ${f.installation}, ${f.sandbox}, ${f.liveActivityEnabled},
      ${f.pushToStartToken}, ${f.activityId}, ${f.activityToken},
      ${f.activityStartedAt},
      ${f.lastCard ? sql.json(f.lastCard as never) : null}, ${f.lastPushedAt}, ${f.pendingStart}, ${f.startAttempts},
      ${f.lastStartAttempt}, ${f.deviceToken}, ${f.alertsEnabled}, now())
    on conflict (id) do update set
      sandbox = excluded.sandbox, live_activity_enabled = excluded.live_activity_enabled,
      push_to_start_token = excluded.push_to_start_token, activity_id = excluded.activity_id,
      activity_token = excluded.activity_token, activity_started_at = excluded.activity_started_at,
      last_card = excluded.last_card, last_pushed_at = excluded.last_pushed_at, pending_start = excluded.pending_start,
      start_attempts = excluded.start_attempts, last_start_attempt = excluded.last_start_attempt,
      device_token = excluded.device_token, alerts_enabled = excluded.alerts_enabled, updated_at = now()`;
}

/// A follower phone's registration, the same rules as the owner's in engine.ts `register`.
export function applyRegistration(f: Follower, r: FollowRegistration, now: number) {
  if (r.apnsEnvironment !== undefined) f.sandbox = r.apnsEnvironment === "sandbox";
  if (r.pushToStartToken) f.pushToStartToken = r.pushToStartToken;
  if (r.endedActivityID && f.activityId === r.endedActivityID) {
    f.activityId = null;
    f.activityToken = null;
    f.activityStartedAt = null;
    f.lastCard = null;
    f.pendingStart = false;
  }
  if (r.activityID && r.activityToken) {
    if (f.activityId !== r.activityID) {
      f.activityStartedAt = now;
      f.lastCard = null;
    }
    f.activityId = r.activityID;
    f.activityToken = r.activityToken;
    f.pendingStart = false;
    f.startAttempts = 0;
  }
  if (r.liveActivityEnabled !== undefined) f.liveActivityEnabled = r.liveActivityEnabled;
  if (r.deviceToken) f.deviceToken = r.deviceToken;
  if (r.alertsEnabled !== undefined) f.alertsEnabled = r.alertsEnabled;
}

// MARK: - In memory (tests)

export class MemoryShareStore implements ShareStore {
  shares: (Share & { tokenHash: string; revokedAt: number | null })[] = [];
  rows: Follower[] = [];
  latest: { card: CardState; at: number } | null = null;

  private live(s: { revokedAt: number | null; expiresAt: number | null }, now: number) {
    return s.revokedAt === null && (s.expiresAt === null || s.expiresAt > now);
  }
  private count(id: string) {
    return this.rows.filter((f) => f.shareId === id).length;
  }
  private view(s: Share): Share {
    return { id: s.id, label: s.label, createdAt: s.createdAt, expiresAt: s.expiresAt, lastViewedAt: s.lastViewedAt, followers: this.count(s.id) };
  }

  createShare(label: string, tokenHash: string, expiresAt: number | null) {
    const s = { id: crypto.randomUUID(), label, createdAt: Date.now() / 1000, expiresAt, lastViewedAt: null, followers: 0, tokenHash, revokedAt: null };
    this.shares.push(s);
    return Promise.resolve(this.view(s));
  }
  listShares(now: number) {
    return Promise.resolve(this.shares.filter((s) => this.live(s, now)).reverse().map((s) => this.view(s)));
  }
  revokeShare(id: string, now: number) {
    const s = this.shares.find((x) => x.id === id && x.revokedAt === null);
    if (!s) return Promise.resolve(null);
    s.revokedAt = now;
    const gone = this.rows.filter((f) => f.shareId === id);
    this.rows = this.rows.filter((f) => f.shareId !== id);
    return Promise.resolve(gone.map((f) => ({ ...f, active: false })));
  }
  shareByToken(tokenHash: string, now: number) {
    const s = this.shares.find((x) => x.tokenHash === tokenHash && this.live(x, now));
    if (!s) return Promise.resolve(null);
    s.lastViewedAt = now;
    return Promise.resolve(this.view(s));
  }
  registerFollower(shareId: string, r: FollowRegistration, now: number) {
    let f = this.rows.find((x) => x.shareId === shareId && x.installation === r.installation);
    if (!f) {
      if (this.count(shareId) >= maxFollowersPerShare) return Promise.resolve(null);
      f = {
        id: crypto.randomUUID(), shareId, label: "", active: true, installation: r.installation, sandbox: false,
        liveActivityEnabled: true, pushToStartToken: null, activityId: null, activityToken: null, activityStartedAt: null,
        lastCard: null, lastPushedAt: null, pendingStart: false, startAttempts: 0, lastStartAttempt: null,
        deviceToken: null, alertsEnabled: true,
      };
      this.rows.push(f);
    }
    applyRegistration(f, r, now);
    return Promise.resolve(structuredClone(f));
  }
  removeFollower(shareId: string, installation: string) {
    const f = this.rows.find((x) => x.shareId === shareId && x.installation === installation) ?? null;
    if (f) this.rows = this.rows.filter((x) => x !== f);
    return Promise.resolve(f);
  }
  followers(now: number) {
    return Promise.resolve(this.rows.map((f) => {
      const s = this.shares.find((x) => x.id === f.shareId);
      return { ...structuredClone(f), label: s?.label ?? "", active: !!s && this.live(s, now) };
    }));
  }
  saveFollower(f: Follower, seen: { activityToken: string | null; pushToStartToken: string | null }) {
    const i = this.rows.findIndex((x) => x.id === f.id);
    const row = this.rows[i];
    if (row && row.activityToken === seen.activityToken && row.pushToStartToken === seen.pushToStartToken) {
      // Like Postgres: the relay saves only its own columns.
      this.rows[i] = {
        ...structuredClone(f), liveActivityEnabled: row.liveActivityEnabled, sandbox: row.sandbox,
        deviceToken: row.deviceToken, alertsEnabled: row.alertsEnabled,
      };
    }
    return Promise.resolve();
  }
  deleteFollowers(ids: string[]) {
    this.rows = this.rows.filter((f) => !ids.includes(f.id));
    return Promise.resolve();
  }
  clearFollowerDeviceToken(id: string, token: string) {
    const f = this.rows.find((x) => x.id === id);
    if (f && f.deviceToken === token) f.deviceToken = null;
    return Promise.resolve();
  }
  latestCard() {
    return Promise.resolve(this.latest);
  }

  checkInRows: CheckIn[] = [];
  owner: OwnerTarget = { deviceToken: null, sandbox: false, card: null };

  followerByInstallation(shareId: string, installation: string, now: number) {
    return this.followers(now).then((all) => all.find((f) => f.shareId === shareId && f.installation === installation) ?? null);
  }
  askCheckIn(f: Follower, name: string, now: number) {
    const open = this.checkInRows.filter((c) => c.followerId === f.id && isOpen(c, now)).sort((a, b) => b.askedAt - a.askedAt)[0];
    if (open) {
      const ping = now - open.lastAskedAt >= checkInPingGap;
      if (name) open.name = name;
      if (ping) open.lastAskedAt = now;
      return Promise.resolve({ checkIn: structuredClone(open), ping });
    }
    const c: CheckIn = {
      id: crypto.randomUUID(), followerId: f.id, shareId: f.shareId, name, askedAt: now, lastAskedAt: now,
      remindedAt: null, answer: null, answeredAt: null,
    };
    this.checkInRows.push(c);
    return Promise.resolve({ checkIn: structuredClone(c), ping: true });
  }
  answerCheckIns(answer: CheckInAnswer, now: number) {
    const out: AnsweredCheckIn[] = [];
    for (const c of this.checkInRows.filter((x) => isOpen(x, now))) {
      c.answer = answer;
      c.answeredAt = now;
      const f = this.rows.find((x) => x.id === c.followerId);
      if (!f) continue;
      const s = this.shares.find((x) => x.id === c.shareId);
      out.push({ checkIn: structuredClone(c), deviceToken: f.deviceToken, sandbox: f.sandbox, label: s?.label ?? "" });
    }
    return Promise.resolve(out);
  }
  checkIns(now: number) {
    const latest = new Map<string, CheckIn>();
    for (const c of this.checkInRows) {
      if (!this.rows.some((f) => f.id === c.followerId)) continue;
      const seen = latest.get(c.followerId);
      if (!seen || c.askedAt > seen.askedAt) latest.set(c.followerId, c);
    }
    return Promise.resolve([...latest.values()].filter((c) => isCurrent(c, now)).map((c) => structuredClone(c)));
  }
  markReminded(ids: string[], now: number) {
    for (const c of this.checkInRows) if (ids.includes(c.id) && c.remindedAt === null) c.remindedAt = now;
    return Promise.resolve();
  }
  ownerTarget() {
    return Promise.resolve(structuredClone(this.owner));
  }
}
