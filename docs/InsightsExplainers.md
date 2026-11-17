# Insights explainers

Each Glance figure has a small ⓘ beside it. It opens a short plain-language note on what the
figure means and how GlucOS worked it out for the period on screen, with that period's own
numbers:

- **Time in range**: the share of readings inside the target range, quoting the range.
- **Average**: every reading added up and divided by how many there were.
- **GMI**: `3.31 + 0.02392 × average in mg/dL`, with the period's average and result. Under 14 days
  of readings it says to treat it as a rough guide, and it always says a lab A1c can differ.
- **Variability (CV)**: standard deviation ÷ average, with both figures, and the 36% mark the
  cards already show.
- **Time below range**: the share of readings under the bottom of the range.

With fewer than 12 readings every note adds that the figure may change a lot as more arrive.

## Where

- iPhone: the At a glance card in Insights (ring, Average, GMI, CV tiles, and the Below legend). A
  sheet with Done, medium and large detents. Not on the follower view, and hidden while the card is
  drawn into a shared picture.
- Mac: the Overview's four headline tiles (Time in range, Average, Variability, Time below) and GMI
  on the Statistics card. A popover.
- The period reads "the last 7 days", or "the 7 days ending 2 Nov" once stepped back.

## Rules

- The notes describe the figure. No advice, no doses, no targets beyond the ones the cards already
  name. `InsightsExplainerTests` checks every figure has a note and none uses advice or dosing words.
- Text lives in `Sources/Engine/InsightsExplainer.swift`; views in
  `Sources/Core/InsightsExplainerViews.swift` (Core, not Shared, since the widgets don't build the
  engine).

## Motion and accessibility

The note scales in from 0.94 with a fade on the emphasized spring; under Reduce Motion it only
fades (0.2 s). VoiceOver reads the note as one element in full: title, meaning, "How it's worked
out", the worked-out line and the caveat. The buttons are labelled "About time in range" and so on.
