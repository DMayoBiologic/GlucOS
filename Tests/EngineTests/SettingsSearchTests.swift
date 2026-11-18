import XCTest
@testable import GlucOSEngine

/// Settings search: the keyword index and how results rank (docs/SettingsSearch.md).
final class SettingsSearchTests: XCTestCase {
    private func top(_ query: String, _ items: [SettingsItem] = SettingsCatalog.phone) -> SettingsAnchor? {
        SettingsSearch.results(for: query, in: items).first?.anchor
    }

    private func anchors(_ query: String, _ items: [SettingsItem] = SettingsCatalog.phone) -> [SettingsAnchor] {
        SettingsSearch.results(for: query, in: items).map(\.anchor)
    }

    // MARK: Words

    func testWordsFoldCaseAccentsAndPunctuation() {
        XCTAssertEqual(SettingsSearch.words("mmol/L"), ["mmol", "l"])
        XCTAssertEqual(SettingsSearch.words("  Mg/dL  "), ["mg", "dl"])
        XCTAssertEqual(SettingsSearch.words("Café-Recap!"), ["cafe", "recap"])
        XCTAssertEqual(SettingsSearch.words("Quick-add presets"), ["quick", "add", "presets"])
        XCTAssertEqual(SettingsSearch.words(""), [])
    }

    func testFillerWordsDroppedUnlessThatsAllThereIs() {
        XCTAssertEqual(SettingsSearch.queryWords("turn off the alerts"), ["alerts"])
        XCTAssertEqual(SettingsSearch.queryWords("on"), ["on"])
    }

    // MARK: Keywords

    func testUnitWordsFindUnits() {
        for q in ["mmol", "MMOL/L", "mg/dl", "mgdl", "units", "uni"] {
            XCTAssertEqual(top(q), .units, q)
            XCTAssertEqual(top(q, SettingsCatalog.mac), .units, "Mac: \(q)")
        }
    }

    func testQuietFindsHowOftenAlertsRepeat() {
        XCTAssertTrue(anchors("quiet").contains(.alertRepeat))
        XCTAssertEqual(top("quiet hours"), .alertRepeat)
        XCTAssertEqual(top("quiet hours", SettingsCatalog.mac), .alertRepeat)
        XCTAssertEqual(top("snooze"), .alertRepeat)
        XCTAssertEqual(top("cooldown", SettingsCatalog.mac), .alertRepeat)
    }

    func testSoundWordsFindTheAlertSoundPicker() {
        for q in ["sound", "ringtone", "chime", "alert tone"] {
            XCTAssertEqual(top(q), .alertSound, q)
            XCTAssertEqual(top(q, SettingsCatalog.mac), .alertSound, "Mac: \(q)")
        }
    }

    func testEverydayWordsLandOnTheRightRow() {
        XCTAssertEqual(top("hypo", SettingsCatalog.mac), .lowAlerts)
        XCTAssertEqual(top("dynamic island"), .liveActivity)
        XCTAssertEqual(top("lock screen"), .liveActivity)
        XCTAssertEqual(top("nfc"), .readSensor)
        XCTAssertEqual(top("password"), .account)
        XCTAssertEqual(top("family"), .shareLive)
        XCTAssertEqual(top("supabase"), .relay)
        XCTAssertEqual(top("hotkey", SettingsCatalog.mac), .keyboardShortcut)
        XCTAssertEqual(top("sparkle", SettingsCatalog.mac), .updates)
        XCTAssertEqual(top("startup", SettingsCatalog.mac), .launchAtLogin)
        XCTAssertEqual(top("font", SettingsCatalog.mac), .textSize)
        XCTAssertEqual(top("tir"), .targetRange)
    }

    // MARK: Matching and ranking

    func testEveryWordMustMatch() {
        XCTAssertEqual(anchors("predicted lows"), [.predictedLows])
        XCTAssertEqual(anchors("rising pizza"), [])
    }

    func testPrefixesMatchAsYouType() {
        XCTAssertEqual(top("evening rec"), .eveningRecap)
        XCTAssertEqual(top("recap"), .eveningRecap)
        XCTAssertEqual(top("bolu"), .bolus)
    }

    func testTitleBeatsKeywordBeatsPlace() {
        // "Sensor ending", "Sensor change reminder" and "Read sensor" have sensor in their titles,
        // so all three rank above rows that only list sensor as a keyword (Sensor lifetime isn't
        // on iPhone).
        let sensor = anchors("sensor")
        XCTAssertEqual(Set(sensor.prefix(3)), [.readSensor, .sensorEndingAlert, .sensorEndReminder])
        // "alerts" is the place of every alert row, but the title hit leads.
        XCTAssertEqual(top("alerts"), .alerts)
        XCTAssertTrue(anchors("alerts").contains(.staleAlert))
    }

    func testTiesKeepScreenOrder() {
        let r = anchors("predicted")
        XCTAssertEqual(r.prefix(2), [.predictedLows, .predictedHighs])
    }

    func testEmptyAndBlankQueriesFindNothing() {
        XCTAssertEqual(anchors(""), [])
        XCTAssertEqual(anchors("   "), [])
        XCTAssertEqual(anchors("/"), [])
    }

    // MARK: Jumping

    func testHiddenRowsFallBackToTheirShownParent() {
        let items = SettingsCatalog.phone
        let warn = items.first { $0.anchor == .warnAhead }!
        // Everything on screen: land on the row itself.
        XCTAssertEqual(SettingsSearch.target(for: warn, in: items) { _ in true }, .warnAhead)
        // Predicted alerts off: Predicted lows. Alerts off too: the alerts switch.
        XCTAssertEqual(SettingsSearch.target(for: warn, in: items) { $0 != .warnAhead }, .predictedLows)
        let alertsOnly: Set<SettingsAnchor> = [.alerts]
        XCTAssertEqual(SettingsSearch.target(for: warn, in: items) { alertsOnly.contains($0) }, .alerts)
        // Nothing shown: stops at the top of the chain instead of looping.
        XCTAssertEqual(SettingsSearch.target(for: warn, in: items) { _ in false }, .alerts)
    }

    // MARK: Catalogue

    func testCataloguesHaveOneRowPerAnchor() {
        for (name, items) in [("phone", SettingsCatalog.phone), ("mac", SettingsCatalog.mac)] {
            let all = items.map(\.anchor)
            XCTAssertEqual(all.count, Set(all).count, "\(name) has a duplicate anchor")
            for item in items {
                XCTAssertFalse(item.title.isEmpty)
                if let parent = item.parent {
                    XCTAssertTrue(all.contains(parent), "\(name): \(item.anchor)'s parent \(parent) isn't listed")
                }
            }
        }
    }

    func testMacRowsNameARealTab() {
        let tabs: Set<String> = ["general", "account", "glucose", "alerts", "logging", "advanced"]
        for item in SettingsCatalog.mac {
            XCTAssertTrue(item.tab.map(tabs.contains) ?? false, "\(item.anchor) has no Mac tab")
        }
        XCTAssertTrue(SettingsCatalog.phone.allSatisfy { $0.tab == nil })
    }

    func testEveryRowFindsItselfByTitle() {
        for items in [SettingsCatalog.phone, SettingsCatalog.mac] {
            for item in items {
                XCTAssertTrue(anchors(item.title, items).contains(item.anchor), item.title)
            }
        }
    }

    func testPlainWords() {
        XCTAssertEqual(SettingsSearch.noResultsMessage(for: " pizza "),
                       "No settings match “pizza”. Try a word like alerts, units, sync or widget.")
        XCTAssertEqual(SettingsSearch.countLabel(1), "1 setting")
        XCTAssertEqual(SettingsSearch.countLabel(3), "3 settings")
    }
}
