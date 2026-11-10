import XCTest
@testable import GlucOSEngine

final class ActionCurveTests: XCTestCase {
    let curves: [(String, InsulinActionCurve)] = [
        ("rapid", .rapid), ("ultraRapid", .ultraRapid), ("regular", .regular), ("nph", .nph),
    ]

    func testInsulinRemainingRunsFromOneToZero() {
        for (name, c) in curves {
            XCTAssertEqual(c.fractionRemaining(after: -60), 1, name)
            XCTAssertEqual(c.fractionRemaining(after: 0), 1, name)
            XCTAssertEqual(c.fractionRemaining(after: c.delay), 1, accuracy: 1e-9, name)
            XCTAssertEqual(c.fractionRemaining(after: c.totalDuration), 0, name)
            XCTAssertEqual(c.fractionRemaining(after: c.totalDuration + 3600), 0, name)
            // Just before the end the model is already essentially zero (continuous at the end).
            XCTAssertLessThan(c.fractionRemaining(after: c.totalDuration - 60), 0.001, name)
        }
    }

    func testInsulinRemainingNeverIncreases() {
        for (name, c) in curves {
            var previous = 1.0
            for t in stride(from: 0.0, through: c.totalDuration, by: 60) {
                let r = c.fractionRemaining(after: t)
                XCTAssertLessThanOrEqual(r, previous + 1e-12, "\(name) at \(t)")
                previous = r
            }
        }
    }

    func testActivityIntegratesToWhatWasUsed() {
        for (name, c) in curves {
            // Midpoint-rule integral of activity over the whole curve is 1.
            var total = 0.0
            for t in stride(from: 0.0, to: c.totalDuration, by: 30) { total += c.activity(after: t + 15) * 30 }
            XCTAssertEqual(total, 1, accuracy: 0.002, name)
            // And up to any point it matches 1 − remaining.
            let half = c.delay + c.duration / 3
            var partial = 0.0
            for t in stride(from: 0.0, to: half, by: 30) { partial += c.activity(after: t + 15) * 30 }
            XCTAssertEqual(partial, 1 - c.fractionRemaining(after: half), accuracy: 0.002, name)
        }
    }

    func testActivityPeaksAtThePeakTime() {
        for (name, c) in curves {
            let best = stride(from: 0.0, through: c.totalDuration, by: 60).max { c.activity(after: $0) < c.activity(after: $1) }!
            XCTAssertEqual(best, c.peakTime, accuracy: 61, name)
        }
    }

    func testRapidActingTimingIsSensible() {
        let c = InsulinActionCurve.rapid
        // About half has acted by 2 hours, nearly all by 5.
        XCTAssertEqual(c.fractionRemaining(after: 2 * 3600), 0.5, accuracy: 0.12)
        XCTAssertLessThan(c.fractionRemaining(after: 5 * 3600), 0.08)
        // Ultra-rapid is ahead of rapid early on.
        XCTAssertLessThan(InsulinActionCurve.ultraRapid.fractionRemaining(after: 3600), c.fractionRemaining(after: 3600))
    }

    func testKindsMapToComponents() {
        XCTAssertEqual(InsulinKind.long.components, [])
        XCTAssertEqual(InsulinKind.long.fastComponents, [])
        XCTAssertEqual(InsulinKind.intermediate.fastComponents, [])
        XCTAssertEqual(InsulinKind.rapid.fastComponents.map(\.share), [1])
        XCTAssertEqual(InsulinKind.premixed.components.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(InsulinKind.premixed.fastComponents.map(\.share), [0.3])
    }

    func testCarbAbsorptionIsContinuousAndComplete() {
        let c = CarbAbsorptionCurve.standard
        XCTAssertEqual(c.fractionAbsorbed(after: 0), 0)
        XCTAssertEqual(c.fractionAbsorbed(after: c.delay), 0)
        XCTAssertEqual(c.fractionAbsorbed(after: c.totalDuration), 1)
        XCTAssertEqual(c.fractionAbsorbed(after: c.totalDuration - 1), 1, accuracy: 1e-4)
        var previous = 0.0
        var integral = 0.0
        for t in stride(from: 0.0, to: c.totalDuration + 600, by: 30) {
            let f = c.fractionAbsorbed(after: t)
            XCTAssertGreaterThanOrEqual(f, previous - 1e-12)
            // No jumps at the breakpoints.
            XCTAssertLessThan(f - previous, 0.01)
            previous = f
            integral += c.rate(after: t + 15) * 30
        }
        XCTAssertEqual(integral, 1, accuracy: 0.002)
    }
}

final class ActiveTherapyTests: XCTestCase {
    let now = referenceNow

    func testNothingLoggedMeansNothingActive() {
        let a = InsulinActivity.compute(doses: [], at: now)
        XCTAssertEqual(a.onBoard, 0)
        XCTAssertFalse(a.isActive)
        XCTAssertNil(a.peakAt)
        XCTAssertNil(a.finishedAt)
        XCTAssertEqual(a.doseCount, 0)
    }

    func testRecentRapidDose() {
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-3600), units: 4, kind: .rapid)
        let a = InsulinActivity.compute(doses: [dose], at: now)
        XCTAssertEqual(a.onBoard, 4 * InsulinActionCurve.rapid.fractionRemaining(after: 3600), accuracy: 1e-9)
        XCTAssertGreaterThan(a.onBoard, 2.5)
        XCTAssertLessThan(a.onBoard, 4)
        // Peak is 85 minutes after the dose: 25 minutes from now.
        XCTAssertEqual(a.peakAt!.timeIntervalSince(now), 25 * 60, accuracy: 61)
        // Mostly done once under 0.4 u (10% of 4 u).
        let done = a.mostlyDoneAt!
        XCTAssertLessThanOrEqual(dose.units * InsulinActionCurve.rapid.fractionRemaining(after: done.timeIntervalSince(dose.timestamp)), 0.4 + 1e-9)
        XCTAssertGreaterThan(done.timeIntervalSince(dose.timestamp), 3.5 * 3600)
        XCTAssertLessThan(done.timeIntervalSince(dose.timestamp), 5.5 * 3600)
        XCTAssertEqual(a.finishedAt, dose.timestamp.addingTimeInterval(InsulinActionCurve.rapid.totalDuration))
        XCTAssertEqual(a.doseCount, 1)
    }

    func testPeakIsNilOncePast() {
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-3 * 3600), units: 4, kind: .rapid)
        let a = InsulinActivity.compute(doses: [dose], at: now)
        XCTAssertNil(a.peakAt)
        XCTAssertTrue(a.isActive)
    }

    func testFutureAndFinishedDosesAreIgnored() {
        let future = InsulinDose(timestamp: now.addingTimeInterval(600), units: 4, kind: .rapid)
        let old = InsulinDose(timestamp: now.addingTimeInterval(-8 * 3600), units: 4, kind: .rapid)
        let a = InsulinActivity.compute(doses: [future, old], at: now)
        XCTAssertEqual(a.onBoard, 0)
        XCTAssertEqual(a.doseCount, 0)
    }

    func testLongActingIsBackgroundOnly() {
        let basal = InsulinDose(timestamp: now.addingTimeInterval(-2 * 3600), units: 20, kind: .long)
        let a = InsulinActivity.compute(doses: [basal], at: now)
        XCTAssertEqual(a.onBoard, 0)
        XCTAssertTrue(a.backgroundInsulinLogged)
    }

    func testPremixedCountsOnlyItsFastPart() {
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-60), units: 10, kind: .premixed)
        let a = InsulinActivity.compute(doses: [dose], at: now)
        XCTAssertEqual(a.onBoard, 3, accuracy: 1e-6)
        XCTAssertEqual(a.unitsGiven, 3, accuracy: 1e-9)
    }

    func testCurveCoversPastAndFuture() {
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-3600), units: 2, kind: .rapid)
        let a = InsulinActivity.compute(doses: [dose], at: now)
        XCTAssertEqual(a.curve.first?.date, now.addingTimeInterval(-3 * 3600))
        XCTAssertGreaterThanOrEqual(a.curve.last!.date, now.addingTimeInterval(5.9 * 3600))
        XCTAssertEqual(a.curve.first?.remaining, 0)   // before the dose
    }

    func testCarbsOnBoard() {
        let meal = MealEntry(timestamp: now.addingTimeInterval(-3600), carbs: 60)
        let c = CarbActivity.compute(meals: [meal], at: now)
        XCTAssertEqual(c.onBoard, 60 * CarbAbsorptionCurve.standard.fractionRemaining(after: 3600), accuracy: 1e-9)
        XCTAssertGreaterThan(c.onBoard, 20)
        XCTAssertLessThan(c.onBoard, 50)
        XCTAssertNotNil(c.mostlyAbsorbedAt)
        XCTAssertFalse(c.uncountedFood)
    }

    func testFoodWithoutCarbsIsFlagged() {
        let meal = MealEntry(timestamp: now.addingTimeInterval(-1800), carbs: 0, food: "Toast")
        XCTAssertTrue(CarbActivity.compute(meals: [meal], at: now).uncountedFood)
        XCTAssertTrue(CarbActivity.compute(meals: [], hypoTreatments: [now.addingTimeInterval(-600)], at: now).uncountedFood)
        XCTAssertFalse(CarbActivity.compute(meals: [], hypoTreatments: [now.addingTimeInterval(-5 * 3600)], at: now).uncountedFood)
    }
}
