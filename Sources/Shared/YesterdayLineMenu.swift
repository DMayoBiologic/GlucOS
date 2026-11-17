import SwiftUI

extension View {
    /// Touch and hold (iPhone) or right-click (Mac) the chart to show or hide yesterday's line, with
    /// the same as a VoiceOver action. A hold on a logged marker peeks it instead (`MarkerPeek`). The line fades in or out; under Reduce Motion it just changes.
    func yesterdayLineMenu(_ isOn: Binding<Bool>) -> some View {
        modifier(YesterdayLineMenu(isOn: isOn))
    }
}

private struct YesterdayLineMenu: ViewModifier {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A finger is down on a logged marker, which peeks instead (`MarkerPeek`). The menu offers
    /// nothing meanwhile, and an empty menu doesn't open, so a hold on a marker never shows it.
    @State private var markerHeld = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(MarkerPeekPressKey.self) { markerHeld = $0 }
            .contextMenu {
                if !markerHeld {
                    Button(action: toggle) {
                        Label(YesterdayLine.menuTitle(showing: isOn), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .accessibilityAction(named: Text(YesterdayLine.menuTitle(showing: isOn)), toggle)
    }

    private func toggle() {
        if reduceMotion {
            isOn.toggle()
        } else {
            withAnimation(DSMotion.quick.animation) { isOn.toggle() }
        }
    }
}
