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

- **iPhone**: the tap sets `AlertHistoryOpenRequest`. The home stack opens Settings with `Jump.alertHistory`, which scrolls to Alerts and pushes Alert History. Done comes back to Insights. A row in the history still closes Settings and opens the Logbook around that alert.
- **Mac**: the click sets the Settings tab to Alerts, sets the request and calls `openSettings()`. The Alerts tab opens its Alert History sheet when it sees the request.
- A request that nobody picks up within 10 seconds is dropped, so it can never open the sheet by surprise later.

## Motion

The figures count up as the card rises in (docs/InsightsLayout.md, `onEntrance`) and roll to new values when the period changes. The bars grow in from the leading edge once, then glide to new counts. Nothing loops. Under Reduce Motion the bars and figures show their values at once. VoiceOver hears the card as one element: its sentences, then any compare lines.

## Files

- `Sources/Engine/AlertsSummary.swift`: `AlertsSummary`, `AlertsSummaryText`, `InsightsCompare.alerts/lowAlerts/highAlerts` and `InsightsEmptyState.alerts`. Tests: `Tests/EngineTests/AlertsSummaryTests.swift`.
- `Sources/App/Views/AlertsCardView.swift`: the card, its bars, and `AlertHistoryOpenRequest`.
- `InsightsCard.alerts` sits after Highs in both shipped orders.
