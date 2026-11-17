import Foundation
import SwiftUI
import UIKit

/// The parts of a log entry the iPhone log sheet can start on (shared with the Mac: `LogFlow`).
typealias PhoneLogPart = LogPart

/// What the iPhone log sheet opens for.
enum PhoneLogTarget {
    case new(start: PhoneLogPart?)
    /// Food at an earlier time: the meal a dose was for ("Was it for a meal?" → Meal → Add Food).
    case meal(at: Date)
    case edit(LogEntry)
    /// "Log treatment" on a low or high alert (docs/AlertActions.md): a hypo treatment, filled
    /// from the "Treat a low" usual when there is one, or a correction dose.
    case treating(AlertTreatment)
    /// A hypo treatment at an earlier time: "Did you treat this low?" → Something else.
    case lowTreatment(at: Date)
    /// A button on the Your usual widget (`UsualEntry.id`): filled in from that entry if the sheet
    /// still offers it, never logged until Log (docs/UsualEntries.md).
    case usual(id: String)
}

struct PhoneLogRequest: Identifiable {
    let id = UUID()
    let target: PhoneLogTarget
    /// Siri, a control, an alert or a widget, when one opened the sheet: what it logs is
    /// highlighted once where it next appears (`LoggedElsewhere`). Nil from inside the app.
    var origin: LogOrigin? = nil
    /// Editing from a Logbook row: what the sheet zooms out of and back into
    /// (`LogbookEditMorph.sourceID`). Nil opens it the usual way.
    var zoomSource: String? = nil
}

/// Opens the log sheet from anywhere: the + button, the Logbook card, `glucos://log` links (Lock
/// Screen widget, Dynamic Island) and the "Log in GlucOS" App Shortcut.
@MainActor
final class PhoneLogRouter: ObservableObject {
    static let shared = PhoneLogRouter()

    @Published var request: PhoneLogRequest?
    /// The open sheet saved something: the log bar's plus bounces once as the sheet closes
    /// (docs/Redesign.md §7.1). Cleared by the bar when it plays it.
    var savedSinceOpen = false
    /// Set by the Glucose control (Control Center, iOS 18): the home screen goes back to Today.
    @Published var todayRequest: UUID?

    func open(_ start: PhoneLogPart? = nil, from origin: LogOrigin? = nil) {
        savedSinceOpen = false
        request = PhoneLogRequest(target: .new(start: start), origin: origin)
    }

    /// The log sheet on food, at `time`.
    func logMeal(at time: Date) {
        savedSinceOpen = false
        request = PhoneLogRequest(target: .meal(at: time))
    }

    /// The log sheet for "Log treatment" on an alert.
    func treat(_ treatment: AlertTreatment, from origin: LogOrigin? = nil) {
        savedSinceOpen = false
        request = PhoneLogRequest(target: .treating(treatment), origin: origin)
    }

    /// The log sheet on a hypo treatment at `time`, for a low that's over.
    func logLowTreatment(at time: Date) {
        savedSinceOpen = false
        request = PhoneLogRequest(target: .lowTreatment(at: time))
    }

    /// Today, from the Glucose control. Leaves an open log sheet alone.
    func showToday() {
        todayRequest = UUID()
    }

    /// What a Control Center control asked for (`ControlActions`). Neither logs anything.
    func openControl(_ target: ControlActions.Target) {
        switch target {
        case .today: showToday()
        case .lowTreatment: treat(.low, from: .controlCenter)
        }
    }

    /// A Home Screen quick action (long-press the app icon, `HomeQuickAction`). None logs anything:
    /// Log treatment and Log meal open the log sheet, Latest reading goes back to Today.
    func openQuickAction(_ action: HomeQuickAction) {
        switch action.destination {
        case .treating(let treatment): treat(treatment, from: HomeQuickAction.origin)
        case .log(let part): open(part, from: HomeQuickAction.origin)
        case .today: showToday()
        }
    }

    /// The log sheet filled in from a usual entry: the Your usual widget's buttons.
    func openUsual(_ id: String) {
        savedSinceOpen = false
        request = PhoneLogRequest(target: .usual(id: id), origin: .widget)
    }

    /// The log sheet editing `entry`. `source`: the Logbook row (or open card) it was tapped on,
    /// which the sheet zooms out of and shrinks back into (`LogbookEditMorph`).
    func edit(_ entry: LogEntry, from source: String? = nil) {
        savedSinceOpen = false
        let next = PhoneLogRequest(target: .edit(entry), zoomSource: source)
        guard source != nil, UIAccessibility.isReduceMotionEnabled else {
            request = next
            return
        }
        // Reduce Motion: no slide up; the sheet's content fades in where it sits instead.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { request = next }
    }

    /// Called by the log sheet when it saves, just before it closes.
    func noteSaved() {
        savedSinceOpen = true
    }

    /// `glucos://log`, `glucos://log/food`, `glucos://log?part=insulin`; `glucos://log/wake` logs a
    /// wake-up straight away. True when the URL was a log link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "glucos", url.host == "log" else { return false }
        let fromPath = url.pathComponents.dropFirst().first
        // The Lock Screen widget and the Dynamic Island are the links' only callers.
        if fromPath == "wake" {
            PhoneWakeLogger.shared.quickLog(from: .widget)
            return true
        }
        let fromQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "part" }?.value
        open((fromPath ?? fromQuery).flatMap(PhoneLogPart.init(rawValue:)), from: .widget)
        return true
    }
}
