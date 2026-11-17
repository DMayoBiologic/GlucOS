import SwiftUI

// Opening a Logbook entry in the edit sheet (docs/LogbookSearch.md "Editing an entry",
// `LogbookEditMorph`): the sheet zooms out of the row it was tapped on and shrinks back into it on
// dismiss. A plain cross-fade under Reduce Motion. Once per open and close, nothing loops.

extension View {
    /// Marks this view as where an entry's edit sheet zooms out of, on `surface`. Nothing outside
    /// the home screen's stack (no navigator), so previews and other hosts are untouched.
    @ViewBuilder
    func logbookEditSource(_ surface: LogbookEditMorph.Surface, _ id: UUID,
                           navigator: PhoneNavigator?) -> some View {
        if let navigator {
            matchedTransitionSource(id: AnyHashable(LogbookEditMorph.sourceID(surface, id)), in: navigator.zoom)
        } else {
            self
        }
    }

    /// The log sheet's side: zooms from `source` when there is one. Under Reduce Motion it fades in
    /// over the screen and out again instead of sliding or zooming (`LogbookEditFade`).
    func logbookEditMorph(from source: String?, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
        modifier(LogbookEditZoom(source: source, namespace: namespace, reduceMotion: reduceMotion))
    }
}

private struct LogbookEditZoom: ViewModifier {
    let source: String?
    let namespace: Namespace.ID
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if let source, LogbookEditMorph.Style(reduceMotion: reduceMotion) == .morph {
            content.navigationTransition(.zoom(sourceID: AnyHashable(source), in: namespace))
        } else if source != nil {
            content.modifier(LogbookEditFade())
        } else {
            content
        }
    }
}

/// Reduce Motion: the sheet is presented without its slide (`PhoneLogRouter.edit` opens it in a
/// transaction with animations off), and its content fades in where it sits.
private struct LogbookEditFade: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: LogbookEditMorph.fadeDuration(reduceMotion: true))) { shown = true }
            }
    }
}
