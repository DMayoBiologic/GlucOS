import Foundation
import AVFoundation
import UserNotifications
#if canImport(UIKit)
import AudioToolbox
#else
import AppKit
#endif

/// Plays the alert sound picker's previews (docs/AlertSounds.md), one at a time across the app.
/// A preview is only audio: it never goes through notifications, so it is never logged, snoozed,
/// counted or grouped into an episode, and is unlike "Send a Test Alert" (TestAlert.swift), which
/// sends a real notification.
@MainActor
final class AlertSoundPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AlertSoundPlayer()

    @Published private(set) var preview = AlertSoundPreview()
    private var player: AVAudioPlayer?

    /// A row was tapped. Returns whether `sound` is now playing.
    @discardableResult
    func tap(_ sound: AlertSound, now: Date = Date()) -> Bool {
        for step in preview.tap(sound, now: now) {
            switch step {
            case .stop: halt()
            case .play(let s): start(s)
            }
        }
        return preview.isPlaying(sound, now: now)
    }

    /// Leaving the screen, or the app leaving the foreground.
    func stop() {
        if preview.leave() != nil { halt() }
    }

    /// 0...1 for the level indicator. Bundled sounds read the player's meter; the device's own
    /// sound has none, so it fades over its length.
    func level(now: Date = Date()) -> Double {
        guard let playing = preview.playing, preview.isPlaying(playing, now: now) else { return 0 }
        if let player, player.isPlaying {
            player.updateMeters()
            return AlertSoundLevel.level(decibels: player.averagePower(forChannel: 0))
        }
        return AlertSoundLevel.envelope(progress: preview.progress(now: now) ?? 1)
    }

    private func start(_ sound: AlertSound) {
        guard let name = sound.fileName else { playStandard(); return }
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            preview.finished(sound)
            return
        }
        #if canImport(UIKit)
        // Heard even with the ring switch on silent, ducking music, as Settings' own tones are.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        p.isMeteringEnabled = true
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        scheduleFallbackEnd(for: sound)
    }

    private func playStandard() {
        #if canImport(UIKit)
        // The tri-tone, the closest a sound ID comes to iOS's own notification sound.
        AudioServicesPlaySystemSound(1007)
        #else
        // macOS plays the alert sound chosen in System Settings › Sound for notifications.
        NSSound.beep()
        #endif
        scheduleFallbackEnd(for: .standard)
    }

    /// Ends the indicator after the sound's length even if the player never reports back.
    private func scheduleFallbackEnd(for sound: AlertSound) {
        let started = preview.startedAt
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(sound.length + 0.1))
            guard let self, self.preview.playing == sound, self.preview.startedAt == started else { return }
            self.finish(sound)
        }
    }

    private func finish(_ sound: AlertSound) {
        preview.finished(sound)
        if preview.playing == nil { halt() }
    }

    private func halt() {
        player?.stop()
        player?.delegate = nil
        player = nil
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player, let playing = self.preview.playing else { return }
            self.finish(playing)
        }
    }
}

extension AlertSound {
    /// The notification sound for an alert. Urgent lows (`critical`) keep the critical variant,
    /// which only sounds through silent mode where the critical alerts entitlement allows it.
    func notificationSound(critical: Bool) -> UNNotificationSound {
        guard let fileName else { return critical ? .defaultCritical : .default }
        let name = UNNotificationSoundName(fileName)
        return critical ? .criticalSoundNamed(name) : UNNotificationSound(named: name)
    }
}
