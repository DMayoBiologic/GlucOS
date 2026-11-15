// Looks for likely sensor compression lows: sudden drops that bounce back within about 20 minutes
// with nothing logged, the shape a sensor gives when it's lain on in bed. Lists every such dip and
// every low (readings under 70 mg/dL), overnight or not, so a guard on low alerts can be judged
// against what really happened. See docs/ForecastAccuracy.md §17.
//
//   GLUCOS_REPLAY_DIR=dir deno run --allow-read --allow-env scripts/compression-lows.ts
//
// dir holds readings.json ([[unix seconds, mg/dL], …]) and log.json ([unix seconds, …]), as for
// low-alert-replay.ts. Knobs: DROP=mg/dL (default 20), RATE=mg/dL a minute (default 2),
// TZ_HOURS=offset from UTC for "overnight" 22:00–07:00 (default 8, Perth).
const env = (k: string) => Deno.env.get(k) ?? "";
const dir = env("GLUCOS_REPLAY_DIR") || ".";
const raw: number[][] = JSON.parse(Deno.readTextFileSync(`${dir}/readings.json`));
const logs: number[] = JSON.parse(Deno.readTextFileSync(`${dir}/log.json`));
const minDrop = Number(env("DROP") || 20), minRate = Number(env("RATE") || 2), tz = Number(env("TZ_HOURS") || 8);
const lowMgdl = 70;

// One reading a minute: LinkUp's 15-minute graph points land a second or so from a live reading.
const byMinute = new Map<number, number[]>();
for (const r of raw) byMinute.set(Math.floor(r[0] / 60), r);
const rs = [...byMinute.values()].sort((a, b) => a[0] - b[0]);

const local = (t: number) => new Date((t + tz * 3600) * 1000);
const label = (t: number) => local(t).toISOString().slice(5, 16).replace("T", " ");
const overnight = (t: number) => { const h = local(t).getUTCHours(); return h >= 22 || h < 7; };
const logged = (from: number, to: number) => logs.some((l) => l >= from && l <= to);

interface Dip { t: number; nadir: number; top: number; rate: number; back: number; logged: boolean; night: boolean }
const dips: Dip[] = [];
for (let i = 0; i < rs.length; i++) {
  const [t, v] = rs[i];
  const near = rs.filter((r) => Math.abs(r[0] - t) <= 10 * 60);
  if (near.some((r) => r[1] < v || (r[1] === v && r[0] < t))) continue; // the first lowest point
  const before = rs.filter((r) => t - r[0] > 0 && t - r[0] <= 15 * 60);
  const after = rs.filter((r) => r[0] - t > 0 && r[0] - t <= 20 * 60);
  if (before.length < 8 || after.length < 8) continue; // needs one-minute readings around it
  const top = Math.max(...before.map((r) => r[1]));
  const topAt = before.find((r) => r[1] === top)![0];
  const rate = (top - v) / Math.max(1, (t - topAt) / 60);
  const back = Math.max(...after.map((r) => r[1])) - v;
  if (top - v >= minDrop && rate >= minRate && back >= (2 / 3) * (top - v)) {
    dips.push({ t, nadir: v, top, rate, back, logged: logged(t - 30 * 60, t + 20 * 60), night: overnight(t) });
  }
}

// Lows as in low-alert-replay.ts: from the first reading under the line until 15 minutes back above.
interface Low { t: number; end: number; nadir: number }
const lows: Low[] = [];
let cur: Low | null = null;
for (const [t, v] of rs) {
  if (v < lowMgdl) {
    cur ??= { t, end: t, nadir: v };
    cur.end = t;
    cur.nadir = Math.min(cur.nadir, v);
  } else if (cur && t - cur.end >= 15 * 60) { lows.push(cur); cur = null; }
}
if (cur) lows.push(cur);

const hours = (rs[rs.length - 1][0] - rs[0][0]) / 3600;
const nights = dips.filter((d) => d.night);
const suspects = dips.filter((d) => d.night && !d.logged && d.nadir < lowMgdl);
console.log(`compression-low scan: ${hours.toFixed(0)} h, ${rs.length} readings; dips of ${minDrop}+ mg/dL at ${minRate}+ a minute that bounced back 2/3 within 20 min`);
console.log(`dips ${dips.length} (overnight ${nights.length}, overnight with nothing logged ${nights.filter((d) => !d.logged).length}); ` +
  `of those under ${lowMgdl}: ${dips.filter((d) => d.nadir < lowMgdl).length} (overnight, nothing logged: ${suspects.length})`);
for (const d of dips) {
  console.log(`dip   ${label(d.t)}  ${d.top}→${d.nadir} at ${d.rate.toFixed(1)}/min, back +${d.back}` +
    `${d.night ? "  overnight" : ""}${d.logged ? "  logged" : ""}${d.nadir < lowMgdl ? "  UNDER 70" : ""}`);
}
for (const l of lows) {
  const into = rs.filter((r) => r[0] < l.t && l.t - r[0] <= 15 * 60);
  const from = into.length ? into[0][1] : NaN;
  console.log(`low   ${label(l.t)}  from ${from} 15 min before, nadir ${l.nadir}, ${((l.end - l.t) / 60).toFixed(0)} min` +
    `${overnight(l.t) ? "  overnight" : ""}${logged(l.t - 30 * 60, l.end + 15 * 60) ? "  logged" : ""}` +
    `${dips.some((d) => d.t >= l.t && d.t <= l.end) ? "  bounced back like a compression low" : ""}`);
}
