import SwiftUI

extension View {
    /// Touch and hold (iPhone) or right-click (Mac) the chart to show or hide yesterday's line, with
    /// the same as a VoiceOver action. The line fades in or out; under Reduce Motion it just changes.
    func yesterdayLineMenu(_ isOn: Binding<Bool>) -> some View {
        modifier(YesterdayLineMenu(isOn: isOn))
    }
}

private struct YesterdayLineMenu: ViewModifier {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: toggle) {
                    Label(YesterdayLine.menuTitle(showing: isOn), systemImage: "clock.arrow.circlepath")
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
