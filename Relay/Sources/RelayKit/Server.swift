import Foundation
import Hummingbird
import AsyncHTTPClient
import NIOCore

extension RelayStatus: ResponseEncodable {}

public enum Relay {
    /// Starts the poll loop and the HTTP API, and runs until the process is stopped.
    public static func run(config: RelayConfig) async throws {
        var sender: PushSending?
        if config.canPush, let pem = config.apnsKeyPEM, let keyID = config.apnsKeyID, let team = config.teamID {
            sender = APNsSender(signer: try APNsTokenSigner(pem: pem, keyID: keyID, teamID: team))
        } else {
            print("glucos-relay: APNS_KEY_P8, APNS_KEY_ID or APPLE_TEAM_ID missing; fetching but not pushing.")
        }
        let engine = RelayEngine(config: config, sender: sender, fetcher: LibreLinkUpFetcher(),
                                 store: StateStore(directory: config.dataDirectory))
        let loop = Task { await engine.run() }
        defer { loop.cancel() }

        let app = Application(router: makeRouter(engine: engine, secret: config.secret),
                              configuration: .init(address: .hostname("0.0.0.0", port: config.port),
                                                   serverName: "glucos-relay"))
        print("glucos-relay \(RelayEngine.version) listening on :\(config.port)")
        try await app.runService()
    }

    static func makeRouter(engine: RelayEngine, secret: String) -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/health") { _, _ in "ok" }

        let api = router.group("v1")
        api.add(middleware: BearerAuth(secret: secret))
        api.get("status") { _, _ in await engine.status() }
        api.post("register") { request, context in
            let reg = try await request.decode(as: RelayRegistration.self, context: context)
            return await engine.register(reg)
        }
        api.post("test") { _, _ in await engine.sendTest() }
        return router
    }
}

/// Every API call needs `Authorization: Bearer <RELAY_SECRET>`.
struct BearerAuth<Context: RequestContext>: RouterMiddleware {
    let secret: String

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let given = request.headers[.authorization] ?? ""
        guard Self.constantTimeEqual(given, "Bearer \(secret)") else {
            throw HTTPError(.unauthorized, message: "Wrong or missing relay secret")
        }
        return try await next(request, context)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
