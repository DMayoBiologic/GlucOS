import XCTest
@testable import GlucOSEngine

// The in-app alert banner (docs/AlertActions.md, "In-app banner").
final class AlertBannerTests: XCTestCase {
    let now = referenceNow

    func banner(_ kind: String?, follower: Bool = false, title: String = "Low glucose — 3.6 mmol/L",
                body: String = "Falling") -> AlertBanner? {
        AlertBanner(kind: kind, isFollowerCopy: follower, title: title, body: body, firedAt: now)
    }

    func testOnlyTheUsersOwnLowAndHighAlertsGetABanner() {
        for kind in AlertNotice.Kind.allCases {
            XCTAssertEqual(banner(kind.rawValue) != nil, kind.treatment != nil, kind.rawValue)
        }
        XCTAssertNil(banner("low", follower: true), "a follower's copy keeps the system banner")
        XCTAssertNil(banner(nil), "check-ins and other notifications carry no kind")
        XCTAssertNil(banner("nonsense"))
    }

    func testButtonsMatchTheNotification() {
        for kind in AlertNotice.Kind.allCases {
            guard let b = banner(kind.rawValue) else { continue }
            XCTAssertEqual(b.buttons.map(\.title), AlertSnoozes.buttonTitles(for: kind), kind.rawValue)
        }
        XCTAssertEqual(banner("urgentLow")?.buttons, [.treat])
        XCTAssertEqual(banner("predictedUrgentLow")?.buttons, [.treat])
        XCTAssertEqual(banner("high")?.buttons, [.treat, .snooze])
        XCTAssertEqual(banner("urgentLow")?.isUrgent, true)
        XCTAssertEqual(banner("predictedLow")?.isLow, true)
        XCTAssertEqual(banner("veryHigh")?.isLow, false)
    }

    func testItGoesAwayOnItsOwnAfterTenMinutes() {
        let b = banner("low")!
        XCTAssertTrue(b.isShowing(at: now))
        XCTAssertTrue(b.isShowing(at: now.addingTimeInterval(9 * 60)))
        XCTAssertFalse(b.isShowing(at: now.addingTimeInterval(10 * 60)))
    }

    func testVoiceOverHearsTheReadingAndTheButtons() {
        XCTAssertEqual(banner("low")?.announcement,
                       "Alert: Low glucose, 3.6 mmol/L. Falling. Log treatment or Snooze 30 minutes at the top of the screen.")
        XCTAssertEqual(banner("urgentLow", title: "URGENT LOW — 2.9 mmol/L",
                              body: "Falling. Treat now and confirm on your phone.")?.announcement,
                       "Alert: URGENT LOW, 2.9 mmol/L. Falling. Treat now and confirm on your phone. Log treatment at the top of the screen.")
        XCTAssertEqual(banner("high", title: "High glucose — 13.4 mmol/L", body: "")?.announcement,
                       "Alert: High glucose, 13.4 mmol/L. Log treatment or Snooze 30 minutes at the top of the screen.")
        XCTAssertEqual(banner("low")?.accessibilityLabel, "Low glucose, 3.6 mmol/L. Falling")
    }

    func testANewerAlertIsADifferentBanner() {
        let a = banner("low")!
        let b = AlertBanner(kind: "low", isFollowerCopy: false, title: a.title, body: a.body,
                            firedAt: now.addingTimeInterval(300))!
        XCTAssertNotEqual(a.id, b.id)
    }
}
