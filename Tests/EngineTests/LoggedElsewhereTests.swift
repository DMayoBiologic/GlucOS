import XCTest
@testable import GlucOSEngine

/// Entries logged from outside the Logbook: one highlight per place, one announcement per save.
final class LoggedElsewhereTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let meal = UUID(), tag = UUID(), other = UUID()

    func testEachPlaceHighlightsOnceAndVoiceOverHearsItOnce() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal, tag], from: .siri, at: t0)
        let row = marks.take(meal, on: .logbook, at: t0.addingTimeInterval(5))
        XCTAssertEqual(row?.origin, .siri)
        XCTAssertEqual(row?.announces, true)
        XCTAssertNil(marks.take(meal, on: .logbook, at: t0.addingTimeInterval(6)), "a row lights once")
        // The hypo tag saved with it, and the meal's marker, still light, but say nothing more.
        XCTAssertEqual(marks.take(tag, on: .logbook, at: t0.addingTimeInterval(6))?.announces, false)
        let marker = marks.take(meal, on: .chart, at: t0.addingTimeInterval(7))
        XCTAssertEqual(marker?.origin, .siri)
        XCTAssertEqual(marker?.announces, false)
        XCTAssertNil(marks.take(meal, on: .chart, at: t0.addingTimeInterval(8)))
    }

    func testEntriesLoggedInTheAppAreNeverHighlighted() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal], from: .widget, at: t0)
        XCTAssertNil(marks.take(other, on: .logbook, at: t0))
        XCTAssertFalse(marks.isPending(other, on: .chart, at: t0))
        XCTAssertTrue(marks.isPending(meal, on: .chart, at: t0))
    }

    func testOldEntriesAppearWithoutAHighlight() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal], from: .controlCenter, at: t0)
        let late = t0.addingTimeInterval(LoggedElsewhereMarks.lifetime + 1)
        XCTAssertFalse(marks.isPending(meal, on: .logbook, at: late))
        XCTAssertNil(marks.take(meal, on: .logbook, at: late))
    }

    func testTheHighlightWaitsForTheLogSheetToClose() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal, tag], from: .alertBanner, at: t0)
        XCTAssertEqual(marks.take(meal, on: .chart, at: t0)?.delay ?? -1, LoggedElsewhereMarks.settle, accuracy: 0.001)
        XCTAssertEqual(marks.take(tag, on: .chart, at: t0.addingTimeInterval(0.6))?.delay ?? -1,
                       LoggedElsewhereMarks.settle - 0.6, accuracy: 0.001)
        // Opened minutes later (the Mac popover): it plays straight away.
        XCTAssertEqual(marks.take(meal, on: .logbook, at: t0.addingTimeInterval(120))?.delay, 0)
    }

    func testEachSaveAnnouncesSeparately() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal], from: .siri, at: t0)
        marks.record([other], from: .notification, at: t0.addingTimeInterval(30))
        XCTAssertEqual(marks.take(meal, on: .logbook, at: t0.addingTimeInterval(31))?.announces, true)
        XCTAssertEqual(marks.take(other, on: .logbook, at: t0.addingTimeInterval(31))?.announces, true)
    }

    func testAForgottenEntryIsNotHighlighted() {
        var marks = LoggedElsewhereMarks()
        marks.record([meal], from: .keyboardShortcut, at: t0)
        marks.forget([meal])
        XCTAssertNil(marks.take(meal, on: .chart, at: t0))
        marks.record([], from: .siri, at: t0)
        XCTAssertNil(marks.take(meal, on: .logbook, at: t0))
    }

    func testCaptionsAndSpokenLines() {
        XCTAssertEqual(LogOrigin.siri.caption, "Logged from Siri")
        XCTAssertEqual(LogOrigin.keyboardShortcut.caption, "Logged with your shortcut")
        XCTAssertEqual(LoggedElsewhereMarks.spoken(.siri, entry: "45 g · Toast"), "Logged from Siri: 45 g · Toast")
        XCTAssertEqual(LoggedElsewhereMarks.spoken(.widget, entry: nil), "Logged from the widget")
        XCTAssertEqual(LoggedElsewhereMarks.chartSpoken(.controlCenter, pop: "Meal added to chart"),
                       "Meal added to chart, logged from Control Center")
        XCTAssertEqual(LoggedElsewhereMarks.chartSpoken(.alertBanner, pop: nil), "Logged from the alert")
        for origin in LogOrigin.allCases {
            XCTAssertFalse(origin.caption.isEmpty)
            XCTAssertLessThanOrEqual(origin.caption.count, 30, "fits in place of a row's time")
        }
    }
}
