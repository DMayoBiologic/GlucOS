import XCTest
@testable import GlucOSEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class FunctionRegionTests: XCTestCase {
    func testTheBuiltInProjectRunsNextToItsDatabase() {
        var req = URLRequest(url: URL(string: "https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/relay/v1/status")!)
        FunctionRegion.pin(&req)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-region"), "ap-south-1")
        XCTAssertEqual(FunctionRegion.region(for: FollowLink.serviceURL), "ap-south-1")
    }

    func testARelayHostedElsewhereIsLeftAlone() {
        var req = URLRequest(url: URL(string: "https://other.supabase.co/functions/v1/relay/v1/status")!)
        FunctionRegion.pin(&req)
        XCTAssertNil(req.value(forHTTPHeaderField: "x-region"))
        XCTAssertNil(FunctionRegion.region(for: nil))
    }
}
