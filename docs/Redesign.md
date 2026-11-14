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
   range crossed, a trend turned. Nothing loops for decoration, except the slow range field drift on
   screens the user is looking at, and that stops when data is stale.
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

### 4.2 Range change ("sweep")

When the range changes, the range field's colour sweeps (`.sweep`) and the range pill swaps with a
push transition in the direction of travel (up for rising into high, down for falling into low). On
iPhone, crossing into low plays a `.warning` haptic and back into range `.success` (rule 7, unchanged).

### 4.3 Stale

When data goes stale the field desaturates to grey (`.ambient`), the strike line draws across the
value left to right (0.35 s, a trim), the needle fades to a question mark, the meter turns amber and
stays full. Reversed when data returns.

### 4.4 Ambient field drift

The range field's mesh nodes drift on a 14 s loop, at most 6 % of the field's size. Only on app
screens the user is looking at, only while data is fresh, and never under Reduce Motion or Low Power
Mode. Rapid trends speed the drift up to a 9 s loop, a cue that something is moving fast.

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

- value: numeric roll;
- needle: rotation with `.arrival` spring;
- rail marker: position with `.arrival`;
- range pill: push transition;
- background tint: cross-fade;
- sparkline: the trace re-renders (Swift Charts cross-fades in place).

Live without updates: freshness meter and age timer. Under Reduce Motion the system and our
`dsAnimation` both drop movement and keep cross-fades.

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
  into low/back to range plays haptics.
- **Collapsing header.** Scrolling up shrinks the stage; once its value scrolls under the navigation
  bar, the bar's title becomes the value and trend arrow in the range colour (iOS 18
  `onScrollGeometryChange`), so the reading is never off screen.
- Below the stage, unchanged order: banners, follows, On board, Chart, Logbook, Insights row, Sensor.
- **Chart card**: hour chips with a sliding selection; the chart re-draws with a horizontal wipe when
  hours change.
- **Insights row → Insights**, **Logbook card → Logbook**: zoom transitions from the card.
- **Bottom log bar**: unchanged position; the plus symbol bounces once when the sheet closes after a
  save.

### 7.2 Other screens

| Screen | Changes |
| --- | --- |
| Welcome | The range field (in-range mint) as the backdrop, drifting; the two choices enter with `dsEntrance`. |
| Sign in, Setup | Steps slide horizontally (push), progress dots fill; the field follows the range being set in the range step. |
| Logbook | Day headers stick with a blur; rows enter with `dsEntrance`; swipe actions unchanged. |
| Insights | Cards use the draw-in rings (existing `drawsIn:`); 7-day columns grow from the baseline on first appearance. |
| Settings | Unchanged layout; section jumps scroll with `.standard`. |
| Sharing / Follow | Follower cards get a small range field strip on their leading edge and a rail. |
| Log sheet | The moment chips slide their selection; the saved toast rises (existing). |
| Sensor scan | The scan ring pulses during NFC reads (system NFC sheet aside); result value rolls in. |

## 8. Mac app

### 8.1 Menu bar

The menu bar item stays text (value + arrow), colour-coded when the option is on. No animation in
the menu bar (it's peripheral vision; motion there is distracting).

### 8.2 Popover

- **Hero** sits on a `RangeField` (not live drift: the popover is short-lived, so the field holds
  still and only sweeps on range change), with the needle, a range rail under the value, and the
  freshness meter replacing the text age row's dot.
- Notices, chart, summary card: unchanged structure. The chart's hour picker gets the sliding chip.
- Opening the popover: hero first, then the cards with `dsEntrance` (as today).

### 8.3 Dashboard window

- **Overview** hero on a `RangeField` with live drift (it's a window you look at), rail and meter.
- **Sidebar**: selection highlight slides between sections.
- **Sections** (Outlook, Patterns, Days, Readings, Logbook, Insights, Report): unchanged layout; charts
  wipe in when their period changes; stat tiles roll their numbers.

### 8.4 Onboarding, Settings, Log sheet, Quick log

Onboarding steps push horizontally with progress dots; Settings unchanged; log sheets as iPhone.

## 9. Widgets

| Widget | Design |
| --- | --- |
| Glucose small | Value + needle, rail along the bottom, age timer. |
| Glucose medium | Value + needle + rail on the left, chart on the right, forecast note and meter in the footer. |
| Glucose large / extra large | As medium with a taller chart and the On board line. |
| Time in Range | Unchanged (rings and bars), numbers roll between timelines. |
| Sensor | Unchanged, days left as a ring. |
| Lock Screen circular | Value in a gauge ring whose fill is the freshness (live), trend arrow under the value. |
| Lock Screen rectangular | Value + arrow + delta, a 3 pt rail, age timer. |
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
| 2 | iPhone stage on the range field with rail, forecast note and freshness meter; collapsing title; sliding chart hours; zoom transitions; welcome entrances | #57 | this release |
| 3 | Mac popover and dashboard heroes on the range field with the rail; sliding chart hours; rail in Home Screen / desktop widgets; freshness ring and rail on Lock Screen accessories | #57 | this release |
| 4 | Directional range sweep (`RangeField(range:)`) and push-swapping range pill (`RangeBadgeSwap`); strike line drawing in (`.staleStrike`); Mac dashboard sidebar's sliding selection, chart wipes (`.chartWipe`) and rolling headline tiles; onboarding push with sliding progress dots | #60 | merged |
| 5 | iPhone motion: log bar bounce after a save (§7.1); Setup steps push in the direction of travel with filling progress and a field that follows the range being set; Logbook sticky day headers and row entrances; Insights columns growing from the baseline; follower cards' range strip and rail; Sensor scan ring pulse and value roll-in (§7.2) | #59 | merged |

Not built yet, still part of this design: the iPhone stage can adopt the sweep and strike with
`RangeField(range:)` and `.staleStrike` (§4.2, §4.3).

Raising iOS to 18.0 drops no devices: iOS 18 runs on every iPhone that runs iOS 17 (XS / XR and
later). It unlocks `MeshGradient`, the watch/CarPlay Live Activity family, zoom transitions and scroll
geometry. macOS stays at 14 with `if #available(macOS 15)` for mesh fields.
