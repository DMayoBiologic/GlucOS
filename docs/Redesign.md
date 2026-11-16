# GlucOS redesign: "Signal"

Status: adopted 2026-11-14. This is the design for the next generation of every GlucOS surface: the
iPhone Live Activity first, then the iPhone app, the Mac menu bar popover and dashboard, and the
widgets. It builds on the design system in `docs/DesignSystem.md` (tokens, `Tone`, surfaces) and
the motion pieces from PR #49 (`Sources/Shared/DesignSystem/Motion.swift`). Where this document and
`DesignSystem.md` disagree, this one wins and `DesignSystem.md` should be updated to match.

Contents

1. Why a redesign
2. Principles
3. The visual language
4. The motion language
5. Signature components
6. The Live Activity (the most important surface)
7. iPhone app, screen by screen
8. Mac app, surface by surface
9. Widgets
10. Accessibility
11. Delivery plan and what shipped when

---

## 1. Why a redesign

GlucOS already gets the rules right: one hue per range, stale is never reassuring, forecasts are grey
and marked "≈". What it lacks is a strong, recognisable shape. Every surface is a stack of similar
cards, the reading is a number on a tinted rectangle, and nearly all motion is a cross-fade. The
redesign keeps every safety rule and changes three things:

- **The reading becomes a place, not a card.** On the iPhone home, the Mac popover and the dashboard
  overview, the current reading sits on a full-bleed *range field*: living colour that says "how am I
  doing" before the number is read.
- **Position and direction become shapes.** A *range rail* shows where the value sits between urgent
  low and very high, and a *trend needle* swings to the direction of travel. Both move when a reading
  arrives, so change is something you see, not something you compare.
- **Freshness becomes visible.** A *freshness meter* fills from the moment of the reading to the
  moment it goes stale. You no longer read "2 min ago"; you see how much of the reading's life is
  left. It runs live in widgets and the Live Activity without any update.

## 2. Principles

1. **Glance first.** Every surface answers, in order: what is it, where is it going, how fresh is it.
   Anything else is one level down.
2. **Safety rules are non-negotiable.** Stale is grey and crossed through. Forecasts are grey, dashed
   and "≈". Urgent states are never hidden behind motion, and never depend on colour alone (each has a
   symbol and words).
3. **Motion explains change.** Something moves only because something changed: a new reading, a
   range crossed, a trend turned. Nothing loops for decoration. The range field drifts for a few
   seconds when a screen opens or the colour changes, then holds; the live dot, the trace's end ring
   and the rapid halo beat once every few seconds rather than looping (§4.6).
4. **Honest precision.** Times to a forecast event are rounded to 5 minutes and marked "≈". No
   ticking countdown to a predicted low (false precision); the reading's own age may tick.
5. **Still is a first-class state.** Every component renders a correct, complete frame with no
   animation: Reduce Motion, widgets, the Live Activity, screenshots, Always On.
6. **One system.** A component is built once in `Sources/Shared` and used on Mac, iPhone, widgets and
   the Live Activity, at different sizes.

## 3. The visual language

### 3.1 Colour

The range hues stay (Palette `crimson`, `coral`, `mint`, `amber`, `magenta`, plus `stale`). New rules:

| Use | Rule |
| --- | --- |
| Range field (hero backgrounds) | The range hue at 22–38 % on dark, 14–26 % on light, as a 3×3 mesh with two lighter and one deeper node. Stale: `Palette.stale` at 16 %, no drift. |
| Big value | In range: primary text colour (calm). Out of range: the range hue. Stale: secondary grey, struck through. Unchanged from today. |
| Rail segments | Each range's hue at 55 % with the in-range segment at 80 %, so the target reads as the "home" segment. |
| Forecast | `Palette.stale` grey, dashed, everywhere. A predicted low is the only forecast element that may use colour, and only as a warning triangle (amber), never the line. |
| Urgent low | Crimson field at 38 %, the value in crimson, and a 2 pt crimson inner border on the hero (so it reads without colour vision too, together with the octagon symbol and "Urgent low"). |

### 3.2 Type

| Role | Spec |
| --- | --- |
| Stage value (iPhone home) | SF Rounded Bold 96 pt, tabular, scales at 40 % of Text Size |
| Hero value (popover, dashboard) | SF Rounded Bold 56/64 pt, unchanged rates |
| Live Activity lock screen value | SF Rounded Bold 52 pt |
| Dynamic Island expanded value | SF Rounded Bold 44 pt |
| Compact / minimal | SF Rounded Heavy, body / caption |
| Eyebrows | `.dsFont(.eyebrow)` uppercase, tracking 0.6 |

Numbers always roll (`.contentTransition(.numericText(value:))`).

### 3.3 Shape and depth

- Heroes lose their card outline on iPhone: the range field bleeds to the top edge under the
  navigation bar. Cards below keep `DS.Radius.card` and `.dsCard`.
- The rail is a 6 pt capsule (4 pt in widgets, 3 pt in the Live Activity), the marker a 12 pt dot with
  a 2 pt surface-coloured ring so it reads on any segment.
- The needle is a filled arrow in a 1.5 pt ring, replacing the old `TrendDial` symbol in a circle.

## 4. The motion language

All motion goes through `DSMotion` (Reduce Motion aware). Two curves are added:

| Token | Curve | Use |
| --- | --- | --- |
| `.quick` | snappy 0.15 s | presses, hovers |
| `.standard` | smooth 0.3 s | state changes |
| `.emphasized` | spring 0.5 / 0.78 | values settling |
| `.ambient` | smooth 0.6 s | colour and glow |
| **`.arrival`** (new) | spring response 0.7, damping 0.72 | a new reading: needle swing, rail marker glide |
| **`.sweep`** (new) | smooth 0.9 s | a range change: the field's colour sweeping across |

### 4.1 Choreography of a new reading ("arrival")

At t = 0 the number rolls to its new value (numeric text), the needle swings to its new angle
(`.arrival`), the rail marker glides (`.arrival`), and the freshness meter resets to empty (it then
refills on its own). At t = 0–0.9 s one soft ripple leaves the hero (existing `readingRipple`). The
chart's trace extends and its end dot pulses once (existing `TracePulse`).

The main glucose chart (`GlucoseChart`, iPhone home, follower view, Mac popover and Outlook) sets
both axes itself (`ChartSpan`) and animates the axes, not the data. A new reading slides the
time axis along by one reading in one `.standard` movement, and the oldest reading slides off the
left edge (a 10-minute lead stays plotted past it, masked) instead of vanishing inside the chart.
Changing 3h / 6h / 12h / 24h is three steps (`ChartSpanTransition`): plot what both spans need
(the extra readings are off the left edge, unseen), spring the time and glucose axes together in
one `.emphasized` movement (`GlucoseChart.spanSpring`), then drop what's off screen once it has
settled. So the marks already on screen stretch or squeeze to the new scale instead of fading out
and in. Under Reduce Motion nothing moves: the old span cross-fades into the new one in 0.25 s.
iPhone Today and the Mac popover both offer 3h / 6h / 12h / 24h, by the control, by pinching the
chart (a 1.4× spread or pinch per step, `ChartHours.pinched`), and on the Mac by ⌘1–⌘4 or
⌘+ / ⌘−. The choice is stored (`AppSettings.chartHours`), so the chart opens on it next time.
Nothing repeats: one movement per reading, tap or pinch step (§4.6).

The Mac dashboard's Overview chart (`TrendChart`) does the same from 3 hours to 30 days, with the
axis ending at the period's end (`PeriodSpan`) rather than at the newest reading. While the range
changes the trace keeps the detail it had when the move began (only readings off screen are
thinned for the wider span), so its shape holds through the glide and it's redrawn at the new
range's detail once, at the end. A new reading, or a live period's end moving on to the next
5 minutes, slides it along. It scrolls only while zoomed, and a new range starts unzoomed. Moving
to another stretch of time (⌘[ / ⌘]) still wipes in (§8.3).

### 4.2 Range change ("sweep")

When the range changes, the range field's colour sweeps (`.sweep`) and the range pill swaps with a
push transition in the direction of travel (up for rising into high, down for falling into low). On
iPhone, crossing into low plays a `.warning` haptic and back into range `.success` (rule 7, unchanged).

### 4.3 Stale

When data goes stale the field desaturates to grey (`.ambient`), the strike line draws across the
value left to right (0.35 s, a trim), the needle fades to a question mark, the meter turns amber and
stays full. Reversed when data returns.

The number fades to grey on `.sweep` as the line draws, and the trend line, needle, rail and pill
fade over with it, everywhere a reading is shown: the iPhone hero and follower cards, the Mac
popover, the menu bar item, the Live Activity in every presentation, and the Home Screen widget
between timeline entries. `.staleStrike` keeps no state, so the same modifier animates between two
Live Activity states or widget entries. The Mac popover redraws at the exact stale moment
(`TimelineView(.explicit)`), and the menu bar item plays it as a one-off run of frames
(`MenuBarGlance.Change`: `.goingStale`, `.comingBack`, `.firstReading`). The first reading after
waiting (a sensor warming up, a new sign-in) fades in over the placeholder. Under Reduce Motion
nothing travels: the colour and the whole line cross-fade in 0.25 s. Nothing loops (§4.6).

### 4.4 Ambient field drift

The range field's mesh nodes drift on a 14 s loop, at most 6 % of the field's size. Only on app
screens the user is looking at, only while data is fresh, and never under Reduce Motion or Low Power
Mode. Rapid trends speed the drift up to a 9 s loop, a cue that something is moving fast. The drift
plays for 12 s when the field appears, when its colour or pace changes and when the app comes back
to the front, then holds its last shape (`MeshField.driftFor`): a screen left open must not redraw
20 times a second for hours.

### 4.6 Power

Nothing on screen animates without end. A continuous animation keeps SwiftUI redrawing every frame
(120 a second on ProMotion) and stops the display dropping to its low-power refresh rate, which is
what made the apps drain batteries before this was fixed (November 2026). Breathing pulses (`LiveDot`, the chart's end ring,
`RapidHalo`) are one beat on a `PulseBeat` clock: 6 s for the dot and ring, 3.5 s for the rapid halo,
hidden between beats. Clocks that only change text tick with `TimelineView(.periodic)`.

### 4.5 Navigation

- iPhone pushes from a card to its full screen use the zoom transition (iOS 18
  `.navigationTransition(.zoom)`) from the card, so the card grows into the screen.
- Chips (hours, filters) slide their selection indicator between options (matched geometry).
- Cards assemble top to bottom on first appearance (`dsEntrance`, existing).

### 4.6 Inside widgets and the Live Activity

WidgetKit and ActivityKit animate between two rendered states only, for at most 2 seconds, and run
no timers or `onAppear`. So: every component's still frame is complete; changes between updates use
`.contentTransition` and `.animation(_:value:)` (honoured by the system between states); and
anything that must move on its own uses the system's live views: `ProgressView(timerInterval:)` for
the freshness meter and `Text(timerInterval:)` for the reading's age. The ambient drift and ripples
never appear there.

### 4.7 Cold launch (the saved reading)

The apps never open on a blank card or a spinner when they have a reading saved. On a cold launch
the store starts from the snapshot saved before (`SharedStore`), so iPhone Today, its collapsed
title and the Mac popover (opened before the first fetch lands) show that reading at once: the
figure, trend, needle and rail at half opacity, the age line reading "Last reading 3 min ago"
with a still clock in place of the live dot, and no refresh spinner (`LaunchReading`,
`LaunchHandover.swift`). VoiceOver adds "Saved reading, checking for a newer one". When this
launch's first fetch lands (`GlucoseStore.fetchedThisLaunch`), the figure cross-fades to the live
value once on `.sweep` (`LaunchFigure`) instead of rolling its digits, the rest brightens in the
same fade, and the new-reading ripple is skipped. Nothing repeats (§4.6); under Reduce Motion it
just changes. A saved reading that is already stale keeps the stale look (§4.3) and isn't dimmed on
top; a sensor warming up shows its countdown instead. A failed first fetch leaves the saved reading
dimmed under the connection notice until a fetch succeeds or it goes stale. Coming back from the
background is not a launch: the reading there is the live one, or stale.

## 5. Signature components

All in `Sources/Shared/DesignSystem/Signal.swift` (the needle is `TrendDial` in `Theme.swift`), compiled
into every target.

### 5.1 `RangeField`

Background view. Inputs: `tone`, `rapid: Bool`, `live: Bool` (drift allowed). iOS 18 / macOS 15:
`MeshGradient` 3×3 with the tone colour at three opacities; drifting through `TimelineView(.animation)`
when `live`, not Reduce Motion and not Low Power. Earlier macOS: the existing `AmbientGlow`. Under
Reduce Transparency: a flat wash at the middle opacity.

### 5.2 Trend needle (`TrendDial`)

`TrendDial` (Theme.swift) is redrawn as the needle. An arrow (`arrow.right`, heavy) rotated to the trend's
angle (−90° rising quickly … +90° falling quickly) inside a ring; rapid trends draw a second, ghosted
arrow behind it (a chevron "trail") and keep the existing `RapidHalo`. Unknown or stale: a question
mark. Rotation animates with `.arrival`, which also works between Live Activity states.

The turn is shared as `.trendTurn(_:)` (Signal.swift), used by `TrendDial` and `TrendArrow`: one
short `.arrival` spring to the new angle, never repeated. Under Reduce Motion the arrow doesn't
travel; the old direction cross-fades into the new one over 0.25 s. VoiceOver hears "Trend now
rising" once per change (`TrendTurn.announcement`), from the iPhone Today hero and, on the Mac, from
the menu bar item only, so an open popover doesn't repeat it. Round 39.

### 5.3 `RangeRail`

A horizontal capsule split into five segments sized on a scale from 40 to 300 mg/dL (clamped):
urgent low (< 54), low (< your low), in range, high (> your high), very high (> 250). A marker sits at
the reading, glides with `.arrival`, and takes the range's hue (grey and hollow when stale). An
optional ghost marker (hollow, grey, dashed ring) sits at the forecast's end value, with "≈" in
accessibility. VoiceOver: one element, "Reading 6.2, in range, between 3.9 and 10.0".

### 5.4 `FreshnessMeter`

A thin capsule (or ring) filling from the reading time to the stale time
(`GlucoseSnapshot.staleAfter`, 6 minutes). Uses `ProgressView(timerInterval:countsDown: false)`, so
it fills live on the Lock Screen and in widgets with no updates. Neutral while fresh, amber once
stale (when the view is next drawn as stale it is drawn full and amber). Paired with a count-up age
label, `Text(timerInterval:)` "0:42", in tabular digits.

### 5.5 `ForecastNote`

The one-line forecast: "≈ 6.8 in 30 min", or "Low ≈ 20 min" with an amber triangle. Rounds times to
5 minutes. Grey except the triangle. Shared by the Live Activity, widgets, popover and iPhone hero.

## 6. The Live Activity

The Live Activity is GlucOS's most important surface: it is what people actually look at, dozens of
times a day, mostly without unlocking. It gets the deepest treatment.

### 6.1 Jobs, in priority order

1. Show the current value, in its range's colour, readable at arm's length.
2. Show direction (trend) and speed (delta).
3. Make freshness unmistakable, and staleness impossible to miss.
4. Warn about a predicted low before it happens.
5. Show the shape of the last 3 hours and the next hour.
6. Offer one action: Log (owner only).

### 6.2 Presentations

**Lock Screen (and banner on devices without the Dynamic Island).** Height ≤ 160 pt.

```
┌──────────────────────────────────────────────────────┐
│ ● In range · for 2 h 10 m               ⟳ 0:42  ▁▁▁▁ │  status row: pill, streak, age, meter
│                                                      │
│  6.2  ↗︎ (needle)      ╭──────── sparkline ───────╮   │  value + needle | 3 h trace + ≈ 1 h
│  mmol/L · +0.2         ╰─── target band, now dot ──╯   │
│  ━━━━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━  (range rail)     │
│  ≈ 6.8 in 30 min        1.2 u on board          Log  │  forecast note | IOB | log
└──────────────────────────────────────────────────────┘
```

- Background: `activityBackgroundTint` is the range hue darkened (in range: near-black with 30 % mint;
  out of range: 45 % hue; urgent low 60 % crimson; stale: system grey). The card's own gradient sits on
  top, so StandBy (which drops the tint) still has colour.
- A predicted low replaces the forecast note with an amber strip: "⚠︎ Low ≈ 20 min · treat early?".
- Stale: whole card desaturates, value struck through, needle "?", meter full and amber, status row
  reads "No reading for 9 min" (count-up timer), the sparkline keeps its shape in grey.
- Follower card: the status row leads with the person's name and a person symbol, no Log button.

**Dynamic Island, compact.** Leading: value in the range hue (struck through when stale). Trailing:
trend arrow, then delta in small type when it fits ("↗ +0.2"); stale: `clock.badge.exclamationmark`.
`keylineTint` is the range hue so the island's outline glows the range colour.

**Dynamic Island, minimal** (when another activity shares the island). The value alone, in the range
hue, scaled to fit. Stale: the value in grey with a 1 pt strike.

**Dynamic Island, expanded** (long-press, or when an update alerts).

```
 leading:  6.2  mmol/L            trailing: needle 44 pt, +0.2
 center:   In range · for 2 h                     (person on follower cards)
 bottom:   sparkline 56 pt with target band and ≈ forecast
           rail ━━━━━●━━━━   ≈ 6.8 in 30 min · 1.2 u · 0:42   [Log]
```

**StandBy.** The Lock Screen view scaled ×2 by the system, background tint removed. Ours keeps an
internal gradient so it isn't a black card; text stays legible on black; in Night Mode the system
tints everything red, which our design survives because nothing depends on hue alone.

**Apple Watch Smart Stack and CarPlay (iOS 18+, `.supplementalActivityFamilies([.small])`).** A
small layout read from `\.activityFamily == .small`:

```
 6.2 ↗︎   +0.2
 ━━━━━━●━━━━  (rail)
 In range · 0:42
```

While there's a check-in (the owner has someone waiting; a follower's person is low or heading low,
or there's a check-in on the card) the rail and status row give way to it, and the age moves up:

```
 3.4 ↘︎        0:42
 ✋ Sam checking in
 [ ✓ I'm okay ][ Help ]
```

On the watch's Always On (`isLuminanceReduced`) the field and rail dim to 50 % and the value turns
white unless out of range. Without the small family the watch would show only the compact views.

### 6.3 Data and freshness

- `GlucoseActivityState` keeps its shape (the relay must stay in step; RelayParityTests). The new
  design needs no new fields: rail, needle and forecast note derive from `mgdl`, thresholds, `trend`,
  `forecast` and `lowExpectedAt`.
- The stale date stays `readingAt + 6 min`; ActivityKit re-renders the card as stale at that moment
  with no push.
- The freshness meter and age timer run live from `readingAt` to `staleDate`.

### 6.4 Update cadence and reliability (relay)

LibreLinkUp gives a reading a minute and the relay ticks every minute. Today an in-range card that
hasn't changed range is pushed at APNs priority 5, which iOS may hold back to save power; that is
how a card can sit minutes behind the phone. New policy, in `cardPriority` (relay `engine.ts`):

| Situation | Priority |
| --- | --- |
| An alert fired this tick, the range changed, or the reading is out of range | 10 |
| The displayed value or trend changed and the last priority-10 push was ≥ 2 min ago | 10 |
| Nothing visible changed for 3 min (the card is approaching its stale date) | 10 |
| Otherwise (history-only change, or the value changed again within 2 min of a priority-10 push) | 5 |

That bounds priority 10 to about one push every 2 minutes in range (the frequent-updates budget
allows far more) while making sure a card is never more than ~3 minutes behind, well inside the
6-minute stale date. The 10-minute heartbeat remains.

Other reliability rules (unchanged, from PR #47): one card, retired ids never re-adopted, the phone
reports its current activity and token on every sync, the relay rotates the card before iOS's 8-hour
limit.

**No alert on Live Activity updates.** An ActivityKit alert would expand the island and light the
screen, but GlucOS already sends a real notification for every alert (with critical sound where
allowed), and both together double the sound and the banner. The notification stays the alert; the
card shows the state.

### 6.5 Motion inside the Live Activity

Between two states (a push or an app update), the system animates for up to 2 seconds:

- value: counts over to the new number (`.numericText(value:)` on the `.arrival` spring) and
  cross-fades to its range colour (`.sweep`), on the Lock Screen card, every Dynamic Island view, the
  Watch and CarPlay card and the Lock Screen accessories (`readingChange` in `Signal.swift`);
- needle: rotation with `.arrival` spring; where the dial doesn't fit (island compact, small card,
  accessories) one arrow (`TrendArrow`) turns to the trend's `needleAngle` instead of swapping
  glyphs;
- rail marker: position with `.arrival`;
- range pill: push transition;
- background tint: cross-fade;
- sparkline: the trace re-renders (Swift Charts cross-fades in place).

Live without updates: freshness meter and age timer. Under Reduce Motion the system and our
`dsAnimation` both drop movement and keep cross-fades: figures fade in place (0.25 s) and arrows
turn at once. Every animation runs once on a changed value and settles in about a second, well
inside ActivityKit's 2 seconds; none repeats (see the power audit, #94).

### 6.6 Accessibility

One element per presentation with a full sentence: "Glucose 6.2 millimoles per litre, in range,
rising, up 0.2, 1 minute ago. Forecast about 6.8 in 30 minutes." Stale: "Glucose reading is 9 minutes
old, last 6.2." Follower: prefixed with the person's name.

## 7. iPhone app

### 7.1 Home ("Now")

- **Stage**, replacing the hero card: the range field bleeds from the top of the screen behind a
  transparent navigation bar. On it: range pill and streak, the 96 pt value with unit, the needle
  (80 pt), delta and trend words, the range rail with forecast ghost marker, the forecast note, and the
  freshness meter with age. New readings play the arrival choreography; range changes sweep; crossing
  into low/back to range plays haptics. The value uses the Live Activity's `.readingChange`: its digits
  roll over to each new reading on `.arrival`, its colour cross-fades across a range edge on `.sweep`,
  and the trend row's `TrendArrow` turns rather than swapping glyphs (the needle already swings). Each
  plays once per change; under Reduce Motion the number just changes; VoiceOver reads only the new
  reading. The collapsed title's value and arrow do the same. Since round 23 a reading crossing a
  range edge moves figure and colour together on `.sweep` (`ReadingRoll`), on the Mac popover too.
- **Collapsing header.** Scrolling up shrinks the stage; once its value scrolls under the navigation
  bar, the bar's title becomes the value and trend arrow in the range colour (iOS 18
  `onScrollGeometryChange`), so the reading is never off screen.
- Below the stage, unchanged order: banners, follows, On board, Chart, Logbook, Insights row, Sensor.
- **Chart card**: hour chips with a sliding selection; the chart's axes glide to the new span when
  hours change (§4.1). The forecast draws in from "Now" once the card has come in (0.4 s,
  `PhoneChartCard.forecastDelay`) and bends into each new forecast, with the same `ForecastMotion`
  as the Mac popover (§8.2): `.sweep` draw-in, `.ambient` morph, once per appearance or forecast,
  never looping. Under Reduce Motion it just changes. Widgets and follower cards are unchanged.
- **Last logged line** (round 38, `LastLogged`): under the chart's legend, "Meal 1 h 40 m ago · 45 g"
  or "Dose 25 m ago · 4 u", the newest entry logged in the last 12 hours, hidden when there isn't
  one. It says only what was logged, never insulin or carbs on board. It redraws once a minute, on
  the minute the entry's age ticks over; the figure rolls once when it changes (just changes under
  Reduce Motion), and nothing loops. A tap zooms into the Logbook and opens that entry's row into
  its detail, as a tap on the row would.
- **Insights row → Insights**, **Logbook card → Logbook**: zoom transitions from the card.
- **Bottom log bar**: unchanged position; the plus symbol bounces once when the sheet closes after a
  save.

### 7.2 Other screens

| Screen | Changes |
| --- | --- |
| Welcome | The range field (in-range mint) as the backdrop, drifting; the two choices enter with `dsEntrance`. |
| Sign in, Setup | Steps slide horizontally (push), progress dots fill; the field follows the range being set in the range step. |
| Logbook | Day headers stick with a blur; rows enter with `dsEntrance`; swipe actions unchanged. Tapping an entry opens it in place: a card grows out of the row's own frame (its line stays where it was, the chevron turns down, corners round, the list dims) to everything the entry holds, with Edit, Log Again and Delete; tapping the line or the dimmed list, or dragging down, shrinks it back into the row. One progress value on a spring drives it (`LogbookRowExpand`, `PhoneLogbookDetail`), so a tap mid-flight turns it round from where it is and a drag moves it under the finger. Plays once per tap, nothing loops. Log Again and Delete wait for the card to land, then the list moves as from a swipe (lit copy, or fold away with Undo). Search matches stay picked out in the card. Under Reduce Motion the open card cross-fades in place. |
| Insights | Cards use the draw-in rings (existing `drawsIn:`) and the At a glance range bar draws in with them (`TimeInRangeBar(drawsIn:)`); 7-day columns grow from the baseline on first appearance. Figures (ring centre, average, GMI, CV, the legend shares, each day's time in range, Week in review's in range, average and lows, forecast accuracy's errors, no-change figures, check counts and inside-the-range share) are `RollingFigure`s: the screen sets `figuresCountUp`, so they count up from zero with the draw-in and roll from the old figure to the new on a period change, on the `.arrival` spring with the `.numericText(value:)` roll the widgets and Live Activity use. The forecast accuracy card's bars grow in row by row (15, then 30, then 60 min) and glide to new lengths when the week's figures change; its comparison line fades to its new colour. Once per appearance or change, never looping; values appear at once under Reduce Motion; VoiceOver reads only the final value. Mac Dashboard Insights does the same (since round 20): it sets `figuresCountUp`, so Week in review, forecast accuracy, the insulin and meal tables (examples and each median and range), the site-age bar labels and the "N of M examples" counts count up as their card assembles, the site-age bars grow from the baseline and the examples bars fill. Elsewhere (Mac Overview, widgets, followers) the same figures only roll on change. "Your usual day" (time-of-day pattern, `DayPatternView`, also on the Mac) is a still chart: worked out once per 15 minutes of new data off the main thread, never animated. "Today so far" (`TodaySoFarView`, iPhone Today and Mac Overview) is recomputed once per 5 minutes of new data off the main thread; since round 28 its in range, average and lows figures are `RollingFigure`s and the card sets `figuresCountUp` itself, so they count up left to right the first time the card shows and roll to the new figure when a reading changes them, and the headline cross-fades. Once per change, still under Reduce Motion, VoiceOver reads the card's one summary. "Week in review" (`WeekInReviewView`, iPhone and Mac Insights) is the same: still tiles and two lines, recomputed once per 15 minutes of new data; since round 30 its sentences and tile colours cross-fade when the week moves on while the figures roll. Also since round 30, nothing on a period change jumps: the range bars (`TimeInRangeBar`, the Mac's `MiniRangeBar`) always draw every share in the same order and glide to new widths, the iPhone Day by day columns glide to new heights on new readings, and on the Mac Dashboard the Overview headline tiles, Statistics figures, time-in-range legend shares (`LegendItem(fraction:)`), Highlights lines, the Patterns time-of-day and weekday tables, the Days table figures and the Logbook totals (`Metric(rolling:)`) roll to the new period's figures. Once per change, instant under Reduce Motion, no loops. |
| Settings | Unchanged layout; section jumps scroll with `.standard`; rows a toggle reveals slide in. The target range editor is the range rail, with a marker at the latest fresh reading. |
| Sharing / Follow | Follower cards get a small range field strip on their leading edge and a rail. |
| Log sheet | Choosing a moment bounces its icon once and its step settles in from just under the tiles (grows from its top edge out of a soft blur, `LogStepMorph`, `.emphasized`), then scrolls into view. Saving plays the success haptic and draws a checkmark ("Logged" / "Saved", spoken to VoiceOver) for 0.75 s, then the sheet closes; the checkmark only follows the confirm steps (calculator dose, "Already logged?", the logged-twice notice). Under Reduce Motion steps fade, the check appears drawn and holds 0.5 s. Nothing loops. |
| Sensor scan | The scan ring pulses during NFC reads (system NFC sheet aside); result value rolls in. |

### 7.3 Haptics

One shared helper plays every iPhone haptic: `Haptics.play(_:)` for a button's action and
`.haptic(trigger:)` for a value that changed (Sources/Shared/HapticFeedback.swift). Each haptic is a
`HapticEvent` named by what it means (Sources/Shared/HapticRules.swift), so the same moment feels
the same on every screen. Haptics are for moments that mean something: first loads, routine
refreshes, dismissing a card and plain navigation stay silent.

| Moment | Event | Feel | Where |
| --- | --- | --- | --- |
| Picking a chip, tile, stepper value, chart hours, setup step | `choice` | selection | Log sheet, Logbook filters, chart hours, Setup, sharing |
| Log saved, Log Again, a question answered (low, dose), export ready, check-in sent, signed in | `done` | success | Log sheet `finishSaving()`, Logbook, low and dose questions, Export, Follow |
| Undo (deleted-entry toast, low and dose question cards) | `undone` | light impact 0.8 | `PhoneUndoToast`, question cards |
| Pull to refresh brought new readings (nothing on no change or failure) | `newData` | light impact 0.8 | `phonePullToRefresh` (#124) |
| Scrubbing the chart crosses the low or high line | `scrubRangeEdge` | light impact 0.9 | `GlucoseChart` (#107) |
| Scrubbing the chart passes something logged | `scrubLogged` | light impact 0.6 | `GlucoseChart` (#107) |
| A new reading crosses into a low | `enteredLow` | warning | Today hero, follower card |
| A new reading comes back into range | `backInRange` | success | Today hero, follower card |
| A low or high alert fires with the app open (its in-app banner slides in) | `alertBanner` | warning | `AlertBannerHost` |
| A follower's check-in comes back "okay" | `followerOkay` | success | Check-in card |
| A check-in comes back "needs help" or unanswered | `followerNeedsHelp` | warning | Check-in card |

No double buzz: every haptic passes `HapticGate`. Within 0.4 s of the last one, a new one only plays
if it ranks higher (warnings, then outcomes, then acknowledgements, then scrub ticks), so a pull that
brings a reading crossing into a low plays the warning, not the warning and a tap. Ticks after ticks
(`choice`, scrub) only need 0.06 s, so stepping or scrubbing quickly still ticks each time.

System Haptics: only the system feedback styles are used (`.sensoryFeedback` and the UIKit feedback
generators), never Core Haptics or a vibrate, so turning off System Haptics in Settings › Sounds &
Haptics silences all of them. `HapticRulesTests` fails if any iPhone code plays a haptic around the
helper.

## 8. Mac app

### 8.1 Menu bar

The menu bar item is the value in its range colour (on by default, urgent lows always) with an SF
trend arrow (one `arrow.right` turned to the trend's angle), the change when that option is on, and optionally a 22 pt sparkline of the last
hour (five-minute averages, never scaled tighter than 2 mmol/L so a flat hour stays flat). Stale
readings get the popover's treatment: grey value with the drawn strike line, an amber warning sign
and the age to the minute, no arrow, no range colour.

Motion is limited to one roll per new reading: the old value leaves and the new one arrives from
the direction it moved, over `DSMotion.arrival` (and the strike draws in as a reading goes stale).
A new trend swings the arrow round on the same spring, drawn frame by frame from
`TrendTurn.springProgress` (round 39). Nothing else moves, and under Reduce Motion only fades
remain: the arrow's old direction cross-fades into the new one. It's peripheral vision, so it must
never loop.

It's on screen all day, so it costs nothing between readings. `MenuBarGlance` holds exactly what's
shown; the item is drawn into an image only when that changes, and one timer is set for the next
moment it changes on its own (the reading going stale, then each minute of its age). The image
carries a light and a dark rendering and picks one when drawn, so it follows the menu bar's
appearance without redrawing.

### 8.2 Popover

- **Hero** sits on a `RangeField` (not live drift: the popover is short-lived, so the field holds
  still and only sweeps on range change), with the needle, a range rail under the value, and the
  freshness meter replacing the text age row's dot.
- Notices, chart, summary card: unchanged structure. The chart's hour picker gets the sliding chip.
- Opening the popover: each time it opens, the sections showing (hero, notices, prompts, chart,
  summary, toolbar, footer) fade and rise 8 pt into place top to bottom, 45 ms apart, 0.32 s each,
  so the whole opening settles in about half a second (`PopoverStagger`, `.popoverEntrance`). Only
  the sections on screen take a turn, so a popover without notices doesn't pause where they would
  be. It plays once per opening and never again while the popover stays open (§4.6); a notice
  that turns up later uses its own transition. Under Reduce Motion everything is simply there.
- A new reading rolls the hero value's digits over to it (`.readingChange`, as on the iPhone), up
  or down with the change, on `.arrival`; the delta rolls with it, the trend words cross-fade and
  the needle swings. A reading that crosses a range edge moves the figure and its colour together
  on the slower `.sweep` fade (`ReadingRoll`), so the colour isn't hurried along by the roll. Each
  plays once per change, never on opening (the stagger only moves the card's opacity and offset);
  under Reduce Motion the number just changes; VoiceOver reads only the new reading.
- Changing the summary card's period cross-slides its figures: the old ones slide 18 pt out as the
  new ones come in from the other side, a longer period from the trailing edge. Reduce Motion
  swaps them.
- The chart's forecast (`ForecastMotion`, Motion.swift) draws in from the newest reading each time
  the popover opens (waiting until its card is 60 % of the way in, `PopoverStagger.forecastDelay`), and when a forecast turns up where there was none (`.sweep`): the axes already
  make room for all of it (`GlucoseChart(forecastReveal:)`), so only the dashed line and its range
  grow. A new forecast bends and slides from the old shape into the new one (`.ambient`), points
  paired by how far ahead they are (`ForecastMorph`), a longer horizon reaching out from the old end
  and a shorter one pulling back. One movement per opening or per forecast, never looping (§4.6).
  Under Reduce Motion, or once it's gone, the forecast just changes.

- The same **last logged line** as the iPhone (§7.1) sits under the chart. Clicking it opens the
  dashboard on the Logbook with that entry selected and lit once; the period goes back to now and
  widens to 12 or 24 hours only if the one picked is too short to hold the entry.

### 8.3 Dashboard window

- **Overview** hero on a `RangeField` with live drift (it's a window you look at), rail and meter.
- **Sidebar**: selection highlight slides between sections.
- **Sections** (Outlook, Patterns, Days, Readings, Logbook, Insights, Report): unchanged layout; charts
  wipe in when their period changes; stat tiles roll their numbers. Insights counts its figures up
  and draws its bars in as each card assembles, as on iPhone (§7.2 Insights row). The Overview chart glides to a
  new range on the same stretch of time instead of wiping (§4.1). The Outlook chart's forecast draws
  in from the newest reading each time the page opens, once its card is most of the way in (0.3 s,
  `OutlookSection.forecastDelay`), and bends into each new forecast, with the same `ForecastMotion`
  as the popover (§8.2). Under Reduce Motion it just changes.

### 8.4 Onboarding, Settings, Log sheet, Quick log

Onboarding steps push horizontally with progress dots; Settings unchanged in layout, its target range
editor drawn as the range rail (as on iPhone); log sheets as iPhone. The Outlook and Insights pages
assemble with `dsEntrance` like the popover, and the Logbook's filter is a `SlidingSegments`.

## 9. Widgets

| Widget | Design |
| --- | --- |
| Glucose (all sizes) | On the range field (still, no drift), grey once stale; urgent low adds the 2 pt crimson border inside the widget's edge. The range pill pushes in the direction of travel between timelines (a fade under Reduce Motion), and a stale value gets the drawn strike line in every rendering mode. |
| Glucose small | Value + needle, rail along the bottom, age timer. |
| Glucose medium | Value + needle + rail on the left, chart on the right, forecast note and meter in the footer. |
| Glucose large / extra large | As medium with a taller chart and the On board line; the meter sits beside the chart's caption. The summary at the bottom is Today so far against your usual day (same words as the iPhone card, neutral colours, "Midnight to 2:30 pm" so it stays true when stale), or the last 12 hours until today has an hour of readings. |
| VoiceOver (Glucose) | The value is read for its freshness: fresh gives range, trend, change and age in words; stale says "Stale" and the age only, never range or trend; expired says when the last reading was. The chart reads the same `ChartSummary` sentence as the app's charts. |
| Reloads | The app reloads only the widgets a snapshot changes (`WidgetReload`): the Glucose and Lock Screen widgets when anything they draw moves, Time in Range and Sensor at most once per 15 minutes of readings, or on a new sensor or setting. A logbook edit or relearn that leaves the forecast where it was reloads nothing. |
| Time in Range | Unchanged (rings and bars), numbers roll and bars grow between timelines. |
| Sensor | Unchanged, days left as a ring; the count rolls down. |
| Lock Screen circular | Value in a gauge ring whose fill is the freshness (live), trend arrow under the value. |
| Lock Screen rectangular | Value + arrow + delta, a 3 pt rail, age timer (live, "Stale" in words once stale). |
| Lock Screen inline | "6.2 ↗ · 1 min". |

Widgets in accented or vibrant rendering modes drop the field and keep the rail as monochrome.

## 10. Accessibility

- Reduce Motion: no drift, no ripple, no needle swing (it jumps), no sweeps (colour cross-fades only).
- Reduce Transparency: flat fields.
- Increase Contrast: rail segments at full opacity with hairline separators; marker ring 3 pt.
- VoiceOver: each hero, card and Live Activity presentation is one element with a sentence.
- Dynamic Type (iPhone) / Text Size (Mac): stage value grows at 40 %, everything else at full rate.
- Colour is never the only signal: range pills carry a symbol and a word; urgent low adds a border.

## 11. Delivery plan

| Step | Scope | PR | State |
| --- | --- | --- | --- |
| 1 | This document; `Signal.swift` components; Live Activity rebuild (all presentations, watch/CarPlay small family); relay priority policy; iOS deployment target 18.0 | #56 | merged |
| 2 | iPhone stage on the range field with rail, forecast note and freshness meter; collapsing title; sliding chart hours; zoom transitions; welcome entrances | #57 | merged |
| 3 | Mac popover and dashboard heroes on the range field with the rail; sliding chart hours; rail in Home Screen / desktop widgets; freshness ring and rail on Lock Screen accessories | #57 | merged |
| 4 | Directional range sweep (`RangeField(range:)`) and push-swapping range pill (`RangeBadgeSwap`); strike line drawing in (`.staleStrike`); Mac dashboard sidebar's sliding selection, chart wipes (`.chartWipe`) and rolling headline tiles; onboarding push with sliding progress dots | #60 | merged |
| 5 | iPhone motion: log bar bounce after a save (§7.1); Setup steps push in the direction of travel with filling progress and a field that follows the range being set; Logbook sticky day headers and row entrances; Insights columns growing from the baseline; follower cards' range strip and rail; Sensor scan ring pulse and value roll-in (§7.2) | #59 | merged |
| 6 | iPhone stage adopts the directional range sweep and the drawn strike line on the hero value and the collapsed title | #64 | merged |
| 7 | Sharing surfaces: the web view behind share links (`web/share`) and the Messages extension's bubble, tapped card, composer and bubble picture (`ShareStage`) on the range field with the needle, rail and forecast ghost, forecast note, freshness meter and drawn strike line | #67 | merged |
| 8 | Widgets finished to §9: the range field and urgent-low border behind the Glucose widget, direction-aware pill swap, drawn strike line, live age timer, forecast note and freshness meter footer; rolling figures and growing bars in Time in Range and Sensor; live age on the Lock Screen rectangular | #80 | merged |
| 9 | Mac popover finished to §8.2: the shared `FreshnessMeter` under the age row in place of the live dot and hand-drawn hairline (fills live, amber once stale), and the cards assembling under the hero with `dsEntrance` on opening | #84 | merged |
| 10 | Remaining screens (§7.2, §8.3, §8.4): the target range editor in Settings (iPhone and Mac), Mac onboarding and iPhone Setup redrawn as the range rail (same log scale and segment colours), with a marker at the latest fresh reading and a line saying what it would count as; iPhone Settings rows that a toggle reveals slide in, and section jumps scroll with `.standard` under Reduce Motion rules; Mac Outlook and Insights pages assemble with `dsEntrance`; Mac Logbook filter on `SlidingSegments`; follower check-in status pushes in with a haptic for "okay" and "needs help" | #88 | merged |
| 11 | Mac menu bar item to §8.1: range colour, symbol trend arrow, optional last-hour sparkline, popover stale treatment, one roll per reading; drawn only when what it shows changes | #96 | merged |
| 12 | iPhone haptics to §7.3: one shared `Haptics` helper and `HapticEvent` table, the same feel for the same moment (undo everywhere, question answers), a gate against double buzzes, System Haptics respected | #181 | merged |

Every part of this design is now built.

Apple Watch: GlucOS has no watchOS app yet. On the Watch, GlucOS appears only as the Live Activity's
`.small` family in the Smart Stack (step 1), which already follows this design. A native Watch app
and complications would be a new target (watchOS app, WidgetKit complications, a data path from the
iPhone or relay, signing for a new bundle ID) and are not part of this plan.

Raising iOS to 18.0 drops no devices: iOS 18 runs on every iPhone that runs iOS 17 (XS / XR and
later). It unlocks `MeshGradient`, the watch/CarPlay Live Activity family, zoom transitions and scroll
geometry. macOS stays at 14 with `if #available(macOS 15)` for mesh fields.
