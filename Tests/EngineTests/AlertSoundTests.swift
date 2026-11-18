import XCTest
@testable import GlucOSEngine

/// The alert sound picker's preview rules and level bars, and that the bundled files, the Swift
/// list and the relay agree (docs/AlertSounds.md).
final class AlertSoundTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Preview: one at a time

    func testTapPlaysThenASecondTapStops() {
        var p = AlertSoundPreview()
        XCTAssertEqual(p.tap(.chime, now: t0), [.play(.chime)])
        XCTAssertTrue(p.isPlaying(.chime, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(p.tap(.chime, now: t0.addingTimeInterval(1)), [.stop])
        XCTAssertNil(p.playing)
    }

    func testAnotherSoundCutsOffTheOneBeforeIt() {
        var p = AlertSoundPreview()
        _ = p.tap(.chime, now: t0)
        XCTAssertEqual(p.tap(.pulse, now: t0.addingTimeInterval(0.4)), [.stop, .play(.pulse)])
        XCTAssertFalse(p.isPlaying(.chime, now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(p.isPlaying(.pulse, now: t0.addingTimeInterval(0.5)))
    }

    func testALateFinishFromAReplacedSoundIsIgnored() {
        var p = AlertSoundPreview()
        _ = p.tap(.chime, now: t0)
        _ = p.tap(.beacon, now: t0.addingTimeInterval(0.3))
        p.finished(.chime)
        XCTAssertEqual(p.playing, .beacon)
        p.finished(.beacon)
        XCTAssertNil(p.playing)
    }

    func testLeavingStopsOnlyWhenSomethingPlays() {
        var p = AlertSoundPreview()
        XCTAssertNil(p.leave())
        _ = p.tap(.standard, now: t0)
        XCTAssertEqual(p.leave(), .stop)
        XCTAssertNil(p.playing)
    }

    func testTheIndicatorNeverSticksPastTheSound() {
        var p = AlertSoundPreview()
        _ = p.tap(.pulse, now: t0)
        XCTAssertTrue(p.isPlaying(.pulse, now: t0.addingTimeInterval(AlertSound.pulse.length)))
        XCTAssertFalse(p.isPlaying(.pulse, now: t0.addingTimeInterval(AlertSound.pulse.length + 0.6)))
        XCTAssertNil(p.progress(now: t0.addingTimeInterval(5)))
        // Tapping it again after it ran out plays it again rather than "stopping" nothing.
        XCTAssertEqual(p.tap(.pulse, now: t0.addingTimeInterval(5)), [.stop, .play(.pulse)])
    }

    func testProgressRunsAcrossTheSound() {
        var p = AlertSoundPreview()
        _ = p.tap(.chime, now: t0)
        XCTAssertEqual(p.progress(now: t0), 0)
        XCTAssertEqual(p.progress(now: t0.addingTimeInterval(AlertSound.chime.length / 2))!, 0.5, accuracy: 1e-6)
    }

    // MARK: Level bars

    func testBarsStayInBoundsAndSway() {
        for level in [-1.0, 0, 0.3, 1, 2] {
            for time in stride(from: 0.0, through: 2, by: 0.05) {
                let hs = AlertSoundLevel.heights(level: level, time: time)
                XCTAssertEqual(hs.count, AlertSoundLevel.bars)
                XCTAssertTrue(hs.allSatisfy { $0 >= 0.2 && $0 <= 1 }, "\(level) \(time) \(hs)")
            }
        }
        // Silence lies flat; sound moves the bars apart from each other.
        XCTAssertEqual(AlertSoundLevel.heights(level: 0, time: 1), [0.2, 0.2, 0.2])
        XCTAssertGreaterThan(Set(AlertSoundLevel.heights(level: 1, time: 0.37)).count, 1)
        XCTAssertNotEqual(AlertSoundLevel.heights(level: 1, time: 0.1), AlertSoundLevel.heights(level: 1, time: 0.2))
    }

    func testStillBarsForReduceMotionAreFixed() {
        XCTAssertEqual(AlertSoundLevel.still.count, AlertSoundLevel.bars)
        XCTAssertTrue(AlertSoundLevel.still.allSatisfy { $0 > 0.2 && $0 <= 1 })
    }

    func testMeterAndEnvelope() {
        XCTAssertEqual(AlertSoundLevel.level(decibels: 0), 1)
        XCTAssertEqual(AlertSoundLevel.level(decibels: -160), 0)
        XCTAssertEqual(AlertSoundLevel.level(decibels: -.infinity), 0)
        XCTAssertEqual(AlertSoundLevel.level(decibels: -22.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AlertSoundLevel.envelope(progress: 0), 1)
        XCTAssertLessThan(AlertSoundLevel.envelope(progress: 0.8), AlertSoundLevel.envelope(progress: 0.2))
        XCTAssertEqual(AlertSoundLevel.envelope(progress: 1), 0)
    }

    // MARK: Sounds

    func testUnknownStoredValuesAreTheStandardSound() {
        XCTAssertEqual(AlertSound(stored: nil), .standard)
        XCTAssertEqual(AlertSound(stored: "siren"), .standard)
        XCTAssertEqual(AlertSound(stored: "pulse"), .pulse)
    }

    func testEveryBundledFileExistsAndIsAsLongAsItSays() throws {
        for sound in AlertSound.allCases {
            guard let name = sound.fileName else { XCTAssertEqual(sound, .standard); continue }
            let url = Self.repo.appendingPathComponent("Sources/App/Sounds/\(name)")
            let data = try Data(contentsOf: url)
            // RIFF/WAVE, PCM: byte rate at 28, data size at 40 (the generator writes no extra chunks).
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF", name)
            func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
            let seconds = Double(u32(40)) / Double(u32(28))
            XCTAssertEqual(seconds, sound.length, accuracy: 0.02, name)
            // Notifications refuse sounds of 30 s or more.
            XCTAssertLessThan(seconds, 30)
        }
    }

    func testTheRelayKnowsTheSameFiles() throws {
        let apns = try String(contentsOf: Self.repo.appendingPathComponent("supabase/functions/relay/apns.ts"), encoding: .utf8)
        for sound in AlertSound.allCases {
            guard let name = sound.fileName else { continue }
            XCTAssertTrue(apns.contains("\(sound.rawValue): \"\(name)\""), "relay alertSoundFiles is missing \(sound.rawValue)")
        }
    }

    func testPreviewWordsNeverPromiseAnAlert() {
        XCTAssertTrue(AlertSound.footer.contains("never count as alerts"))
        XCTAssertTrue(AlertSound.accessibilityHint.contains("Nothing is sent or logged"))
    }
}
