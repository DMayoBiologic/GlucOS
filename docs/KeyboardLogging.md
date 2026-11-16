# Logging from the keyboard (Mac)

Logging on the Mac can be done without touching the mouse.

## Opening the log window

- **⌘L** in the menu bar popover or the dashboard opens the log sheet.
- **⌥⌘1 – ⌥⌘3** in the menu bar popover open it filled in from one of "Your usual" (the chips
  above the toolbar, in the order shown). Return then logs it, after the same checks as the button.
- **From any app (optional):** Settings → Logging → Keyboard → "Open the log window from any app".
  It is **off by default**, because a system-wide shortcut takes that key combination away from
  every other app. The suggested combination is **⌃⌥⌘L**; click the shortcut to record another.
  - It needs two modifier keys, one of them ⌘ or ⌃, so it never takes a shortcut other apps use
    (⌘L alone is every browser's address bar). ⌘Space, ⌘Tab and the ⇧⌘ shortcuts macOS uses
    (screenshots, redo, save as…) are refused with the reason (`LogHotKey.problem`).
  - It is a Carbon hot key (`GlobalLogShortcut`). It needs no Accessibility permission, and macOS
    passes GlucOS only that one combination, never other keystrokes.
  - If another app already holds the combination, Settings says so under the switch.
  - Pressing it while the log window is open brings it to the front and keeps the entry being typed.

## In the log sheet

A new entry opens with the keyboard on "What's happening?".

| Keys | What it does |
| --- | --- |
| ← → ↑ ↓ | Move between the moments (three to a row). The first arrow press shows the highlight. |
| Return | Pick the highlighted moment and move on to fill it in (the cursor goes to carbs or units). |
| Return on a moment that's already on | Log, once the entry is ready ("Woke up", Return, Return logs a wake-up). It never turns the moment off. |
| Space | Turn a moment on or off and stay on the tiles, to pick several (eating and a bolus). |
| ⌘1 – ⌘6 | Turn a moment on or off from anywhere in the sheet. |
| ⌥⌘1 – ⌥⌘3 | Fill in one of "Your usual", as clicking its chip does. Listed only while the sheet offers them. |
| ⌘F | Search foods. |
| Return in a field | Log, once the entry is ready. |
| Esc | Cancel. |
| ⌘? | List the shortcuts. |

While the tiles have the keyboard, the Log button is not the default button, so Return belongs to
the tiles. Logging from the keyboard goes through the same checks as the button: the calculator
dose confirmation and "Already logged?" both still ask.

## ⌘? lists

⌘? shows the shortcuts for where you are: over the menu bar popover (also in its ⋯ menu), in the
log sheet (also the keyboard button in its header) and in the dashboard (⌘/ too). Every list ends
with the "from any app" shortcut while it is turned on. The rows live in `ShortcutCatalog`, so the
lists can't drift apart.

## Code

- Rules (unit-tested in `LogKeyboardTests`): `Sources/App/Logbook/LogKeyboard.swift`:
  `LogKeyboard.move` (grid navigation), `LogKeyboard.action` (Return and Space), `UsualKeys` (⌥⌘1–3), `LogHotKey`,
  `ShortcutCatalog`.
- Hot key: `Sources/App/GlobalLogShortcut.swift`, started from `AppDelegate`.
- Views: `LogSheet.momentPicker`, `PopoverUsualRow`, `ShortcutListView`, Settings `KeyboardLoggingSection`.
