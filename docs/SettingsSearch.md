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

## Adding a setting

Add a `SettingsAnchor` case, a `SettingsItem` in `SettingsCatalog.phone` and/or `.mac` in screen
order, and `.settingsAnchor(.thatCase)` on the row (a row, never a Section). The catalogue tests
check anchors are unique, parents exist, Mac rows name a real tab, and every row finds itself by
its title.
