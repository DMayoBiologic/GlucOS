// Episode keying for low and high alerts (docs/AlertEpisodes.md). The same numbers as the Swift
// AlertEpisodesTests, so local alerts and pushes are keyed alike.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  type AlertKind, backInRangeText, defaultAlertPreferences, earlierPayload, episodeDuration, episodeShownLimit,
  episodeSide, evaluateAlerts, newEpisodes, newPlanner, observeEpisodes, recordEpisodeAlert, type Snapshot,
} from "./core.ts";
import { payloads } from "./apns.ts";

const t0 = 1_789_999_200;
const at = (minutes: number) => t0 + minutes * 60;
const snap = (mgdl: number, minute: number, unit: "mmol" | "mgdl" = "mgdl"): Snapshot => ({
  current: { t: at(minute), mgdl, trend: 3 }, history: [], sensor: null, unit, lowMgdl: 70, highMgdl: 180,
  lastError: null, outlook: null,
});

Deno.test("episodes: alerts from one low share an id, the next low gets its own", () => {
  const p = newPlanner(), e = newEpisodes();
  const step = (mgdl: number, minute: number) => {
    const s = snap(mgdl, minute), now = at(minute) + 30;
    const ended = observeEpisodes(e, s, now);
    const ids = evaluateAlerts(p, s, defaultAlertPreferences(), now)
      .map((n) => recordEpisodeAlert(e, n.kind, now)?.identifier ?? `glucos.${n.kind}`);
    return { ids, ended };
  };
  assertEquals(step(80, 0).ids, []);
  assertEquals(step(65, 5).ids, ["glucos.low.1789999500"]);
  assertEquals(step(60, 10).ids, []);
  assertEquals(step(58, 15).ids, []);
  assertEquals(step(61, 20).ids, ["glucos.low.1789999500"]);
  assertEquals(step(68, 25).ids, []);
  const back = step(82, 30);
  assertEquals(back.ids, []);
  assertEquals(back.ended.length, 1);
  const b = back.ended[0];
  assertEquals([b.identifier, b.minutes], ["glucos.low.1789999500", 25]);
  assertEquals(backInRangeText(b, "mgdl"), { title: "Back in range after 25 min", body: "Lowest 58 mg/dL, now 82 mg/dL." });
  assertEquals(b.shown.map((s) => s.kind), ["low", "low"]);
  assertEquals(e.low, null);
  assertEquals(step(66, 60).ids, ["glucos.low.1790002800"]);
});

Deno.test("episodes: highs say highest, in the user's unit", () => {
  const e = newEpisodes();
  observeEpisodes(e, snap(200, 0), at(0));
  recordEpisodeAlert(e, "high", at(0));
  observeEpisodes(e, snap(262, 40), at(40));
  recordEpisodeAlert(e, "veryHigh", at(40));
  observeEpisodes(e, snap(240, 80), at(80));
  const ended = observeEpisodes(e, snap(170, 95, "mmol"), at(95));
  assertEquals(ended.length, 1);
  assertEquals(backInRangeText(ended[0], "mmol"), {
    title: "Back in range after 1 h 35 min", body: "Highest 14.5 mmol/L, now 9.4 mmol/L.",
  });
  assertEquals(ended[0].identifier, "glucos.high.1789999200");
});

Deno.test("episodes: only low and high alerts are grouped", () => {
  const e = newEpisodes();
  for (const k of ["rapidChange", "stale", "sensorExpiring", "apiBroken"] as AlertKind[]) {
    assertEquals(episodeSide(k), null);
    assertEquals(recordEpisodeAlert(e, k, t0), null);
  }
  for (const k of ["urgentLow", "low", "predictedUrgentLow", "predictedLow"] as AlertKind[]) assertEquals(episodeSide(k), "low");
  for (const k of ["high", "veryHigh", "predictedHigh", "predictedVeryHigh"] as AlertKind[]) assertEquals(episodeSide(k), "high");
});

Deno.test("episodes: nothing shown, a long gap, stale readings or the other side end it quietly", () => {
  let e = newEpisodes();
  observeEpisodes(e, snap(200, 0), at(0));
  assertEquals(observeEpisodes(e, snap(150, 30), at(30)), []);
  assertEquals(e.high, null);

  e = newEpisodes();
  observeEpisodes(e, snap(60, 0), at(0));
  recordEpisodeAlert(e, "low", at(0));
  assertEquals(observeEpisodes(e, snap(100, 5), at(20)), []); // stale: nothing changes
  assert(e.low !== null);
  assertEquals(observeEpisodes(e, snap(100, 31), at(31)), []); // 31 min without a reading
  assertEquals(e.low, null);

  e = newEpisodes();
  observeEpisodes(e, snap(60, 0), at(0));
  recordEpisodeAlert(e, "low", at(0));
  assertEquals(observeEpisodes(e, snap(190, 5), at(5)), []);
  assertEquals(e.low, null);
  assert(e.high !== null);
});

Deno.test("episodes: a heads-up opens the episode, and expires if it never came true", () => {
  let e = newEpisodes();
  observeEpisodes(e, snap(85, 0), at(0));
  assertEquals(recordEpisodeAlert(e, "predictedLow", at(0))?.identifier, "glucos.low.1789999200");
  assertEquals(observeEpisodes(e, snap(78, 5), at(5)), []);
  observeEpisodes(e, snap(66, 15), at(15));
  const low = recordEpisodeAlert(e, "low", at(15));
  assertEquals(low?.identifier, "glucos.low.1789999200");
  assertEquals(low?.earlier.map((s) => s.kind), ["predictedLow"]);
  assertEquals(observeEpisodes(e, snap(75, 35), at(35)).map((b) => b.minutes), [20]);

  e = newEpisodes();
  recordEpisodeAlert(e, "predictedHigh", at(0));
  assertEquals(observeEpisodes(e, snap(150, 44), at(44)), []);
  assert(e.high !== null);
  observeEpisodes(e, snap(150, 45), at(45));
  assertEquals(e.high, null);
});

Deno.test("episodes: earlier alerts are capped and sent as [kind, seconds]", () => {
  const e = newEpisodes();
  for (let i = 0; i < 15; i++) recordEpisodeAlert(e, "low", at(i * 5));
  const last = recordEpisodeAlert(e, "urgentLow", at(80))!;
  assertEquals(last.earlier.length, episodeShownLimit);
  assertEquals(earlierPayload([{ kind: "low", at: t0 }]), [["low", t0]]);
  assertEquals([episodeDuration(1), episodeDuration(60), episodeDuration(125)], ["1 min", "1 h", "2 h 5 min"]);
});

Deno.test("episodes: the back-in-range push is quiet; alerts keep their sound", () => {
  const b = { side: "low" as const, identifier: "glucos.low.1", minutes: 25, extremeMgdl: 58, nowMgdl: 82, shown: [{ kind: "low" as const, at: t0 }] };
  const quiet = payloads.backInRange(b, "mgdl");
  const qa = quiet.aps as Record<string, unknown>;
  assertEquals(qa["interruption-level"], "passive");
  assertEquals("sound" in qa, false);
  assertEquals("category" in qa, false);
  assertEquals(quiet.earlier, [["low", t0]]);
  const follower = payloads.backInRange(b, "mgdl", { label: "Dec", shareId: "s1" });
  assertEquals((follower.aps as Record<string, unknown>)["thread-id"], "glucos.follow.s1");
  assertEquals(((follower.aps as Record<string, unknown>).alert as Record<string, string>).title, "Dec: Back in range after 25 min");
  assertEquals("earlier" in follower, false);
  const loud = payloads.alert({ kind: "low", title: "Low", body: "b", critical: false }, false, null, b.shown);
  assertEquals([(loud.aps as Record<string, unknown>).sound, (loud.aps as Record<string, unknown>)["interruption-level"]], ["default", "active"]);
  assertEquals(loud.earlier, [["low", t0]]);
});
