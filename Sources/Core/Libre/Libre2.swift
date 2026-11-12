// FreeStyle Libre 2 (and 2 Plus, non-Gen2) decryption, CRC, FRAM and Bluetooth packet parsing,
// and conversion from raw sensor values to glucose.
//
// Ported from LibreTransmitter (https://github.com/LoopKit/LibreTransmitter: PreLibre2.swift,
// CRC.swift, SensorData.swift, Measurement.swift, GlucoseFromRaw.swift, SensorPairingService.swift),
// MIT License, Copyright (c) 2016 Mark Wilson and LoopKit Authors. See docs/third-party/LibreTransmitter-LICENSE.txt.
// The algorithms are unchanged. The types were reshaped into plain values so the whole thing runs
// (and is tested) on Linux, and nothing here touches NFC or Bluetooth.
//
// Byte order: `uid` is the sensor's 8-byte NFC identifier least-significant byte first, which is the
// reverse of `NFCISO15693Tag.identifier` (that one starts E0 07).

import Foundation

public enum Libre2 {

    public enum CryptoError: Error, Equatable {
        case badLength
        case badCRC
    }

    // MARK: - Crypto core

    static let key: [UInt16] = [0xA0C5, 0x6860, 0x0000, 0x14C6]

    static func processCrypto(_ input: [UInt16]) -> [UInt16] {
        func op(_ value: UInt16) -> UInt16 {
            var res = value >> 2
            if value & 1 != 0 { res ^= key[1] }
            if value & 2 != 0 { res ^= key[0] }
            return res
        }
        let r0 = op(input[0]) ^ input[3]
        let r1 = op(r0) ^ input[2]
        let r2 = op(r1) ^ input[1]
        let r3 = op(r2) ^ input[0]
        let r4 = op(r3)
        let r5 = op(r4 ^ r0)
        let r6 = op(r5 ^ r1)
        let r7 = op(r6 ^ r2)
        return [r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4]
    }

    static func word(_ high: UInt8, _ low: UInt8) -> UInt16 { UInt16(high) << 8 | UInt16(low) }

    static func prepareVariables(uid: [UInt8], x: UInt16, y: UInt16) -> [UInt16] {
        let s1 = UInt16(truncatingIfNeeded: UInt(word(uid[5], uid[4])) + UInt(x) + UInt(y))
        let s2 = UInt16(truncatingIfNeeded: UInt(word(uid[3], uid[2])) + UInt(key[2]))
        let s3 = UInt16(truncatingIfNeeded: UInt(word(uid[1], uid[0])) + UInt(x) * 2)
        let s4 = 0x241a ^ key[3]
        return [s1, s2, s3, s4]
    }

    static func prepareVariables(uid: [UInt8], i1: UInt16, i2: UInt16, i3: UInt16, i4: UInt16) -> [UInt16] {
        let s1 = UInt16(truncatingIfNeeded: UInt(word(uid[5], uid[4])) + UInt(i1))
        let s2 = UInt16(truncatingIfNeeded: UInt(word(uid[3], uid[2])) + UInt(i2))
        let s3 = UInt16(truncatingIfNeeded: UInt(word(uid[1], uid[0])) + UInt(i3) + UInt(key[2]))
        let s4 = UInt16(truncatingIfNeeded: UInt(i4) + UInt(key[3]))
        return [s1, s2, s3, s4]
    }

    static func usefulFunction(uid: [UInt8], x: UInt16, y: UInt16) -> [UInt8] {
        let blockKey = processCrypto(prepareVariables(uid: uid, x: x, y: y))
        let r1 = blockKey[0] ^ 0x4163
        let r2 = blockKey[1] ^ 0x4344
        return [UInt8(truncatingIfNeeded: r1), UInt8(truncatingIfNeeded: r1 >> 8),
                UInt8(truncatingIfNeeded: r2), UInt8(truncatingIfNeeded: r2 >> 8)]
    }

    // MARK: - FRAM

    public static let framBlocks = 43
    public static let framSize = 344

    /// Decrypts the 43 FRAM blocks read over NFC. Throws `badCRC` unless the header, body and footer
    /// checksums all match, so a wrong key or a sensor this code doesn't understand is never decoded
    /// into numbers.
    public static func decryptFRAM(uid: [UInt8], patchInfo: [UInt8], fram: [UInt8]) throws -> [UInt8] {
        guard uid.count == 8, patchInfo.count >= 6, fram.count == framSize else { throw CryptoError.badLength }
        let arg = word(patchInfo[5], patchInfo[4]) ^ 0x44
        var out = [UInt8]()
        out.reserveCapacity(framSize)
        for i in 0..<framBlocks {
            let k = processCrypto(prepareVariables(uid: uid, x: UInt16(i), y: arg))
            for (j, w) in k.enumerated() {
                out.append(fram[i * 8 + j * 2] ^ UInt8(truncatingIfNeeded: w))
                out.append(fram[i * 8 + j * 2 + 1] ^ UInt8(truncatingIfNeeded: w >> 8))
            }
        }
        guard LibreFRAM.hasValidCRCs(out) else { throw CryptoError.badCRC }
        return out
    }

    // MARK: - Bluetooth

    /// Decrypts one 46-byte Bluetooth packet into 44 bytes (the last two are its CRC).
    public static func decryptBLE(uid: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard uid.count == 8, data.count == 46 else { throw CryptoError.badLength }
        let d = usefulFunction(uid: uid, x: 0x1b, y: 0x1b6a)
        let x = word(d[1], d[0]) ^ word(d[3], d[2]) | 0x63
        let y = word(data[1], data[0]) ^ 0x63
        var key = [UInt8]()
        var k = processCrypto(prepareVariables(uid: uid, x: x, y: y))
        for _ in 0..<8 {
            for w in k {
                key.append(UInt8(truncatingIfNeeded: w))
                key.append(UInt8(truncatingIfNeeded: w >> 8))
            }
            k = processCrypto(k)
        }
        let result = data[2...].enumerated().map { i, v in v ^ key[i] }
        guard LibreCRC.hasValidCRC16InLastTwoBytes(result) else { throw CryptoError.badCRC }
        return result
    }

    /// The unlock code GlucOS uses when it enables streaming. Any 32-bit value works as long as the
    /// same one goes into `enableStreamingParameters` and `streamingUnlockPayload`.
    public static let unlockCode: UInt32 = 42

    /// Parameters for NFC custom command 0xA1 that switch the sensor's Bluetooth stream to this phone.
    /// The sensor answers with its 6-byte Bluetooth MAC address (reversed).
    public static func enableStreamingParameters(uid: [UInt8], patchInfo: [UInt8], unlockCode: UInt32 = unlockCode) -> [UInt8] {
        let b: [UInt8] = [UInt8(unlockCode & 0xFF), UInt8((unlockCode >> 8) & 0xFF),
                          UInt8((unlockCode >> 16) & 0xFF), UInt8((unlockCode >> 24) & 0xFF)]
        let y = word(patchInfo[5], patchInfo[4]) ^ word(b[1], b[0])
        let d = usefulFunction(uid: uid, x: 0x1e, y: y)
        return [0x1e] + b + d
    }

    /// The 12 bytes written to the sensor after every Bluetooth connection. `unlockCount` must go up
    /// by one on each connection.
    public static func streamingUnlockPayload(uid: [UInt8], patchInfo: [UInt8], enableTime: UInt32 = unlockCode, unlockCount: UInt16) -> [UInt8] {
        let time = enableTime &+ UInt32(unlockCount)
        let b: [UInt8] = [UInt8(time & 0xFF), UInt8((time >> 8) & 0xFF), UInt8((time >> 16) & 0xFF), UInt8((time >> 24) & 0xFF)]
        let ad = usefulFunction(uid: uid, x: 0x1b, y: 0x1b6a)
        let ed = usefulFunction(uid: uid, x: 0x1e, y: UInt16(enableTime & 0xFFFF) ^ word(patchInfo[5], patchInfo[4]))
        let t11 = word(ed[1], ed[0]) ^ word(b[3], b[2])
        let t12 = word(ad[1], ad[0])
        let t13 = word(ed[3], ed[2]) ^ word(b[1], b[0])
        let t14 = word(ad[3], ad[2])
        let t2 = processCrypto(prepareVariables(uid: uid, i1: t11, i2: t12, i3: t13, i4: t14))
        func bytes(_ w: UInt16) -> [UInt8] { [UInt8(w & 0xFF), UInt8(w >> 8)] }
        let t31 = LibreCRC.crc16([0xc1, 0xc4, 0xc3, 0xc0, 0xd4, 0xe1, 0xe7, 0xba] + bytes(t2[0])).byteSwapped
        let t32 = LibreCRC.crc16(bytes(t2[1]) + bytes(t2[2]) + bytes(t2[3])).byteSwapped
        let t33 = LibreCRC.crc16([ad[0], ad[1], ad[2], ad[3], ed[0], ed[1]]).byteSwapped
        let t34 = LibreCRC.crc16([ed[2], ed[3], b[0], b[1], b[2], b[3]]).byteSwapped
        let t4 = processCrypto(prepareVariables(uid: uid, i1: t31, i2: t32, i3: t33, i4: t34))
        return b + t4.flatMap(bytes)
    }
}

// MARK: - CRC

public enum LibreCRC {
    static let table: [UInt16] = {
        // CRC-16/CCITT, reflected (poly 0x8408), the table LibreMonitor uses.
        (0..<256).map { i -> UInt16 in
            var c = UInt16(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
            return c
        }
    }()

    /// Libre's CRC-16: reflected CCITT, then bit-reversed and byte-swapped (as LibreMonitor does it).
    public static func crc16(_ message: [UInt8], seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for b in message { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(b)) & 0xFF)] }
        var reversed: UInt16 = 0
        for _ in 0..<16 {
            reversed = reversed << 1 | crc & 1
            crc >>= 1
        }
        return reversed.byteSwapped
    }

    public static func hasValidCRC16InFirstTwoBytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 2 else { return false }
        return crc16(Array(bytes.dropFirst(2)), seed: 0xffff) == (UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    public static func hasValidCRC16InLastTwoBytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 2 else { return false }
        let n = bytes.count
        return crc16(Array(bytes.dropLast(2)), seed: 0xffff) == (UInt16(bytes[n - 2]) << 8 | UInt16(bytes[n - 1]))
    }
}

// MARK: - Raw values and calibration

/// One raw measurement as the sensor stores it: before calibration, with its thermistor readings.
public struct LibreRawMeasurement: Equatable, Sendable {
    public let rawGlucose: Int
    public let rawTemperature: Int
    public let rawTemperatureAdjustment: Int
    /// The sensor's own error bits; 0 when the measurement is good.
    public let errorBits: Int
    /// Sensor minute this measurement belongs to (minutes since the sensor started).
    public let minute: Int

    public var isValid: Bool { rawGlucose > 0 && errorBits == 0 }

    public init(rawGlucose: Int, rawTemperature: Int, rawTemperatureAdjustment: Int, errorBits: Int = 0, minute: Int) {
        self.rawGlucose = rawGlucose
        self.rawTemperature = rawTemperature
        self.rawTemperatureAdjustment = rawTemperatureAdjustment
        self.errorBits = errorBits
        self.minute = minute
    }

    /// From the 6-byte FRAM record.
    init(framRecord b: [UInt8], minute: Int) {
        let glucose = LibreBits.read(b, 0, 0, 0xe)
        let temperature = LibreBits.read(b, 0, 0x1a, 0xc) << 2
        let adjustment = LibreBits.read(b, 0, 0x26, 0x9) << 2
        let negative = LibreBits.read(b, 0, 0x2f, 0x1) != 0
        self.init(rawGlucose: glucose, rawTemperature: temperature,
                  rawTemperatureAdjustment: negative ? -adjustment : adjustment,
                  // As DiaBLE reads it: 9 quality bits, and an error flag at bit 0x19.
                  errorBits: (LibreBits.read(b, 0, 0xe, 0xb) & 0x1FF) | (LibreBits.read(b, 0, 0x19, 1) << 9),
                  minute: minute)
    }
}

/// The factory calibration the sensor carries in its FRAM. Bluetooth packets don't include it, so
/// it's saved from the NFC read and used for every streamed reading after that.
public struct LibreCalibration: Codable, Equatable, Sendable {
    public let i1: Int
    public let i2: Int
    public let i3: Double
    public let i4: Double
    public let i5: Double
    public let i6: Double

    public init(i1: Int, i2: Int, i3: Double, i4: Double, i5: Double, i6: Double) {
        self.i1 = i1; self.i2 = i2; self.i3 = i3; self.i4 = i4; self.i5 = i5; self.i6 = i6
    }

    /// The tables only cover these indexes; anything else means the FRAM isn't what we think.
    public var isUsable: Bool {
        i2 >= 1 && i2 <= LibreCalibrationTables.t1.count && i2 <= LibreCalibrationTables.t2.count
            && i4 != i3 && i6 > 0
    }

    /// Glucose in mg/dL for one raw measurement, or nil when the maths isn't defined (bad thermistor
    /// value, unusable calibration).
    public func mgdl(for m: LibreRawMeasurement) -> Double? {
        guard isUsable, m.rawGlucose > 0 else { return nil }
        let x = 1000.0 + 71500.0
        let y = 1000.0
        let ca = 0.0009180023, cb = 0.0001964561, cc = 0.0000007061775, cd = 0.00000005283566
        let denominator = Double(m.rawTemperatureAdjustment) + i6
        guard denominator != 0 else { return nil }
        let r = Double(m.rawTemperature) * x / denominator - y
        guard r > 0 else { return nil }
        let logR = log(r)
        let d = pow(logR, 3) * cd + pow(logR, 2) * cc + logR * cb + ca
        let temperature = 1 / d - 273.15
        let g1 = 65.0 * (Double(m.rawGlucose) - i3) / (i4 - i3)
        let g2 = pow(1.045, 32.5 - temperature)
        let v1 = LibreCalibrationTables.t1[i2 - 1]
        let v2 = LibreCalibrationTables.t2[i2 - 1]
        let result = (g1 * g2 - v1) / v2
        return result.isFinite ? result.rounded() : nil
    }
}

enum LibreBits {
    static func read(_ buffer: [UInt8], _ byteOffset: Int, _ bitOffset: Int, _ bitCount: Int) -> Int {
        var res = 0
        for i in 0..<bitCount {
            let total = byteOffset * 8 + bitOffset + i
            let byte = total / 8
            guard total >= 0, byte < buffer.count else { continue }
            if (buffer[byte] >> (total % 8)) & 1 == 1 { res |= 1 << i }
        }
        return res
    }
}

// MARK: - FRAM contents

/// The decrypted 344-byte FRAM: header (3 blocks), body (37 blocks), footer (3 blocks).
public struct LibreFRAM: Equatable, Sendable {
    public let bytes: [UInt8]

    public init?(decrypted bytes: [UInt8]) {
        guard bytes.count == Libre2.framSize, Self.hasValidCRCs(bytes) else { return nil }
        self.bytes = bytes
    }

    static func hasValidCRCs(_ b: [UInt8]) -> Bool {
        guard b.count == Libre2.framSize else { return false }
        return LibreCRC.hasValidCRC16InFirstTwoBytes(Array(b[0..<24]))
            && LibreCRC.hasValidCRC16InFirstTwoBytes(Array(b[24..<320]))
            && LibreCRC.hasValidCRC16InFirstTwoBytes(Array(b[320..<344]))
    }

    var body: ArraySlice<UInt8> { bytes[24..<320] }
    var footer: ArraySlice<UInt8> { bytes[320..<344] }

    /// Minutes since the sensor started.
    public var age: Int { Int(bytes[24 + 293]) << 8 | Int(bytes[24 + 292]) }
    /// Total wear time in minutes, as the sensor reports it.
    public var maxLife: Int { Int(bytes[320 + 7]) << 8 | Int(bytes[320 + 6]) }

    public enum State: Equatable, Sendable {
        case notActivated, warmingUp, active, expired, shutdown, failure, unknown(UInt8)
        init(_ b: UInt8) {
            switch b {
            case 0x01: self = .notActivated
            case 0x02: self = .warmingUp
            case 0x03: self = .active
            case 0x04: self = .expired
            case 0x05: self = .shutdown
            case 0x06: self = .failure
            default: self = .unknown(b)
            }
        }
    }

    public var state: State { State(bytes[4]) }

    public var calibration: LibreCalibration {
        let i1 = LibreBits.read(bytes, 2, 0, 3)
        let i2 = LibreBits.read(bytes, 2, 3, 0xa)
        let i3 = Double(LibreBits.read(bytes, 0x150, 0, 8))
        let i4 = Double(LibreBits.read(bytes, 0x150, 8, 0xe))
        let negativeI3 = LibreBits.read(bytes, 0x150, 0x21, 1) != 0
        let i5 = Double(LibreBits.read(bytes, 0x150, 0x28, 0xc) << 2)
        let i6 = Double(LibreBits.read(bytes, 0x150, 0x34, 0xc) << 2)
        return LibreCalibration(i1: i1, i2: i2, i3: negativeI3 ? -i3 : i3, i4: i4, i5: i5, i6: i6)
    }

    private var nextTrendBlock: Int { Int(bytes[24 + 2]) }
    private var nextHistoryBlock: Int { Int(bytes[24 + 3]) }

    /// The last 16 minutes, newest first (one per minute).
    public var trend: [LibreRawMeasurement] {
        let body = Array(self.body)
        return (0..<16).map { i in
            var index = 4 + (nextTrendBlock - 1 - i) * 6
            if index < 4 { index += 96 }
            return LibreRawMeasurement(framRecord: Array(body[index..<index + 6]), minute: age - i)
        }
    }

    /// The last 8 hours, newest first (one per 15 minutes).
    public var history: [LibreRawMeasurement] {
        let body = Array(self.body)
        // The most recent history record's minute, as LibreMonitor works it out.
        let fromCounter = ((age - 3) / 15) % 32
        let delay = (age - 3) % 15 + 3
        let newestMinute = fromCounter == nextHistoryBlock ? age - delay : age - delay + 15
        return (0..<32).map { i in
            var index = 100 + (nextHistoryBlock - 1 - i) * 6
            if index < 100 { index += 192 }
            return LibreRawMeasurement(framRecord: Array(body[index..<index + 6]), minute: newestMinute - i * 15)
        }
    }
}

// MARK: - Bluetooth packet

/// A decrypted 44-byte Bluetooth packet: 7 recent minutes plus the 3 latest 15-minute history points.
public struct LibreBLEPacket: Equatable, Sendable {
    public let age: Int
    /// Newest first: minutes 0, 2, 4, 6, 7, 12 and 15 ago.
    public let trend: [LibreRawMeasurement]
    /// Newest first.
    public let history: [LibreRawMeasurement]

    public init?(decrypted d: [UInt8]) {
        guard d.count == 44, LibreCRC.hasValidCRC16InLastTwoBytes(d) else { return nil }
        let age = Int(d[41]) << 8 | Int(d[40])
        self.age = age
        let offsets = [0, 2, 4, 6, 7, 12, 15]
        var trend = [LibreRawMeasurement]()
        var history = [LibreRawMeasurement]()
        for i in 0..<10 {
            let raw = LibreBits.read(d, i * 4, 0, 0xe)
            let temperature = LibreBits.read(d, i * 4, 0xe, 0xc) << 2
            var adjustment = LibreBits.read(d, i * 4, 0x1a, 0x5) << 2
            if LibreBits.read(d, i * 4, 0x1f, 0x1) != 0 { adjustment = -adjustment }
            let minute = i < 7 ? age - offsets[i] : ((age - 2) / 15) * 15 - 15 * (i - 7)
            // A zero raw value carries error bits in the temperature field; keep it as invalid.
            let m = LibreRawMeasurement(rawGlucose: raw, rawTemperature: raw == 0 ? 0 : temperature,
                                        rawTemperatureAdjustment: adjustment,
                                        errorBits: raw == 0 ? max(1, temperature >> 2) : 0, minute: minute)
            if i < 7 { trend.append(m) } else { history.append(m) }
        }
        self.trend = trend
        self.history = history
    }
}

// MARK: - From raw to readings

public struct LibreGlucosePoint: Equatable, Sendable {
    public let minute: Int
    public let mgdl: Double
}

public extension LibreCalibration {
    /// Valid measurements converted to glucose, dropping anything outside the sensor's reportable
    /// range (40–500 mg/dL) rather than clamping it.
    func points(_ measurements: [LibreRawMeasurement]) -> [LibreGlucosePoint] {
        measurements.compactMap { m in
            guard m.isValid, let g = mgdl(for: m), g >= 40, g <= 500 else { return nil }
            return LibreGlucosePoint(minute: m.minute, mgdl: g)
        }
    }
}
