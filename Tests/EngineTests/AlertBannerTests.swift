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

    // MARK: Stack (round 59)

    func make(_ kind: String, at minutes: Double) -> AlertBanner {
        AlertBanner(kind: kind, isFollowerCopy: false, title: "t", body: "b",
                    firedAt: now.addingTimeInterval(minutes * 60))!
    }

    func testASecondAlertStacksBehindNewestInFront() {
        var stack = AlertBannerStack()
        stack.add(make("high", at: 0), now: now)
        stack.add(make("predictedLow", at: 1), now: now.addingTimeInterval(60))
        XCTAssertEqual(stack.banners.map(\.kind.rawValue), ["predictedLow", "high"])
        XCTAssertEqual(stack.moreLine, "1 more alert · Tap to show")
    }

    func testARepeatOfTheSameKindReplacesItRatherThanStacking() {
        var stack = AlertBannerStack()
        stack.add(make("low", at: 0), now: now)
        stack.add(make("high", at: 1), now: now)
        let again = make("low", at: 2)
        stack.add(again, now: now)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.front, again)
    }

    func testUrgentLowsStayInFront() {
        var stack = AlertBannerStack()
        stack.add(make("urgentLow", at: 0), now: now)
        stack.add(make("high", at: 1), now: now)
        XCTAssertEqual(stack.front?.kind.rawValue, "urgentLow")
    }

    func testAtMostThreeAndTheOldestGoesButNeverAnUrgentLowFirst() {
        var stack = AlertBannerStack()
        stack.add(make("urgentLow", at: 0), now: now)
        stack.add(make("high", at: 1), now: now)
        stack.add(make("veryHigh", at: 2), now: now)
        stack.add(make("predictedHigh", at: 3), now: now)
        XCTAssertEqual(stack.banners.map(\.kind.rawValue), ["urgentLow", "predictedHigh", "veryHigh"])
    }

    func testExpandingNeedsTwoAndFoldsBackWhenOneIsLeft() {
        var stack = AlertBannerStack()
        stack.add(make("low", at: 0), now: now)
        stack.setExpanded(true)
        XCTAssertFalse(stack.isExpanded, "nothing to spread out")
        stack.add(make("high", at: 1), now: now)
        stack.setExpanded(true)
        XCTAssertTrue(stack.isExpanded)
        XCTAssertNil(stack.moreLine, "no 'more' line once spread out")
        stack.remove(id: stack.front!.id)
        XCTAssertFalse(stack.isExpanded)
        XCTAssertEqual(stack.front?.kind.rawValue, "low", "the one behind comes forward")
    }

    func testOldBannersGoOnTheirOwnWithOneTimerAtTheNextEnd() {
        var stack = AlertBannerStack()
        stack.add(make("low", at: 0), now: now)
        stack.add(make("high", at: 4), now: now.addingTimeInterval(240))
        XCTAssertEqual(stack.nextExpiry, now.addingTimeInterval(AlertBanner.lifetime))
        XCTAssertTrue(stack.prune(at: now.addingTimeInterval(11 * 60)))
        XCTAssertEqual(stack.banners.map(\.kind.rawValue), ["high"])
        XCTAssertFalse(stack.prune(at: now.addingTimeInterval(12 * 60)))
        XCTAssertEqual(stack.nextExpiry, now.addingTimeInterval(4 * 60 + AlertBanner.lifetime))
        stack.removeAll()
        XCTAssertNil(stack.nextExpiry)
    }

    func testCardsBehindPeekOutSmallerAndFainter() {
        XCTAssertEqual(AlertBannerStack.peek(at: 0), .init(offset: 0, scale: 1, opacity: 1))
        let one = AlertBannerStack.peek(at: 1), two = AlertBannerStack.peek(at: 2)
        XCTAssertEqual(one.offset, 8)
        XCTAssertEqual(two.offset, 16)
        XCTAssertLessThan(two.scale, one.scale)
        XCTAssertLessThan(two.opacity, one.opacity)
        XCTAssertGreaterThan(two.opacity, 0)
        XCTAssertEqual(AlertBannerStack.peek(at: 3).opacity, 0, "only two peek out")
        var stack = AlertBannerStack()
        for (i, kind) in ["low", "high", "veryHigh"].enumerated() { stack.add(make(kind, at: Double(i)), now: now) }
        XCTAssertEqual(stack.moreLine, "2 more alerts · Tap to show")
    }

    // MARK: Swipe (round 59)

    func testSwipeFollowsUpAndResistsDown() {
        XCTAssertEqual(AlertBannerSwipe.offset(for: -50), -50)
        XCTAssertEqual(AlertBannerSwipe.offset(for: 0), 0)
        let small = AlertBannerSwipe.offset(for: 10), big = AlertBannerSwipe.offset(for: 400)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(small, 10)
        XCTAssertLessThan(big, AlertBannerSwipe.downLimit)
        XCTAssertGreaterThan(big, small)
    }

    func testFarOrFastUpDismissesAndShortSwipesSpringBack() {
        XCTAssertTrue(AlertBannerSwipe.dismisses(translation: -31, predicted: -31))
        XCTAssertTrue(AlertBannerSwipe.dismisses(translation: -10, predicted: -120), "a flick")
        XCTAssertFalse(AlertBannerSwipe.dismisses(translation: -20, predicted: -40))
        XCTAssertFalse(AlertBannerSwipe.dismisses(translation: 60, predicted: 90), "down never dismisses")
    }

    func testReduceMotionFadesInsteadOfMoving() {
        XCTAssertEqual(AlertBannerSwipe.reducedOpacity(for: 0), 1)
        XCTAssertEqual(AlertBannerSwipe.reducedOpacity(for: 40), 1)
        XCTAssertEqual(AlertBannerSwipe.reducedOpacity(for: -75), 0.5, accuracy: 0.001)
        XCTAssertEqual(AlertBannerSwipe.reducedOpacity(for: -500), 0.4)
    }
}
