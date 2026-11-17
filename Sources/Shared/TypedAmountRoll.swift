import Foundation

/// How a typed amount in the log sheets (units, grams of carbs, a finger-prick reading) changes on
/// screen as it's typed or stepped, kept free of SwiftUI so it can be unit-tested.
///
/// Each new digit rolls into place with the numeric content transition on the quick `.arrival`
/// spring, upward as the number grows and downward as it shrinks (a backspace, the − button).
/// Under Reduce Motion the new figure simply replaces the old. VoiceOver reads the field's own
/// value, so it only ever hears the final figure, never one on its way there.
///
/// Display only: the typed text is never changed, and nothing here feeds any amount or sum.
enum TypedAmountRoll: Equatable, Sendable {
    /// The text didn't change.
    case none
    /// The digits roll to the new figure; `countsDown` when it's smaller than the old one.
    case roll(countsDown: Bool)
    /// Reduce Motion: the new figure replaces the old at once.
    case instant

    static func between(_ old: String, _ new: String, reduceMotion: Bool) -> TypedAmountRoll {
        guard old != new else { return .none }
        if reduceMotion { return .instant }
        return .roll(countsDown: value(of: new) < value(of: old))
    }

    /// The figure the text shows, for the transition's direction: a comma counts as the decimal
    /// point, and an empty or half-typed entry ("", ".") counts as zero.
    static func value(of text: String) -> Double {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t) ?? (t == "." ? 0 : Double(t.filter { $0.isNumber || $0 == "." }) ?? 0)
    }
}
