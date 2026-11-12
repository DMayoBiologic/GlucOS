import XCTest
@testable import GlucOSEngine

final class LibrePatchInfoTests: XCTestCase {
    func testKnownFamilies() {
        XCTAssertEqual(LibrePatchInfo(raw: [0xDF, 0x00, 0x00, 0x01, 0x00, 0x00]).family, .libre1)
        XCTAssertEqual(LibrePatchInfo(raw: [0x9D, 0x08, 0x30, 0x01, 0x76, 0x25]).family, .libre2)
        XCTAssertEqual(LibrePatchInfo(raw: [0xC6, 0x09, 0x31, 0x04, 0x00, 0x00]).family, .libre2Plus)
        XCTAssertEqual(LibrePatchInfo(raw: [0x7F, 0x0E, 0x31, 0x01, 0x00, 0x00]).family, .libre2Plus)
        XCTAssertEqual(LibrePatchInfo(raw: [0x7F, 0x0E, 0x30, 0x01, 0x00, 0x00]).family, .libre2)
        let au = LibrePatchInfo(raw: [0x7F, 0x0E, 0x3A, 0x04, 0x6F, 0x0E])
        XCTAssertEqual(au.family, .libre2PlusGen2)
        XCTAssertTrue(au.isGen2)
        XCTAssertEqual(au.directAccess, .none)
        XCTAssertEqual(au.lifetimeDays, 15)
        XCTAssertEqual(LibrePatchInfo(raw: [0x2C, 0x0A, 0x3A, 0x02, 0x00, 0x00]).family, .libre2PlusGen2)
        XCTAssertEqual(LibrePatchInfo(raw: [0x2B, 0x0A, 0x3A, 0x08, 0x00, 0x00]).family, .libre2PlusGen2)
        XCTAssertEqual(LibrePatchInfo(raw: [0x2B, 0x0A, 0x39, 0x08, 0x00, 0x00]).family, .libre2Gen2)
        XCTAssertEqual(LibrePatchInfo(raw: [0x76, 0x00, 0x00, 0x02, 0x00, 0x00]).family, .libre2Gen2)
        XCTAssertEqual(LibrePatchInfo(raw: libre3(product: 4, generation: 0)).family, .libre3)
        XCTAssertEqual(LibrePatchInfo(raw: libre3(product: 4, generation: 1)).family, .libre3Plus)
        XCTAssertEqual(LibrePatchInfo(raw: libre3(product: 9, generation: 0)).family, .unknown) // Lingo
        XCTAssertEqual(LibrePatchInfo(raw: Array(repeating: 0, count: 12)).family, .unknown)
        XCTAssertEqual(LibrePatchInfo(raw: [0x11, 0, 0, 0, 0, 0]).family, .unknown)
        XCTAssertEqual(LibrePatchInfo(raw: []).family, .unknown)
    }

    func testRegionAndAccess() {
        let p = LibrePatchInfo(raw: [0xC6, 0x09, 0x31, 0x04, 0x00, 0x00])
        XCTAssertEqual(p.region, .australiaCanada)
        XCTAssertEqual(p.directAccess, .encryptedKnown)
        XCTAssertEqual(p.lifetimeDays, 15)
        XCTAssertEqual(p.hex, "C6 09 31 04 00 00")
        XCTAssertEqual(LibrePatchInfo(raw: [0x2C, 0x0A, 0x3A, 0x02, 0x00, 0x00]).directAccess, .none)
        let l3 = LibrePatchInfo(raw: libre3(product: 4, generation: 0))
        XCTAssertEqual(l3.directAccess, .none)
        XCTAssertEqual(l3.region, .australiaCanada)
        XCTAssertEqual(LibrePatchInfo.serialNumber(identifier: [], patchInfo: l3), "0D0012345")
    }

    /// A 24-byte Libre 3 style header: region 4 at byte 2, generation at 4–5, product at 12,
    /// serial text at 15–23.
    private func libre3(product: UInt8, generation: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 24)
        b[2] = 0x04
        b[4] = generation
        b[12] = product
        b.replaceSubrange(15...23, with: Array("0D0012345".utf8))
        return b
    }

    func testStripsLeadingResponseFlag() {
        let p = LibrePatchInfo(raw: [0x00, 0x9D, 0x08, 0x30, 0x01, 0x76, 0x25])
        XCTAssertEqual(p.raw.count, 6)
        XCTAssertEqual(p.family, .libre2)
        XCTAssertEqual(p.region, .europe)
    }

    func testSerialNumber() {
        let p = LibrePatchInfo(raw: [0x9D, 0x08, 0x30, 0x01, 0x76, 0x25])
        // All-zero ID bytes map to the first table character in every slot.
        XCTAssertEqual(LibrePatchInfo.serialNumber(identifier: [0xE0, 0x07, 0, 0, 0, 0, 0, 0], patchInfo: p),
                       "30000000000")
        let serial = LibrePatchInfo.serialNumber(identifier: [0xE0, 0x07, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6], patchInfo: p)
        XCTAssertEqual(serial?.count, 11)
        XCTAssertEqual(serial?.first, "3")
        XCTAssertNil(LibrePatchInfo.serialNumber(identifier: [1, 2, 3], patchInfo: p))
    }
}
