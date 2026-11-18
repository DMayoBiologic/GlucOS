import Foundation

// "Sensor started" in the Logbook (docs/SensorStartLog.md): the first time GlucOS sees a new sensor
// (a new serial, or a new start time when LibreLinkUp gives no serial), it logs one event at the
// sensor's start time. Plain Foundation so `swift test` covers it; `LogbookStore.logSensorStart`
// saves it and `GlucoseStore` calls that on every publish.
//
// One event per sensor across devices: the event's id is worked out from the serial, so the Mac
// and the iPhone that both see the sensor write the same record, and sync keeps one. Its edit time
// is the sensor's start (`modified`), so a delete made anywhere since is always newer and wins:
// a device that sees the sensor after the event was deleted elsewhere can't bring it back.
enum SensorStartLog {
    /// A sensor that started longer ago than its life is an old one: never logged.
    /// A start more than this far ahead of the clock is a clock problem, not a new sensor.
    static let futureSlack: TimeInterval = 60
    /// Only a start this recent offers the undo toast. An older one (the sensor already being worn
    /// when GlucOS updated, or a device that was off for the change) is logged quietly.
    static let undoWindow: TimeInterval = 12 * 3600
    /// A "Sensor started" already this close to the start is the same sensor seen another way (an
    /// NFC scan's serial needn't read like LibreLinkUp's), so it isn't logged twice.
    static let sameStartTolerance: TimeInterval = 30 * 60
    /// How many sensors' keys are remembered as handled. Two a month: years of sensors.
    static let rememberedLimit = 40

    /// What identifies the sensor: its serial, or its start time when LibreLinkUp gives no serial.
    static func key(for sensor: SensorInfo) -> String {
        let serial = sensor.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if serial.isEmpty || serial == "?" { return "at:\(Int(sensor.activated.timeIntervalSince1970))" }
        return "sn:\(serial.uppercased())"
    }

    /// The first four bytes of every sensor-start id, so a record pulled from sync can be told
    /// to be one without its payload (a delete has none).
    static let marker: [UInt8] = [0x5E, 0x45, 0x05, 0x57]

    /// The same id on every device for the same sensor.
    static func id(for sensor: SensorInfo) -> UUID { id(forKey: key(for: sensor)) }

    static func id(forKey key: String) -> UUID {
        let a = fnv1a(Array("glucos.sensorStart.a|\(key)".utf8))
        let b = fnv1a(Array("glucos.sensorStart.b|\(key)".utf8))
        var bytes = marker
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: a >> (8 * UInt64(i)))) }
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: b >> (8 * UInt64(i)))) }
        // RFC 9562 version 8 (custom) and the standard variant, so it reads as a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether `id` is a sensor start's (`id(for:)`).
    static func isSensorStartID(_ id: UUID) -> Bool {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3] == marker
    }

    /// The Logbook event for `sensor`: "Sensor started" at its start time.
    static func event(for sensor: SensorInfo) -> ContextEvent {
        ContextEvent(id: id(for: sensor), timestamp: sensor.activated, tags: [.sensorStarted])
    }

    /// The edit time the event is saved and synced with: the sensor's start, so any change made to
    /// it afterwards (an edit, Undo, a delete) on any device is newer.
    static func modified(for sensor: SensorInfo) -> Double { sensor.activated.timeIntervalSince1970 }

    enum Decision: Equatable {
        /// Nothing to do.
        case none
        /// The event is already in the logbook (synced in, or logged before): remember the sensor.
        case remember(UUID)
        /// Log it. `offersUndo` when the start is recent enough for the toast to make sense.
        case log(ContextEvent, offersUndo: Bool)
    }

    /// What to do about `sensor` now. Never for a follower, with the switch off, without a sensor,
    /// for a start in the future or one older than the sensor's life, or for a sensor already
    /// handled on this device (logged, synced in, or deleted since). `loggedStarts` are the times of
    /// the "Sensor started" events already in the logbook.
    static func decide(sensor: SensorInfo?, enabled: Bool, follower: Bool, handled: Set<UUID>,
                       exists: (UUID) -> Bool, loggedStarts: [Date] = [], now: Date) -> Decision {
        guard enabled, !follower, let sensor else { return .none }
        let id = id(for: sensor)
        guard !handled.contains(id) else { return .none }
        let age = now.timeIntervalSince(sensor.activated)
        guard age >= -futureSlack, age <= Double(max(1, sensor.lifetimeDays)) * 86_400 else { return .none }
        if exists(id) || loggedStarts.contains(where: { abs($0.timeIntervalSince(sensor.activated)) <= sameStartTolerance }) {
            return .remember(id)
        }
        return .log(event(for: sensor), offersUndo: age <= undoWindow)
    }

    /// The handled ids with `id` added, newest last, keeping only the latest `rememberedLimit`.
    static func remembering(_ id: UUID, in list: [UUID]) -> [UUID] {
        var out = list.filter { $0 != id }
        out.append(id)
        return Array(out.suffix(rememberedLimit))
    }

    /// 64-bit FNV-1a: stable across launches, platforms and Swift versions (unlike `Hasher`).
    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}
