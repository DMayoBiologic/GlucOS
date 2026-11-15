import XCTest
@testable import GlucOSEngine

/// "Did you treat this low?" (docs/LowTreatmentQuestion.md): which lows are asked about, when,
/// what one tap logs, and how a late answer reaches the forecast checks.
final class LowTreatmentCheckTests: XCTestCase {
    let now = referenceNow
    let low = 70.0

    func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    /// Readings every 5 minutes for the last 3 hours: 110, a low from `from` to `to` minutes ago
    /// (bottoming at 55 halfway), then 100.
    func series(lowFrom from: Double = 90, to: Double = 60) -> [GlucoseReading] {
        readings(endingAt: now, minutes: 180) { m in
            if m <= from && m > to {
                let mid = (from + to) / 2
                return 55 + abs(m - mid) / (from - to) * 20
            }
            return m > from ? 110 : 100
        }
    }

    func glucose(_ mgdl: Double? = 100, rate: Double? = 0) -> UsualGlucose {
        UsualGlucose(mgdl: mgdl, ratePerMinute: rate, lowMgdl: low, highMgdl: 180)
    }

    func pending(_ r: [GlucoseReading], glucose g: UsualGlucose? = nil, meals: [MealEntry] = [],
                 contexts: [ContextEvent] = [], answers: [LowAnswer] = [], now t: Date? = nil) -> LowEpisode? {
        LowTreatmentCheck.pending(readings: r, glucose: g ?? glucose(), meals: meals, contexts: contexts,
                                  answers: answers, now: t ?? now)
    }

    // MARK: Finding lows

    func testFindsALowWithItsLowestReading() throws {
        let eps = LowTreatmentCheck.episodes(readings: series(), lowMgdl: low, now: now)
        let e = try XCTUnwrap(eps.first)
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(e.start, at(90))
        XCTAssertEqual(e.end, at(60))
        XCTAssertEqual(e.nadirAt, at(75))
        XCTAssertEqual(e.nadirMgdl, 55, accuracy: 0.001)
    }

    func testABriefDipIsNotALow() {
        // One reading below the line.
        let r = readings(endingAt: now, minutes: 120) { m in m == 60 ? 65 : 100 }
        XCTAssertTrue(LowTreatmentCheck.episodes(readings: r, lowMgdl: low, now: now).isEmpty)
    }

    func testABounceBackBelowIsTheSameLow() throws {
        // Below 100–80, up for 10 minutes, below again 70–55.
        let r = readings(endingAt: now, minutes: 180) { m in
            (m <= 100 && m > 80) || (m <= 70 && m > 55) ? 60 : 100
        }
        let eps = LowTreatmentCheck.episodes(readings: r, lowMgdl: low, now: now)
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps.first?.start, at(100))
        XCTAssertEqual(eps.first?.end, at(55))
    }

    func testALowStillGoingHasNoEnd() {
        let r = readings(endingAt: now, minutes: 60) { m in m <= 30 ? 60 : 100 }
        let e = LowTreatmentCheck.episodes(readings: r, lowMgdl: low, now: now).last
        XCTAssertNotNil(e)
        XCTAssertNil(e?.end)
    }

    // MARK: When it asks

    func testAsksOnceTheLowIsOverWithNothingLogged() throws {
        let e = try XCTUnwrap(pending(series()))
        XCTAssertEqual(e.start, at(90))
    }

    func testNeverAsksDuringTheLow() {
        let r = readings(endingAt: now, minutes: 60) { m in m <= 30 ? 60 : 100 }
        XCTAssertNil(pending(r, glucose: glucose(60)))
        // Nor while glucose is just above the line and still falling.
        XCTAssertNil(pending(series(), glucose: glucose(80, rate: -1.5)))
        // Nor without a fresh reading.
        XCTAssertNil(pending(series(), glucose: glucose(nil)))
    }

    func testWaitsForGlucoseToStayUp() {
        // Came up 10 minutes ago: not yet.
        XCTAssertNil(pending(series(lowFrom: 40, to: 10)))
        // 15 minutes: asks.
        XCTAssertNotNil(pending(series(lowFrom: 45, to: 15)))
    }

    func testStopsAskingTwoHoursAfter() {
        XCTAssertNotNil(pending(series(lowFrom: 150, to: 115)))
        XCTAssertNil(pending(series(lowFrom: 160, to: 125)))
    }

    func testFoodOrAHypoTagAroundTheLowAnswersIt() {
        // Food 10 minutes into the low, food 15 minutes before it, a hypo tag just after it.
        XCTAssertNil(pending(series(), meals: [MealEntry(timestamp: at(75), carbs: 15)]))
        XCTAssertNil(pending(series(), meals: [MealEntry(timestamp: at(100), carbs: 0, food: "Juice")]))
        XCTAssertNil(pending(series(), contexts: [ContextEvent(timestamp: at(55), tags: [.hypoTreatment])]))
        // Lunch two hours before doesn't; nor does another kind of event.
        XCTAssertNotNil(pending(series(), meals: [MealEntry(timestamp: at(170), carbs: 50)]))
        XCTAssertNotNil(pending(series(), contexts: [ContextEvent(timestamp: at(75), tags: [.exercise])]))
    }

    func testAnAnswerFromAnyDeviceStopsIt() throws {
        let e = try XCTUnwrap(pending(series()))
        // Another device saw the low start a few minutes later and end a reading earlier.
        let theirs = LowAnswer(lowStart: e.start.addingTimeInterval(240), lowEnd: try XCTUnwrap(e.end).addingTimeInterval(-300),
                               answer: .notTreated, answeredAt: now)
        XCTAssertNil(pending(series(), answers: [theirs]))
        // An answer about an earlier low doesn't.
        let earlier = LowAnswer(lowStart: at(400), lowEnd: at(380), answer: .dismissed, answeredAt: at(300))
        XCTAssertNotNil(pending(series(), answers: [earlier]))
    }

    func testLowAnswerDecodesAnUnknownAnswerAsDismissed() throws {
        let json = #"{"id":"9F1C1D2E-1111-4222-8333-944455556666","lowStart":1,"lowEnd":2,"answer":"later","answeredAt":3}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let a = try d.decode(LowAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.answer, .dismissed)
    }

    // MARK: What it logs

    func testTreatmentTimeIsJustBeforeTheLowestReading() throws {
        let e = try XCTUnwrap(pending(series()))
        XCTAssertEqual(LowTreatmentCheck.treatmentTime(for: e), at(85), "Ten minutes before the lowest reading, 75 minutes ago")
        // Lowest right as it began: not before the low.
        let early = LowEpisode(start: at(120), end: at(60), nadirAt: at(115), nadirMgdl: 50)
        XCTAssertEqual(LowTreatmentCheck.treatmentTime(for: early), at(120))
    }

    func testOneTapLogsTheUsualTreatmentAsTheSheetWould() throws {
        // Jelly beans twice for a low in the last fortnight.
        var meals: [MealEntry] = [], contexts: [ContextEvent] = []
        for days in [3.0, 9.0] {
            let t = now.addingTimeInterval(-days * 86_400)
            meals.append(MealEntry(timestamp: t, carbs: 15, food: "Jelly beans"))
            contexts.append(ContextEvent(timestamp: t, tags: [.hypoTreatment]))
        }
        let usual = try XCTUnwrap(LowTreatmentCheck.usualTreatment(meals: meals, contexts: contexts, now: now))
        XCTAssertEqual(usual.detail, "Jelly beans · 15 g")
        let e = try XCTUnwrap(pending(series(), meals: meals, contexts: contexts))
        let time = LowTreatmentCheck.treatmentTime(for: e)
        let (meal, context) = LowTreatmentCheck.entries(for: usual, at: time)
        XCTAssertEqual(meal.timestamp, time)
        XCTAssertEqual(meal.carbs, 15)
        XCTAssertEqual(meal.food, "Jelly beans")
        XCTAssertEqual(context.tags, [.hypoTreatment])
        XCTAssertEqual(context.timestamp, time)
        XCTAssertTrue(UsualEntries.isHypoTreatment(meal, contexts: [context]))
        XCTAssertEqual(LowTreatmentCheck.logged(meal), "Logged Jelly beans at \(ClockLabel.time(time)) as a hypo treatment.")
        // Once logged, the question goes, and the usual counts it.
        XCTAssertNil(pending(series(), meals: meals + [meal], contexts: contexts + [context]))
        XCTAssertEqual(LowTreatmentCheck.usualTreatment(meals: meals + [meal], contexts: contexts + [context], now: now)?.count, 3)
    }

    func testNoUsualTreatmentWithoutTwoLoggedLows() {
        let t = now.addingTimeInterval(-86_400)
        XCTAssertNil(LowTreatmentCheck.usualTreatment(meals: [MealEntry(timestamp: t, carbs: 15, food: "Juice")],
                                                      contexts: [ContextEvent(timestamp: t, tags: [.hypoTreatment])], now: now))
    }

    // MARK: Forecast checks

    /// A treatment logged after the forecasts around it have settled (and been sent) still marks
    /// their later points as after a log, and sends them again, so the server's checks match.
    func testALateTreatmentRemarksSettledForecastsAndResendsThem() throws {
        var ledger = ForecastLedger()
        let issued = at(240)
        let r = readings(endingAt: issued, minutes: 30) { 120 - $0 }
        let f = try GlucoseForecaster.forecast(ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [],
                                                             profile: .empty, now: issued)).get()
        XCTAssertTrue(ledger.note(f, device: "iPhone", tuned: false, now: issued))
        let all = GlucoseSeries(readings(endingAt: now, minutes: 270) { _ in 100 })
        ledger.score(readings: all, logTimes: [], now: now)
        XCTAssertTrue(ledger.records[0].settled)
        XCTAssertEqual(ledger.records[0].points.map(\.afterLog), [false, false])
        ledger.markUploaded([ledger.records[0].id])
        XCTAssertTrue(ledger.pendingUpload().isEmpty)

        // The low's treatment, logged now at 20 minutes after the forecast.
        let treated = issued.addingTimeInterval(20 * 60)
        XCTAssertTrue(ledger.score(readings: all, logTimes: [treated, treated], now: now))
        XCTAssertEqual(ledger.records[0].points.map(\.afterLog), [false, true])
        XCTAssertEqual(ledger.pendingUpload().map(\.id), [ledger.records[0].id])
        // Nothing more to change after that.
        ledger.markUploaded([ledger.records[0].id])
        XCTAssertFalse(ledger.score(readings: all, logTimes: [treated, treated], now: now.addingTimeInterval(60)))

        // Undo takes it away again.
        XCTAssertTrue(ledger.score(readings: all, logTimes: [], now: now.addingTimeInterval(120)))
        XCTAssertEqual(ledger.records[0].points.map(\.afterLog), [false, false])
    }

    func testForecastsOlderThanTheWindowAreLeftAlone() throws {
        var ledger = ForecastLedger()
        let issued = now.addingTimeInterval(-ForecastLedger.relogWindow - 3600)
        let r = readings(endingAt: issued, minutes: 30) { 120 - $0 }
        let f = try GlucoseForecaster.forecast(ForecastInputs(readings: GlucoseSeries(r), doses: [], meals: [], contexts: [],
                                                             profile: .empty, now: issued)).get()
        ledger.note(f, device: "Mac", tuned: false, now: issued)
        let all = GlucoseSeries(readings(endingAt: now, minutes: 900) { _ in 100 })
        ledger.score(readings: all, logTimes: [], now: issued.addingTimeInterval(3600))
        ledger.markUploaded([ledger.records[0].id])
        ledger.score(readings: all, logTimes: [issued.addingTimeInterval(20 * 60)], now: now)
        XCTAssertEqual(ledger.records[0].points.map(\.afterLog), [false, false])
        XCTAssertTrue(ledger.pendingUpload().isEmpty)
    }

    // MARK: Sync

    func testAnswersSyncBetweenDevices() throws {
        var mac = LogbookContents(), phone = LogbookContents()
        var macState = LogbookSyncState(), phoneState = LogbookSyncState()
        let a = LowAnswer(lowStart: at(85), lowEnd: at(60), answer: .notTreated, answeredAt: now)
        mac.lowAnswers.append(a)
        LogbookMerge.touch(a.id, kind: .lowAnswer, deleted: false, now: now, state: &macState)
        let pushed = LogbookMerge.outgoing(mac, state: macState, device: "Mac")
        XCTAssertEqual(pushed.map(\.kind), ["lowAnswer"])
        let remote = pushed.enumerated().map { i, r in var r = r; r.rev = Int64(i + 1); return r }
        XCTAssertTrue(LogbookMerge.apply(remote, to: &phone, state: &phoneState))
        XCTAssertEqual(phone.lowAnswers, [a])

        // Undo on the Mac deletes it everywhere.
        mac.lowAnswers = []
        LogbookMerge.touch(a.id, kind: .lowAnswer, deleted: true, now: now.addingTimeInterval(5), state: &macState)
        let gone = LogbookMerge.outgoing(mac, state: macState, device: "Mac").map { r in var r = r; r.rev = 10; return r }
        XCTAssertTrue(LogbookMerge.apply(gone, to: &phone, state: &phoneState))
        XCTAssertTrue(phone.lowAnswers.isEmpty)
    }
}
