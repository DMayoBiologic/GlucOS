// Sharing: share links from the owner, followers' Lock Screen cards, revoking and expiry. An
// in-memory store and fake APNs; sharing_pg_test.ts runs the Postgres store.
import { assert, assertEquals, assertNotEquals, assertRejects } from "jsr:@std/assert@1";
import type { PushRequest, PushResult, PushSender } from "./apns.ts";
import { followerConcurrency, followerOrder, RelayEngine, rotateAfter, type Store, type Tx, newRow, type RelayRow } from "./engine.ts";
import type { Reading } from "./core.ts";
import type { Account, GlucoseFetcher, LibreSession } from "./libre.ts";
import { hashShareToken, isShareToken, maxFollowersPerShare, MemoryShareStore, shareURL } from "./sharing.ts";
import { handle as shareHandle } from "../share/index.ts";

class MemoryStore implements Store {
  row: RelayRow = newRow();
  account: Account | null = null;
  readings: Reading[] = [];
  lease: string | null = null;
  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    const tx: Tx = {
      row: this.row,
      account: () => Promise.resolve(this.account),
      setAccount: (a) => { this.account = a; return Promise.resolve(); },
      libreSession: () => Promise.resolve(null),
      setLibreSession: () => Promise.resolve(),
      readings: (since) => Promise.resolve(this.readings.filter((r) => r.t >= since).sort((a, b) => a.t - b.t)),
      addReadings: (rs) => {
        const m = new Map(this.readings.map((r) => [r.t, r]));
        for (const r of rs) m.set(r.t, r);
        this.readings = [...m.values()];
        return Promise.resolve();
      },
      clearReadings: () => { this.readings = []; return Promise.resolve(); },
      pruneReadings: () => Promise.resolve(),
      ownsLease: (l) => Promise.resolve(this.lease === l),
    };
    return fn(tx);
  }
  claimTick() { this.lease = "l"; return Promise.resolve("l"); }
  releaseTick() { this.lease = null; return Promise.resolve(); }
}

function setup() {
  let now = 1_790_000_000;
  const clock = () => now;
  const store = new MemoryStore();
  const shares = new MemoryShareStore();
  // In Postgres this reads the relay row; here, the in-memory one.
  shares.latestCard = () => Promise.resolve(store.row.work.latestCard);
  const sent: PushRequest[] = [];
  const results: Record<string, PushResult> = {};
  const sender: PushSender = { send: (p) => { sent.push(p); return Promise.resolve(results[p.deviceToken] ?? { kind: "delivered" }); } };
  let mgdl = 120;
  const fetcher: GlucoseFetcher = {
    fetch: (_a: Account, s: LibreSession | null) => {
      const history: Reading[] = [];
      for (let back = 60; back >= 5; back -= 5) history.push({ t: now - back * 60, mgdl, trend: 3 });
      return Promise.resolve({
        result: { current: { t: now - 30, mgdl, trend: 3 }, history, sensor: null },
        session: s ?? { key: "k", base: "b", token: "t", expires: now + 3600, accountId: "a" },
      });
    },
  };
  const engine = new RelayEngine(store, sender, fetcher, { bundleId: "app", criticalAlerts: false, shares }, clock);
  store.account = { email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15 };
  return {
    engine, shares, sent, results, clock,
    advance: (s: number) => { now += s; },
    setMgdl: (v: number) => { mgdl = v; },
  };
}

/// What the share function would see, against the same in-memory store.
const share = (t: ReturnType<typeof setup>, path: string, token: string, body?: unknown) =>
  shareHandle(new Request(`https://x.supabase.co/share${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), () => t.shares, t.clock);

const events = (sent: PushRequest[]) =>
  sent.map((p) => `${p.deviceToken}:${(p.payload.aps as Record<string, unknown>).event ?? p.type}`);

Deno.test("a share link's token is random, and only its hash is kept", async () => {
  const t = setup();
  const a = await t.engine.createShare({ label: "Declan", expiresIn: 3600 });
  const b = await t.engine.createShare({});
  assert(isShareToken(a.token));
  assertNotEquals(a.token, b.token);
  assertEquals(a.url, shareURL(a.token));
  assert(a.url.includes(`#${a.token}`));
  assertEquals(t.shares.shares[0].tokenHash, await hashShareToken(a.token));
  assert(!JSON.stringify(t.shares.shares).includes(a.token));
  assertEquals(a.share.label, "Declan");
  assertEquals(a.share.expiresAt, t.clock() + 3600);
  assertEquals(b.share.expiresAt, null);
  assertEquals(b.share.label, "GlucOS");
  assertEquals((await t.engine.listShares()).length, 2);
});

Deno.test("the web view sees the latest card; a wrong, revoked or expired link sees nothing", async () => {
  const t = setup();
  const { token, share: s } = await t.engine.createShare({ label: "Declan", expiresIn: 3600 });
  let res = await share(t, "/v1/snapshot", token);
  assertEquals(res.status, 200);
  let body = await res.json();
  assertEquals(body.card, null);
  assertEquals(body.label, "Declan");
  assertEquals(res.headers.get("access-control-allow-origin"), "*");

  await t.engine.tick();
  body = await (await share(t, "/v1/snapshot", token)).json();
  assertEquals(body.card.mgdl, 120);
  assertEquals(body.updatedAt, t.clock());
  assertEquals(body.followID, s.id);

  const wrong = await share(t, "/v1/snapshot", token.slice(0, -1) + (token.endsWith("A") ? "B" : "A"));
  assertEquals(wrong.status, 404);
  await wrong.body?.cancel();

  t.advance(3601);
  const expired = await share(t, "/v1/snapshot", token);
  assertEquals(expired.status, 404);
  await expired.body?.cancel();

  const other = await t.engine.createShare({});
  await t.engine.revokeShare(other.share.id);
  const revoked = await share(t, "/v1/snapshot", other.token);
  assertEquals(revoked.status, 404);
  await revoked.body?.cancel();
});

Deno.test("preflight is answered without a token", async () => {
  const res = await shareHandle(new Request("https://x.supabase.co/share/v1/snapshot", { method: "OPTIONS" }), () => new MemoryShareStore());
  assertEquals(res.status, 204);
  assert(res.headers.get("access-control-allow-headers")?.includes("authorization"));
});

Deno.test("a follower's Lock Screen card gets each new reading, then is ended when the owner stops sharing", async () => {
  const t = setup();
  const { token, share: s } = await t.engine.createShare({ label: "Declan" });
  const res = await share(t, "/v1/follow", token, {
    installation: "phone-1234", apnsEnvironment: "production", activityID: "F1", activityToken: "abcdef0123456789",
    pushToStartToken: "fedcba9876543210",
  });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).followID, s.id);

  await t.engine.tick();
  assertEquals(events(t.sent), ["abcdef0123456789:update"]);
  const card = (t.sent[0].payload.aps as Record<string, unknown>)["content-state"] as Record<string, number>;
  assertEquals(card.mgdl, 120);

  // Same card a minute later: not resent.
  t.sent.length = 0;
  t.advance(30);
  await t.engine.tick();
  t.sent.length = 0;
  t.advance(10);
  await t.engine.tick();
  assertEquals(t.sent.filter((p) => p.deviceToken === "abcdef0123456789" && p.priority === 10), []);

  t.sent.length = 0;
  assertEquals((await t.engine.listShares())[0].followers, 1);
  await t.engine.revokeShare(s.id);
  assertEquals(events(t.sent), ["abcdef0123456789:end"]);
  assertEquals(t.shares.rows, []);
  assertEquals(await t.engine.listShares(), []);
  await assertRejects(() => t.engine.revokeShare(s.id));
});

Deno.test("an expired share's followers have their cards ended on the next tick", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({ expiresIn: 600 });
  (await share(t, "/v1/follow", token, { installation: "phone-1234", activityID: "F1", activityToken: "abcdef0123456789" })).body?.cancel();
  t.advance(700);
  t.sent.length = 0;
  await t.engine.tick();
  assertEquals(events(t.sent), ["abcdef0123456789:end"]);
  assertEquals(t.shares.rows, []);
});

Deno.test("a follower's card is replaced before iOS's 8-hour limit, as theirs", async () => {
  const t = setup();
  const { token, share: s } = await t.engine.createShare({ label: "Declan" });
  (await share(t, "/v1/follow", token, {
    installation: "phone-1234", activityID: "F1", activityToken: "abcdef0123456789", pushToStartToken: "fedcba9876543210",
  })).body?.cancel();
  await t.engine.tick();
  t.sent.length = 0;
  t.advance(rotateAfter + 60);
  await t.engine.tick();
  assertEquals(events(t.sent), ["abcdef0123456789:end", "fedcba9876543210:start"]);
  const aps = t.sent[1].payload.aps as Record<string, unknown>;
  assertEquals(aps.attributes, { name: "Declan", followID: s.id });
  assertEquals(aps["attributes-type"], "GlucoseActivityAttributes");

  // The new card's token arrives from the follower's phone.
  t.sent.length = 0;
  (await share(t, "/v1/follow", token, { installation: "phone-1234", activityID: "F2", activityToken: "0123456789abcdef" })).body?.cancel();
  t.advance(60);
  await t.engine.tick();
  assertEquals(events(t.sent), ["0123456789abcdef:update"]);
});

Deno.test("a dismissed follower card or a switched-off one isn't updated", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  const follow = (b: Record<string, unknown>) => share(t, "/v1/follow", token, { installation: "phone-1234", ...b }).then((r) => r.body?.cancel());
  await follow({ activityID: "F1", activityToken: "abcdef0123456789" });
  await follow({ endedActivityID: "F1" });
  await t.engine.tick();
  assertEquals(t.sent, []);
  await follow({ activityID: "F2", activityToken: "abcdef0123456789", liveActivityEnabled: false });
  await t.engine.tick();
  assertEquals(t.sent, []);
});

Deno.test("a share has a follower cap, and the same phone following again replaces itself", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  for (let i = 0; i < maxFollowersPerShare; i++) {
    const r = await share(t, "/v1/follow", token, { installation: `phone-${1000 + i}` });
    assertEquals(r.status, 200);
    await r.body?.cancel();
  }
  const again = await share(t, "/v1/follow", token, { installation: "phone-1000" });
  assertEquals(again.status, 200);
  await again.body?.cancel();
  const over = await share(t, "/v1/follow", token, { installation: "phone-9999" });
  assertEquals(over.status, 409);
  await over.body?.cancel();
  const gone = await share(t, "/v1/unfollow", token, { installation: "phone-1000" });
  assertEquals(gone.status, 200);
  await gone.body?.cancel();
  assertEquals(t.shares.rows.length, maxFollowersPerShare - 1);
});

Deno.test("bad registrations are refused or cleaned", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  const bad = await share(t, "/v1/follow", token, { installation: "x" });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  (await share(t, "/v1/follow", token, { installation: "phone-1234", activityID: "F1", activityToken: "not hex!" })).body?.cancel();
  assertEquals(t.shares.rows[0].activityToken, null);
});

Deno.test("an invalid follower token is forgotten", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  (await share(t, "/v1/follow", token, { installation: "phone-1234", activityID: "F1", activityToken: "abcdef0123456789" })).body?.cancel();
  t.results["abcdef0123456789"] = { kind: "tokenInvalid", reason: "Unregistered" };
  await t.engine.tick();
  assertEquals(t.shares.rows[0].activityToken, null);
  // The owner's push status isn't touched by a follower's token.
  assertEquals((await t.engine.status()).lastPushError, undefined);
});

Deno.test("sign-out clears what share links show", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  await t.engine.tick();
  assert((await (await share(t, "/v1/snapshot", token)).json()).card);
  await t.engine.register({ signedOut: true });
  assertEquals((await (await share(t, "/v1/snapshot", token)).json()).card, null);
});

Deno.test("a failing follower doesn't stop the others or the owner's tick", async () => {
  const t = setup();
  const { token } = await t.engine.createShare({});
  for (const [i, tok] of [["phone-1111", "aaaaaaaaaaaaaaaa"], ["phone-2222", "bbbbbbbbbbbbbbbb"]]) {
    (await share(t, "/v1/follow", token, { installation: i, activityID: i, activityToken: tok })).body?.cancel();
  }
  const save = t.shares.saveFollower.bind(t.shares);
  let calls = 0;
  t.shares.saveFollower = (f, seen) => (calls++ === 0 ? Promise.reject(new Error("db down")) : save(f, seen));
  assertEquals(await t.engine.tick(), "done");
  assertEquals(events(t.sent).sort(), ["aaaaaaaaaaaaaaaa:update", "bbbbbbbbbbbbbbbb:update"]);
  assertEquals(t.shares.rows.filter((f) => f.lastCard).length, 1);
});

Deno.test("followers past the tick's time budget wait for the next tick", async () => {
  const t = setup();
  t.engine["config"].followerBudgetMs = 0;
  // Two links, so there are more followers than one batch (and than one link allows).
  const links = [await t.engine.createShare({}), await t.engine.createShare({})];
  for (let i = 0; i < followerConcurrency + 2; i++) {
    const tok = i.toString(16).padStart(16, "0");
    (await share(t, "/v1/follow", links[i % 2].token, { installation: `phone-${1000 + i}`, activityID: `a${i}`, activityToken: tok })).body?.cancel();
  }
  assertEquals(await t.engine.tick(), "done");
  // The first batch always goes; the rest are left for the next tick, which starts with them.
  const first = events(t.sent).filter((e) => e.endsWith(":update"));
  assertEquals(first.length, followerConcurrency);
  t.sent.length = 0;
  t.advance(60);
  assertEquals(await t.engine.tick(), "done");
  const second = events(t.sent).filter((e) => e.endsWith(":update"));
  assertEquals(new Set([...first, ...second]).size, followerConcurrency + 2);
});

Deno.test("short ticks reach every follower even when deletes keep failing and ticks are skipped", async () => {
  const t = setup();
  t.engine["config"].followerBudgetMs = 0;
  // Two links run out, and their followers can't be deleted, so they stay in the list every tick.
  // (Two of each, as one link takes at most maxFollowersPerShare.)
  const ending = [await t.engine.createShare({ expiresIn: 600 }), await t.engine.createShare({ expiresIn: 600 })];
  const lasting = [await t.engine.createShare({ expiresIn: 86_400 }), await t.engine.createShare({ expiresIn: 86_400 })];
  const want = { end: new Set<string>(), update: new Set<string>() };
  for (let i = 0; i < 12; i++) {
    for (const [links, kind] of [[ending, "end"], [lasting, "update"]] as const) {
      const link = links[i % 2];
      const tok = `${kind === "end" ? "e" : "a"}${i}`.padStart(16, "0"); // hex, like a real token
      want[kind].add(`${tok}:${kind}`);
      (await share(t, "/v1/follow", link.token, { installation: `phone-${kind}-${i}`, activityID: `${kind}${i}`, activityToken: tok })).body?.cancel();
    }
  }
  t.shares.deleteFollowers = () => Promise.reject(new Error("db down"));
  t.advance(700);
  const got = new Set<string>();
  for (let tick = 0; tick < 3; tick++) {
    assertEquals(await t.engine.tick(), "done");
    // One batch per tick, from where the last one stopped. (An ended follower already told is
    // visited again but sends nothing, so a batch can send fewer.)
    assert(t.sent.length <= followerConcurrency);
    events(t.sent).forEach((e) => got.add(e));
    t.sent.length = 0;
    t.advance(tick === 0 ? 3 * 3600 : 60); // a long gap, as if the scheduler skipped ticks
  }
  assertEquals([...got].filter((e) => e.endsWith(":end")).sort(), [...want.end].sort());
  assertEquals([...got].filter((e) => e.endsWith(":update")).sort(), [...want.update].sort());
});

Deno.test("ticks short of time pick up where the last one stopped, so every follower gets a turn", () => {
  // Each tick only gets through its first batch, then saves where it stopped. Ended followers
  // whose delete keeps failing stay in the list; followers come and go between ticks.
  let fs = Array.from({ length: 25 }, (_, i) => ({ id: `f${String(i).padStart(2, "0")}` }));
  let cursor: string | null = null;
  const seen = new Set<string>();
  for (let tick = 0; tick < 3; tick++) {
    const order: { id: string }[] = followerOrder(fs, cursor);
    assertEquals(order.length, fs.length);
    order.slice(0, followerConcurrency).forEach((f) => seen.add(f.id));
    cursor = order[followerConcurrency]?.id ?? null;
    if (tick === 0) fs = fs.filter((f) => f.id !== "f03").concat({ id: "f99" }); // one leaves, one joins
  }
  assertEquals(seen.size, 26);
  // A cursor past the end wraps round.
  assertEquals(followerOrder(fs, "zzz")[0].id, "f00");
});

Deno.test("share expiry is kept between 10 minutes and 90 days", async () => {
  const t = setup();
  assertEquals((await t.engine.createShare({ expiresIn: 1 })).share.expiresAt, t.clock() + 600);
  assertEquals((await t.engine.createShare({ expiresIn: 1e9 })).share.expiresAt, t.clock() + 90 * 86_400);
});
