# Sharing an Insights card

Any Insights card can go out as a picture, on iPhone and Mac.

- **iPhone:** touch and hold a card, then **Share Card…**. VoiceOver: the card's actions include
  **Share card**.
- **Mac:** right-click a card on the Dashboard's Insights page, then **Share Card…**.

A sheet shows the exact picture that will leave the device. Its **Share…** button opens the system
share sheet (Messages, Mail, AirDrop, Save Image, Files and so on). The file is a PNG named for the
card and the day, such as `GlucOS Lows 17 Nov 2026.png`.

## What's in the picture

The card as it looks on screen, then a small footer:

> Lows · Last 14 days · 3–17 Nov 2026
> Shared from GlucOS

- The footer comes from `InsightsShare.footer` (Sources/Engine/InsightsShare.swift): the card's
  title, its period and the dates it covers. Nothing else, so no name, email, account, share link
  or device name ever goes in. Tests: `InsightsShareTests`.
- The period is the one the card's own picker is on (the UserDefaults keys in
  `InsightsShare.Key`). Fixed cards: Day by day and Forecast accuracy cover 7 days, In-range
  streaks 14, Week in review "This week and last week", Mornings "All readings kept" from the
  first stored reading. At a glance now remembers its 24h/7d/14d choice so the footer can say it.
- Period pickers are left out of the picture (`\.insightsShareSnapshot`); the footer names the
  period instead. Figures show their final values, without the count-up or draw-in.

## How it's drawn

`InsightsSharePreview` (Sources/App/Views/InsightsShareView.swift, both targets) builds the card
again away from the screen, with the screen's environment objects attached, and draws it with
`ImageRenderer` at the display scale (at least 2×), 390 pt wide on iPhone and 560 pt on Mac. The
renderer is kept alive and redraws once the card has been quiet for 0.6 s (up to six times), so a
card that works its figures out a moment after appearing is pictured settled, not blank. The card
sits on the system grouped background so its glass reads the same wherever the picture lands.

Everything happens on the device. Nothing is uploaded until the person picks a destination.
