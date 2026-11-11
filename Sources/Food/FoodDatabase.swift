import Foundation

// Foods to pick from when logging a meal, with their carbohydrate per 100 g and household
// measures ("1 slice", "1 cup (250 ml)").
//
// - Built in: AUSNUT 2023, © Food Standards Australia New Zealand, licensed CC BY 4.0. Bundled as
//   `ausnut-foods.json`, made by scripts/food/build_ausnut.py (see .github/workflows/food-data.yml).
//   Carbs are available carbohydrate without sugar alcohols, which is what carb counting uses.
// - Packaged products: searched online in Open Food Facts (ODbL), when the user asks.
// - The user's own foods and favourites, synced with the logbook (`SavedFood`).
//
// Plain Foundation so `swift test` covers it.

// MARK: - Database

struct FoodDatabase {
    let foods: [FoodItem]
    let attribution: String
    private let index: [[String]]

    static let empty = FoodDatabase(foods: [], attribution: "")

    init(foods: [FoodItem], attribution: String) {
        self.foods = foods
        self.attribution = attribution
        index = foods.map { Self.words($0.name + " " + $0.brand) }
    }

    /// Reads the bundled file's format: `{"attribution": …, "foods": [[key, name, carbs, [[measure, grams]…]]…]}`.
    init(json data: Data) throws {
        struct File: Decodable {
            let attribution: String
            let foods: [Row]
        }
        struct Row: Decodable {
            let key: String, name: String, carbs: Double, measures: [FoodPortion]
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                key = try c.decode(String.self)
                name = try c.decode(String.self)
                carbs = try c.decode(Double.self)
                var m = try c.nestedUnkeyedContainer()
                var out: [FoodPortion] = []
                while !m.isAtEnd {
                    var pair = try m.nestedUnkeyedContainer()
                    out.append(FoodPortion(name: try pair.decode(String.self), grams: try pair.decode(Double.self)))
                }
                measures = out
            }
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        let foods = file.foods.compactMap { r -> FoodItem? in
            guard r.carbs.isFinite, (0...100).contains(r.carbs) else { return nil }
            return FoodItem(id: "ausnut:\(r.key)", name: r.name, carbsPer100g: r.carbs,
                            portions: r.measures.filter { $0.grams > 0 && $0.grams < 5000 }, source: .ausnut)
        }
        self.init(foods: foods, attribution: file.attribution)
    }

    /// The bundled AUSNUT list, loaded once.
    static let bundled: FoodDatabase = {
        guard let url = Bundle.main.url(forResource: "ausnut-foods", withExtension: "json"),
              let data = try? Data(contentsOf: url), let db = try? FoodDatabase(json: data) else { return .empty }
        return db
    }()

    func food(id: String) -> FoodItem? { foods.first { $0.id == id } }

    /// Foods whose name has a word starting with every word typed, best matches first.
    func search(_ query: String, limit: Int = 40) -> [FoodItem] {
        let terms = Self.words(query)
        guard !terms.isEmpty else { return [] }
        var scored: [(Double, Int)] = []
        for (i, words) in index.enumerated() {
            if let s = Self.score(terms: terms, words: words, name: foods[i].name) { scored.append((s, i)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : foods[$0.1].name.count < foods[$1.1].name.count }
        return scored.prefix(limit).map { foods[$0.1] }
    }

    static func score(terms: [String], words: [String], name: String) -> Double? {
        var total = 0.0
        for (n, t) in terms.enumerated() {
            let singular = t.count > 3 && t.hasSuffix("s") ? String(t.dropLast()) : t
            var best = 0.0
            for (position, w) in words.enumerated() {
                var s = 0.0
                if w == t || w == singular { s = 3 } else if w.hasPrefix(t) || w.hasPrefix(singular) { s = 2 } else { continue }
                // Words early in the name ("Banana, …") say what the food is.
                if position == 0 { s += n == 0 ? 3 : 1 } else if position < 3 { s += 0.5 }
                best = max(best, s)
            }
            if best == 0 { return nil }
            total += best
        }
        // Prefer plain, everyday entries over long qualified ones.
        total -= Double(words.count) * 0.08
        let lower = name.lowercased()
        if lower.contains("not further defined") { total += 0.4 }
        if lower.contains("raw") || lower.contains("cooked") || lower.contains("boiled") { total += 0.1 }
        return total
    }

    /// Lowercased words without accents or punctuation.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_AU"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Portions

enum FoodPortionMath {
    /// What `quantity` of `portion` weighs, or `grams` when no portion is picked.
    static func grams(quantity: Double, portion: FoodPortion?, grams: Double?) -> Double? {
        if let portion {
            guard quantity.isFinite, quantity > 0, quantity <= 50 else { return nil }
            return quantity * portion.grams
        }
        guard let grams, grams.isFinite, grams > 0, grams <= 5000 else { return nil }
        return grams
    }

    /// "2 × slice, thick", "½ × cup (250 ml)".
    static func label(quantity: Double, portion: FoodPortion) -> String {
        let q: String
        switch quantity {
        case 0.25: q = "¼"
        case 0.5: q = "½"
        case 0.75: q = "¾"
        default: q = LogFormat.number(quantity)
        }
        return "\(q) × \(portion.name)"
    }
}

// MARK: - Recents

extension Array where Element == MealEntry {
    /// Foods picked from the database in past meals, most recent first, one per food.
    func recentFoodItems(limit: Int = 12) -> [MealItem] {
        var seen = Set<String>()
        var out: [MealItem] = []
        for m in self.sorted(by: { $0.timestamp > $1.timestamp }) {
            for item in m.items ?? [] where !seen.contains(item.foodID) {
                seen.insert(item.foodID)
                out.append(item)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

// MARK: - Open Food Facts

/// Reads Open Food Facts search results. Data © Open Food Facts contributors, ODbL.
enum OpenFoodFacts {
    static let attribution = "Packaged foods from Open Food Facts (openfoodfacts.org), ODbL. Community data: check the label."

    /// The search URL, limited to products sold in Australia when `australia` is set.
    static func searchURL(_ query: String, australia: Bool = true) -> URL? {
        var c = URLComponents(string: australia ? "https://au.openfoodfacts.org/cgi/search.pl" : "https://world.openfoodfacts.org/cgi/search.pl")
        c?.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "25"),
            URLQueryItem(name: "fields", value: "code,product_name,product_name_en,brands,nutriments,serving_size,serving_quantity"),
        ]
        return c?.url
    }

    static func parse(_ data: Data) -> [FoodItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { return [] }
        return products.compactMap { p in
            guard let code = p["code"] as? String, !code.isEmpty,
                  let nutriments = p["nutriments"] as? [String: Any],
                  let carbs = number(nutriments["carbohydrates_100g"]), carbs.isFinite, (0...100).contains(carbs) else { return nil }
            let name = ((p["product_name_en"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? p["product_name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let brand = (p["brands"] as? String ?? "").split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            var portions: [FoodPortion] = []
            if let serving = number(p["serving_quantity"]), serving > 0, serving < 5000 {
                let label = (p["serving_size"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(LogFormat.number(serving)) g"
                portions.append(FoodPortion(name: "serve, \(label)", grams: serving))
            }
            return FoodItem(id: "off:\(code)", name: name, brand: brand, carbsPer100g: (carbs * 10).rounded() / 10,
                            portions: portions, source: .openFoodFacts)
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
