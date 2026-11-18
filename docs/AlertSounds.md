# Alert sounds

Settings › Alerts › **Alert sound** picks the sound glucose alerts play, on iPhone and Mac.

| Sound | What it is |
| --- | --- |
| Standard | The device's own notification sound (what every alert played before) |
| Chime | Two bell notes falling a third, twice (1.9 s) |
| Pulse | Three short beeps, a breath, three more (1.3 s) |
| Beacon | Four rising notes, the last held (1.4 s) |

The three tones are synthesised by `scripts/make_alert_sounds.py` into `Sources/App/Sounds/*.wav`
(16-bit mono, -3 dBFS peak), so they carry no licence and can be redrawn. Both apps bundle them.

## Where it applies

- Every glucose alert: lows, urgent lows (their critical variant, which only sounds through silent
  mode where the critical alerts entitlement allows it), highs, predicted alerts, rapid change, no
  data, sensor ending.
- "Send a Test Alert" (docs/TestAlert.md) and the relay's test push, so a test sounds like a real
  alert.
- The push relay (2.20.0): the phone sends `alertSound` with its registration, and the owner's
  alert pushes name the same file (`alertSoundName` in `supabase/functions/relay/apns.ts`).
  Anything the relay doesn't know is `"default"`.
- Not: back in range (silent), check-ins, follower alerts (they keep the standard sound on the
  follower's phone), the evening recap and sensor reminder (no sound).

## Previews

Tapping a sound selects it and plays it once. On iPhone the picker is its own screen; on the Mac
the "Alert sound" button opens it in a popover.

- **One at a time.** Tapping another sound cuts the first one off; tapping the playing one again
  stops it. `AlertSoundPlayer.shared` is the only player, so two screens can't overlap either.
- **Stops when you leave.** Going back, closing the popover or the app leaving the foreground
  stops the preview.
- **Never an alert.** A preview is audio only (`AVAudioPlayer`, or the system sound for Standard).
  It never posts a notification, so it is never logged, snoozed, counted in the alert count
  preview or grouped into an episode. That is the difference from "Send a Test Alert", which sends
  a real (sample) notification.
- On iPhone previews play through the silent switch and duck music, like Settings' own tones.
  Standard plays the tri-tone (sound 1007), the nearest system sound; on the Mac it plays the
  alert sound from System Settings › Sound.

## The level indicator

Three small bars beside the playing row follow the player's meter (`AlertSoundLevel.heights`),
each swaying at its own rate. Standard has no meter, so its bars follow a fading strike over its
length. The bars only animate while a preview plays (a `TimelineView` that pauses otherwise) and
always stop by the sound's length plus half a second, even if the player never reports back.

- **Reduce Motion:** the bars stand still in a fixed shape while the preview plays.
- **VoiceOver:** each row is one element, "Chime, Selected, Playing, Two bell notes, twice", with
  the hint "Plays a preview and uses this sound for glucose alerts. Nothing is sent or logged."
  The bars themselves are hidden.

## Code

- `Sources/Core/AlertSound.swift`: the sounds, `AlertSoundPreview` (one-at-a-time rules) and
  `AlertSoundLevel` (bar heights). Tests: `AlertSoundTests`, which also checks every bundled file
  exists, is as long as `length` says, and is known to the relay.
- `Sources/App/AlertSoundPlayer.swift`: playback, metering, `notificationSound(critical:)`.
- `Sources/App/Views/AlertSoundViews.swift`: the list, rows, bars, the iPhone link and the Mac
  popover button.
- Settings search finds it by "sound", "tone", "ringtone", "chime" and others.
