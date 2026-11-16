# Reordering and hiding Insights cards

People use Insights differently: one person opens it for Lows, another for the usual day. Both
Insights screens let them put the cards in their own order and hide the ones they don't use.

## iPhone

- **Edit** in the Insights toolbar swaps the cards for an edit list (a cross-fade). The **Shown**
  section has drag handles; the minus button hides a card. Hidden cards wait in the **Hidden**
  section, and the plus button brings one back. **Restore Standard Order** undoes everything.
  **Done** goes back to the cards.
- Touch and hold a card for **Move Up**, **Move Down**, **Hide** and **Edit Cards…**.
- VoiceOver users reorder in the edit list with the standard List move actions.

## Mac

- **Customise Cards…** above the movable cards on the Dashboard's Insights page opens a sheet with
  the same Shown and Hidden sections. Drag rows to reorder; Hide and Show buttons on each row;
  VoiceOver has Move up and Move down actions on each shown row. Changes apply as they're made.
- Right-click a card for **Move Up**, **Move Down**, **Hide** and **Customise Cards…**.
- The logging cards (the safety note, insulin action, meals and sites) stay fixed at the top. They
  depend on the therapy setting and read as one block. The movable cards are Week in review, Lows,
  Highs, Overnight, Weekdays and weekends, In-range streaks, Your usual day and Forecast accuracy.

## Motion

Cards spring into their new places (`DSMotion.emphasized`). Under Reduce Motion the stack
cross-fades to the new order instead (0.25 s ease in out), so nothing slides past anything else.

## Storage and new cards

`InsightsLayout` (Sources/Engine/InsightsLayout.swift) holds the order of every card the person has
placed, hidden ones included, and the set of hidden cards, as raw strings. It is stored as JSON in
UserDefaults on each device, under `insights.layout.phone` and `insights.layout.mac`. It isn't
synced: the two screens have different cards.

- **Nothing chosen** stores an empty string and shows the shipped order.
- **A new card** (one that isn't in the stored order) always shows, slotted in after the card it
  follows in the shipped order, so it lands near its neighbours rather than at the bottom.
- **A hidden card keeps its slot**, so dragging other cards past it and then restoring it puts it
  back where it was.
- **Unknown names** (a newer build's card, after going back a version) are kept at the end of the
  stored order, so going forward again restores them.

Adding a card: add a case to `InsightsCard` (title, symbol), put it in `phoneDefault` and/or
`macDefault` where it ships, and add it to the switch in `PhoneInsightsView.view(for:)` and/or
`InsightsSection.view(for:)`. Raw values never change once shipped.
