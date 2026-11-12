import Foundation

/// What a FreeStyle Libre sensor says about itself when the phone taps it over NFC.
///
/// The sensor answers Abbott's custom ISO 15693 command 0xA1 with a few "patch info" bytes. The
/// first byte names the sensor generation and the fourth its sales region. Only this unencrypted
/// header is read. Glucose data on Libre 2 and later is encrypted and is not touched here.
///
/// The byte values come from the open-source projects that document them (DiaBLE, LibreTransmitter,
/// xDrip4iOS). A new sensor revision can use a value we haven't seen, so the raw bytes are kept and
/// shown, and an unknown value is reported as unknown rather than guessed.
public struct LibrePatchInfo: Equatable, Sendable {
    public enum Family: String, Equatable, Sendable {
        case libre1 = "FreeStyle Libre"
        case libre1US = "FreeStyle Libre 14 day (US)"
        case librePro = "FreeStyle Libre Pro"
        case libre2 = "FreeStyle Libre 2"
        case libre2Plus = "FreeStyle Libre 2 Plus"
        /// The second-generation security that US and some other markets' Libre 2 sensors use.
        case libre2Gen2 = "FreeStyle Libre 2 (Gen2)"
        case libre2PlusGen2 = "FreeStyle Libre 2 Plus (Gen2)"
        case libre3 = "FreeStyle Libre 3"
        case libre3Plus = "FreeStyle Libre 3 Plus"
        case unknown = "Unknown sensor"
    }

    public enum Region: String, Equatable, Sendable {
        case europe = "Europe"
        case usa = "United States"
        case australiaCanada = "Australia / Canada"
        case restOfWorld = "Rest of world"
        case unknown = "Unknown"
    }

    /// How far GlucOS could go with this sensor without the cloud.
    public enum DirectAccess: Equatable, Sendable {
        /// Readings are unencrypted over NFC (first-generation sensors).
        case nfcPlain
        /// Readings are encrypted; open-source apps decrypt them over NFC and Bluetooth. Taking the
        /// Bluetooth link stops LibreLink's alarms and LinkUp sharing.
        case encryptedKnown
        /// No known way to read it on iPhone (Libre 3 and Gen2-security Libre 2 sensors).
        case none
        case unknown
    }

    public let raw: [UInt8]
    public let family: Family
    public let region: Region

    public init(raw: [UInt8]) {
        // Some readers return the ISO 15693 response-flags byte (0x00) before the payload.
        var bytes = raw
        if bytes.count == 7 || bytes.count == 25, bytes.first == 0x00 { bytes.removeFirst() }
        self.raw = bytes
        self.family = Self.family(for: bytes)
        self.region = Self.region(for: bytes)
    }

    public var hex: String { raw.map { String(format: "%02X", $0) }.joined(separator: " ") }

    public var directAccess: DirectAccess {
        switch family {
        case .libre1, .libre1US, .librePro: return .nfcPlain
        case .libre2, .libre2Plus: return .encryptedKnown
        case .libre2Gen2, .libre2PlusGen2, .libre3, .libre3Plus: return .none
        case .unknown: return .unknown
        }
    }

    /// True for Gen2-security Libre 2 sensors, whose memory and Bluetooth are locked to Abbott's apps.
    public var isGen2: Bool { family == .libre2Gen2 || family == .libre2PlusGen2 }

    /// Days of wear, where known.
    public var lifetimeDays: Int? {
        switch family {
        case .libre1, .libre1US, .librePro, .libre2, .libre2Gen2, .libre3: return 14
        case .libre2Plus, .libre2PlusGen2, .libre3Plus: return 15
        case .unknown: return nil
        }
    }

    // Known 6-byte headers (from DiaBLE):
    //   Libre 2+ EU: C6 09 31 01 / 7F 0E 31 01    Libre 2 EU: 7F 0E 30 01
    //   Libre 2+ US: 2C 0A 3A 02                  Libre 2+ LatAm: 2B 0A 3A 08
    //   Libre 2 RU (Gen2): 2B 0A 39 08            Libre 2+ AU (Gen2): 7F 0E 3A 04
    static func family(for b: [UInt8]) -> Family {
        if b.count == 24 {
            // Libre 3 family: byte 12 is the product type (4 = Libre 3, 9 = Lingo), bytes 4–5 the
            // generation (1 = Plus), and byte 3 0xC0 marks the French Libre Select.
            guard b[12] == 4, b[3] != 0xC0 else { return .unknown }
            let generation = Int(b[4]) | Int(b[5]) << 8
            return generation == 1 ? .libre3Plus : .libre3
        }
        guard b.count == 6 else { return .unknown }
        let revision = b[2] & 0x0F
        switch b[0] {
        case 0xDF, 0xA2: return .libre1
        case 0xE5, 0xE6: return .libre1US
        case 0x70: return .librePro
        case 0x9D, 0xC5: return .libre2
        case 0xC6: return .libre2Plus
        // DiaBLE's rule: in a Libre 2 header the low nibble of byte 2 is the security revision, and 9
        // or more means Gen2 security (US 2C 0A 3A 02 is Gen2). A 7F 0E 3A 04 Libre 2 Plus from
        // Australia drops the NFC connection on the first memory read, as a Gen2 sensor does.
        case 0x7F: return revision >= 9 ? .libre2PlusGen2 : revision > 0 ? .libre2Plus : .libre2
        case 0x2C: return .libre2PlusGen2
        case 0x2B: return revision > 9 ? .libre2PlusGen2 : .libre2Gen2
        case 0x76: return .libre2Gen2
        default: return .unknown
        }
    }

    static func region(for b: [UInt8]) -> Region {
        let code: UInt8
        switch b.count {
        case 6: code = b[3]
        case 24: code = b[2]
        default: return .unknown
        }
        switch code {
        case 0x01: return .europe
        case 0x02: return .usa
        case 0x04: return .australiaCanada
        case 0x08: return .restOfWorld
        default: return .unknown
        }
    }

    /// The serial printed on the sensor box (e.g. "3MH005ABCDE"), from the tag's 8-byte NFC
    /// identifier in the most-significant-byte-first order iOS gives it (starting E0 07).
    /// Libre 3 sensors carry the serial as text in bytes 15–23 of their header instead.
    public static func serialNumber(identifier: [UInt8], patchInfo: LibrePatchInfo) -> String? {
        if patchInfo.raw.count == 24 {
            return String(bytes: patchInfo.raw[15...23], encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        }
        guard identifier.count == 8 else { return nil }
        let b = Array(identifier.suffix(6))
        let table = Array("0123456789ACDEFGHJKLMNPQRTUVWXYZ")
        let groups: [UInt8] = [
            b[0] >> 3,
            (b[0] << 2) | (b[1] >> 6),
            b[1] >> 1,
            (b[1] << 4) | (b[2] >> 4),
            (b[2] << 1) | (b[3] >> 7),
            b[3] >> 2,
            (b[3] << 3) | (b[4] >> 5),
            b[4],
            b[5] >> 3,
            b[5] << 2,
        ]
        // The leading digit is the sensor family code from the patch info (0 for Libre 1, 3 for Libre 2).
        let familyDigit = patchInfo.raw.count >= 3 ? Int(patchInfo.raw[2] >> 4) : 0
        return groups.reduce(String(familyDigit)) { $0 + String(table[Int($1 & 0x1F)]) }
    }
}
