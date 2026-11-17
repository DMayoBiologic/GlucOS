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
  Highs, Overnight, Weekdays and weekends, In-range streaks, Best and toughest days, Tags, Your usual
  day, Time in range by hour and Forecast accuracy. Tags is left off both screens until some entry carries a tag; its
  place in the order is kept, and it stays in the Edit list and the customise sheet.

## Motion

Cards spring into their new places (`DSMotion.emphasized`). Under Reduce Motion the stack
cross-fades to the new order instead (0.25 s ease in out), so nothing slides past anything else.

## Storage, sync and new cards

`InsightsLayout` (Sources/Engine/InsightsLayout.swift) holds the order of every card the person has
placed, hidden ones included, and the set of hidden cards, as raw strings. Each screen's layout is
kept in the logbook (`LogbookStore.insightsLayouts`, in logbook.json) and syncs like the bolus
calculator settings: one record per screen, kind `insightsLayout`, with a fixed id
(`InsightsScreen.recordID`). The iPhone and Mac layouts stay separate, because the two screens have
different cards, but a second iPhone, a second Mac or a reinstall gets the same order and hidden
cards back. The later edit wins. Followers never see these records.

- **Restore Standard Order** removes the record, so every device goes back to the shipped order.
- **Builds before sync** kept the layout in UserDefaults (`insights.layout.phone`,
  `insights.layout.mac`). The first launch of a syncing build moves it into the logbook as older
  than anything on the server, so a layout another device already synced wins, and then removes
  the old key.
- **Nothing chosen** keeps no record and shows the shipped order.
- **A new card** (one that isn't in the stored order) always shows, slotted in after the card it
  follows in the shipped order, so it lands near its neighbours rather than at the bottom.
- **A hidden card keeps its slot**, so dragging other cards past it and then restoring it puts it
  back where it was.
- **Unknown names** (a newer build's card, after going back a version) are kept at the end of the
  stored order, so going forward again restores them.

Adding a card: add a case to `InsightsCard` (title, symbol), put it in `phoneDefault` and/or
`macDefault` where it ships, and add it to the switch in `PhoneInsightsView.view(for:)` and/or
`InsightsSection.view(for:)`. Raw values never change once shipped.
