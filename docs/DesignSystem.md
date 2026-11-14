# GlucOS design system

Everything visual comes from `Sources/Shared/DesignSystem/` (compiled into the app and the widget) plus the glucose-specific pieces in `Sources/Shared/Theme.swift` and `GlucoseStyle.swift`. Reach for these before writing a literal.

## Rules

1. **Colour is status.** Components take a `Tone`, not a raw colour. Each range has one hue, used everywhere that reading appears.
2. **Stale is never reassuring.** Old data is `Tone.stale` (neutral grey). Use `snapshot.displayTone()`, `range.tone(stale:)`, `RangeBadge(range:stale:)` and `GlucoseChart` (works out staleness itself unless told otherwise). Never show a stale value in green.
3. **Small text uses `tone.textColor`**, which reaches 4.5:1 in light mode. `tone.color` is for fills, lines, icons and large numbers.
4. **Spacing is in steps of 4** (`DS.Space`). Radii nest: a tile inside a card is one step smaller.
5. **Nothing wraps letter by letter.** Single-line labels get `lineLimit(1)`, numbers get `minimumScaleFactor`, and rows that can run out of width use `DSAdaptiveRow`, which moves the accessory underneath.
6. **Motion respects Reduce Motion.** Use `.dsAnimation(_:value:)`, `DS.animate(_:reduceMotion:)` and `DS.Transition.*`, never a bare `.animation` or `withAnimation`.
7. **Haptics only mean something (iPhone).** Use `.sensoryFeedback`: `.selection` for scrubbing the chart and switching chart hours, `.warning` when a new reading crosses into a low, `.success` when it comes back into range. Never on first load, never for routine refreshes.
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

## Colour

`Tone`: `.neutral`, `.brand`, `.success`, `.warning`, `.critical`, `.info`, `.stale`, `.glucose(GlucoseRange)`, `.custom(Color)`. Each has `.color`, `.textColor` and a default `.systemImage`.

`Palette` holds the raw values, with light, dark and Increase Contrast variants: range hues (`mint`, `amber`, `coral`, `crimson`, `magenta`) and their `…Text` versions, `stale`, `neutral`, `brand`, `brandGradient`, `onBrand`, and log categories `insulin`, `food`, `site`, `context`.

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
