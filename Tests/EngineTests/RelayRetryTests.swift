import XCTest
@testable import GlucOSEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RelayRetryTests: XCTestCase {
    struct Gateway: RetryableError { let code: Int; var isTransient: Bool { Self.isGatewayHiccup(code) } }
    struct Refused: Error {}

    final class Calls: @unchecked Sendable { var count = 0; var slept: [TimeInterval] = [] }

    func testATimeoutIsRetriedAndTheRetryAnswers() async throws {
        let calls = Calls()
        let value = try await RelayRetry.run(sleep: { calls.slept.append($0) }) { () async throws -> Int in
            calls.count += 1
            if calls.count == 1 { throw URLError(.timedOut) }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.slept, [1])
    }

    func testGivesUpAfterThreeTries() async {
        let calls = Calls()
        do {
            _ = try await RelayRetry.run(sleep: { calls.slept.append($0) }) { () async throws -> Int in
                calls.count += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.slept, [1, 3])
    }

    func testDoesNotRetryWhatWontPass() async {
        for error: Error in [Refused(), Gateway(code: 401), Gateway(code: 500), URLError(.cancelled), URLError(.badURL)] {
            let calls = Calls()
            _ = try? await RelayRetry.run(sleep: { _ in }) { () async throws -> Int in
                calls.count += 1
                throw error
            }
            XCTAssertEqual(calls.count, 1, "\(error)")
        }
        XCTAssertTrue(RelayRetry.isTransient(Gateway(code: 503)))
        XCTAssertTrue(RelayRetry.isTransient(URLError(.cannotFindHost)))
    }

    func testOneDroppedCallDoesNotShowTheBanner() {
        var health = RelayHealth()
        XCTAssertTrue(health.failed(URLError(.timedOut), message: "timed out"))
        XCTAssertNil(health.visibleError)
        health.succeeded()
        XCTAssertTrue(health.failed(URLError(.timedOut), message: "timed out"))
        XCTAssertNil(health.visibleError, "a success in between starts the count again")
        health.failed(URLError(.timedOut), message: "timed out")
        XCTAssertEqual(health.visibleError, "timed out", "unreachable twice in a row is worth saying")
        health.succeeded()
        XCTAssertNil(health.visibleError)
    }

    func testAWrongSecretShowsAtOnce() {
        var health = RelayHealth()
        XCTAssertFalse(health.failed(Refused(), message: "The relay didn't accept the secret."))
        XCTAssertEqual(health.visibleError, "The relay didn't accept the secret.")
    }
}
