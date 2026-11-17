import SwiftUI

// The log sheets' Save button turning into a checkmark once the entry is saved, on iPhone and Mac.
// Here rather than in Shared because widgets never show it and don't build LogFlow.

extension Animation {
    /// The log sheets' Save button turning into a checkmark (`LogFlow.saveMorphDuration`): a short
    /// spring, or a plain cross-fade under Reduce Motion. Played once, when the entry is saved.
    static func saveMorph(reduceMotion: Bool) -> Animation {
        let d = LogFlow.saveMorphDuration(reduceMotion: reduceMotion)
        return reduceMotion ? .easeInOut(duration: d) : .spring(duration: d, bounce: 0.18)
    }
}

/// The tick a log sheet's Save button turns into: it draws itself once, left to right, a beat
/// after it appears. Fully drawn from the first frame under Reduce Motion (the button cross-fades
/// to it instead).
struct DrawnCheckmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var lineWidth: CGFloat = 3
    var color: Color = .white
    /// Waits for the button to finish shrinking before the stroke starts.
    var delay: Double = 0.14
    @State private var drawn: CGFloat = 0

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: reduceMotion ? 1 : drawn)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion, drawn == 0 else { return }
                withAnimation(.easeOut(duration: 0.28).delay(delay)) { drawn = 1 }
            }
    }
}

/// A checkmark stroke filling its rect: a short down stroke, then the long one up to the right.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return p
    }
}
