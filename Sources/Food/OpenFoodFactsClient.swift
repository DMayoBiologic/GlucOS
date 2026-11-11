import Foundation

/// Searches Open Food Facts for packaged products, only when the user asks. Sends just the words
/// typed; nothing about the user.
enum OpenFoodFactsClient {
    static func search(_ query: String) async throws -> [FoodItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var items = try await fetch(OpenFoodFacts.searchURL(q, australia: true))
        if items.isEmpty { items = try await fetch(OpenFoodFacts.searchURL(q, australia: false)) }
        return items
    }

    private static func fetch(_ url: URL?) async throws -> [FoodItem] {
        guard let url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        // Open Food Facts asks apps to name themselves.
        request.setValue("GlucOS/\(version) (diabetes logbook)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try OpenFoodFacts.parse(data)
    }
}
