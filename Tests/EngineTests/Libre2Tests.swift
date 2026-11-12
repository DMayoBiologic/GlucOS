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

final class LibreRobustnessTests: XCTestCase {
    typealias V = Libre2Vectors

    func testOutOfRangeRingCursorIsRejected() throws {
        var plain = try Libre2.decryptFRAM(uid: V.uid1, patchInfo: V.info1, fram: V.fram1)
        // Bump the history cursor past its 32 slots and fix the body's CRC so only the cursor is wrong.
        plain[24 + 3] = 33
        let crc = LibreCRC.crc16(Array(plain[26..<320]), seed: 0xffff)
        plain[24] = UInt8(crc >> 8)
        plain[25] = UInt8(crc & 0xff)
        XCTAssertTrue(LibreFRAM.hasValidCRCs(plain))
        XCTAssertNil(LibreFRAM(decrypted: plain))
    }

    func testAgreementSkipsInvalidNearestReference() {
        let t = Date(timeIntervalSince1970: 0)
        let ours = [GlucoseReading(timestamp: t, mgdl: 100, trend: .flat)]
        let linkUp = [GlucoseReading(timestamp: t.addingTimeInterval(10), mgdl: 0, trend: .flat),
                      GlucoseReading(timestamp: t.addingTimeInterval(50), mgdl: 100, trend: .flat)]
        XCTAssertEqual(LibreReadings.agreement(ours, linkUp: linkUp)?.pairs, 1)
    }
}

final class LibreDirectTests: XCTestCase {
    typealias V = Libre2Vectors

    private func sensor(uid: [UInt8] = V.uid3) throws -> DirectSensor {
        let fram = try XCTUnwrap(LibreFRAM(decrypted: Libre2.decryptFRAM(uid: V.uid1, patchInfo: V.info1, fram: V.fram1)))
        return DirectSensor(uid: uid, patchInfo: V.info1, serial: nil, macAddress: "a4:b7:c9:02:3f:8d",
                            calibration: fram.calibration, maxLife: fram.maxLife, takenOverAt: Date(timeIntervalSince1970: 0))
    }

    func testMacAddressAndAdvertisementMatching() throws {
        XCTAssertEqual(DirectSensor.macAddress(fromEnableReply: [0x8d, 0x3f, 0x02, 0xc9, 0xb7, 0xa4]), "A4B7C9023F8D")
        XCTAssertNil(DirectSensor.macAddress(fromEnableReply: [1, 2, 3]))
        let s = try sensor()
        XCTAssertEqual(s.macAddress, "A4B7C9023F8D")
        XCTAssertTrue(s.isAdvertisement(name: "A4B7C9023F8D", manufacturerData: nil))
        XCTAssertFalse(s.isAdvertisement(name: "A4B7C9023F8E", manufacturerData: nil))
        // Older sensors: bytes 2…7 of the manufacturer data are the tag identifier without its 07 E0.
        let m = Data([0x00, 0x00] + Array(V.uid3[0..<6]))
        XCTAssertTrue(s.isAdvertisement(name: "ABBOTT3MH0000000", manufacturerData: m))
        XCTAssertFalse(s.isAdvertisement(name: nil, manufacturerData: Data([0, 0, 1, 2, 3, 4, 5, 6])))
    }

    func testEachConnectionUsesTheNextUnlockPayload() throws {
        var s = try sensor()
        let first = s.nextUnlockPayload()
        let second = s.nextUnlockPayload()
        XCTAssertEqual(s.unlockCount, 2)
        XCTAssertEqual(first, Libre2.streamingUnlockPayload(uid: V.uid3, patchInfo: V.info1, unlockCount: 1))
        XCTAssertNotEqual(first, second)
    }

    func testPacketFromAnotherSensorIsRejected() throws {
        let s = try sensor(uid: V.uid1)
        XCTAssertThrowsError(try s.readings(packet: V.ble3, receivedAt: Date())) {
            XCTAssertEqual($0 as? DirectSensor.PacketError, .badPacket)
        }
    }

    func testPacketDecodesToReadings() throws {
        let s = try sensor()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let (r, age) = try s.readings(packet: V.ble3, receivedAt: now)
            XCTAssertGreaterThan(age, 0)
            XCTAssertEqual(r.map(\.timestamp), r.map(\.timestamp).sorted())
            XCTAssertLessThanOrEqual(r.last?.timestamp ?? now, now)
        } catch DirectSensor.PacketError.noReadings {
            // Another sensor's calibration can put every value outside 40–500; decoding still worked.
        }
    }

    func testAssemblerJoinsChunksAndDropsStaleOnes() {
        var a = LibreBLEAssembler()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertNil(a.append(Array(V.ble3[0..<20]), at: t))
        XCTAssertNil(a.append(Array(V.ble3[20..<38]), at: t.addingTimeInterval(1)))
        XCTAssertEqual(a.append(Array(V.ble3[38..<46]), at: t.addingTimeInterval(2)), V.ble3)
        // A chunk left over from a broken packet doesn't poison the next one.
        XCTAssertNil(a.append(Array(V.ble3[0..<20]), at: t.addingTimeInterval(10)))
        XCTAssertNil(a.append(Array(V.ble3[0..<20]), at: t.addingTimeInterval(30)))
        XCTAssertNil(a.append(Array(V.ble3[20..<38]), at: t.addingTimeInterval(31)))
        XCTAssertEqual(a.append(Array(V.ble3[38..<46]), at: t.addingTimeInterval(32)), V.ble3)
    }

    private func r(_ minutesAgo: Double, _ mgdl: Double, now: Date) -> GlucoseReading {
        GlucoseReading(timestamp: now.addingTimeInterval(-minutesAgo * 60), mgdl: mgdl, trend: .flat)
    }

    func testUnionKeepsRecentMinutesAndThinsOlderOnes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minutes = (0..<120).map { r(Double($0), 100 + Double($0), now: now) }
        let u = ReadingTimeline.union(minutes, now: now)
        XCTAssertEqual(u.current?.mgdl, 100)
        XCTAssertEqual(u.history.map(\.timestamp), u.history.map(\.timestamp).sorted())
        let recent = u.history.filter { now.timeIntervalSince($0.timestamp) <= 20 * 60 }
        XCTAssertEqual(recent.count, 20)
        let older = u.history.filter { now.timeIntervalSince($0.timestamp) > 20 * 60 }
        XCTAssertLessThanOrEqual(older.count, 21)
        XCTAssertGreaterThanOrEqual(older.count, 19)
        // Same minute: the later one in the list wins.
        XCTAssertEqual(ReadingTimeline.union([r(0, 100, now: now), r(0, 120, now: now)], now: now).current?.mgdl, 120)
    }

    func testAFetchKeepsNewerSensorReadings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let linkUpHistory = [r(60, 100, now: now), r(45, 105, now: now)]
        let linkUpCurrent = r(30, 110, now: now)
        // Nothing newer: LinkUp's answer stands as it is.
        let plain = ReadingTimeline.afterFetch(linkUpCurrent: linkUpCurrent, linkUpHistory: linkUpHistory,
                                               previousCurrent: r(31, 109, now: now), previousHistory: [], now: now)
        XCTAssertEqual(plain.current, linkUpCurrent)
        XCTAssertEqual(plain.history, linkUpHistory)
        // The sensor kept going after LibreLink lost it.
        let mixed = ReadingTimeline.afterFetch(linkUpCurrent: linkUpCurrent, linkUpHistory: linkUpHistory,
                                               previousCurrent: r(1, 130, now: now), previousHistory: [r(2, 128, now: now)], now: now)
        XCTAssertEqual(mixed.current?.mgdl, 130)
        XCTAssertEqual(mixed.history.map(\.mgdl), [100, 105, 110, 128])
    }
}
