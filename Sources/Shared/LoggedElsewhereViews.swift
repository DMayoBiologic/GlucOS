import SwiftUI
import Charts
import Accessibility

/// The app's own list of entries logged from outside the Logbook (`LoggedElsewhereMarks`). The log
/// sheets record what they saved when they were opened from Siri, a control, an alert or a widget;
/// Logbook rows and the chart take their highlight from here as they appear. Kept in memory only:
/// relaunching the app is a fresh start, and nothing about it syncs.
@MainActor
final class LoggedElsewhere {
    static let shared = LoggedElsewhere()

    /// How long the caption stays before it fades.
    static let hold: TimeInterval = 2.4
    /// The fade in and out: an opacity change, so it reads the same under Reduce Motion.
    static let fade = Animation.easeInOut(duration: 0.45)

    private var marks = LoggedElsewhereMarks()

    /// Entries just saved by a log sheet opened from `origin`. Nothing happens for a sheet opened
    /// in the app (`origin == nil`).
    func record(_ ids: [UUID], from origin: LogOrigin?) {
        guard let origin else { return }
        marks.record(ids, from: origin, at: Date())
    }

    func isPending(_ id: UUID, on surface: LoggedElsewhereMarks.Surface) -> Bool {
        marks.isPending(id, on: surface, at: Date())
    }

    func take(_ id: UUID, on surface: LoggedElsewhereMarks.Surface) -> LoggedElsewhereMarks.Highlight? {
        marks.take(id, on: surface, at: Date())
    }

    func forget(_ ids: [UUID]) { marks.forget(ids) }

    /// Low priority, so "Saved" from the closing sheet finishes first.
    static func announce(_ text: String) {
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
    }
}

extension View {
    /// One soft tint behind a Logbook row logged from elsewhere, the first time it appears, with its
    /// caption handed to the row through `caption` while it shows. Fades in, holds, fades out; once.
    func loggedElsewhereRow(_ id: UUID, tint: Color, title: String?, caption: Binding<String?>,
                            enabled: Bool = true) -> some View {
        modifier(LoggedElsewhereRowHighlight(id: id, tint: tint, title: title, caption: caption, enabled: enabled))
    }
}

@MainActor
private struct LoggedElsewhereRowHighlight: ViewModifier {
    let id: UUID
    let tint: Color
    let title: String?
    @Binding var caption: String?
    let enabled: Bool
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(tint.opacity(lit ? 0.14 : 0))
                    .padding(.horizontal, -DS.Space.xs)
                    .allowsHitTesting(false)
            }
            .task(id: id) { await play() }
    }

    private func play() async {
        guard enabled, let h = LoggedElsewhere.shared.take(id, on: .logbook) else { return }
        if h.delay > 0 { try? await Task.sleep(for: .seconds(h.delay)) }
        withAnimation(LoggedElsewhere.fade) {
            lit = true
            caption = h.origin.caption
        }
        if h.announces { LoggedElsewhere.announce(LoggedElsewhereMarks.spoken(h.origin, entry: title)) }
        // Cut short if the row goes; it still fades rather than staying lit.
        try? await Task.sleep(for: .seconds(LoggedElsewhere.hold))
        withAnimation(LoggedElsewhere.fade) {
            lit = false
            caption = nil
        }
    }
}

/// A chart marker logged from elsewhere: one soft ring that eases out of it and fades, with the
/// caption above it. Under Reduce Motion the ring doesn't grow; it and the caption just fade in and
/// out. Placed with the chart's proxy exactly where the marker is drawn; calls `done` once.
struct LoggedElsewhereMarkerGlow: View {
    let proxy: ChartProxy
    let date: Date
    let value: Double
    let tint: Color
    let origin: LogOrigin
    let delay: TimeInterval
    let done: () -> Void
    @State private var ring = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: date),
               let y = proxy.position(forY: value) {
                let origin = geo[plot].origin
                let point = CGPoint(x: origin.x + x, y: origin.y + y)
                Circle()
                    .stroke(tint, lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(reduceMotion ? 1.3 : (ring ? 1.9 : 1))
                    .opacity(reduceMotion ? (shown ? 0.55 : 0) : (ring ? 0 : (shown ? 0.7 : 0)))
                    .position(point)
                Text(self.origin.caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, DS.Space.xs + 2)
                    .padding(.vertical, DS.Space.xxs)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(shown ? 1 : 0)
                    .position(captionPoint(for: point, in: geo.size))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// Above the marker, kept inside the chart so a marker near either edge doesn't cut it off.
    private func captionPoint(for p: CGPoint, in size: CGSize) -> CGPoint {
        let half: CGFloat = 70
        let x = size.width > half * 2 ? min(max(p.x, half), size.width - half) : size.width / 2
        return CGPoint(x: x, y: max(p.y - 20, 8))
    }

    private func play() async {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        withAnimation(LoggedElsewhere.fade) { shown = true }
        var held: TimeInterval = 0
        if !reduceMotion {
            // The ring shows first, then eases outwards as it fades: one movement.
            try? await Task.sleep(for: .seconds(0.25))
            held = 0.25
            withAnimation(.easeOut(duration: 1.1)) { ring = true }
        }
        try? await Task.sleep(for: .seconds(LoggedElsewhere.hold - held))
        withAnimation(LoggedElsewhere.fade, completionCriteria: .logicallyComplete) {
            shown = false
        } completion: {
            done()
        }
    }
}
