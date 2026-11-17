# Logbook tags

Any Logbook entry (a dose, a meal, a site change or a moment) can carry tags, so it can be found
again later: "Exercise", "Sick", "Stress", "Alcohol", or the user's own ("Travel", "Night shift").

## Picking tags

Both log sheets (Mac `LogSheet`, iPhone `PhoneLogSheet`) have a **Tags** row under the note
(`LogTagPicker`, shared). It shows the four built-in tags, then the user's own tags by how often
they've been used, then **New Tag** to type one. Return (or leaving the field) adds it. Every
entry the sheet saves gets the same tags, and editing an entry shows and keeps its tags.

Rules (`Sources/Engine/LogbookTags.swift`, tests in `LogbookTagsTests`):

- A tag is trimmed, inner spaces collapse, a leading `#` is dropped, and it's cut to 24 characters.
- Case, accents and spacing don't make a different tag: "travel" and "Travel" are one. A built-in
  typed in any case takes the built-in spelling.
- At most 8 tags on one entry.

## Storage and sync

Each entry keeps its tags as `labels: [String]?` in logbook.json. Nil (no key at all) when there
are none, so untagged entries encode exactly as before. The sync payload is the encoded entry, so
tags reach the other device with no server change, and the later edit wins as for any other field.
An older app version reads a tagged entry fine but drops its tags if it edits that entry.

## Finding entries by tag

The Logbook's chip bar (iPhone) and filter row (Mac) add a chip for each tag in use, most used
first. One tag at a time, on top of the kind chip and the search: Meals and Exercise shows meals
tagged Exercise. Alert rows carry no tags, so they drop out while a tag chip is picked. The empty
list says "Nothing in Meals tagged Travel…", and Search All Dates treats a tag chip like a kind chip.

A "What else is going on?" choice that matches a built-in tag counts as that tag for the chip:
Exercise, Unwell (as Sick), Stress and Alcohol moments show under those chips too.

Tags are also searched as words, and shown in the row's detail line (iPhone), the opened entry's
detail ("Tags"), and the Mac table's Details column.

## What tags don't do

Tags are labels for finding things. Insights, the forecast and the bolus calculator never read
them. The "What else is going on?" choices (`ContextTag`) still decide which examples Insights sets
aside.
