import XCTest
@testable import GlucOSEngine

final class LibrePatchInfoTests: XCTestCase {
    func testKnownFamilies() {
        XCTAssertEqual(LibrePatchInfo(raw: [0xDF, 0x00, 0x00, 0x01, 0x00, 0x00]).family, .libre1)
        XCTAssertEqual(LibrePatchInfo(raw: [0x9D, 0x08, 0x30, 0x01, 0x76, 0x25]).family, .libre2)
        XCTAssertEqual(LibrePatchInfo(raw: [0xC6, 0x09, 0x31, 0x04, 0x00, 0x00]).family, .libre2Plus)
        XCTAssertEqual(LibrePatchInfo(raw: [0x76, 0x00, 0x00, 0x02, 0x00, 0x00]).family, .libre2US)
        XCTAssertEqual(LibrePatchInfo(raw: Array(repeating: 0, count: 24)).family, .libre3)
        XCTAssertEqual(LibrePatchInfo(raw: [0x11, 0, 0, 0, 0, 0]).family, .unknown)
        XCTAssertEqual(LibrePatchInfo(raw: []).family, .unknown)
    }

    func testRegionAndAccess() {
        let p = LibrePatchInfo(raw: [0xC6, 0x09, 0x31, 0x04, 0x00, 0x00])
        XCTAssertEqual(p.region, .australiaCanada)
        XCTAssertEqual(p.directAccess, .encryptedKnown)
        XCTAssertEqual(p.lifetimeDays, 15)
        XCTAssertEqual(p.hex, "C6 09 31 04 00 00")
        XCTAssertEqual(LibrePatchInfo(raw: Array(repeating: 0, count: 24)).directAccess, .none)
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
