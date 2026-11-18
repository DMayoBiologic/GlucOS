import SwiftUI

/// The alert sound picker on iPhone and Mac (docs/AlertSounds.md). Tapping a sound selects it and
/// plays a preview, with three small bars beside it while it plays (still under Reduce Motion).
/// One preview at a time; leaving the screen stops it. Previews are audio only, never an alert.
struct AlertSoundList: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var player = AlertSoundPlayer.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ForEach(AlertSound.allCases) { sound in
            AlertSoundRow(sound: sound, selected: settings.alertSound == sound,
                          playing: player.preview.playing == sound) {
                settings.alertSound = sound
                player.tap(sound)
            }
        }
        .onDisappear { player.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.stop() }
        }
    }
}

private struct AlertSoundRow: View {
    let sound: AlertSound
    let selected: Bool
    let playing: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.title).foregroundStyle(.primary)
                    Text(sound.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AlertSoundLevelIndicator(playing: playing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sound.title)
        .accessibilityValue(Self.value(selected: selected, playing: playing, detail: sound.detail))
        .accessibilityHint(AlertSound.accessibilityHint)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    static func value(selected: Bool, playing: Bool, detail: String) -> String {
        [selected ? "Selected" : nil, playing ? "Playing" : nil, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Three bars that follow the preview's level while it plays, and lie flat otherwise. Under
/// Reduce Motion they stand still in a fixed shape while it plays. Hidden from VoiceOver: the
/// row's value says "Playing".
struct AlertSoundLevelIndicator: View {
    let playing: Bool
    @ObservedObject private var player = AlertSoundPlayer.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 3
    private let height: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing || reduceMotion)) { context in
            bars(heights(at: context.date))
        }
        .frame(width: barWidth * 3 + 4, height: height)
        .opacity(playing ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: playing)
        .accessibilityHidden(true)
    }

    private func heights(at date: Date) -> [Double] {
        guard playing else { return AlertSoundLevel.idle }
        if reduceMotion { return AlertSoundLevel.still }
        return AlertSoundLevel.heights(level: player.level(now: date), time: date.timeIntervalSinceReferenceDate)
    }

    private func bars(_ hs: [Double]) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(hs.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: barWidth, height: max(barWidth, height * hs[i]))
            }
        }
        .frame(height: height)
    }
}

#if os(iOS)
/// Settings › Alerts › Alert sound on iPhone: a row that opens the list.
struct AlertSoundPickerLink: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationLink {
            List {
                Section {
                    AlertSoundList()
                } footer: {
                    Text(AlertSound.footer)
                }
            }
            .navigationTitle(AlertSound.pickerTitle)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(AlertSound.pickerTitle, value: settings.alertSound.title)
        }
    }
}
#else
/// Settings › Alerts › Alert sound on the Mac: a button naming the sound that opens the list in a
/// popover. Closing the popover stops the preview.
struct AlertSoundPickerButton: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var open = false

    var body: some View {
        LabeledContent(AlertSound.pickerTitle) {
            Button(settings.alertSound.title) { open = true }
                .accessibilityLabel("\(AlertSound.pickerTitle), \(settings.alertSound.title)")
                .accessibilityHint("Opens the list of sounds. Choosing one plays a preview.")
                .popover(isPresented: $open, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        AlertSoundList()
                        Text(AlertSound.footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 280)
                    .environmentObject(settings)
                }
        }
    }
}
#endif
