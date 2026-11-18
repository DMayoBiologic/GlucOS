import Foundation

/// The sound glucose alerts play, picked in Settings › Alerts › Alert sound on iPhone and Mac
/// (docs/AlertSounds.md). `standard` is the device's own notification sound, as before; the
/// others are short tones bundled with the app (Sources/App/Sounds, drawn by
/// scripts/make_alert_sounds.py). The relay pushes the same file name (relay 2.20.0), so an alert
/// sounds the same whether the phone or the relay sent it.
///
/// Only glucose alerts use it. Back in range stays silent, check-ins and follower alerts keep the
/// standard sound, and the evening recap and sensor reminder make none.
enum AlertSound: String, CaseIterable, Codable, Hashable, Identifiable {
    case standard, chime, pulse, beacon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .chime: "Chime"
        case .pulse: "Pulse"
        case .beacon: "Beacon"
        }
    }

    /// One line under the name, also read by VoiceOver.
    var detail: String {
        switch self {
        case .standard: "Your device's notification sound"
        case .chime: "Two bell notes, twice"
        case .pulse: "Three short beeps, twice"
        case .beacon: "Four rising notes"
        }
    }

    /// The bundled file, nil for the device's own sound. The relay sends the same name.
    var fileName: String? {
        switch self {
        case .standard: nil
        case .chime: "glucos-chime.wav"
        case .pulse: "glucos-pulse.wav"
        case .beacon: "glucos-beacon.wav"
        }
    }

    /// About how long it plays, so the preview's indicator still stops if the player never says
    /// it finished (the device's own sound gives no length).
    var length: TimeInterval {
        switch self {
        case .standard: 1.0
        case .chime: 1.87
        case .pulse: 1.3
        case .beacon: 1.43
        }
    }

    /// A stored or relayed value; anything unknown is the standard sound.
    init(stored: String?) {
        self = stored.flatMap(AlertSound.init(rawValue:)) ?? .standard
    }

    static let pickerTitle = "Alert sound"
    static let accessibilityHint = "Plays a preview and uses this sound for glucose alerts. Nothing is sent or logged."
    static let footer = "Tap a sound to hear it. Previews never count as alerts. Urgent lows use it too."
}

/// The preview in the alert sound picker: which sound is playing, one at a time. Tapping a sound
/// plays it, cutting off any other; tapping the one playing stops it; leaving the screen stops it.
/// Plain state, so the rules are tested without audio (AlertSoundTests). Never an alert: nothing
/// here reaches notifications, the alert log, episodes or snoozes.
struct AlertSoundPreview: Equatable {
    enum Step: Equatable { case stop, play(AlertSound) }

    private(set) var playing: AlertSound?
    private(set) var startedAt: Date?

    /// What a tap on `sound`'s row does: stop whatever plays, then play it, unless it was the one
    /// playing (a second tap stops it). The row is selected either way.
    mutating func tap(_ sound: AlertSound, now: Date) -> [Step] {
        if isPlaying(sound, now: now) {
            playing = nil; startedAt = nil
            return [.stop]
        }
        let wasPlaying = playing != nil
        playing = sound; startedAt = now
        return wasPlaying ? [.stop, .play(sound)] : [.play(sound)]
    }

    /// The player finished `sound`. A late finish from a sound already replaced is ignored.
    mutating func finished(_ sound: AlertSound) {
        guard playing == sound else { return }
        playing = nil; startedAt = nil
    }

    /// The screen went away (or the app went to the background).
    mutating func leave() -> Step? {
        guard playing != nil else { return nil }
        playing = nil; startedAt = nil
        return .stop
    }

    /// Playing, and not past its length (plus a little): the indicator never sticks on.
    func isPlaying(_ sound: AlertSound, now: Date) -> Bool {
        guard playing == sound, let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < sound.length + 0.5
    }

    func progress(now: Date) -> Double? {
        guard let playing, let startedAt, isPlaying(playing, now: now) else { return nil }
        return min(1, max(0, now.timeIntervalSince(startedAt) / playing.length))
    }
}

/// The three bars beside a playing row.
enum AlertSoundLevel {
    static let bars = 3
    /// Under Reduce Motion: still bars, a fixed "sound on" shape.
    static let still: [Double] = [0.45, 0.85, 0.6]
    /// Not playing: flat.
    static let idle: [Double] = [0.2, 0.2, 0.2]

    /// Bar heights (0.2...1) for a level (0...1, from the player's meter) at a time: each bar
    /// sways at its own rate around the level, so it reads as sound rather than one bar.
    static func heights(level: Double, time: TimeInterval) -> [Double] {
        let l = min(1, max(0, level))
        return (0..<bars).map { i in
            let sway = 0.5 + 0.5 * sin(time * (9 + Double(i) * 4.3) + Double(i) * 1.7)
            return 0.2 + 0.8 * l * (0.55 + 0.45 * sway)
        }
    }

    /// A level from the meter's average power in dB (-160...0).
    static func level(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        return Double(min(1, max(0, (decibels + 45) / 45)))
    }

    /// For a sound with no meter (the device's own): a strike that fades over its length.
    static func envelope(progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return p >= 1 ? 0 : exp(-2.5 * p)
    }
}
