// The share page's working-out, kept apart from the page so it's unit-tested (follow_test.js, run in
// CI with `deno test web/`). Each function is a port of the apps' own, named beside it, so the page
// and the apps say the same thing about the same readings:
//
// - `todaySoFar`, `todayText`: TodaySoFar.swift (the "Today so far" card, PR #105).
// - `chartSummary`: ChartSummary.swift (what VoiceOver says about a chart).
// - `chartReadings`: FollowChartCard.readings (the loaded readings with the card's newer ones on the end).
// - `logMarkers`: ChartLogMarker.logbook (insulin, food and wake-ups along the chart's bottom).
// - `monotonePath`: Swift Charts' `.monotone` interpolation, so the trace has the apps' shape.
//
// Readings are { t: seconds since 1970, mgdl }. Plain functions, no DOM.

export const MGDL_PER_MMOL = 18.0182;
export const STALE_AFTER = 6 * 60;

// ---- Ranges and units ----

/// GlucoseRange.classify.
export const classify = (mgdl, lo, hi) =>
  mgdl < 54 ? "urgentLow" : mgdl < lo ? "low" : mgdl > 250 ? "veryHigh" : mgdl > hi ? "high" : "inRange";

export const SPOKEN_RANGE = { urgentLow: "urgent low", low: "low", inRange: "in range", high: "high", veryHigh: "very high" };

export const fmt = (mgdl, unit) => unit === "mgdl" ? String(Math.round(mgdl)) : (mgdl / MGDL_PER_MMOL).toFixed(1);
export const unitLabel = (u) => u === "mgdl" ? "mg/dL" : "mmol/L";
export const spokenUnit = (u) => u === "mgdl" ? "milligrams per decilitre" : "millimoles per litre";
export const fmtDelta = (d, unit) => {
  const v = unit === "mgdl" ? Math.round(d) : Math.round((d / MGDL_PER_MMOL) * 10) / 10;
  return `${v > 0 ? "+" : v < 0 ? "−" : "±"}${unit === "mgdl" ? Math.abs(v) : Math.abs(v).toFixed(1)}`;
};
export const percent = (fraction) => `${Math.round(fraction * 100)}%`;

/// DayPatternText.clock: "2:30 pm", "noon", "midnight".
export function clock(minute) {
  const m = ((minute % 1440) + 1440) % 1440;
  if (m === 0) return "midnight";
  if (m === 720) return "noon";
  const h24 = Math.floor(m / 60), mm = m % 60, h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  const suffix = h24 < 12 ? "am" : "pm";
  return mm === 0 ? `${h12} ${suffix}` : `${h12}:${String(mm).padStart(2, "0")} ${suffix}`;
}

/// A moment's clock time, the same way.
export const clockAt = (t) => {
  const d = new Date(t * 1000);
  return clock(d.getHours() * 60 + d.getMinutes());
};

// ---- Today so far (TodaySoFar.swift) ----

export const TODAY = {
  bucketMinutes: 5, coverageMinutes: 15, minimumMinutes: 60, minimumCoverage: 0.5,
  lowMinimum: 15 * 60, lowMaxGap: 30 * 60, minimumDays: 5, rangeStep: 0.05, meanStepMgdl: 9,
  // The share function keeps 14 days (detailReadingDays in supabase/functions/share/detail.ts).
  windowDays: 14,
};

/// Local midnight `days` before the day `t` falls on. Calendar days, so a daylight-saving change
/// still lands on midnight.
export function midnight(t, days = 0) {
  const d = new Date(t * 1000);
  d.setHours(0, 0, 0, 0);
  if (days) d.setDate(d.getDate() - days);
  return d.getTime() / 1000;
}

const median = (values) => {
  const s = [...values].sort((a, b) => a - b);
  if (!s.length) return 0;
  const h = Math.floor(s.length / 2);
  return s.length % 2 ? s[h] : (s[h - 1] + s[h]) / 2;
};

/// Runs below `low` of 15 minutes or more; a gap of over 30 minutes ends a run. `points` are
/// [seconds, mg/dL] 5-minute buckets in time order.
export function lowRuns(points, low) {
  const size = TODAY.bucketMinutes * 60;
  let count = 0, start = null, lastLow = null;
  const close = (end) => {
    if (start !== null && end - start >= TODAY.lowMinimum) count += 1;
    start = null; lastLow = null;
  };
  for (const [t, mgdl] of points) {
    if (lastLow !== null && t - lastLow > TODAY.lowMaxGap) close(lastLow + size);
    if (mgdl < low) {
      if (start === null) start = t;
      lastLow = t;
    } else if (start !== null) {
      close(t);
    }
  }
  if (lastLow !== null) close(lastLow + size);
  return count;
}

/// One day's figures from `start` over `span` seconds, or null when under half of it has readings.
export function dayFigures(readings, start, span, low, high) {
  const end = start + span, size = TODAY.bucketMinutes * 60;
  const buckets = new Map();
  for (const r of readings) {
    if (r.t < start || r.t > end) continue;
    const key = Math.floor((r.t - start) / size);
    const b = buckets.get(key) ?? { sum: 0, n: 0 };
    b.sum += r.mgdl; b.n += 1;
    buckets.set(key, b);
  }
  // Coverage in 15-minute slots, so LibreLinkUp's 15-minute history counts as complete.
  const possible = Math.max(1, Math.ceil(span / (TODAY.coverageMinutes * 60)));
  const filled = new Set([...buckets.keys()].map((k) => Math.floor((k * TODAY.bucketMinutes) / TODAY.coverageMinutes))).size;
  if (!buckets.size || filled < TODAY.minimumCoverage * possible) return null;
  const ordered = [...buckets.keys()].sort((a, b) => a - b).map((k) => [start + k * size, buckets.get(k).sum / buckets.get(k).n]);
  const inRange = ordered.filter(([, v]) => v >= low && v <= high).length;
  const mean = ordered.reduce((s, [, v]) => s + v, 0) / ordered.length;
  return { timeInRange: inRange / ordered.length, meanMgdl: mean, lows: lowRuns(ordered, low) };
}

/// Today from local midnight to the newest reading, beside the same hours on the usual day (the
/// median of the earlier days that have enough readings). Null when there's nothing to say yet.
export function todaySoFar(readings, low, high, now) {
  const todayStart = midnight(now);
  let newest = null;
  for (let i = readings.length - 1; i >= 0; i--) {
    if (readings[i].t <= now && readings[i].mgdl > 0) { newest = readings[i]; break; }
  }
  if (!newest || newest.t < todayStart) return null;
  const elapsed = newest.t - todayStart;
  if (elapsed < TODAY.minimumMinutes * 60) return null;
  const windowStart = midnight(now, TODAY.windowDays);
  const recent = readings.filter((r) => r.t >= windowStart && r.t <= newest.t && r.mgdl > 0);
  const today = dayFigures(recent, todayStart, elapsed, low, high);
  if (!today) return null;
  const days = [];
  for (let k = 1; k <= TODAY.windowDays; k++) {
    const f = dayFigures(recent, midnight(now, k), elapsed, low, high);
    if (f) days.push(f);
  }
  const usual = days.length >= TODAY.minimumDays
    ? {
      timeInRange: median(days.map((d) => d.timeInRange)),
      meanMgdl: median(days.map((d) => d.meanMgdl)),
      daysWithLows: days.filter((d) => d.lows > 0).length,
      days: days.length,
    }
    : null;
  return { minute: Math.floor(elapsed / 60), today, usual, windowDays: TODAY.windowDays };
}

export function rangeChange(t) {
  if (!t.usual) return null;
  const d = t.today.timeInRange - t.usual.timeInRange;
  return Math.abs(d) < TODAY.rangeStep ? "same" : d > 0 ? "better" : "worse";
}

/// The card's words (TodaySoFarText), for someone else's day: "than usual" rather than "your usual day".
export function todayText(t, unit) {
  const change = rangeChange(t);
  const headline = change === "better" ? "More time in range than usual by now."
    : change === "worse" ? "Less time in range than usual by now."
    : change === "same" ? "About a usual day by now."
    : `${percent(t.today.timeInRange)} of today in range so far.`;
  const u = t.usual;
  const lowsCaption = !u ? null : u.daysWithLows === 0 ? "Usually none by now" : `${u.daysWithLows} of ${u.days} days by now`;
  const footnote = u
    ? `Compared with the same hours on ${u.days} of the last ${t.windowDays} days. Observations, not advice.`
    : `Their usual day joins in once there are ${TODAY.minimumDays} days with readings over these hours.`;
  // Spoken: a few sentences, as TodaySoFarText.spoken.
  const label = unitLabel(unit);
  const parts = [`Today so far, midnight to ${clock(Math.floor(t.minute / 5) * 5)}`, headline.slice(0, -1)];
  const rangeNow = `${Math.round(t.today.timeInRange * 100)} percent in range`;
  if (u) {
    parts.push(`${rangeNow}, usually ${Math.round(u.timeInRange * 100)} percent`);
    parts.push(`Average ${fmt(t.today.meanMgdl, unit)} ${label}, usually ${fmt(u.meanMgdl, unit)}`);
  } else {
    parts.push(rangeNow);
    parts.push(`Average ${fmt(t.today.meanMgdl, unit)} ${label}`);
  }
  const n = t.today.lows;
  let lowLine = n === 0 ? "No lows" : n === 1 ? "1 low" : `${n} lows`;
  if (u) lowLine += u.daysWithLows === 0 ? ", and usually none by now" : `. ${u.daysWithLows} of the last ${u.days} days had one by this time`;
  parts.push(lowLine);
  return {
    period: `Midnight to ${clock(Math.floor(t.minute / 5) * 5)}`,
    headline,
    range: percent(t.today.timeInRange), rangeCaption: u ? `Usually ${percent(u.timeInRange)}` : null,
    mean: fmt(t.today.meanMgdl, unit), meanCaption: u ? `Usually ${fmt(u.meanMgdl, unit)}` : null,
    lows: n === 0 ? "None" : String(n), lowsCaption,
    footnote,
    spoken: parts.join(". ") + ".",
  };
}

// ---- Chart data ----

/// The card's 3 hours as readings: one per 5-minute slot, ending at the reading.
export function cardReadings(card) {
  const n = card.history.length;
  return card.history.map((v, i) => v === null ? null : { t: card.readingAt - (n - 1 - i) * 300, mgdl: v }).filter(Boolean);
}

/// The loaded readings of the last `hours`, with the card's newer ones on the end (the card can be a
/// minute or so ahead of the last bucket). Just the card's before anything loads.
export function chartReadings(card, loaded, hours, now) {
  const fromCard = cardReadings(card);
  if (!loaded || !loaded.length) return fromCard;
  const since = Math.max(now, card.readingAt) - hours * 3600 - 15 * 60;
  const out = loaded.filter((r) => r.t >= since);
  const last = out.length ? out[out.length - 1].t : -Infinity;
  for (const r of fromCard) if (r.t > last + 60) out.push(r);
  const newest = out.length ? out[out.length - 1].t : -Infinity;
  if (newest < card.readingAt - 60) out.push({ t: card.readingAt, mgdl: card.mgdl });
  return out;
}

/// New buckets from GET /v1/detail into what's loaded. The response starts at `since`, and its first
/// bucket can replace a partial one that's already here.
export function mergeReadings(loaded, incoming, since) {
  const kept = loaded.filter((r) => r.t < since);
  const added = incoming.map(([t, mgdl]) => ({ t, mgdl }));
  return kept.concat(added).sort((a, b) => a.t - b.t);
}

/// Where to ask from next time: the start of the newest bucket, which may still fill up.
export const nextSince = (loaded) => loaded.length ? Math.floor(loaded[loaded.length - 1].t / 300) * 300 : null;

// ---- Logged markers (ChartLogMarker.logbook) ----

const unitsWords = (u) => {
  const v = Math.round(u * 100) / 100;
  return `${v} ${v === 1 ? "unit" : "units"}`;
};
const KIND_TITLES = {
  rapid: "Rapid-acting", ultraRapid: "Ultra-rapid", short: "Short-acting", intermediate: "Intermediate",
  long: "Long-acting", premixed: "Premixed",
};

/// Insulin, food and wake-ups since `since`, each with its lane (from the bottom) and a spoken label.
/// Only what was taken and eaten: notes and food descriptions are never shown (the share function
/// blanks notes anyway).
export function logMarkers(logbook, since) {
  if (!Array.isArray(logbook)) return [];
  const out = [];
  for (const e of logbook) {
    const p = e && e.payload;
    if (!p || typeof p.timestamp !== "number" || p.timestamp < since) continue;
    const at = clockAt(p.timestamp);
    if (e.kind === "dose" && typeof p.units === "number") {
      const name = typeof p.name === "string" && p.name ? p.name : KIND_TITLES[p.kind] ?? "insulin";
      out.push({ id: e.id, t: p.timestamp, kind: "insulin", lane: 0, label: `${unitsWords(p.units)} ${name} at ${at}` });
    } else if (e.kind === "meal") {
      const carbs = typeof p.carbs === "number" ? p.carbs : 0;
      out.push({ id: e.id, t: p.timestamp, kind: "food", lane: 1, label: carbs > 0 ? `${Math.round(carbs)} g carbs at ${at}` : `Food at ${at}` });
    } else if (e.kind === "context" && Array.isArray(p.tags) && p.tags.includes("wokeUp")) {
      out.push({ id: e.id, t: p.timestamp, kind: "wake", lane: 2, label: `Woke up at ${at}` });
    }
  }
  return out.sort((a, b) => a.t - b.t);
}

// ---- Chart summary (ChartSummary.swift) ----

/// Stretches of consecutive readings that meet `test`.
export function episodes(readings, test) {
  let count = 0, inside = false;
  for (const r of readings) {
    const hit = test(r);
    if (hit && !inside) count += 1;
    inside = hit;
  }
  return count;
}

const times = (n) => n === 1 ? "once" : n === 2 ? "twice" : `${n} times`;

/// What the chart shows, in a few spoken sentences: the period, now, lowest and highest, time in
/// range, how often it left the range, where the forecast ends, and how much is logged. A stale
/// chart says so first and never states a forecast.
export function chartSummary({ readings, lowMgdl, highMgdl, unit, hours, stale, forecastEnd, loggedCount }) {
  const rs = [...readings].sort((a, b) => a.t - b.t);
  const period = `Last ${hours === 1 ? "hour" : `${hours} hours`}`;
  const last = rs[rs.length - 1];
  if (!last) return `${period}. No readings.`;
  const parts = [period];
  parts.push(stale ? `Stale: the last reading was ${fmt(last.mgdl, unit)}`
    : `Now ${fmt(last.mgdl, unit)}, ${SPOKEN_RANGE[classify(last.mgdl, lowMgdl, highMgdl)]}`);
  if (rs.length > 1) {
    const lo = Math.min(...rs.map((r) => r.mgdl)), hi = Math.max(...rs.map((r) => r.mgdl));
    parts.push(`Lowest ${fmt(lo, unit)}, highest ${fmt(hi, unit)}`);
  }
  const inRange = rs.filter((r) => r.mgdl >= lowMgdl && r.mgdl <= highMgdl).length;
  parts.push(`${Math.round((inRange / rs.length) * 100)} percent in range`);
  const lows = episodes(rs, (r) => r.mgdl < lowMgdl), highs = episodes(rs, (r) => r.mgdl > highMgdl);
  const ex = [];
  if (lows) ex.push(`below range ${times(lows)}`);
  if (highs) ex.push(`above range ${times(highs)}`);
  if (ex.length) parts.push(`Went ${ex.join(" and ")}`);
  if (!stale && forecastEnd && forecastEnd.t > last.t) {
    const minutes = Math.max(5, Math.round((forecastEnd.t - last.t) / 300) * 5);
    parts.push(`Forecast, not a reading: about ${fmt(forecastEnd.mgdl, unit)} in ${minutes} minutes`);
  }
  if (loggedCount > 0) parts.push(loggedCount === 1 ? "1 entry logged" : `${loggedCount} entries logged`);
  return parts.join(". ") + ".";
}

// ---- Drawing helpers ----

/// Splits readings where more than `maxGap` seconds pass between two, so a gap stays a gap.
export function segments(readings, maxGap = 16 * 60) {
  const out = [];
  let cur = [];
  for (const r of readings) {
    if (cur.length && r.t - cur[cur.length - 1].t > maxGap) { out.push(cur); cur = []; }
    cur.push(r);
  }
  if (cur.length) out.push(cur);
  return out;
}

/// An SVG path through [x, y] points with monotone cubic interpolation (Fritsch–Carlson, as Swift
/// Charts' `.monotone`): smooth, and never overshooting between two readings.
export function monotonePath(pts) {
  const n = pts.length;
  if (!n) return "";
  const f = (v) => Math.round(v * 100) / 100;
  if (n === 1) return `M${f(pts[0][0])},${f(pts[0][1])}`;
  if (n === 2) return `M${f(pts[0][0])},${f(pts[0][1])}L${f(pts[1][0])},${f(pts[1][1])}`;
  const dx = [], s = [], m = new Array(n);
  for (let i = 0; i < n - 1; i++) {
    dx[i] = pts[i + 1][0] - pts[i][0];
    s[i] = dx[i] === 0 ? 0 : (pts[i + 1][1] - pts[i][1]) / dx[i];
  }
  m[0] = s[0]; m[n - 1] = s[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = s[i - 1] * s[i] <= 0 ? 0 : (s[i - 1] + s[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (s[i] === 0) { m[i] = 0; m[i + 1] = 0; continue; }
    const a = m[i] / s[i], b = m[i + 1] / s[i], h = a * a + b * b;
    if (h > 9) { const k = 3 / Math.sqrt(h); m[i] = k * a * s[i]; m[i + 1] = k * b * s[i]; }
  }
  let d = `M${f(pts[0][0])},${f(pts[0][1])}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = pts[i], [x1, y1] = pts[i + 1], h = dx[i] / 3;
    d += `C${f(x0 + h)},${f(y0 + m[i] * h)} ${f(x1 - h)},${f(y1 - m[i + 1] * h)} ${f(x1)},${f(y1)}`;
  }
  return d;
}

/// Nice glucose axis values in the person's units between two mg/dL bounds, about four of them.
export function yTicks(loMgdl, hiMgdl, unit) {
  const k = unit === "mgdl" ? 1 : 1 / MGDL_PER_MMOL;
  const lo = loMgdl * k, hi = hiMgdl * k;
  const steps = unit === "mgdl" ? [25, 50, 100, 200] : [1, 2, 4, 5, 10];
  const step = steps.find((s) => (hi - lo) / s <= 4.5) ?? steps[steps.length - 1];
  const out = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) out.push(v / k);
  return out;
}

/// The nearest reading to `t` within 10 minutes, or null over a gap: only real readings are read
/// out, never a value between two.
export function nearest(readings, t) {
  let best = null;
  for (const r of readings) if (!best || Math.abs(r.t - t) < Math.abs(best.t - t)) best = r;
  return best && Math.abs(best.t - t) <= 600 ? best : null;
}

/// The reading before `r`, when it's close enough (15 minutes) for a change to mean something.
export function previous(readings, r) {
  let prev = null;
  for (const x of readings) if (x.t < r.t) prev = x;
  return prev && r.t - prev.t <= 900 ? prev : null;
}
