import Foundation

/// A Libre 2 or 2 Plus whose Bluetooth stream GlucOS took over from LibreLink with an NFC tap.
/// Everything needed to find it, unlock each connection and turn its packets into readings.
struct DirectSensor: Codable, Equatable, Sendable {
    /// The tag's identifier, least-significant byte first (what the Libre 2 crypto wants).
    var uid: [UInt8]
    var patchInfo: [UInt8]
    var serial: String?
    /// Bluetooth address, upper-case hex with no separators. Newer sensors advertise it as their name.
    var macAddress: String
    /// From the sensor's memory at the tap. Packets carry raw values only.
    var calibration: LibreCalibration
    /// Wear time in minutes, as the sensor reported it.
    var maxLife: Int
    /// Unlock payloads used so far. Each connection takes the next one, so this is saved first.
    var unlockCount: UInt16
    /// iOS's identifier for the sensor once it has been found, so later connections skip the scan.
    var peripheralID: UUID?
    /// When GlucOS took the sensor over (the person agreed LibreLink's alarms stop at this point).
    var takenOverAt: Date
    /// The last good packet and the sensor's age then, in minutes.
    var lastPacketAt: Date?
    var lastAge: Int?

    init(uid: [UInt8], patchInfo: [UInt8], serial: String?, macAddress: String,
                calibration: LibreCalibration, maxLife: Int, takenOverAt: Date) {
        self.uid = uid
        self.patchInfo = patchInfo
        self.serial = serial
        self.macAddress = macAddress.uppercased().filter(\.isHexDigit)
        self.calibration = calibration
        self.maxLife = maxLife
        self.unlockCount = 0
        self.takenOverAt = takenOverAt
    }

    /// The sensor's Bluetooth address from the enable-streaming reply (6 bytes, LSB first).
    static func macAddress(fromEnableReply reply: [UInt8]) -> String? {
        guard reply.count == 6 else { return nil }
        return reply.reversed().map { String(format: "%02X", $0) }.joined()
    }

    /// Whether an advertisement is this sensor's: newer ones advertise their address as their
    /// name, older ones put most of the tag's identifier in the manufacturer data.
    func isAdvertisement(name: String?, manufacturerData: Data?) -> Bool {
        if let name, name.uppercased().filter(\.isHexDigit) == macAddress, name.count >= 12 { return true }
        guard let d = manufacturerData.map({ [UInt8]($0) }), d.count == 8, uid.count == 8 else { return false }
        return Array(d[2..<8]) + [0x07, 0xE0] == uid
    }

    /// Takes the next unlock payload, for the connection that's starting now.
    mutating func nextUnlockPayload() -> [UInt8] {
        unlockCount &+= 1
        return Libre2.streamingUnlockPayload(uid: uid, patchInfo: patchInfo, unlockCount: unlockCount)
    }

    /// Minutes of wear left at the last packet.
    var minutesLeft: Int? { lastAge.map { max(0, maxLife - $0) } }

    enum PacketError: Error, Equatable {
        /// Decrypted, but the checksum failed: not this sensor, or the packet was garbled.
        case badPacket
        /// The sensor sent nothing GlucOS could turn into glucose (warming up, or a sensor error).
        case noReadings
    }

    /// Readings from one 46-byte packet, oldest first.
    func readings(packet: [UInt8], receivedAt: Date) throws -> (readings: [GlucoseReading], age: Int) {
        guard let plain = try? Libre2.decryptBLE(uid: uid, data: packet),
              let p = LibreBLEPacket(decrypted: plain) else { throw PacketError.badPacket }
        let r = LibreReadings.readings(packet: p, calibration: calibration, receivedAt: receivedAt)
        guard !r.isEmpty else { throw PacketError.noReadings }
        return (r, p.age)
    }
}

/// Puts a packet back together from the notifications it arrives in (20 + 18 + 8 bytes).
struct LibreBLEAssembler: Sendable {
    static let packetSize = 46
    /// Chunks further apart than this belong to different packets.
    static let gap: TimeInterval = 6

    private var buffer: [UInt8] = []
    private var lastChunk: Date?

    init() {}

    /// The whole packet once the last chunk is in, otherwise nil.
    mutating func append(_ chunk: [UInt8], at date: Date) -> [UInt8]? {
        if let last = lastChunk, date.timeIntervalSince(last) > Self.gap { buffer.removeAll() }
        lastChunk = date
        buffer += chunk
        guard buffer.count >= Self.packetSize else { return nil }
        defer { buffer.removeAll() }
        return buffer.count == Self.packetSize ? buffer : nil
    }

    mutating func reset() {
        buffer.removeAll()
        lastChunk = nil
    }
}

/// Combines readings from LibreLinkUp and from the sensor itself into one current reading and history.
enum ReadingTimeline {
    /// Readings newer than this keep every minute; older ones are thinned to one per `slot`, like
    /// LinkUp's own history, so the snapshot (read by the widgets) stays small.
    static let fineWindow: TimeInterval = 20 * 60
    static let slot: TimeInterval = 5 * 60

    /// The newest reading as `current` and the rest of the last `window` as history, oldest first.
    /// Readings in the same minute are one reading: the later one in `readings` wins.
    static func union(_ readings: [GlucoseReading], window: TimeInterval = 12 * 3600,
                             now: Date = Date()) -> (current: GlucoseReading?, history: [GlucoseReading]) {
        var byMinute = [Int: GlucoseReading]()
        for r in readings where r.timestamp >= now.addingTimeInterval(-window) && r.timestamp <= now.addingTimeInterval(600) {
            byMinute[Int((r.timestamp.timeIntervalSince1970 / 60).rounded(.down))] = r
        }
        var sorted = byMinute.values.sorted { $0.timestamp < $1.timestamp }
        guard let current = sorted.popLast() else { return (nil, []) }
        var seenSlots = Set<Int>()
        var history = [GlucoseReading]()
        // Newest first so each slot keeps its latest reading.
        for r in sorted.reversed() {
            if current.timestamp.timeIntervalSince(r.timestamp) <= fineWindow {
                history.append(r)
            } else if seenSlots.insert(Int((r.timestamp.timeIntervalSince1970 / slot).rounded(.down))).inserted {
                history.append(r)
            }
        }
        return (current, history.reversed())
    }

    /// After a LinkUp fetch: LinkUp's readings, plus whatever the app already had that's newer than
    /// LinkUp's newest (readings from the sensor while LibreLink isn't uploading).
    static func afterFetch(linkUpCurrent: GlucoseReading?, linkUpHistory: [GlucoseReading],
                                  previousCurrent: GlucoseReading?, previousHistory: [GlucoseReading],
                                  now: Date = Date()) -> (current: GlucoseReading?, history: [GlucoseReading]) {
        let linkUp = linkUpHistory + [linkUpCurrent].compactMap { $0 }
        let newestLinkUp = linkUp.map(\.timestamp).max() ?? .distantPast
        let newer = (previousHistory + [previousCurrent].compactMap { $0 }).filter { $0.timestamp > newestLinkUp.addingTimeInterval(60) }
        guard !newer.isEmpty else { return (linkUpCurrent, linkUpHistory) }
        return union(linkUp + newer, now: now)
    }
}
