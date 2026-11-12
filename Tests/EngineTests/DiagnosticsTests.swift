import XCTest
@testable import GlucOSEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DiagnosticsTests: XCTestCase {
    /// Captures what the reporter posts.
    final class Server: @unchecked Sendable {
        var status = 200
        var batches: [DiagnosticBatch] = []
        let lock = NSLock()

        func handle(_ req: URLRequest) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            if let body = req.httpBody { batches.append(try JSONDecoder().decode(DiagnosticBatch.self, from: body)) }
            return status
        }
        var events: [DiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return batches.flatMap(\.events) }
    }

    private func make(_ server: Server, now: @escaping () -> Date = Date.init, queue: URL? = nil) -> (Diagnostics, UserDefaults) {
        let suite = "diagnostics-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let r = Diagnostics(defaults: d, queueURL: queue, clock: now, transport: { try server.handle($0) })
        return (r, d)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testScrubsEmailsAndClipsFields() {
        let e = DiagnosticEvent(feature: "linkup.fetch", step: "fetch", code: "HTTP 500",
                                message: "Login for declan@example.com.au failed", detail: String(repeating: "x", count: 5000),
                                context: ["account": "a.b@c.io"]).scrubbed()
        XCTAssertEqual(e.message, "Login for <email> failed")
        XCTAssertEqual(e.detail?.count, 2000)
        XCTAssertEqual(e.context["account"], "<email>")
    }

    func testErrorCodes() {
        XCTAssertEqual(DiagnosticEvent.code(for: URLError(.timedOut)), "URLError -1001")
        XCTAssertTrue(DiagnosticEvent.isNoise(URLError(.notConnectedToInternet)))
        XCTAssertTrue(DiagnosticEvent.isNoise(CancellationError()))
        XCTAssertFalse(DiagnosticEvent.isNoise(URLError(.timedOut)))
        XCTAssertEqual(DiagnosticEvent.code(for: NSError(domain: "NFCError", code: 100)), "NFCError 100")
    }

    func testSendsOnceAnHourAndCountsRepeats() async {
        let server = Server()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let (r, _) = make(server, now: { now })
        let e = DiagnosticEvent(feature: "sensor.nfc", step: "read-memory", code: "NFC 100", message: "cut short")
        r.report(e)
        await settle()
        r.report(e)
        r.report(e)
        await settle()
        XCTAssertEqual(server.events.count, 1)
        now += 3601
        r.report(e)
        await settle()
        XCTAssertEqual(server.events.count, 2)
        XCTAssertEqual(server.events.last?.repeats, 2)
        XCTAssertEqual(server.batches.first?.device.installID, server.batches.last?.device.installID)
        XCTAssertTrue(r.pending.isEmpty)
    }

    func testOptOutStopsAutomaticReportsButNotSendReport() async {
        let server = Server()
        let (r, _) = make(server)
        r.isEnabled = false
        let e = DiagnosticEvent(feature: "relay", step: "status", code: "HTTP 500", message: "boom")
        r.report(e)
        await settle()
        XCTAssertTrue(server.events.isEmpty)
        // Still remembered for the Send Report button.
        XCTAssertEqual(r.latest(feature: "relay")?.code, "HTTP 500")
        let ok = await r.send(e, note: "  tapped refresh  ")
        XCTAssertTrue(ok)
        XCTAssertEqual(server.events.count, 1)
        XCTAssertEqual(server.events[0].userSent, true)
        XCTAssertEqual(server.events[0].note, "tapped refresh")
    }

    func testKeepsReportsWhileOfflineAndRetries() async throws {
        let server = Server()
        server.status = 503
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let (r, _) = make(server, queue: url)
        let ok = await r.send(DiagnosticEvent(feature: "sensor.nfc", step: "scan", code: nil, message: "x"), note: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(r.pending.count, 1)
        // A fresh reporter (next launch) picks the queue up from disk.
        server.status = 200
        let again = Diagnostics(defaults: UserDefaults(suiteName: "diag-\(UUID().uuidString)")!, queueURL: url,
                                transport: { try server.handle($0) })
        XCTAssertEqual(again.pending.count, 1)
        await again.flush()
        XCTAssertTrue(again.pending.isEmpty)
        XCTAssertEqual(server.events.count, 2)
    }

    func testBatchShape() throws {
        let b = DiagnosticBatch(device: .current(installID: "abc"), events: [
            DiagnosticEvent(feature: "f", step: "s", code: "c", message: "m"),
        ])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        let device = json["device"] as! [String: Any]
        XCTAssertEqual(Set(device.keys), ["installID", "platform", "app", "appVersion", "build", "osVersion", "model"])
        let event = (json["events"] as! [[String: Any]])[0]
        XCTAssertNotNil(event["occurredAt"] as? Double)
        XCTAssertEqual(event["userSent"] as? Bool, false)
        XCTAssertFalse((device["model"] as! String).isEmpty)
    }
}
