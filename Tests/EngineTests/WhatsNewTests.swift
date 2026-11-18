import XCTest
@testable import GlucOSEngine

final class WhatsNewTests: XCTestCase {
    private let catalog: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.73.0", highlights: [.init(symbol: "a", title: "A", detail: "a")]),
        WhatsNewRelease(version: "1.71.0", highlights: [.init(symbol: "b", title: "B", detail: "b")]),
        WhatsNewRelease(version: "1.72.0", highlights: [.init(symbol: "c", title: "C", detail: "c")]),
        WhatsNewRelease(version: "1.70.0", highlights: [.init(symbol: "d", title: "D", detail: "d")]),
        WhatsNewRelease(version: "1.69.0", highlights: []),
    ]

    private func versions(_ d: WhatsNew.Decision) -> [String]? {
        if case .show(let r) = d { return r.map(\.version) }
        return nil
    }

    private func makeDefaults() -> UserDefaults {
        let name = "WhatsNewTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Versions

    func testVersionParsingAndOrder() {
        XCTAssertEqual(AppVersion("1.73"), AppVersion("1.73.0"))
        XCTAssertEqual(AppVersion("v1.73.0"), AppVersion("1.73.0"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("?"))
        XCTAssertNil(AppVersion("1.x"))
        XCTAssertNil(AppVersion("1.2.3.4"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertLessThan(AppVersion("1.9.3")!, AppVersion("1.10.0")!)
        XCTAssertLessThan(AppVersion("1.73.0")!, AppVersion("1.73.1")!)
        XCTAssertLessThan(AppVersion("0.99.0")!, AppVersion("1.0.0")!)
    }

    func testShortVersion() {
        XCTAssertEqual(WhatsNewRelease(version: "1.73.0", highlights: []).shortVersion, "1.73")
        XCTAssertEqual(WhatsNewRelease(version: "1.73.2", highlights: []).shortVersion, "1.73.2")
    }

    // MARK: When it shows

    func testFreshInstallNeverShows() {
        XCTAssertEqual(WhatsNew.decide(current: "1.73.0", lastSeen: nil, hasUsedBefore: false, catalog: catalog), .record)
    }

    func testFirstUpdateSinceWhatsNewShippedShowsTheLatestRelease() {
        // An earlier build never stored a version, but the app was already in use.
        XCTAssertEqual(versions(WhatsNew.decide(current: "1.74.0", lastSeen: nil, hasUsedBefore: true, catalog: catalog)),
                       ["1.73.0"])
        XCTAssertEqual(versions(WhatsNew.decide(current: "1.73.0", lastSeen: nil, hasUsedBefore: true, catalog: catalog)),
                       ["1.73.0"])
    }

    func testUpdateShowsOnlyReleasesSinceLastSeen() {
        XCTAssertEqual(versions(WhatsNew.decide(current: "1.73.0", lastSeen: "1.72.0", hasUsedBefore: true, catalog: catalog)),
                       ["1.73.0"])
        XCTAssertEqual(versions(WhatsNew.decide(current: "1.73.0", lastSeen: "1.70.0", hasUsedBefore: true, catalog: catalog)),
                       ["1.73.0", "1.72.0", "1.71.0"])
    }

    func testSkippingManyUpdatesCapsTheList() {
        let r = versions(WhatsNew.decide(current: "1.73.0", lastSeen: "1.60.0", hasUsedBefore: true, catalog: catalog))
        XCTAssertEqual(r, ["1.73.0", "1.72.0", "1.71.0"])
        XCTAssertEqual(r?.count, WhatsNew.maxReleasesShown)
    }

    func testNeverTwiceForOneVersion() {
        XCTAssertEqual(WhatsNew.decide(current: "1.73.0", lastSeen: "1.73.0", hasUsedBefore: true, catalog: catalog), .nothing)
    }

    func testDowngradeShowsNothing() {
        XCTAssertEqual(WhatsNew.decide(current: "1.72.0", lastSeen: "1.73.0", hasUsedBefore: true, catalog: catalog), .nothing)
    }

    func testPatchOrUnlistedUpdateIsRecordedQuietly() {
        XCTAssertEqual(WhatsNew.decide(current: "1.73.1", lastSeen: "1.73.0", hasUsedBefore: true, catalog: catalog), .record)
        XCTAssertEqual(WhatsNew.decide(current: "1.74.0", lastSeen: "1.73.0", hasUsedBefore: true, catalog: catalog), .record)
    }

    func testReleaseWithNoHighlightsIsSkipped() {
        XCTAssertEqual(WhatsNew.decide(current: "1.69.0", lastSeen: "1.68.0", hasUsedBefore: true, catalog: catalog), .record)
    }

    func testUnreadableVersionsDoNothingHarmful() {
        XCTAssertEqual(WhatsNew.decide(current: "?", lastSeen: nil, hasUsedBefore: true, catalog: catalog), .nothing)
        // A garbled stored value counts as none stored.
        XCTAssertEqual(versions(WhatsNew.decide(current: "1.73.0", lastSeen: "junk", hasUsedBefore: true, catalog: catalog)),
                       ["1.73.0"])
    }

    // MARK: Settings › About

    func testSettingsListsEveryReleaseUpToThisVersion() {
        XCTAssertEqual(WhatsNew.all(current: "1.72.5", catalog: catalog).map(\.version), ["1.72.0", "1.71.0", "1.70.0"])
        // A development build (0.1.2, or no version) still has something to show.
        XCTAssertEqual(WhatsNew.all(current: "0.1.2", catalog: catalog).first?.version, "1.73.0")
        // Releases with nothing to say never show as an empty section.
        XCTAssertEqual(WhatsNew.all(current: "", catalog: catalog).count, catalog.count - 1)
    }

    func testTitles() {
        XCTAssertEqual(WhatsNew.title(for: [catalog[0]]), "What's New in GlucOS 1.73")
        XCTAssertEqual(WhatsNew.title(for: [catalog[0], catalog[2]]), "What's New in GlucOS")
    }

    // MARK: Motion and timing

    func testRowsRiseInOrderAndInstantlyUnderReduceMotion() {
        XCTAssertEqual(WhatsNew.riseDelay(row: 0, reduceMotion: false), 0)
        XCTAssertEqual(WhatsNew.riseDelay(row: 2, reduceMotion: false), 2 * WhatsNew.rowStagger, accuracy: 1e-9)
        XCTAssertEqual(WhatsNew.riseDelay(row: 50, reduceMotion: false),
                       Double(WhatsNew.maxStaggerSteps) * WhatsNew.rowStagger, accuracy: 1e-9)
        XCTAssertEqual(WhatsNew.riseDelay(row: -1, reduceMotion: false), 0)
        for i in 0..<10 { XCTAssertEqual(WhatsNew.riseDelay(row: i, reduceMotion: true), 0) }
    }

    func testHoldsDuringALow() {
        XCTAssertTrue(WhatsNew.holdsFor(.urgentLow))
        XCTAssertTrue(WhatsNew.holdsFor(.low))
        XCTAssertFalse(WhatsNew.holdsFor(.inRange))
        XCTAssertFalse(WhatsNew.holdsFor(.high))
        XCTAssertFalse(WhatsNew.holdsFor(nil))
    }

    // MARK: Stored version

    func testLaunchRecordsFreshInstallAndNeverShowsLater() {
        let launch = WhatsNewLaunch(defaults: makeDefaults())
        XCTAssertNil(launch.check(current: "1.73.0", hasUsedBefore: false, catalog: catalog))
        XCTAssertEqual(launch.lastSeen, "1.73.0")
        // Signed in by the next launch: still the same version, so still nothing.
        XCTAssertNil(launch.check(current: "1.73.0", hasUsedBefore: true, catalog: catalog))
    }

    func testLaunchShowsUntilMarkedSeenThenNeverAgain() {
        let launch = WhatsNewLaunch(defaults: makeDefaults())
        launch.markSeen("1.72.0")
        XCTAssertEqual(launch.check(current: "1.73.0", hasUsedBefore: true, catalog: catalog)?.map(\.version), ["1.73.0"])
        // Not on screen yet (another sheet was up): it comes back next launch.
        XCTAssertEqual(launch.check(current: "1.73.0", hasUsedBefore: true, catalog: catalog)?.map(\.version), ["1.73.0"])
        launch.markSeen("1.73.0")
        XCTAssertNil(launch.check(current: "1.73.0", hasUsedBefore: true, catalog: catalog))
        XCTAssertEqual(launch.lastSeen, "1.73.0")
    }

    func testMarkSeenNeverMovesBackwards() {
        let launch = WhatsNewLaunch(defaults: makeDefaults())
        launch.markSeen("1.73.0")
        launch.markSeen("1.72.0")
        launch.markSeen("garbage")
        XCTAssertEqual(launch.lastSeen, "1.73.0")
    }

    // MARK: The bundled list

    func testBundledCatalogueIsWellFormed() {
        let releases = WhatsNewCatalog.releases
        XCTAssertFalse(releases.isEmpty)
        let parsed = releases.compactMap { AppVersion($0.version) }
        XCTAssertEqual(parsed.count, releases.count, "every version parses")
        XCTAssertEqual(parsed, parsed.sorted(by: >), "newest first")
        XCTAssertEqual(Set(parsed).count, parsed.count, "one entry per version")
        for version in ["1.70.0", "1.71.0", "1.72.0", "1.73.0"] {
            XCTAssertTrue(releases.contains { $0.version == version }, "\(version) is listed")
        }
        let advice = ["dose", "bolus", "units of insulin", "should take", "inject"]
        for release in releases {
            XCTAssertFalse(release.highlights.isEmpty, "\(release.version) has highlights")
            XCTAssertLessThanOrEqual(release.highlights.count, 4, "\(release.version) keeps to a few")
            XCTAssertEqual(Set(release.highlights.map(\.id)).count, release.highlights.count)
            for h in release.highlights {
                XCTAssertFalse(h.symbol.isEmpty)
                XCTAssertFalse(h.title.isEmpty)
                XCTAssertLessThanOrEqual(h.title.count, 40, "\(h.title) is short")
                XCTAssertTrue(h.detail.hasSuffix("."), "\(h.title)'s detail is a sentence")
                let text = (h.title + " " + h.detail).lowercased()
                for word in advice { XCTAssertFalse(text.contains(word), "\(h.title) gives no dosing advice") }
            }
        }
    }

    func testSettingsSearchFindsWhatsNew() {
        XCTAssertEqual(SettingsSearch.results(for: "what's new", in: SettingsCatalog.phone).first?.anchor, .whatsNew)
        XCTAssertEqual(SettingsSearch.results(for: "changelog", in: SettingsCatalog.mac).first?.anchor, .whatsNew)
        XCTAssertEqual(SettingsSearch.results(for: "sparkle", in: SettingsCatalog.mac).first?.anchor, .updates)
    }
}
