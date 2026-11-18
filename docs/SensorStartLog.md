# Sensor started in the Logbook

When GlucOS first sees a new sensor, it adds one **Sensor started** event to the Logbook at the
time the sensor started. Nobody has to log it. It shows like any other event: a Logbook row, a
chart marker (iPhone Today, the Mac popover and Outlook), in search ("sensor"), in exports
("Sensor started") and on the Mac dashboard chart.

## What counts as a new sensor

- LibreLinkUp reports the sensor with every fetch (`SensorInfo`: serial, start time, life).
  `GlucoseStore.publish` hands it to `LogbookStore.logSensorStart` each time; that does nothing
  once the sensor is handled.
- An iPhone NFC scan that reads the sensor's memory also counts (start = scan time minus the
  sensor's age in minutes). Gen 2 sensors, which refuse plain reads, only come through LinkUp.
- The sensor is identified by its serial, or by its start time when LibreLinkUp gives no serial.
- Not logged: with the setting off, on a follower-only iPhone, with no sensor, for a start more
  than a minute in the future (a clock problem), or for a sensor older than its life.
- A start already in the Logbook within 30 minutes of this one counts as the same sensor seen
  another way (an NFC serial needn't read like LinkUp's), so it isn't logged twice.

The rules are in `Sources/Engine/SensorStartLog.swift` and covered by `SensorStartLogTests`.

## One event across devices

- The event's id is worked out from the serial (`SensorStartLog.id`), so the Mac and the iPhone
  that both see the sensor write the same record and sync keeps one. Its first four bytes are a
  fixed marker, so a synced record can be told to be a sensor start without its payload.
- It is saved with the sensor's start as its edit time. Any later change on any device (an edit,
  Undo, a delete) is newer and wins under the logbook's last-writer-wins rule, so a device that sees
  the sensor after the event was deleted elsewhere can't bring it back. The server refuses the older
  write, and that device drops its own copy on its next full pull (at most 12 hours).
- Each device remembers the sensors it has handled (`sensorStartLog.handled` in UserDefaults, the
  latest 40): logged, found already in the logbook, or seen in a synced record. A deleted event
  never comes back on its own.

## Undo

A start in the last 12 hours offers the usual undo toast: "Logged sensor start · Undo". Undo
deletes it on every device. On the Mac the toast also shows over the menu bar popover and the
dashboard's other pages, as "Logged twice?" does. An older start (the sensor already being worn
when GlucOS updated, or a device that was off during the change) is logged quietly; it can be
deleted from the Logbook like any entry.

## What it doesn't do

It only marks a time. The `sensorStarted` tag doesn't affect forecasts, insights, the learners or
the bolus calculator (`affectsResponses` and `isComparable` are false, `reach` is 0), isn't a
"last logged" entry, isn't a log time for the forecast ledger, and isn't offered in the log sheet's
list for a new entry (`isAutomatic`). A chart marker offers Edit only. A version older than this
one reads the event as an untitled event, since it skips tags it doesn't know.

## Setting

iPhone Settings › Logging › **Log new sensors**, Mac Settings › Logging › Sensor › **Log new
sensors** (`AppSettings.logSensorStarts`, on by default, per device). Found in Settings search
under "sensor", "started" and "automatic".
