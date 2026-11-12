// The diagnostics function with a fake store, and its table against a real Supabase Postgres
// (skipped unless GLUCOS_TEST_DB_URL is set; CI runs it against the supabase/postgres image).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { connect } from "../relay/store.ts";
import {
  type DiagnosticDevice, type DiagnosticEvent, type DiagnosticsStore, handle, limits, parseBatch,
  PostgresDiagnosticsStore,
} from "./index.ts";

const now = 1_800_000_000;
const install = "6f1c1f9e-3a52-4c55-9d1b-6f0d1f4b2a10";
const device = {
  installID: install, platform: "ios", app: "au.com.declanmayo.glucos.ios", appVersion: "0.24.0", build: "40",
  osVersion: "26.1.0", model: "iPhone17,1",
};
const event = (over: Partial<DiagnosticEvent> = {}): DiagnosticEvent => ({
  id: crypto.randomUUID(), occurredAt: now - 10, feature: "sensor.nfc", step: "read-memory", code: "NFC 100",
  message: "The read was cut short.", detail: "block 0: multi NFC 100 (Tag connection lost)",
  context: { sensor: "FreeStyle Libre 2 Plus", region: "Australia / Canada" }, repeats: 0, userSent: false, ...over,
});

class FakeStore implements DiagnosticsStore {
  rows: { device: DiagnosticDevice; event: DiagnosticEvent }[] = [];
  recentCount(installID: string) {
    return Promise.resolve(this.rows.filter((r) => r.device.installID === installID).length);
  }
  insert(d: DiagnosticDevice, events: DiagnosticEvent[]) {
    const fresh = events.filter((e) => !this.rows.some((r) => r.event.id === e.id));
    this.rows.push(...fresh.map((event) => ({ device: d, event })));
    return Promise.resolve(fresh.length);
  }
}

const post = (body: unknown, store: FakeStore) =>
  handle(
    new Request("https://x.supabase.co/functions/v1/diagnostics/v1/report", {
      method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
    }),
    () => store,
    () => now,
  );

Deno.test("stores a batch, once even when retried", async () => {
  const store = new FakeStore();
  const body = { device, events: [event(), event({ step: "scan", code: null })] };
  const r = await post(body, store);
  assertEquals(r.status, 200);
  assertEquals((await r.json()).stored, 2);
  assertEquals((await (await post(body, store)).json()).stored, 0);
  assertEquals(store.rows.length, 2);
  assertEquals(store.rows[0].event.context?.sensor, "FreeStyle Libre 2 Plus");
});

Deno.test("refuses malformed reports", async () => {
  const store = new FakeStore();
  assertEquals((await post("nope", store)).status, 400);
  assertEquals((await post({ device: { ...device, installID: "x" }, events: [event()] }, store)).status, 400);
  assertEquals((await post({ device, events: [] }, store)).status, 400);
  assertEquals((await post({ device, events: [event({ feature: "Robert'); drop table" })] }, store)).status, 400);
  const many = Array.from({ length: limits.eventsPerRequest + 1 }, () => event());
  assertEquals((await post({ device, events: many }, store)).status, 400);
  assertEquals((await post("x".repeat(limits.bodyBytes + 1), store)).status, 413);
  assertEquals(store.rows.length, 0);
});

Deno.test("clips long fields and fixes impossible times", () => {
  const b = parseBatch({ device, events: [event({ detail: "d".repeat(5000), occurredAt: now + 86400 })] }, now);
  assert(typeof b !== "string");
  assertEquals(b.events[0].detail?.length, 2000);
  assertEquals(b.events[0].occurredAt, now);
});

Deno.test("limits automatic reports per install per hour, but not ones the person sent", async () => {
  const store = new FakeStore();
  for (let i = 0; i < limits.perInstallPerHour / limits.eventsPerRequest; i++) {
    const events = Array.from({ length: limits.eventsPerRequest }, () => event());
    assertEquals((await post({ device, events }, store)).status, 200);
  }
  assertEquals((await post({ device, events: [event()] }, store)).status, 429);
  const mine = await post({ device, events: [event(), event({ userSent: true, note: "tapped Scan" })] }, store);
  assertEquals(mine.status, 200);
  assertEquals(await mine.json(), { stored: 1, dropped: 1 });
});

Deno.test("health and wrong routes", async () => {
  const store = new FakeStore();
  const h = await handle(new Request("https://x/functions/v1/diagnostics/health"), () => store);
  assertEquals(await h.text(), "ok");
  assertEquals((await handle(new Request("https://x/functions/v1/diagnostics/v1/report"), () => store)).status, 405);
  assertEquals((await handle(new Request("https://x/functions/v1/diagnostics/v2"), () => store)).status, 404);
});

const url = Deno.env.get("GLUCOS_TEST_DB_URL");
if (url && /supabase\.(co|com)/.test(url)) throw new Error("GLUCOS_TEST_DB_URL must be a local test database");

Deno.test({
  name: "postgres diagnostics store and views",
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const sql = connect(url);
    try {
      await sql`delete from glucos.diagnostics`;
      const store = new PostgresDiagnosticsStore(sql);
      const real = Date.now() / 1000;
      const a = event({ occurredAt: real - 60, repeats: 3 });
      const b = event({ occurredAt: real - 30, userSent: true, note: "held still" });
      assertEquals(await store.insert(device, [a, b], real), 2);
      assertEquals(await store.insert(device, [a], real), 0);
      assertEquals(await store.recentCount(install), 2);
      assertEquals(await store.recentCount("00000000-0000-0000-0000-000000000000"), 0);

      const [s] = await sql`select * from glucos.diagnostics_summary where feature = 'sensor.nfc'`;
      assertEquals(Number(s.reports), 2);
      assertEquals(Number(s.occurrences), 5);
      assertEquals(Number(s.installs), 1);
      assertEquals(Number(s.sent_by_user), 1);
      assertEquals(s.latest_detail, "block 0: multi NFC 100 (Tag connection lost)");
      const recent = await sql`select sensor, note, context from glucos.diagnostics_recent`;
      assertEquals(recent.length, 2);
      assertEquals(recent[0].sensor, "FreeStyle Libre 2 Plus");
      assertEquals(recent[0].note, "held still");
      assertEquals(recent[0].context.region, "Australia / Canada");
      // Nothing outside the database owner can read it.
      const [{ anon }] = await sql`select has_table_privilege('anon', 'glucos.diagnostics', 'select') as anon`;
      assertEquals(anon, false);
    } finally {
      await sql`delete from glucos.diagnostics`;
      await sql.end();
    }
  },
});
