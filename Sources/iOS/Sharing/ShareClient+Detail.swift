import Foundation

// The follower view's call, kept out of ShareClient.swift because the Messages app builds that file
// without the logbook sync types `ShareDetail` needs.
extension ShareClient {
    /// The follower view's readings since `since` (all 14 days when nil) and recent logbook.
    func detail(since: Double?) async throws -> ShareDetail {
        try await call("v1/detail", method: "GET",
                       query: since.map { [URLQueryItem(name: "since", value: String(Int($0)))] })
    }
}
