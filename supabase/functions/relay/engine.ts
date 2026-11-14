// The relay's work, ported from the Swift relay (formerly Relay/Sources/RelayKit/RelayEngine.swift):
// on every tick fetch from LibreLinkUp, alert first, then update the Lock Screen card; between
// ticks, take registrations from the phone. State lives in Postgres (see store.ts), because the
// edge function starts fresh every minute.

import {
  type AlertKind, type AlertNotice, type AlertPreferences, type Calibration, type CardState, cardRange, cardStaleDate, defaultAlertPreferences,
  type Display, formatGlucose, learnCalibration, noticeIdentifier, newPlanner, type PlannerState, processTick, type Reading, sameCard,
  type Sensor, unitOf,
} from "./core.ts";
import { payloads, type PushRequest, type PushResult, type PushSender } from "./apns.ts";
import {
  type CheckIn, type CheckInAnswer, type CheckInCard, checkInOpenFor, checkInPayloads, checkInRemindAfter,
  followerCheckInCard, isOpen, ownerCheckInCard, sameCheckIn, withCheckIn,
} from "./checkins.ts";
import type { Account, GlucoseFetcher, LibreSession } from "./libre.ts";
import {
  cleanLabel, type Follower, hashShareToken, maxShareLifetime, maxShares, newShareToken, type Share, type ShareStore,
  shareURL,
} from "./sharing.ts";

export const version = "2.2.0";
/// iOS ends a Live Activity after 8 hours. The relay ends it a little before and starts the next
/// one, so the Lock Screen card never just disappears.
export const rotateAfter = 7 * 3600 + 40 * 60;
/// Resend the card at least this often, even when nothing changed, so a missed push heals.
export const activityRefresh = 10 * 60;
/// Priority-10 (send now) Live Activity pushes for a visible change are spaced at least this far
/// apart while in range, and one goes out at least this often, so a card is never more than a few
/// minutes behind. See `cardPriority` and docs/Redesign.md §6.4.
export const urgentPushGap = 2 * 60;
export const urgentPushEvery = 3 * 60;
export const startRetry = 15 * 60;
export const maxStartAttempts = 3;
/// How many ended or replaced activity ids the relay remembers.
export const retiredActivityMemory = 16;
/// How often the forecast's accuracy is relearnt, and from how much history.
export const relearnEvery = 3 * 3600;
export const learnFromDays = 14;
/// Readings kept in the database.
export const readingRetentionDays = 90;
/// Follower pushes sent at once.
export const followerConcurrency = 10;
/// How long one tick spends on followers before leaving the rest to the next tick, well inside the
/// relay row's 50 s lease. A skipped follower's card is a minute late, never lost.
export const followerBudgetMs = 25_000;

/// The order a tick works through followers when it might run out of time: by id, starting from
/// the first one the last short tick didn't reach (`cursor`), wrapping round. However the ticks go
/// (some short, some skipped, followers coming and going), everyone gets a turn.
export function followerOrder<F extends { id: string }>(all: F[], cursor: string | null | undefined): F[] {
  const sorted = [...all].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const start = cursor == null ? 0 : sorted.findIndex((f) => f.id >= cursor);
  return start <= 0 ? sorted : [...sorted.slice(start), ...sorted.slice(0, start)];
}

/// The APNs priority for this tick's Live Activity updates (docs/Redesign.md §6.4). Priority 5 lets
/// iOS hold an update back to save power, which left in-range cards minutes behind, so:
/// - 10 when an alert fired, the range changed, or the reading is out of range;
/// - 10 when what the card shows (value or trend) changed and the last 10 was `urgentPushGap` ago;
/// - 10 when the last 10 was `urgentPushEvery` ago, so a card never drifts towards its stale date;
/// - otherwise 5 (only the history changed, or a visible change came hard on the heels of a 10).
/// `previous` is the card of the tick before, `urgentAt` when the last priority-10 tick was.
export function cardPriority(card: CardState, previous: CardState | null, urgentAt: number | null,
                             alerted: boolean, now: number): 5 | 10 {
  if (alerted || !previous || urgentAt === null) return 10;
  if (cardRange(card) !== "inRange" || cardRange(previous) !== cardRange(card)) return 10;
  const since = now - urgentAt;
  if (since >= urgentPushEvery) return 10;
  const unit = unitOf(card.unit);
  const visible = previous.trend !== card.trend || previous.unit !== card.unit ||
    formatGlucose(unit, previous.mgdl) !== formatGlucose(unit, card.mgdl);
  return visible && since >= urgentPushGap ? 10 : 5;
}

/// The owner's alerts that also go to followers who want them: about the glucose itself, not
/// the owner's sensor or account.
export const followerAlertKinds: ReadonlySet<AlertKind> = new Set<AlertKind>([
  "urgentLow", "low", "high", "veryHigh", "rapidChange", "stale",
  "predictedUrgentLow", "predictedLow", "predictedHigh", "predictedVeryHigh",
]);

/// Claiming the relay's secret with the LibreLinkUp login it fetches with: this many wrong tries
/// in this window and claims are refused until it passes.
export const claimLimit = 5;
export const claimWindow = 15 * 60;

// MARK: - State

export interface RelayPrefs {
  deviceToken?: string;
  pushToStartToken?: string;
  sandbox: boolean;
  liveActivityEnabled: boolean;
  display: Display;
  alerts: AlertPreferences;
}

export interface ActivityRecord {
  id: string;
  /// Update token (hex) for this activity.
  token: string;
  startedAt: number;
}

/// What the tick works out and keeps.
export interface Work {
  planner: PlannerState;
  calibration: Calibration | null;
  learnedAt: number;
  current: Reading | null;
  sensor: Sensor | null;
  lastFetchAt: number | null;
  lastError: string | null;
  lastPushAt: number | null;
  lastPushError: string | null;
  /// The last card delivered to `activityId`, so unchanged cards aren't resent.
  lastCard: { activityId: string; card: CardState; pushedAt: number } | null;
  /// The newest card, whether or not the owner has a Live Activity: what followers see.
  latestCard: { card: CardState; at: number } | null;
  /// When a tick last sent its Live Activity updates at priority 10 (`cardPriority`). Missing on
  /// old rows.
  urgentCardAt?: number | null;
  /// The first follower the last tick ran out of time for (`followerOrder`). Missing on old rows.
  followerCursor?: string | null;
  /// Wrong claims (`claim`) since `since`. Missing on old rows.
  claimFailures?: { count: number; since: number } | null;
  /// Activities the relay has ended or replaced, newest last. A late registration from one of
  /// them (its token upload was stuck behind a timeout) mustn't bring it back as a second card.
  /// Missing on old rows.
  retiredActivities?: string[];
}

export interface RelayRow {
  prefs: RelayPrefs;
  /// Bumped whenever the account changes, so a fetch that was in flight across the change is
  /// thrown away instead of restoring the old account's readings.
  accountGeneration: number;
  activity: ActivityRecord | null;
  /// The relay ended an activity at iOS's 8-hour limit and is starting the next one.
  pendingStart: boolean;
  startAttempts: number;
  lastStartAttempt: number | null;
  work: Work;
}

export const newRow = (): RelayRow => ({
  prefs: {
    sandbox: false, liveActivityEnabled: true,
    display: { unit: "mmol", lowMgdl: 70, highMgdl: 180 }, alerts: defaultAlertPreferences(),
  },
  accountGeneration: 0, activity: null, pendingStart: false, startAttempts: 0, lastStartAttempt: null,
  work: {
    planner: newPlanner(), calibration: null, learnedAt: 0, current: null, sensor: null, lastFetchAt: null,
    lastError: null, lastPushAt: null, lastPushError: null, lastCard: null,
    latestCard: null,
  },
});

/// One locked read-modify-write of the relay's state. `row` is saved when the callback returns.
export interface Tx {
  row: RelayRow;
  account(): Promise<Account | null>;
  setAccount(a: Account | null): Promise<void>;
  libreSession(): Promise<LibreSession | null>;
  setLibreSession(s: LibreSession | null): Promise<void>;
  readings(since: number): Promise<Reading[]>;
  addReadings(rs: Reading[]): Promise<void>;
  clearReadings(): Promise<void>;
  pruneReadings(before: number): Promise<void>;
  /// Whether this tick's lease is still the current one (no later tick has claimed the relay).
  ownsLease(lease: string): Promise<boolean>;
}

export interface Store {
  /// `readOnly` neither locks the relay row nor writes it back: a status read mustn't wait behind
  /// a tick that holds the row while it sends pushes.
  transaction<T>(fn: (tx: Tx) => Promise<T>, options?: { readOnly?: boolean }): Promise<T>;
  /// Only one tick at a time: false while another holds the lease.
  /// A token for the lease, or null when another tick holds it.
  claimTick(now: number, seconds: number): Promise<string | null>;
  /// Ends this lease only, so a tick that overran can't end the next tick's.
  releaseTick(lease: string): Promise<void>;
}

// MARK: - Protocol (Sources/Core/RelayProtocol.swift)

export interface RelayRegistration {
  deviceToken?: string;
  pushToStartToken?: string;
  activityToken?: string;
  activityID?: string;
  endedActivityID?: string;
  liveActivityEnabled?: boolean;
  apnsEnvironment?: string;
  account?: Account;
  signedOut?: boolean;
  display?: Display;
  alerts?: AlertPreferences;
}

export interface RelayStatus {
  version: string;
  lastFetchAt?: number;
  lastReadingAt?: number;
  lastError?: string;
  lastPushAt?: number;
  lastPushError?: string;
  hasAccount: boolean;
  hasDeviceToken: boolean;
  hasPushToStartToken: boolean;
  activityID?: string;
  activityStartedAt?: number;
  liveActivityEnabled: boolean;
  alertsEnabled: boolean;
  /// Followers waiting for the owner to answer a check-in (checkins.ts). Missing when nobody is.
  checkIn?: CheckInCard;
}

// MARK: - Engine

export interface EngineConfig {
  bundleId: string;
  criticalAlerts: boolean;
  /// Share links and followers. Without it the relay serves only the owner.
  shares?: ShareStore;
  /// Overrides `followerBudgetMs` (tests).
  followerBudgetMs?: number;
}

export interface CreateShareRequest {
  label?: string;
  /// Seconds from now; null or missing: until revoked.
  expiresIn?: number | null;
}

export interface CreatedShare {
  share: Share;
  /// Given out once: only its hash is kept.
  token: string;
  url: string;
}

export class ShareError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export class RelayEngine {
  constructor(
    private readonly store: Store,
    private readonly sender: PushSender | null,
    private readonly fetcher: GlucoseFetcher,
    private readonly config: EngineConfig,
    private readonly clock: () => number = () => Date.now() / 1000,
  ) {}

  // MARK: API

  async register(r: RelayRegistration): Promise<RelayStatus> {
    return await this.attachCheckIn(await this.store.transaction(async (tx) => {
      const now = this.clock();
      const row = tx.row;
      if (r.deviceToken) row.prefs.deviceToken = r.deviceToken;
      if (r.pushToStartToken) row.prefs.pushToStartToken = r.pushToStartToken;
      if (r.apnsEnvironment !== undefined) row.prefs.sandbox = r.apnsEnvironment === "sandbox";
      if (r.display) row.prefs.display = r.display;
      if (r.alerts) row.prefs.alerts = { ...defaultAlertPreferences(), ...r.alerts };

      if (r.signedOut === true) {
        row.accountGeneration += 1;
        await tx.setAccount(null);
        await tx.setLibreSession(null);
        await tx.clearReadings();
        row.work.current = null;
        row.work.sensor = null;
        // Share links mustn't keep showing a signed-out account's reading.
        row.work.latestCard = null;
        row.work.lastError = null;
        await this.endActivity(row, now);
      } else if (r.account) {
        const old = await tx.account();
        if (old?.email.toLowerCase() !== r.account.email.toLowerCase()) {
          // Another person's readings: start again.
          await tx.clearReadings();
          row.work.current = null;
          row.work.sensor = null;
          row.work.latestCard = null;
          row.work.planner = newPlanner();
          row.work.calibration = null;
          row.work.learnedAt = 0;
        }
        if (JSON.stringify(old) !== JSON.stringify(normaliseAccount(r.account))) {
          row.accountGeneration += 1;
          await tx.setAccount(normaliseAccount(r.account));
        }
      }

      // An ended card's token is never adopted again, whether or not the relay was updating it.
      if (r.endedActivityID) this.retire(row, r.endedActivityID);
      if (r.endedActivityID && row.activity?.id === r.endedActivityID) {
        // The phone ended it, or it was swiped away. Don't put it back until the phone starts another.
        row.activity = null;
        row.pendingStart = false;
      }
      if (r.activityID && r.activityToken && !(row.work.retiredActivities ?? []).includes(r.activityID)) {
        // Another activity. Arrival order doesn't say which card the phone kept (a stale upload
        // can land after the current one), so nothing is retired here: the phone ends the card it
        // doesn't keep, that end retires it, and the same request names the card it kept.
        const startedAt = row.activity?.id === r.activityID ? row.activity.startedAt : now;
        row.activity = { id: r.activityID, token: r.activityToken, startedAt };
        row.pendingStart = false;
        row.startAttempts = 0;
      }
      if (r.liveActivityEnabled !== undefined) {
        row.prefs.liveActivityEnabled = r.liveActivityEnabled;
        if (!r.liveActivityEnabled) await this.endActivity(row, now);
      }
      return this.statusOf(row, (await tx.account()) !== null);
    }));
  }

  /// A phone signed in to the same LibreLinkUp account the relay fetches with is the owner's, so
  /// it may have the relay secret: the app no longer carries it, because anyone can install it.
  /// Wrong tries are limited, so this can't be used to guess the password.
  claim(email: unknown, password: unknown): Promise<"ok" | "denied" | "locked" | "no account"> {
    return this.store.transaction(async (tx) => {
      const now = this.clock();
      const w = tx.row.work;
      let f = w.claimFailures ?? null;
      if (f && now - f.since >= claimWindow) f = null;
      if (f && f.count >= claimLimit) {
        w.claimFailures = f;
        return "locked";
      }
      const account = await tx.account();
      if (!account) return "no account";
      const ok = typeof email === "string" && typeof password === "string"
        && email.trim().toLowerCase() === account.email.trim().toLowerCase()
        && constantTimeEqual(password, account.password);
      if (ok) {
        w.claimFailures = null;
        return "ok";
      }
      w.claimFailures = { count: (f?.count ?? 0) + 1, since: f?.since ?? now };
      return "denied";
    });
  }

  async status(): Promise<RelayStatus> {
    return await this.attachCheckIn(
      await this.store.transaction(async (tx) => this.statusOf(tx.row, (await tx.account()) !== null),
        { readOnly: true }),
    );
  }

  // MARK: Check-ins

  /// The check-ins still current, or none when sharing isn't set up (or can't be read: a check-in
  /// must never break the owner's own tick).
  private async currentCheckIns(now: number): Promise<CheckIn[]> {
    if (!this.config.shares) return [];
    try {
      return await this.config.shares.checkIns(now);
    } catch (e) {
      console.error("checkIns", e);
      return [];
    }
  }

  private async attachCheckIn(s: RelayStatus): Promise<RelayStatus> {
    const now = this.clock();
    const c = ownerCheckInCard(await this.currentCheckIns(now), now);
    if (c) s.checkIn = c;
    return s;
  }

  /// The owner answers (from the notification, their Lock Screen card or the app): every follower
  /// waiting hears back straight away, and their cards change on the next tick.
  async answerCheckIns(answer: CheckInAnswer): Promise<RelayStatus> {
    const now = this.clock();
    const shares = this.shares;
    const answered = await shares.answerCheckIns(answer, now);
    if (this.sender) {
      for (const a of answered) {
        if (!a.deviceToken) continue;
        const result = await this.sender.send({
          deviceToken: a.deviceToken, type: "alert", topic: this.config.bundleId, priority: 10,
          payload: checkInPayloads.answer(a.label, a.checkIn.shareId, answer, this.config.criticalAlerts),
          collapseId: `glucos.checkin.${a.checkIn.shareId}`.slice(0, 64), expiration: now + checkInOpenFor,
          sandbox: a.sandbox,
        });
        if (result.kind === "tokenInvalid") await shares.clearFollowerDeviceToken(a.checkIn.followerId, a.deviceToken);
      }
    }
    return await this.status();
  }

  sendTest(): Promise<RelayStatus> {
    return this.store.transaction(async (tx) => {
      const row = tx.row;
      if (row.prefs.deviceToken) {
        await this.push(row, {
          deviceToken: row.prefs.deviceToken, type: "alert", topic: this.config.bundleId, priority: 10,
          payload: payloads.test(), collapseId: "glucos.test", expiration: this.clock() + 600, sandbox: row.prefs.sandbox,
        }, (r) => { delete r.prefs.deviceToken; });
      } else {
        row.work.lastPushError = "The phone hasn't registered for notifications yet";
      }
      return this.statusOf(row, (await tx.account()) !== null);
    });
  }

  private statusOf(row: RelayRow, hasAccount: boolean): RelayStatus {
    const w = row.work;
    const s: RelayStatus = {
      version,
      hasAccount,
      hasDeviceToken: !!row.prefs.deviceToken && this.sender !== null,
      hasPushToStartToken: !!row.prefs.pushToStartToken,
      liveActivityEnabled: row.prefs.liveActivityEnabled,
      alertsEnabled: row.prefs.alerts.enabled,
    };
    if (w.lastFetchAt !== null) s.lastFetchAt = w.lastFetchAt;
    if (w.current) s.lastReadingAt = w.current.t;
    if (w.lastError !== null) s.lastError = w.lastError;
    if (w.lastPushAt !== null) s.lastPushAt = w.lastPushAt;
    const pushError = this.sender === null ? "APNs key not configured on the relay" : w.lastPushError;
    if (pushError) s.lastPushError = pushError;
    if (row.activity) {
      s.activityID = row.activity.id;
      s.activityStartedAt = row.activity.startedAt;
    }
    return s;
  }

  // MARK: Tick

  async tick(): Promise<"done" | "busy" | "no account" | "account changed" | "superseded"> {
    const started = this.clock();
    const lease = await this.store.claimTick(started, 50);
    if (lease === null) return "busy";
    try {
      // Read what's needed for the fetch, then let go of the row while LibreLinkUp answers.
      const before = await this.store.transaction(async (tx) => ({
        account: await tx.account(), session: await tx.libreSession(), generation: tx.row.accountGeneration,
      }));
      if (!before.account) return "no account";
      let fetched: Awaited<ReturnType<GlucoseFetcher["fetch"]>> | null = null;
      let error: string | null = null;
      try {
        fetched = await this.fetcher.fetch(before.account, before.session);
      } catch (e) {
        error = e instanceof Error ? e.message : String(e);
      }

      return await this.store.transaction(async (tx) => {
        const row = tx.row;
        if (row.accountGeneration !== before.generation) return "account changed";
        // Overran its lease and a later tick took over: its reading and pushes would be stale.
        if (!(await tx.ownsLease(lease))) return "superseded";
        const now = this.clock();
        const w = row.work;
        if (fetched) {
          if (fetched.session !== before.session) await tx.setLibreSession(fetched.session);
          const incoming = [...fetched.result.history];
          if (fetched.result.current) incoming.push(fetched.result.current);
          await tx.addReadings(incoming);
          if (fetched.result.current) w.current = fetched.result.current;
          if (fetched.result.sensor) w.sensor = fetched.result.sensor;
          w.lastError = null;
        } else {
          w.lastError = error;
        }
        w.lastFetchAt = now;

        const stored = await tx.readings(now - 13 * 3600);
        if (now - w.learnedAt > relearnEvery) {
          const history = await tx.readings(now - learnFromDays * 86_400);
          if (history.length > 24) {
            w.calibration = learnCalibration(history, now);
            w.learnedAt = now;
          }
          await tx.pruneReadings(now - readingRetentionDays * 86_400);
        }

        const result = processTick({
          stored, current: w.current, sensor: w.sensor, lastError: w.lastError, display: row.prefs.display,
          prefs: row.prefs.alerts, planner: w.planner, calibration: w.calibration, now,
        });

        const token = row.prefs.deviceToken;
        if (token) {
          for (const n of result.notices) {
            await this.push(row, {
              deviceToken: token, type: "alert", topic: this.config.bundleId, priority: 10,
              payload: payloads.alert(n, this.config.criticalAlerts), collapseId: noticeIdentifier(n),
              expiration: now + 15 * 60, sandbox: row.prefs.sandbox,
            }, (r) => { delete r.prefs.deviceToken; });
          }
        }
        // One priority for every card this tick (owner's and followers'), from how the card
        // changed since the last tick.
        const priority = result.card
          ? cardPriority(result.card, w.latestCard?.card ?? null, w.urgentCardAt ?? null, result.notices.length > 0, now)
          : 5;
        if (priority === 10) w.urgentCardAt = now;
        // Check-ins: the owner's card shows who's waiting, each follower's card their own; and
        // after `checkInRemindAfter` without an answer both sides hear about it once.
        const checkIns = await this.currentCheckIns(now);
        const due = checkIns.filter((c) => isOpen(c, now) && c.remindedAt === null && now - c.askedAt >= checkInRemindAfter);
        if (due.length && token) {
          const waiting = checkIns.filter((c) => isOpen(c, now));
          await this.push(row, {
            deviceToken: token, type: "alert", topic: this.config.bundleId, priority: 10,
            payload: checkInPayloads.ask(due.find((c) => c.name)?.name ?? "", waiting.length, result.card, true,
              this.config.criticalAlerts),
            collapseId: "glucos.checkin", expiration: now + checkInOpenFor, sandbox: row.prefs.sandbox,
          }, (r) => { delete r.prefs.deviceToken; });
        }
        const ownerCard = result.card ? withCheckIn(result.card, ownerCheckInCard(checkIns, now)) : null;
        await this.updateActivity(row, ownerCard, result.notices.length > 0, priority, now);
        if (result.card) w.latestCard = { card: result.card, at: now };
        await this.updateFollowers(w, result.card, result.notices, priority, now, checkIns, due);
        if (due.length) {
          try {
            await this.config.shares?.markReminded(due.map((c) => c.id), now);
          } catch (e) {
            console.error("markReminded", e);
          }
        }
        return "done";
      });
    } finally {
      await this.store.releaseTick(lease);
    }
  }

  // MARK: Live Activity

  private async updateActivity(row: RelayRow, card: CardState | null, urgent: boolean, tickPriority: 5 | 10,
                               now: number) {
    if (!row.prefs.liveActivityEnabled || !card) return;
    const a = row.activity;
    if (a) {
      if (now - a.startedAt >= rotateAfter && row.prefs.pushToStartToken) {
        await this.endActivity(row, now);
        row.pendingStart = true;
        row.startAttempts = 0;
        row.lastStartAttempt = null;
      } else {
        const last = row.work.lastCard?.activityId === a.id ? row.work.lastCard : null;
        const changed = !sameCard(card, last?.card);
        const due = last ? now - last.pushedAt >= activityRefresh : true;
        if (!changed && !due) return;
        const rangeChanged = last ? cardRange(last.card) !== cardRange(card) : true;
        const checkInChanged = !sameCheckIn(last?.card.checkIn, card.checkIn);
        // This card's own history counts too: it may have missed the push where the range changed.
        const priority = tickPriority === 10 || urgent || rangeChanged || checkInChanged ||
            cardRange(card) !== "inRange" ? 10 : 5;
        const result = await this.push(row, {
          deviceToken: a.token, type: "liveactivity", topic: this.config.bundleId, priority,
          payload: payloads.activity("update", card, now), expiration: cardStaleDate(card), sandbox: row.prefs.sandbox,
        }, (r) => { if (r.activity?.id === a.id) r.activity = null; });
        if (result.kind === "delivered") row.work.lastCard = { activityId: a.id, card, pushedAt: now };
        return;
      }
    }

    const p2s = row.prefs.pushToStartToken;
    if (!row.pendingStart || !p2s || row.startAttempts >= maxStartAttempts) return;
    if (row.lastStartAttempt !== null && now - row.lastStartAttempt < startRetry) return;
    row.startAttempts += 1;
    row.lastStartAttempt = now;
    // The new activity's own update token reaches the phone, which registers it here.
    const result = await this.push(row, {
      deviceToken: p2s, type: "liveactivity", topic: this.config.bundleId, priority: 10,
      payload: payloads.activity("start", card, now), expiration: now + 600, sandbox: row.prefs.sandbox,
    }, (r) => { delete r.prefs.pushToStartToken; });
    // APNs accepted it, which doesn't prove the phone started the card, but starting again because
    // its registration is slow put a second card on the Lock Screen. So a delivered start isn't
    // retried: the card's registration (sent with every app sync) re-arms everything, and if no
    // card ever appears the app starts one the next time it's opened.
    if (result.kind === "delivered") row.pendingStart = false;
  }

  private async endActivity(row: RelayRow, now: number) {
    const a = row.activity;
    if (!a) return;
    row.activity = null;
    row.work.lastCard = null;
    const result = await this.push(row, {
      deviceToken: a.token, type: "liveactivity", topic: this.config.bundleId, priority: 10,
      payload: payloads.activity("end", null, now), sandbox: row.prefs.sandbox,
    }, () => {});
    // Only a card that's really gone is retired. If the end didn't go through it's still on the
    // Lock Screen, and the phone may keep it and register it again.
    if (result.kind !== "failed") this.retire(row, a.id);
  }

  private retire(row: RelayRow, id: string) {
    row.work.retiredActivities = [...(row.work.retiredActivities ?? []).filter((x) => x !== id), id]
      .slice(-retiredActivityMemory);
  }

  // MARK: Sharing

  private get shares(): ShareStore {
    if (!this.config.shares) throw new ShareError("Sharing isn't set up on this relay", 503);
    return this.config.shares;
  }

  listShares(): Promise<Share[]> {
    return this.shares.listShares(this.clock());
  }

  async createShare(r: CreateShareRequest): Promise<CreatedShare> {
    const now = this.clock();
    const shares = this.shares;
    if ((await shares.listShares(now)).length >= maxShares) {
      throw new ShareError(`At most ${maxShares} share links at once. Stop sharing an old one first.`, 409);
    }
    let expiresAt: number | null = null;
    if (r.expiresIn !== undefined && r.expiresIn !== null) {
      if (typeof r.expiresIn !== "number" || !Number.isFinite(r.expiresIn)) throw new ShareError("bad expiresIn", 400);
      expiresAt = now + Math.min(Math.max(r.expiresIn, 600), maxShareLifetime);
    }
    const token = newShareToken();
    const share = await shares.createShare(cleanLabel(r.label), await hashShareToken(token), expiresAt);
    return { share, token, url: shareURL(token) };
  }

  /// Ends a share now: the link stops working and followers' Lock Screen cards are taken down.
  async revokeShare(id: string): Promise<Share[]> {
    const now = this.clock();
    const gone = await this.shares.revokeShare(id, now);
    if (gone === null) throw new ShareError("No such share", 404);
    for (const f of gone) await this.endFollower(f, now);
    return await this.shares.listShares(now);
  }

  /// Each follower's Lock Screen card gets the same card as the owner's, by the same rules:
  /// resent when it changes or every 10 minutes, replaced before iOS's 8-hour limit, and taken
  /// down when the share expires.
  private async updateFollowers(w: Work, card: CardState | null, notices: AlertNotice[], priority: 5 | 10,
                                now: number, checkIns: CheckIn[] = [], dueCheckIns: CheckIn[] = []) {
    const checkInOf = new Map(checkIns.map((c) => [c.followerId, c]));
    const due = new Set(dueCheckIns.map((c) => c.followerId));
    const urgent = notices.length > 0;
    const forFollowers = notices.filter((n) => followerAlertKinds.has(n.kind));
    const shares = this.config.shares;
    if (!shares || !this.sender) return;
    let all: Follower[];
    try {
      all = await shares.followers(now);
    } catch (e) {
      console.error("followers", e);
      return;
    }
    // A follower's failure must never undo the owner's tick, so each one is on its own. And
    // they go out a few at a time, so a slow APNs can't hold the relay row for long.
    const ended: string[] = [];
    const one = async (f: Follower) => {
      try {
        if (!f.active) {
          await this.endFollower(f, now);
          ended.push(f.id);
          return;
        }
        if (forFollowers.length && f.alertsEnabled && f.deviceToken) await this.alertFollower(f, forFollowers, now);
        // They asked, so they hear about no answer whatever their alert switch says.
        if (due.has(f.id) && f.deviceToken) await this.tellNoAnswer(f, now);
        if (!card || !f.liveActivityEnabled) return;
        const seen = { activityToken: f.activityToken, pushToStartToken: f.pushToStartToken };
        const content = withCheckIn(card, followerCheckInCard(checkInOf.get(f.id), now));
        if (await this.updateFollower(f, content, urgent, priority, now)) await shares.saveFollower(f, seen);
      } catch (e) {
        console.error("follower", f.id, e);
      }
    };
    const budget = this.config.followerBudgetMs ?? followerBudgetMs;
    const started = Date.now();
    const order = followerOrder(all, w.followerCursor);
    w.followerCursor = null;
    for (let i = 0; i < order.length; i += followerConcurrency) {
      if (i > 0 && Date.now() - started >= budget) {
        console.warn(`followers: ${order.length - i} left for the next tick`);
        w.followerCursor = order[i].id;
        break;
      }
      await Promise.all(order.slice(i, i + followerConcurrency).map(one));
    }
    try {
      await shares.deleteFollowers(ended);
    } catch (e) {
      console.error("deleteFollowers", e);
    }
  }

  /// Whether `f` changed and needs saving.
  private async updateFollower(f: Follower, card: CardState, urgent: boolean, tickPriority: 5 | 10,
                               now: number): Promise<boolean> {
    const sender = this.sender!;
    let dirty = false;
    if (f.activityId && f.activityToken) {
      const age = f.activityStartedAt === null ? 0 : now - f.activityStartedAt;
      if (age >= rotateAfter && f.pushToStartToken) {
        await this.endFollower(f, now);
        f.activityId = f.activityToken = null;
        f.activityStartedAt = null;
        f.lastCard = null;
        f.pendingStart = true;
        f.startAttempts = 0;
        f.lastStartAttempt = null;
        dirty = true;
      } else {
        const changed = !sameCard(card, f.lastCard);
        const due = f.lastPushedAt === null || now - f.lastPushedAt >= activityRefresh;
        if (!changed && !due) return false;
        const rangeChanged = f.lastCard ? cardRange(f.lastCard) !== cardRange(card) : true;
        const checkInChanged = !sameCheckIn(f.lastCard?.checkIn, card.checkIn);
        const result = await sender.send({
          deviceToken: f.activityToken, type: "liveactivity", topic: this.config.bundleId,
          priority: tickPriority === 10 || urgent || rangeChanged || checkInChanged || cardRange(card) !== "inRange" ? 10 : 5,
          payload: payloads.activity("update", card, now), expiration: cardStaleDate(card), sandbox: f.sandbox,
        });
        if (result.kind === "delivered") {
          f.lastCard = card;
          f.lastPushedAt = now;
          return true;
        }
        if (result.kind === "tokenInvalid") {
          f.activityId = f.activityToken = null;
          f.activityStartedAt = null;
          f.lastCard = null;
          return true;
        }
        return false;
      }
    }

    const p2s = f.pushToStartToken;
    if (!f.pendingStart || !p2s || f.startAttempts >= maxStartAttempts) return dirty;
    if (f.lastStartAttempt !== null && now - f.lastStartAttempt < startRetry) return dirty;
    f.startAttempts += 1;
    f.lastStartAttempt = now;
    const result = await sender.send({
      deviceToken: p2s, type: "liveactivity", topic: this.config.bundleId, priority: 10,
      payload: payloads.activity("start", card, now, { name: f.label, followID: f.shareId }),
      expiration: now + 600, sandbox: f.sandbox,
    });
    if (result.kind === "tokenInvalid") f.pushToStartToken = null;
    // Delivered means iOS started it: don't start a second card while its registration is slow.
    if (result.kind === "delivered") f.pendingStart = false;
    return true;
  }

  /// The owner's glucose alerts, on a follower's phone.
  private async alertFollower(f: Follower, notices: AlertNotice[], now: number) {
    const token = f.deviceToken!;
    for (const n of notices) {
      const result = await this.sender!.send({
        deviceToken: token, type: "alert", topic: this.config.bundleId, priority: 10,
        payload: payloads.followerAlert(n, f.label, f.shareId, this.config.criticalAlerts),
        collapseId: `${noticeIdentifier(n)}.${f.shareId}`.slice(0, 64), expiration: now + 15 * 60, sandbox: f.sandbox,
      });
      if (result.kind === "tokenInvalid") {
        await this.config.shares!.clearFollowerDeviceToken(f.id, token);
        return;
      }
    }
  }

  private async tellNoAnswer(f: Follower, now: number) {
    const token = f.deviceToken!;
    const result = await this.sender!.send({
      deviceToken: token, type: "alert", topic: this.config.bundleId, priority: 10,
      payload: checkInPayloads.noAnswer(f.label, f.shareId),
      collapseId: `glucos.checkin.${f.shareId}`.slice(0, 64), expiration: now + checkInOpenFor, sandbox: f.sandbox,
    });
    if (result.kind === "tokenInvalid") await this.config.shares!.clearFollowerDeviceToken(f.id, token);
  }

  private async endFollower(f: Follower, now: number) {
    if (!this.sender || !f.activityToken) return;
    await this.sender.send({
      deviceToken: f.activityToken, type: "liveactivity", topic: this.config.bundleId, priority: 10,
      payload: payloads.activity("end", null, now), sandbox: f.sandbox,
    });
  }

  // MARK: Plumbing

  private async push(row: RelayRow, request: PushRequest, onInvalid: (row: RelayRow) => void): Promise<PushResult> {
    if (!this.sender) return { kind: "failed", reason: "no APNs key" };
    const result = await this.sender.send(request);
    switch (result.kind) {
      case "delivered":
        row.work.lastPushAt = this.clock();
        row.work.lastPushError = null;
        break;
      case "tokenInvalid":
        row.work.lastPushError = `${request.type}: ${result.reason}`;
        onInvalid(row);
        break;
      case "failed":
        row.work.lastPushError = `${request.type}: ${result.reason}`;
        break;
    }
    return result;
  }
}

export function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function normaliseAccount(a: Account): Account {
  return {
    email: a.email, password: a.password, region: a.region, clientVersion: a.clientVersion,
    sensorLifetimeDays: a.sensorLifetimeDays,
  };
}
