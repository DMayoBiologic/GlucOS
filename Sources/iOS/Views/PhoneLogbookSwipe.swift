import SwiftUI
import UIKit

// A Logbook row's swipe actions, drawn by GlucOS rather than the system so the icons can follow the
// finger (round 95, rules in `LogbookSwipe`, docs/LogbookSearch.md "Swiping a row"). What a swipe can
// do is the same as before (#249):
//
// - Swipe left to delete. A full swipe works, since the Undo toast can bring the entry back.
// - Swipe right for Log Again Now. It only ever logs on a tap of its button, never on a flick or a
//   full swipe, so a dose can't be logged twice.
//
// As the row slides, the icon grows and fades in, and a soft tick (`HapticEvent.swipeThreshold`)
// plays once at the point where letting go does something. Under Reduce Motion the icon is there at
// full size as soon as the row moves, and the row snaps open or shut instead of springing. One row
// is open at a time, and scrolling the list shuts it. VoiceOver keeps the row's own
// "Log Again Now" and "Delete" actions; the icons are hidden from it.

extension View {
    /// Swipe actions for the Logbook row `id`. `openID` is the list's one open row.
    func phoneLogbookSwipe(_ id: UUID, openID: Binding<UUID?>, tint: Color, reduceMotion: Bool,
                           logAgain: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        modifier(PhoneLogbookSwipe(id: id, openID: openID, tint: tint, reduceMotion: reduceMotion,
                                   logAgain: logAgain, delete: delete))
    }
}

private struct PhoneLogbookSwipe: ViewModifier {
    let id: UUID
    @Binding var openID: UUID?
    let tint: Color
    let reduceMotion: Bool
    let logAgain: () -> Void
    let delete: () -> Void

    /// Where the row sits now, in points (positive is slid right).
    @State private var offset: Double = 0
    /// Where the current drag started from: 0, or an open action's width.
    @State private var base: Double = 0
    @State private var rowWidth: Double = 360
    @State private var dragging = false
    /// The edge left open for a tap, if any.
    @State private var openEdge: LogbookSwipe.Edge?
    @State private var tick = LogbookSwipe.Tick()

    func body(content: Content) -> some View {
        content
            // While an action is open, a tap on the row shuts it rather than opening the entry.
            .overlay {
                if openEdge != nil && !dragging {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { settle(.close) }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset)
            .background(alignment: .leading) { action(.logAgain) }
            .background(alignment: .trailing) { action(.delete) }
            .clipped()
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { rowWidth = max($0, 1) }
            .gesture(PhoneHorizontalPan(onChange: changed, onEnd: ended))
            .onChange(of: openID) { _, now in
                if now != id, offset != 0, !dragging { settle(.close, sharing: false) }
            }
    }

    private func action(_ edge: LogbookSwipe.Edge) -> some View {
        // The room the row has made on this side, and the row's offset as seen from this side.
        let room = edge == .logAgain ? max(offset, 0) : max(-offset, 0)
        let signed = edge == .logAgain ? room : -room
        return Button {
            switch edge {
            case .logAgain:
                settle(.close)
                logAgain()
            case .delete:
                settle(.delete)
            }
        } label: {
            Image(systemName: edge == .logAgain ? "arrow.clockwise" : "trash")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(edge == .logAgain ? tint : Color.red, in: Circle())
                .scaleEffect(LogbookSwipe.iconScale(offset: signed, rowWidth: rowWidth, reduceMotion: reduceMotion))
                .opacity(LogbookSwipe.iconOpacity(offset: signed, reduceMotion: reduceMotion))
        }
        .buttonStyle(.plain)
        .frame(width: room)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(openEdge == edge && !dragging)
        .accessibilityHidden(true)
    }

    private func changed(_ translation: Double) {
        if !dragging {
            dragging = true
            tick.reset()
            // Starting to swipe this row shuts any other.
            if openID != id { openID = id }
        }
        offset = LogbookSwipe.offset(translation: translation, base: base, rowWidth: rowWidth)
        if tick.update(offset: offset, rowWidth: rowWidth) { Haptics.play(.swipeThreshold) }
    }

    private func ended(_ velocity: Double) {
        dragging = false
        tick.reset()
        settle(LogbookSwipe.release(offset: offset, velocity: velocity, rowWidth: rowWidth))
    }

    /// Moves the row to where `release` leaves it. Only a delete changes anything, and it goes
    /// through the list's own delete, so the Undo toast always offers the entry back.
    private func settle(_ release: LogbookSwipe.Release, sharing: Bool = true) {
        let rest = LogbookSwipe.restingOffset(release, rowWidth: rowWidth)
        let motion: Animation? = reduceMotion ? nil : DSMotion.emphasized.animation
        switch release {
        case .close:
            openEdge = nil
            base = 0
            if sharing, openID == id { openID = nil }
            withAnimation(motion) { offset = rest }
        case .open(let edge):
            openEdge = edge
            base = rest
            if sharing { openID = id }
            withAnimation(motion) { offset = rest }
        case .delete:
            openEdge = nil
            base = 0
            if openID == id { openID = nil }
            if reduceMotion {
                offset = 0
                delete()
            } else {
                withAnimation(.smooth(duration: 0.2)) { offset = rest } completion: { delete() }
            }
        }
    }
}

/// A sideways pan that only starts when the finger moves more across than up or down, so the list
/// still scrolls and a row's tap and long-press still work.
private struct PhoneHorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (Double) -> Void
    /// Called with the finger's sideways speed, in points per second (0 when cancelled).
    var onEnd: (Double) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let view = recognizer.view
        switch recognizer.state {
        case .began, .changed: onChange(Double(recognizer.translation(in: view).x))
        case .ended: onEnd(Double(recognizer.velocity(in: view).x))
        case .cancelled, .failed: onEnd(0)
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return abs(speed.x) > abs(speed.y) * 1.3
        }
    }
}
