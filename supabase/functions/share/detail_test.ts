// The follower view's data (detail.ts): readings in 5-minute buckets since a time, the owner's
// logbook unless the link hides it, notes blanked. detail_pg_test.ts runs the Postgres queries.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { hashShareToken, MemoryShareStore, newShareToken } from "../relay/sharing.ts";
import { clampSince, detailReadingDays, followerPayload, MemoryDetailSource, sharedLogKinds } from "./detail.ts";
import { handle } from "./index.ts";

const now = 1_790_000_000;

async function setup() {
  const shares = new MemoryShareStore();
  const token = newShareToken();
  const share = await shares.createShare("Declan", await hashShareToken(token), null);
  const detail = new MemoryDetailSource();
  const get = (path: string) =>
    handle(new Request(`https://x.supabase.co/share${path}`, { headers: { authorization: `Bearer ${token}` } }),
           () => shares, () => now, () => null, () => detail);
  return { shares, share, detail, get, token };
}

Deno.test("detail: readings in 5-minute buckets since the time asked for", async () => {
  const t = await setup();
  // A reading every minute for the last 20 minutes.
  for (let back = 20; back >= 0; back--) t.detail.points.push([now - back * 60, 100 + back]);
  const res = await t.get(`/v1/detail?since=${now - 600}`);
  assertEquals(res.status, 200);
  const body = await res.json();
  assert(body.readings.length >= 2 && body.readings.length <= 3);
  for (const [time] of body.readings) assert(time >= now - 600);
  assertEquals(body.readings.at(-1)[0], now);
  assertEquals(body.generatedAt, now);
  // Nonsense and missing `since` mean the whole window.
  const all = await (await t.get("/v1/detail?since=banana")).json();
  assert(all.readings.length > body.readings.length);
});

Deno.test("detail: since is clamped to the window", () => {
  assertEquals(clampSince(null, now), now - detailReadingDays * 86_400);
  assertEquals(clampSince("0", now), now - detailReadingDays * 86_400);
  assertEquals(clampSince(String(now + 999), now), now);
  assertEquals(clampSince(String(now - 60), now), now - 60);
});

Deno.test("detail: the logbook, newest first, without notes; hidden when the owner turns it off", async () => {
  const t = await setup();
  t.detail.entries = [
    { id: "a", kind: "dose", deleted: false, modified: now, payload: { timestamp: now - 3600, units: 4, note: "private", calculation: { x: 1 } } },
    { id: "b", kind: "meal", deleted: false, modified: now, payload: { timestamp: now - 600, carbs: 30, note: "" } },
    { id: "c", kind: "meal", deleted: false, modified: now, payload: { timestamp: now - 72 * 3600, carbs: 10, note: "" } },
  ];
  let body = await (await t.get("/v1/detail")).json();
  assertEquals(body.showsLogbook, true);
  assertEquals(body.logbook.map((e: { id: string }) => e.id), ["b", "a"]);
  assertEquals(body.logbook[1].payload.note, "");
  assertEquals(body.logbook[1].payload.calculation, undefined);
  assertEquals(body.logbook[1].payload.units, 4);

  const snap = await (await t.get("/v1/snapshot")).json();
  assertEquals(snap.showsLogbook, true);

  assert(await t.shares.setShowsLogbook(t.share.id, false, now));
  body = await (await t.get("/v1/detail")).json();
  assertEquals(body.showsLogbook, false);
  assertEquals(body.logbook, null);
  assertEquals((await (await t.get("/v1/snapshot")).json()).showsLogbook, false);
});

Deno.test("detail: no owner found means no logbook, not an error", async () => {
  const t = await setup();
  t.detail.entries = null;
  const body = await (await t.get("/v1/detail")).json();
  assertEquals(body.showsLogbook, true);
  assertEquals(body.logbook, null);
});

Deno.test("detail: a wrong token sees nothing", async () => {
  const t = await setup();
  const res = await handle(new Request("https://x.supabase.co/share/v1/detail", { headers: { authorization: `Bearer ${newShareToken()}` } }),
                           () => t.shares, () => now, () => null, () => t.detail);
  assertEquals(res.status, 404);
  await res.body?.cancel();
});

Deno.test("detail: follower payloads keep the shape the apps decode", () => {
  assertEquals(followerPayload({ note: "x", units: 1 }), { note: "", units: 1 });
  assertEquals(followerPayload({ units: 1 }), { units: 1 });
});

Deno.test("detail: followers never see alerts or the app's own records", () => {
  // Alert rows (docs/AlertLog.md), low answers and settings are the owner's alone.
  assertEquals(sharedLogKinds, ["dose", "meal", "siteChange", "context"]);
  for (const k of ["alert", "lowAnswer", "preset", "food", "insulin", "bolusSettings", "insightsLayout"]) assert(!sharedLogKinds.includes(k));
});
