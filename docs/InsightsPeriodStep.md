# Step through earlier Insights periods

Insights can show earlier periods, not just the latest. Each card with a period moves to the period
of the same length just before the one it shows: a 7-day card moves 7 days, a 30-day card 30 days,
At a glance on 24h one day. Insights never steps past today.

## Where

- **iPhone**: swipe sideways anywhere on Insights. Swipe right for the period before, left for the
  one after. A strip under "Compare to previous period" says where you are ("Latest",
  "2 periods earlier") and has Earlier and Later buttons, plus Latest once you've stepped back.
  A swipe has to be clearly sideways, so scrolling never steps, and a swipe from the screen's left
  edge still goes back. Each step plays the light `choice` tick. Insights opens on the latest each
  visit.
- **Mac**: ⌘[ and ⌘] or the toolbar's Earlier and Later arrows, on the Dashboard's Insights page.
  **Latest** (⌘J) appears once you've stepped back, and the window subtitle says how far back.

## Cards

| Steps | Keeps the latest |
| --- | --- |
| At a glance (iPhone), Lows, Highs, Overnight, Weekdays and weekends, Best and toughest days, Tags, Your usual day, Time in range by hour | Days, Week in review, In-range streaks, Mornings, Forecast accuracy, the Mac's logbook cards |

A card that has stepped back shows its dates under its period picker: "7 days · 27 Oct – 2 Nov 2026".
Compare to previous period then compares with the period before that one. A shared picture's footer
names the same dates ("Lows · 14 days · 20 Oct – 3 Nov 2026").

## Rules (`Sources/Engine/InsightsPeriodStep.swift`)

- A period of whole days steps by calendar days, so it ends at the same clock time across a
  daylight-saving change and the dates roll over month and year ends the way the calendar does.
- A card's period ends that many steps before its newest reading (now, for At a glance). The card
  is worked out on the readings up to that end, so its own rules are unchanged.
- The screen can step earlier while a 7-day period that far back still ends after the first stored
  reading (and at most 60 steps). Cards with longer periods can run out first; they show their own
  empty state.
- It only picks which readings a card sees. No dosing maths.

## Accessibility and motion

The figures roll to the new period as they do when the period picker changes, and each card's dates
slide in from the side the period came from (a cross-fade under Reduce Motion). VoiceOver hears the
iPhone strip, and the Mac's toolbar arrows on Insights, as one adjustable "Period" control: swipe up
for a later period, down for an earlier one. The iPhone strip also has a "Show Latest" action. Each
card's dates read as "Showing the 7 days to 2 Nov 2026".
