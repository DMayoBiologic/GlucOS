# Insights: Alerts

An Insights card on the iPhone and the Mac that sums up the low and high alerts of the last 7, 14 or 30 days: how many went off, of which kind, and how each one ended. It's built from the same records as Settings › Alerts › Alert History (docs/AlertHistory.md), and tapping it opens that list.

## What it shows

- **Headline**: "9 alerts in the last 14 days."
- **Alerts, Low, High**: the total, the low and predicted low alerts, and the high and predicted high alerts. Low and High take their range's colour when there are any.
- **By kind**: four bars, Low and urgent low, Predicted low, High and very high, Predicted high, each with its count.
- **How they ended**: one bar split by outcome, with a key under it giving each part's symbol, name and count, so colour is never the only cue. The outcomes are the Alert History's: Tapped Log treatment, Snoozed, Dismissed and No response. Under it a line such as "7 of 9 got a response."
- **Footnote**: each alert counts once, even when the Mac and iPhone both showed it, and test alerts aren't counted. If GlucOS only started keeping alerts partway through the period, it says from when ("GlucOS has kept alerts since 15 Nov 2026").
- **Open Alert History**, at the foot of the card. Tapping anywhere on the figures does the same.

It only observes. It never suggests a dose, a treatment or a change to any setting.

## Rules

- Alerts come from `AlertHistory.items`, called with the card's period start (`since:`) rather than the history's 7 days. Only low and high alerts are kept. The Mac's and the iPhone's copies of one alert within 3 minutes count once, and the best outcome is kept (treating, then snoozed, then dismissed, then no response).
- The period ends at now on the latest. Once Insights is stepped back (docs/InsightsPeriodStep.md) it ends where the other cards' periods end. It runs back the period's calendar days (`InsightsPeriodStep.start`), so it keeps its clock time across a daylight-saving change. An alert exactly at the start belongs to the period before.
- The picker is stored in `insights.alertsDays` (default 14) and the shared picture's footer reads it too (`InsightsShare.Key.alerts`).

## Compare to previous period

With the switch on (docs/InsightsCompare.md), Alerts, Low and High get an up or down badge against the same-length period before. Fewer is better. The period before is compared only when:

1. it has readings on 4 of every 7 of its days, as the other cards ask, and
2. GlucOS was already keeping alerts then: the oldest alert record reaches back to within a day of that period's start.

Without the second rule, the weeks before alert logging existed would read as "no alerts", and every card would look like it got worse.

## When it shows

- The card stays off the screen until a low or high alert has been recorded (`AlertsSummary.shows`), as Tags does until something is tagged. Its place in the order is kept, so it appears where the person put it.
- In a period with no alerts it shows the empty note (docs/EmptyStates.md): "No alerts in 7 days", with **Show 30 Days** when a longer period had some (`InsightsEmptyState.alerts`). Otherwise it says why, with no button.

## Opening Alert History

- **iPhone**: the card zooms into Alert History on the home stack (`PhoneRoute.alertHistory`, zoom source `AlertsCardMotion.sourceID`), like the Lows card into the Logbook. Back shrinks it into the card again, whichever period it shows. Under Reduce Motion it's a plain push. A row pushes the Logbook around its alert on top, so Back comes back to Alert History, then Insights.
- **Mac**: the dashboard cross-fades Insights to Alert History in place (`InsightsAlertHistoryPage`). "‹ Insights", Esc or any sidebar pick cross-fades back, and Insights scrolls to the Alerts card. A row opens the Logbook around its alert, as from Settings.
- Where the card has no way in (the Mac card outside the dashboard, the iPhone card without the home stack), the old route stays: `AlertHistoryOpenRequest` opens Settings › Alerts › Alert History. A request nobody picks up within 10 seconds is dropped, so it can never open the sheet by surprise later.

## Motion

Numbers live in `AlertsCardMotion` (tests: `AlertsCardMotionTests`).

- **Reveal**: as the card rises in (docs/InsightsLayout.md, `onEntrance`), the Alerts, Low and High totals count up once, and the four kind bars grow from the leading edge one after another (0.15 s, then 0.045 s apart), then the outcome bar. Once per visit, never a loop.
- **Period changes and stepping**: figures roll to the new counts and the bars glide to their new lengths. Outcome parts keep their order and width 0 when empty, so a new outcome widens into place instead of the colours shifting.
- **Compare to previous period**: the period before shares the kind bars' scale, so turning the switch on or off glides the bars to the new scale while a thin mark on each track (where the period before's bar would end) fades in or out. A thinner "Before" outcome bar grows in under the main one. A one-line key names the mark.
- **Reduce Motion**: the bars fade in rather than grow, and cross-fade to new counts and marks rather than gliding (0.2 s). Figures show their values at once.
- **VoiceOver**: the card is one element, a button that opens Alert History. It reads its sentences, then any compare lines, and says nothing on its own while the bars move.

## Files

- `Sources/Engine/AlertsSummary.swift`: `AlertsSummary`, `AlertsSummaryText`, `InsightsCompare.alerts/lowAlerts/highAlerts` and `InsightsEmptyState.alerts`. Tests: `Tests/EngineTests/AlertsSummaryTests.swift`.
- `Sources/App/Views/AlertsCardView.swift`: the card, its bars, and `AlertHistoryOpenRequest`.
- `InsightsCard.alerts` sits after Highs in both shipped orders.
