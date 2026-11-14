// Check-ins: when someone a follower follows goes low (or is forecast to), the follower taps
// "Check in" on their Lock Screen card. The owner gets a notification with "I'm okay" and
// "I need help" buttons (and the same on their own Lock Screen card); their answer goes back to the
// follower as a notification and on the follower's card. No answer in 5 minutes: the owner is
// asked again, louder, and the follower is told. See docs/Sharing.md "Check-ins".
//
// The follower asks through the public `share` function (the share token is their credential),
// which notifies the owner straight away. The owner answers through the relay (the relay secret).
// The relay's minute tick does the rest: the reminder, and both Lock Screen cards.

import type { PushSender } from "./apns.ts";
import { type CardState, formatGlucose, unitOf } from "./core.ts";
import type { Follower, ShareStore } from "./sharing.ts";

export type CheckInAnswer = "okay" | "help";

export interface CheckIn {
  id: string;
  followerId: string;
  shareId: string;
  /// The follower's name, as they gave it ("" when they didn't).
  name: string;
  /// Seconds since 1970.
  askedAt: number;
  /// The last time the owner was notified for it (asking again re-notifies, at most every 2 minutes).
  lastAskedAt: number;
  /// When the no-answer reminder went out.
  remindedAt: number | null;
  answer: CheckInAnswer | null;
  answeredAt: number | null;
}

/// A check-in as a Live Activity shows it, in its content state. Mirrors `CheckInState` in
/// Sources/Shared/GlucoseActivityState.swift.
export interface CheckInCard {
  /// asked: waiting for an answer; noAnswer: still waiting after `checkInRemindAfter`;
  /// okay / help: the owner's answer.
  status: "asked" | "noAnswer" | "okay" | "help";
  askedAt: number;
  answeredAt?: number;
  /// On the owner's card: who is asking (the first of them), when they gave a name.
  who?: string;
  /// On the owner's card: how many people are waiting for an answer.
  count?: number;
}

/// An unanswered check-in stops waiting after an hour.
export const checkInOpenFor = 60 * 60;
/// No answer after this long: the owner is notified again (critical, when the relay may) and the
/// follower is told.
export const checkInRemindAfter = 5 * 60;
/// An answer stays on the follower's card this long.
export const checkInAnswerShownFor = 30 * 60;
/// Tapping Check in again re-notifies the owner at most this often.
export const checkInPingGap = 2 * 60;
export const nameLength = 30;

export const isOpen = (c: CheckIn, now: number) => c.answer === null && now - c.askedAt < checkInOpenFor;

/// Still worth showing: waiting for an answer, or answered recently.
export function isCurrent(c: CheckIn, now: number): boolean {
  if (c.answer === null) return isOpen(c, now);
  return now - (c.answeredAt ?? c.askedAt) < checkInAnswerShownFor;
}

export function cleanName(raw: unknown): string {
  const s = typeof raw === "string" ? raw.replace(/[\u0000-\u001f\u007f]/g, "").trim() : "";
  return [...s].slice(0, nameLength).join("");
}

/// What a follower's card shows of their own latest check-in.
export function followerCheckInCard(c: CheckIn | null | undefined, now: number): CheckInCard | undefined {
  if (!c || !isCurrent(c, now)) return undefined;
  if (c.answer !== null) return { status: c.answer, askedAt: c.askedAt, answeredAt: c.answeredAt ?? c.askedAt };
  return { status: now - c.askedAt >= checkInRemindAfter ? "noAnswer" : "asked", askedAt: c.askedAt };
}

/// What the owner's card shows: everyone still waiting, oldest first.
export function ownerCheckInCard(all: CheckIn[], now: number): CheckInCard | undefined {
  const open = all.filter((c) => isOpen(c, now)).sort((a, b) => a.askedAt - b.askedAt);
  if (!open.length) return undefined;
  const first = open[0];
  const card: CheckInCard = {
    status: now - first.askedAt >= checkInRemindAfter ? "noAnswer" : "asked", askedAt: first.askedAt, count: open.length,
  };
  const named = open.find((c) => c.name);
  if (named) card.who = named.name;
  return card;
}

/// The card with a check-in on it (or not).
export function withCheckIn(card: CardState, checkIn: CheckInCard | undefined): CardState {
  if (!checkIn) return card;
  return { ...card, checkIn };
}

export const sameCheckIn = (a: CheckInCard | undefined, b: CheckInCard | undefined) =>
  JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

// MARK: - Notifications

/// The owner's notification category: "I'm okay" and "I need help" (registered by the iPhone app,
/// `CheckInNotifications` in Sources/iOS/CheckIns.swift).
export const ownerCategory = "glucos.checkin";
/// A follower's low alerts carry a "Check in" button.
export const followerLowCategory = "glucos.follow.low";

export const checkInPayloads = {
  /// To the owner. `reminder`: nobody's answered for `checkInRemindAfter`.
  ask(who: string, count: number, card: CardState | null, reminder: boolean, criticalSound: boolean) {
    const name = who || "Someone who follows you";
    const others = count > 1 ? ` and ${count - 1} other${count > 2 ? "s" : ""}` : "";
    const reading = card ? ` Your glucose is ${formatGlucose(unitOf(card.unit), card.mgdl, true)}.` : "";
    const title = reminder ? `${name}${others} still waiting` : `${name}${others} checking in`;
    const body = reminder
      ? `No answer yet.${reading} Let them know you're okay.`
      : `Are you okay?${reading}`;
    const critical = reminder && criticalSound;
    return {
      aps: {
        alert: { title, body },
        category: ownerCategory,
        "thread-id": "glucos.checkin",
        "interruption-level": critical ? "critical" : "time-sensitive",
        "relevance-score": 1.0,
        sound: critical ? { critical: 1, name: "default", volume: 1.0 } : "default",
      },
      kind: "checkIn",
    };
  },

  /// To a follower: the owner answered.
  answer(label: string, shareId: string, answer: CheckInAnswer, criticalSound: boolean) {
    const help = answer === "help";
    return {
      aps: {
        alert: help
          ? { title: `${label} needs help`, body: `${label} answered your check-in: they need help. Go to them or call now.` }
          : { title: `${label} is okay`, body: `${label} answered your check-in.` },
        "thread-id": `glucos.follow.${shareId}`,
        "interruption-level": help ? (criticalSound ? "critical" : "time-sensitive") : "active",
        "relevance-score": help ? 1.0 : 0.6,
        sound: help && criticalSound ? { critical: 1, name: "default", volume: 1.0 } : "default",
      },
      kind: "checkInAnswer",
      followID: shareId,
    };
  },

  /// To a follower: no answer after `checkInRemindAfter`.
  noAnswer(label: string, shareId: string) {
    return {
      aps: {
        alert: {
          title: `No answer from ${label}`,
          body: `${label} hasn't answered your check-in for 5 minutes. They've been asked again. If you can, call them.`,
        },
        category: followerLowCategory,
        "thread-id": `glucos.follow.${shareId}`,
        "interruption-level": "time-sensitive",
        "relevance-score": 1.0,
        sound: "default",
      },
      kind: "checkInNoAnswer",
      followID: shareId,
    };
  },
};

// MARK: - Asking

/// Where the owner's notifications go, and their latest card (for the reading in the message).
export interface OwnerTarget {
  deviceToken: string | null;
  sandbox: boolean;
  card: CardState | null;
}

export interface CheckInConfig {
  bundleId: string;
  criticalAlerts: boolean;
}

/// A follower taps Check in: record it and notify the owner (unless they were notified moments
/// ago for the same check-in). Returns what the follower's card should show.
export async function askCheckIn(shares: ShareStore, sender: PushSender | null, config: CheckInConfig, follower: Follower,
                                 name: string, now: number): Promise<CheckInCard> {
  const { checkIn, ping } = await shares.askCheckIn(follower, name, now);
  if (ping && sender) {
    const owner = await shares.ownerTarget();
    if (owner.deviceToken) {
      const waiting = (await shares.checkIns(now)).filter((c) => isOpen(c, now));
      const result = await sender.send({
        deviceToken: owner.deviceToken, type: "alert", topic: config.bundleId, priority: 10,
        payload: checkInPayloads.ask(checkIn.name, Math.max(1, waiting.length), owner.card, false, config.criticalAlerts),
        collapseId: "glucos.checkin", expiration: now + checkInOpenFor, sandbox: owner.sandbox,
      });
      if (result.kind !== "delivered") console.warn("check-in: owner push", result);
    }
  }
  return followerCheckInCard(checkIn, now)!;
}
