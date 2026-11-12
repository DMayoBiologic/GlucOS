import XCTest
@testable import GlucOSEngine

final class Libre2Tests: XCTestCase {
    typealias V = Libre2Vectors

    func testDecryptsFRAMWithValidChecksums() throws {
        for (uid, info, fram) in [(V.uid1, V.info1, V.fram1), (V.uid2, V.info2, V.fram2)] {
            let plain = try Libre2.decryptFRAM(uid: uid, patchInfo: info, fram: fram)
            XCTAssertNotNil(LibreFRAM(decrypted: plain))
        }
    }

    func testWrongKeyFailsTheChecksum() {
        var info = V.info1
        info[4] ^= 0x01
        XCTAssertThrowsError(try Libre2.decryptFRAM(uid: V.uid1, patchInfo: info, fram: V.fram1)) {
            XCTAssertEqual($0 as? Libre2.CryptoError, .badCRC)
        }
        XCTAssertThrowsError(try Libre2.decryptFRAM(uid: V.uid1, patchInfo: V.info1, fram: [0, 1, 2]))
    }

    func testFRAMReadingsArePlausible() throws {
        let fram = try XCTUnwrap(LibreFRAM(decrypted: Libre2.decryptFRAM(uid: V.uid1, patchInfo: V.info1, fram: V.fram1)))
        XCTAssertEqual(fram.state, .active)
        XCTAssertGreaterThan(fram.age, 0)
        XCTAssertGreaterThan(fram.maxLife, 14 * 1440 - 1)
        let cal = fram.calibration
        XCTAssertTrue(cal.isUsable, "\(cal)")
        let trend = cal.points(fram.trend)
        let history = cal.points(fram.history)
        XCTAssertGreaterThan(trend.count, 10)
        XCTAssertGreaterThan(history.count, 20)
        // Locks the port to LibreTransmitter's output for this sensor.
        XCTAssertEqual(trend.first?.mgdl, 99)
        XCTAssertEqual(history.first?.mgdl, 107)
        for p in trend + history { XCTAssert((40...500).contains(p.mgdl)) }
        // Minutes run newest → oldest, one apart in the trend and 15 apart in the history.
        XCTAssertEqual(fram.trend.first?.minute, fram.age)
        XCTAssertEqual(zip(fram.trend, fram.trend.dropFirst()).map { $0.minute - $1.minute }, Array(repeating: 1, count: 15))
        XCTAssertEqual(Set(zip(fram.history, fram.history.dropFirst()).map { $0.minute - $1.minute }), [15])
        // Consecutive minutes don't jump wildly (a decode error would).
        for (a, b) in zip(trend, trend.dropFirst()) where a.minute - b.minute == 1 {
            XCTAssertLessThan(abs(a.mgdl - b.mgdl), 15)
        }
    }

    func testDecryptsAndParsesBluetoothPacket() throws {
        let plain = try Libre2.decryptBLE(uid: V.uid3, data: V.ble3)
        XCTAssertEqual(plain.count, 44)
        let packet = try XCTUnwrap(LibreBLEPacket(decrypted: plain))
        XCTAssertEqual(packet.trend.count, 7)
        XCTAssertEqual(packet.history.count, 3)
        XCTAssertEqual(packet.trend.first?.minute, packet.age)
        XCTAssertGreaterThan(packet.age, 0)
        XCTAssertGreaterThan(packet.trend.filter(\.isValid).count, 4)
        XCTAssertEqual(packet.history.map(\.minute), packet.history.map(\.minute).sorted(by: >))
    }

    func testBluetoothWithWrongSensorFailsTheChecksum() {
        XCTAssertThrowsError(try Libre2.decryptBLE(uid: V.uid1, data: V.ble3))
    }

    func testCommandsHaveTheRightShape() {
        let enable = Libre2.enableStreamingParameters(uid: V.uid1, patchInfo: V.info1)
        XCTAssertEqual(enable.count, 9)
        XCTAssertEqual(enable.first, 0x1e)
        XCTAssertEqual(Array(enable[1...4]), [42, 0, 0, 0])
        let unlock1 = Libre2.streamingUnlockPayload(uid: V.uid1, patchInfo: V.info1, unlockCount: 1)
        let unlock2 = Libre2.streamingUnlockPayload(uid: V.uid1, patchInfo: V.info1, unlockCount: 2)
        XCTAssertEqual(unlock1.count, 12)
        XCTAssertEqual(Array(unlock1[0...3]), [43, 0, 0, 0])
        XCTAssertNotEqual(unlock1, unlock2)
    }

    func testCRC() {
        // CRC-16 of the empty message with Libre's seed is the seed itself, bit-reversed and swapped.
        XCTAssertEqual(LibreCRC.crc16([], seed: 0xffff), 0xffff)
        XCTAssertFalse(LibreCRC.hasValidCRC16InFirstTwoBytes([0, 0, 1]))
    }
}

final class LibreReadingsTests: XCTestCase {
    typealias V = Libre2Vectors

    func testNFCReadingsCoverEightHoursOldestFirst() throws {
        let fram = try XCTUnwrap(LibreFRAM(decrypted: Libre2.decryptFRAM(uid: V.uid1, patchInfo: V.info1, fram: V.fram1)))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = LibreReadings.readings(fram: fram, readAt: now)
        XCTAssertEqual(r.last?.timestamp, now)
        XCTAssertEqual(r.last?.mgdl, 99)
        XCTAssertEqual(r.map(\.timestamp), r.map(\.timestamp).sorted())
        XCTAssertEqual(Set(r.map(\.timestamp)).count, r.count)
        let span = now.timeIntervalSince(try XCTUnwrap(r.first).timestamp)
        XCTAssert((7 * 3600...8.5 * 3600).contains(span), "\(span / 3600) h")
        XCTAssertNotEqual(r.last?.trend, .unknown)
    }

    func testTrendArrows() {
        func pts(_ slope: Double) -> [LibreGlucosePoint] { (0...15).map { LibreGlucosePoint(minute: $0, mgdl: 100 + slope * Double($0)) } }
        XCTAssertEqual(LibreReadings.trend(at: 15, in: pts(0)), .flat)
        XCTAssertEqual(LibreReadings.trend(at: 15, in: pts(1.5)), .rising)
        XCTAssertEqual(LibreReadings.trend(at: 15, in: pts(-3)), .fallingQuickly)
        XCTAssertEqual(LibreReadings.trend(at: 2, in: pts(0)), .unknown)
    }

    func testAgreement() {
        let t = Date(timeIntervalSince1970: 0)
        let ours = [GlucoseReading(timestamp: t, mgdl: 110, trend: .flat),
                    GlucoseReading(timestamp: t.addingTimeInterval(900), mgdl: 90, trend: .flat),
                    GlucoseReading(timestamp: t.addingTimeInterval(9000), mgdl: 90, trend: .flat)]
        let linkUp = [GlucoseReading(timestamp: t.addingTimeInterval(60), mgdl: 100, trend: .flat),
                      GlucoseReading(timestamp: t.addingTimeInterval(900), mgdl: 100, trend: .flat)]
        let a = LibreReadings.agreement(ours, linkUp: linkUp)
        XCTAssertEqual(a?.pairs, 2)
        XCTAssertEqual(a?.meanAbsoluteDifference, 10)
        XCTAssertEqual(a?.bias, 0)
        XCTAssertEqual(a?.mard ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertNil(LibreReadings.agreement(ours, linkUp: []))
    }
}
