# Logbook search (iPhone)

Round 17 of the improvement loop. The iPhone Logbook's search field and chips are there to find
"that pizza last week" in a couple of taps. Everything runs on what's already on the phone (the
synced logbook and the alert records), so search works offline. Rules live in
`Sources/Engine/LogbookSearch.swift` and are covered by `LogbookSearchTests`.

## What the search reads

- **Words.** Every word has to be found somewhere in the entry. Case, accents and a plain plural
  don't matter ("PIZZAS" finds "Pizza"). Words like "that", "the" and "I had" are skipped.
- **Where it looks.** The row's title and note, a meal's foods, an insulin's name, type, site and
  purpose, a moment's tags, the kind of entry ("insulin", "meal", "site"), and "low"/"hypo" on
  anything logged with a Hypo treatment tag. Alert rows are found by their title and what was tapped.
- **Days.** One stretch of time per search: `today`, `yesterday`, `tonight`, `this morning`,
  `last night` (5 pm to 7 am), `this week`, `this month`, `last week` and `last month` (both run up
  to now, since "last week" often means four days ago), weekdays (`monday`, `fri`, `last thursday`:
  the latest one, today included unless "last"), `last 3 days`, `past 2 weeks` and `2 days ago`.
  "sat" and "sun" aren't read as days.

What the search understood shows as a chip above the list ("Since last week ✕") with how many
rows it found. Tapping the chip drops the time part and keeps the words.

## Quick filter chips

All, then whichever of these would show something: **Meals**, **Insulin**, **Lows** (Hypo treatment
tags, the food or insulin logged with one, and low alert rows), **Notes** (anything with a note),
**Sites**, **Moments**, **Alerts**. One chip at a time, on top of the search.

## Highlights and the empty list

The words found are bold, on a faint wash of the row's own colour, in the row's title and its
second line. When nothing matches, the list says what was searched ("Nothing in Meals matches
“pizza” since last week.") with **Clear Filters**, and **Search All Dates** when a day was part of it.

The Mac Logbook keeps its own plain search for now.
