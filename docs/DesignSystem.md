# GlucOS design system

Everything visual comes from `Sources/Shared/DesignSystem/` (compiled into the app and the widget) plus the glucose-specific pieces in `Sources/Shared/Theme.swift` and `GlucoseStyle.swift`. Reach for these before writing a literal.

## Rules

1. **Colour is status.** Components take a `Tone`, not a raw colour. Each range has one hue, used everywhere that reading appears.
2. **Stale is never reassuring.** Old data is `Tone.stale` (neutral grey). Use `snapshot.displayTone()`, `range.tone(stale:)`, `RangeBadge(range:stale:)` and `GlucoseChart` (works out staleness itself unless told otherwise). Never show a stale value in green.
3. **Small text uses `tone.textColor`**, which reaches 4.5:1 in light mode. `tone.color` is for fills, lines, icons and large numbers.
4. **Spacing is in steps of 4** (`DS.Space`). Radii nest: a tile inside a card is one step smaller.
5. **Nothing wraps letter by letter.** Single-line labels get `lineLimit(1)`, numbers get `minimumScaleFactor`, and rows that can run out of width use `DSAdaptiveRow`, which moves the accessory underneath.
6. **Motion respects Reduce Motion.** Use `.dsAnimation(_:value:)`, `DS.animate(_:reduceMotion:)` and `DS.Transition.*`, never a bare `.animation` or `withAnimation`.
7. **Haptics only mean something (iPhone).** Play them only through `Haptics.play(_:)` or `.haptic(trigger:)`, by meaning (`HapticEvent`): `choice` (selection) for picking, `done` (success) when something is logged, saved or answered, `undone` for undo, `newData` when a pull brings new readings, scrub ticks only when the trace crosses the low or high line or the finger passes something logged (`ChartScrub`; never one tick per reading), `enteredLow` (warning) when a new reading crosses into a low, `backInRange` (success) when it comes back. Never on first load, never for routine refreshes, never Core Haptics. The full table is docs/Redesign.md §7.3.
8. **Charts show out-of-range time as a shape.** `GlucoseChart` fills between the trace and the high or low line it crossed, and fades the forecast band as it reaches further ahead. Its end-of-trace pulse only plays when `interactive` (app screens), never in widgets or the Live Activity.

## Tokens

| Token | Values |
| --- | --- |
| `DS.Space` | `xxs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, `xxl` 24, `xxxl` 32 |
| `DS.Radius` | `control` 8, `tile` 12, `card` 16, `panel` 20, `hero` 24 |
| `DS.Stroke` | `hairline` 0.75, `increased` 1.25 (Increase Contrast) |
| `\.dsDensity` | `.compact` (popover), `.regular` (dashboard), `.comfortable` (full screen): `cardPadding`, `stackSpacing`, `gutter`, `cardRadius` |
| `DSElevation` | `.none`, `.low` (cards), `.medium` (hero, banners, tooltips), `.high` (toasts, overlays), applied with `.dsShadow(_:tint:)` |
| `DSMotion` | `.quick` (press, hover), `.standard` (state changes), `.emphasized` (values settling), `.ambient` (colour and glow) |

## Type

`.dsFont(_:)` with one of `heroValue` 64, `display` 40, `title` 22, `sectionTitle` 15, `headline` 13, `body` 13, `callout` 12, `label` 11, `caption` 10.5, `eyebrow` 10 (uppercase; sizes scale in half-point steps), `metricValue` 20, `metricValueLarge` 28, `unit` 12. Numbers are SF Rounded with tabular digits.

macOS has no Dynamic Type for third-party apps, so GlucOS has its own Text Size setting (`TextSizePicker`, stored under the `dsTextScale` UserDefaults key). Every `.dsFont` follows it; big numbers grow at half rate so they stay inside their cards. Override a subtree with `.environment(\.dsTextScale, 1.0)`. To change weight, put `.fontWeight(_:)` **before** `.dsFont`.

On iPhone `PhoneTextScale` maps Dynamic Type onto the same scale: 1.1 at xSmall up to 1.5 at xxxLarge, then on through the accessibility sizes to 2.25 at AX5 (body about 29 pt, like iOS's own). The iPhone hero reading stops growing at xxxLarge, since it's already about 115 pt.

## Colour

`Tone`: `.neutral`, `.brand`, `.success`, `.warning`, `.critical`, `.info`, `.stale`, `.glucose(GlucoseRange)`, `.custom(Color)`. Each has `.color`, `.textColor` and a default `.systemImage`.

`Palette` holds the raw values, with light, dark and Increase Contrast variants: range hues (`mint`, `amber`, `coral`, `crimson`, `magenta`) and their `…Text` versions, `stale`, `neutral`, `brand`, `brandGradient`, `onBrand`, and log categories `insulin`, `food`, `site`, `context`.

Contrast is checked against the backgrounds the colours actually sit on: white, the grouped background `#F2F2F7` and the Mac window `#ECECEC` in light mode; black, `#1C1C1E`, `#2C2C2E` and the Mac's dark window `#323232` in dark mode. The worst case for each (WCAG 2 ratios):

| Colour | Light | Dark | Needs |
| --- | --- | --- | --- |
| `mint` / `amber` / `coral` / `crimson` / `magenta` | 3.47 / 3.32 / 3.31 / 4.75 / 4.63 | 6.67 / 7.68 / 4.62 / 4.02 / 4.84 | 3:1 (graphics, large numbers) |
| `stale` | 3.32 | 3.93 | 3:1 |
| `mintText` / `amberText` / `coralText` / `crimsonText` / `magentaText` | 4.64 / 5.02 / 4.71 / 5.32 / 6.16 | 6.67 / 7.68 / 4.62 / 4.87 / 4.84 | 4.5:1 (small text) |
| `staleText` / `brandText` | 5.06 / 5.67 | 5.17 / 5.04 | 4.5:1 |

## Surfaces

`.dsCard(_ style, padding:, radius:)` with `.standard`, `.inset`, `.tinted(Tone)` or `.hero(Tone)`. `DSSurface` is the same background without padding. Both switch to opaque fills under Reduce Transparency and to stronger borders, without shadows, under Increase Contrast. `glassCard()` is kept as `.dsCard(.standard)`.

## Components

| Component | Use |
| --- | --- |
| `.buttonStyle(.ds(.primary / .secondary / .tinted(Tone) / .ghost, size: .small / .regular / .large))` | All buttons |
| `DSChip`, `DSChipButtonStyle`, `DSChipPicker` | Time ranges, filters, toggles |
| `TonePill(text:systemImage:tone:)` | Small status capsule; `RangeBadge` is built on it |
| `StatTile(_:value:unit:caption:tone:large:boxed:)` | A labelled headline number |
| `SectionHeader(_:systemImage:subtitle:trailing:)` | Card titles, with a caption or controls that drop below when narrow |
| `LegendItem(color:label:value:detail:)` | Chart and ring keys |
| `EmptyStateView(systemImage:title:message:tone:actionTitle:action:)` | Sections with nothing to show |
| `StatusBanner` | Notices; buttons reflow under the text when narrow, and the message is never truncated |
| `DSAdaptiveRow` | Main content with an accessory beside it, or below it when narrow |
| `DSDivider` | Hairline separators |

## Accessibility

- **Large text (iPhone).** At the accessibility sizes (`dynamicTypeSize.dsLargeText`), rows that run out of width stack: use `DSAccessibleStack` (an HStack that becomes a leading VStack) and `.dsLineLimit(n)` (a line limit that lifts so text wraps instead of truncating). Grids drop a column. Fixed-size surfaces (widgets, the Live Activity) keep their one-line limits.
- **VoiceOver.** A reading is one element with the whole sentence (`accessibilitySummary`). A chart is one element too: `GlucoseChart` reads `ChartSummary.sentence` (period, now, lowest and highest, percent in range, times it left the range, where the forecast ends, marked as not a reading) and carries `GlucoseAudioGraph`, so "Chart Details" in the rotor plays the readings and the forecast as an audio graph.
- **Never colour alone.** Each range has a symbol and a name in `RangeBadge`; stale data is grey, crossed through and says "Stale". An urgent low also gets `.urgentRim(_:in:)`, a crimson rim on the card that holds the reading (iPhone hero, follower cards, popover hero, dashboard hero), and the octagon in the iPhone title bar and the Mac menu bar.

### Recent features checked (round 30)

Each feature shipped since the round-2 pass (#68), checked for VoiceOver, large text, contrast and Reduce Motion. "Fixed" rows changed in round 30; the rest already met these rules.

| Feature | VoiceOver | Large text | Contrast | Reduce Motion |
| --- | --- | --- | --- | --- |
| Your Usual widget, iPhone (#173) and Mac (#177) | Each button reads the entry in words (`UsualGlance.spoken`) with a hint that it opens the sheet and never logs; "+" is "Log something else"; the caption is a header | Widget, fixed sizes: titles and details wrap to two lines and shrink to 85 % | **Fixed:** the detail line was `.secondary`, 2.95:1 on the filled low tile in light mode and about 3.5:1 on the Mac desktop. It's now primary at 72 %, at least 5.6:1 on every tile in light and dark. Icons stay at 3.4:1 or more | Nothing moves; the system cross-fades entries |
| Logbook export, iPhone (#157) and Mac (#161) | Standard form controls. **Fixed:** while the iPhone file is being made the button reads "Making the file", and a failure is announced, since it appears in the footer away from the focus. On the Mac every dashboard toast (Saved…, Couldn't save…) is announced and stays 20 s under VoiceOver instead of 8 | Form rows wrap | System colours; the PDF's grey text is 6.3:1 on white and 5.6:1 on its tiles | Nothing moves |
| Logbook export PDF | Real text, not images, so a screen reader or text selection can read it, but Core Graphics PDFs carry no tags (reading order, headings). Every coloured band is labelled with its name and share | A4 print sizes, 7 pt and up | Bands are labelled, never colour alone | – |
| Sensor warm-up, iPhone Today (#140), Mac popover and menu bar (#169) | **Fixed:** read as "Sensor warming up. Readings start in about 42 minutes, around 9:41 am" (`SensorWarmUp.spoken`, tested). It said "42 min", which VoiceOver can read as "minimum", and left out the time. The ring is hidden; the card is one element that updates frequently | iPhone ring sits above the words at the accessibility sizes (`DSAccessibleStack`) and grows to 120 pt | Brand ring on the hero field, words in label colours | The ring and minutes ease once a minute, instantly under Reduce Motion |
| Sensor warm-up Live Activity (#140) | **Fixed:** it read "In about 42 minutes" worked out when the card was drawn, which a Live Activity keeps until the next push, so it went on saying 42 long after. It now says only the time readings start; the drawn timer carries the countdown. The expanded Dynamic Island no longer reads "Sensor warming up" twice | Live Activity, fixed sizes | Dark card, label colours | System timer views; the swap to the first reading is a fade |
| Lock Screen widgets (#179) | One element per accessory reading `WidgetSpeech.reading`: no range or trend once stale, ages in words ("12 minutes ago", not "12m") | Fixed sizes, figures shrink to fit | Monochrome; stale is struck through and named, never only tinted | No animation beyond the system's |
| Back in range (#141, #145, #149) | "Back in range in about 25 minutes if nothing else changes" everywhere (`BackInRangeText.spoken`); in the Live Activity, widget and menu bar sentences | Wraps on iPhone Today | Forecast grey icon (3:1) beside label-colour text, never a reading's colour | Fades in, never moves |
| Logbook day bars, iPhone and Mac (round 32) | One heading per day: "Tuesday 12 November, 78% in range, 4% below" (`DayInRangeText.spoken`, tested); the bar itself is hidden | The figure is text beside the bar and grows with the header; the bar stays 4 pt | Coral / mint / amber at full strength, 3.31:1 or more on light backgrounds, gaps widen to 2 pt under Increase Contrast; the percent is always in words | Draws in once per day, then still; instant under Reduce Motion |
| Insights Lows card, iPhone and Mac (round 33) | One element after the period picker: "Lows below 3.9 mmol/L, the last 14 days. 4 lows. Typical length 30 minutes. 2 of 4 treated, 1 came up by itself, 1 with nothing logged. 3 of 4 started overnight, midnight to 6 am." (`LowsSummaryText.spoken`, tested); the time-of-day bars are hidden | Tiles stack in `DSAccessibleStack`; each time-of-day row puts its label and count on one line above its bar, so nothing narrows at AX sizes; sentences wrap | The Lows figure is `coralText` (4.71:1 light, 4.62:1 dark); bars are `coral` at full strength (3.31:1 / 4.62:1) on a 6 % track, and every count is also text beside its bar | Bars grow in once, figures count up once, a period change rolls figures and glides bars; instant under Reduce Motion, no loops |

