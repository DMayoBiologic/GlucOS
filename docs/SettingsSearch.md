# Settings search

A search field at the top of Settings on iPhone and Mac finds a setting by its title or by the
words people use for it: "mmol" finds Units, "quiet" or "snooze" finds how often alerts repeat,
"dynamic island" finds Live Activity, "hypo" finds the low alerts.

Code: `Sources/Engine/SettingsSearch.swift` (catalogue, keywords, matching, jump targets),
`Sources/App/Views/SettingsSearchViews.swift` (shared model, row anchor + highlight, result and
empty rows). iPhone: `PhoneSettingsView`. Mac: `SettingsView` (`settingsSearchPage` on each tab).
Tests: `SettingsSearchTests`.

## Rules

1. Text is folded to lowercase, accent-free words of letters and digits ("mmol/L" is `mmol`, `l`).
   Filler words ("turn off the…") are dropped unless they are the whole query.
2. Every query word has to start a word of the row's title, keywords or place (section, or on the
   Mac tab › section). Title hits outrank keyword hits outrank place hits; an exact word beats a
   prefix; a title that starts with the whole query gets a bonus. Ties keep screen order.
3. Picking a result (tap, click, or Return for the best match) closes the search, waits
   `SettingsSearch.jumpDelay` for the full list to come back, scrolls the row to the middle and
   lights it in the brand tint for `highlightSeconds`. Under Reduce Motion the scroll and the
   highlight are instant, with no fade.
4. A row that only shows once something is on (iPhone alert options, Warn me ahead by, your
   insulins, bolus calculator, presets) lands on the switch that reveals it (`parent`).
5. On the Mac a result on another tab switches to that tab first. ⌘F focuses the field, Escape
   clears it.
6. Nothing found: "No settings match “…”. Try a word like alerts, units, sync or widget."

There are no alert quiet hours in GlucOS; "quiet", "mute" and "silence" lead to the alerts switch
and the repeat interval instead.

## Motion

Round 88. Rules and timings: `Sources/Engine/SettingsSearchMotion.swift` (tested in
`SettingsSearchMotionTests`); views in `SettingsSearchViews.swift`. Display only: what a search
finds and where a jump lands are unchanged.

1. **Results stagger in as you type.** Rows the latest letter adds fade and rise 6 pt into place,
   top to bottom, 35 ms apart (`entranceDelays`); past 6 rows the rest come in together. Rows
   already listed hold still, so narrowing a search moves nothing. A row takes its delay once, so
   scrolling it away and back never replays it.
2. **Matched words glint.** The result titles use `SearchHighlightText` with `flare`: newly matched
   letters' wash rises to 1.8× its resting strength and settles over 0.55 s (`flaredWash`); still
   matched letters hold, letters no longer matched fade out. Bold switches at once, as in the
   Logbook, so the line never reflows.
3. **Jumping springs the row into view.** The scroll uses the emphasized spring, then 0.3 s later,
   once the row is on screen, it and its wash grow to 1.025× for 0.16 s and spring back, alongside the 1.6 s highlight.
4. **Section icons bounce once.** Section headers are `SettingsSectionHeader(title, systemImage:)`
   on a Section tagged `.settingsSection(title)`; when a jump lands on one of its rows the header
   icon bounces once (`symbolBounce`). Rows in a section without a header (the Mac Alerts tab's
   top section, About) only spring.

Under Reduce Motion rows appear at once, the wash switches with no glint, the scroll is instant,
the row holds still and the icon doesn't bounce. VoiceOver is unchanged: header icons are hidden,
result rows read as before.

## Adding a setting

Add a `SettingsAnchor` case, a `SettingsItem` in `SettingsCatalog.phone` and/or `.mac` in screen
order, and `.settingsAnchor(.thatCase)` on the row (a row, never a Section). The catalogue tests
check anchors are unique, parents exist, Mac rows name a real tab, and every row finds itself by
its title. Give a new section a `SettingsSectionHeader` and `.settingsSection` with the same
title so its icon answers a jump.
