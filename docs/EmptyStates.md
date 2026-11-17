# Empty states

When an Insights card or a Logbook search has nothing to show, it says why in a sentence and
offers the one thing that helps, instead of leaving a blank area. This works the same on the
iPhone and the Mac.

## Insights cards

Each card keeps its own line about what it needs (its `emptyLine`). Once the card turns out empty,
`InsightsEmptyNote` (Sources/App/Views/InsightsEmptyNote.swift) works out an `InsightsEmptyState`
(Sources/Engine/InsightsEmptyState.swift) off the main thread and cross-fades to it. Under Reduce
Motion it swaps at once. A card with figures never does this work.

| Situation | Title | Button |
| --- | --- | --- |
| No readings at all | No readings yet | none |
| This period is too thin, a longer one of the card's periods has figures | Not enough in 7 days | Show 14 Days (the shortest that works) |
| No period has enough yet | Still gathering readings, with "So far: 2 days of 3" while short of the card's days | none |
| Tags card, nothing tagged in this period but a longer one has tags | Nothing tagged in 7 days | Show 30 Days |
| Tags card, nothing tagged in any period | Nothing tagged in 14 days | Log Something (opens the log sheet) |

- A longer period is offered only after the card's own compute returns figures for it, so the
  button never leads to another empty card. Periods are tried shortest first, and the search stops
  at the first hit.
- Week in review and Streaks have no period picker, so they only say "no readings" or how many
  days so far.
- A shared picture of a card (docs/InsightsShare.md) leaves the button out.
- On the iPhone, every card hidden shows "Every card is hidden" with Edit Cards.

## Logbook

The Logbook already said "Nothing logged yet" (with Log Something) and "No matches" (with the
search explained, plus Search All Dates when a day narrowed it). The No matches button now names
what it takes away (`LogbookSearch.clearTitle`):

- words only: Clear Search
- one chip (a filter or a tag): Clear Filter
- a day only (a typed day, or the days an Insights card opened the Logbook on): Show All Dates on
  the iPhone. The Mac goes back to its toolbar period, so it says Clear Search.
- more than one of these: Clear Filters

Tests: Tests/EngineTests/EmptyStateTests.swift.
