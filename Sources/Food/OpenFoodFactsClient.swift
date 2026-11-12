import Foundation

/// Somewhere packaged and branded foods can be looked up online. To search another food list as
/// well, write one of these for it and add it to `FoodSources.online`: the food picker shows its
/// results with the rest.
protocol OnlineFoodSource: Sendable {
    /// Shown with its results, as the list's licence asks.
    var attribution: String { get }
    /// Foods matching what was typed. Send only the words typed, nothing about the user.
    func search(_ query: String) async throws -> [FoodItem]
}

struct OpenFoodFactsSource: OnlineFoodSource {
    var attribution: String { OpenFoodFacts.attribution }
    func search(_ query: String) async throws -> [FoodItem] { try await OpenFoodFactsClient.search(query) }
}

enum FoodSources {
    static let online: [any OnlineFoodSource] = [OpenFoodFactsSource()]

    /// Every online list's matches, one food per id. Fails only when every list failed.
    static func searchOnline(_ query: String) async throws -> [FoodItem] {
        var out: [FoodItem] = []
        var seen = Set<String>()
        var failure: Error?
        var answered = false
        for source in online {
            do {
                for item in try await source.search(query) where seen.insert(item.id).inserted { out.append(item) }
                answered = true
            } catch {
                failure = error
            }
        }
        if !answered, let failure { throw failure }
        return out
    }
}

/// Searches Open Food Facts for packaged products as the user types a search in the food picker.
/// Sends just the words typed; nothing about the user.
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
