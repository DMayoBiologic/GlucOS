# Insights explainers

Each Glance figure has a small ⓘ beside it. It opens a short plain-language note on what the
figure means and how GlucOS worked it out for the period on screen, with that period's own
numbers:

- **Time in range**: the share of readings inside the target range, quoting the range.
- **Average**: every reading added up and divided by how many there were.
- **GMI**: `3.31 + 0.02392 × average in mg/dL`, with the period's average and result. Under 14 days
  of readings it says it is only a rough guide, and it always says a lab A1c can differ.
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

Since round 71 the note grows out of the figure it explains (`InsightsExplainerEntrance`):

- **iPhone:** the sheet zooms out of the tapped figure (the ring, the Average, GMI or CV tile, or
  the "Below" share) with a matched-geometry zoom, and shrinks back into it on Done or a swipe
  down. Each figure is its own zoom source. The note inside doesn't scale as well.
- **Mac:** the popover hangs off the whole figure tile, not just the ⓘ, and the note scales up
  from 0.9 at its top edge (the side touching the figure) with a fade on the emphasized spring.
- **Reduce Motion:** nothing zooms or scales. On iPhone the sheet opens and closes without its
  slide and the note fades in (0.2 s); on the Mac the note only fades.

It plays once per open and close; nothing loops. The note's title is a heading, and with
VoiceOver on, focus moves to it once the note has landed (0.55 s, or 0.25 s under Reduce Motion).
The rest of the note reads as one element after it: meaning, "How it's worked out", the
worked-out line and the caveat. The buttons are labelled "About time in range" and so on.
