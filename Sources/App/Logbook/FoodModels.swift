import Foundation

// Foods in the logbook: what a meal was made of, and the foods the user saved. The food list
// itself and its search are in Sources/Food (apps only); these plain models go wherever the
// logbook does.

enum FoodSource: String, Codable, Hashable {
    case ausnut, openFoodFacts, custom

    var title: String {
        switch self {
        case .ausnut: return "AUSNUT 2023"
        case .openFoodFacts: return "Open Food Facts"
        case .custom: return "My food"
        }
    }
}

/// A household measure and what it weighs.
struct FoodPortion: Codable, Hashable {
    /// "slice, thick", "cup (250 ml)".
    var name: String
    var grams: Double
}

/// One food from any source.
struct FoodItem: Codable, Hashable, Identifiable {
    /// "ausnut:F000262", "off:9300633603379", "custom:<uuid>".
    var id: String
    var name: String
    var brand: String = ""
    /// Grams of available carbohydrate in 100 g.
    var carbsPer100g: Double
    var portions: [FoodPortion] = []
    var source: FoodSource
    /// A food the user only knows per serve: it can't be weighed, and its one portion stands for a
    /// serve rather than a real weight. Nil (not false) in older records.
    var servingOnly: Bool? = nil

    func carbs(grams: Double) -> Double { max(0, carbsPer100g * grams / 100) }

    var isServingOnly: Bool { servingOnly == true }

    /// The user's own food. With a weight it behaves like any other food; without one it can only be
    /// counted in serves (its serve is stored as a nominal 100 g so the per-serve carbs are exact).
    static func custom(name: String, carbsPerServe: Double, serveName: String, serveGrams: Double?) -> FoodItem {
        let label = serveName.trimmingCharacters(in: .whitespacesAndNewlines)
        let grams = serveGrams ?? 100
        return FoodItem(id: "custom:\(UUID().uuidString)", name: name, carbsPer100g: carbsPerServe / grams * 100,
                        portions: [FoodPortion(name: label.isEmpty ? "serve" : label, grams: grams)], source: .custom,
                        servingOnly: serveGrams == nil ? true : nil)
    }

    var displayName: String { brand.isEmpty ? name : "\(name) · \(brand)" }
}

/// One food in a logged meal: how much, and the carbs that came to.
struct MealItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var foodID: String
    var name: String
    /// Total weight eaten.
    var grams: Double
    var carbs: Double
    /// What the user picked: "2 × slice, thick", or nil when they entered grams.
    var portion: String?
    var carbsPer100g: Double
    var source: FoodSource

    init(food: FoodItem, grams: Double, portion: String?) {
        foodID = food.id
        name = food.displayName
        self.grams = grams
        carbs = (food.carbs(grams: grams) * 10).rounded() / 10
        self.portion = portion
        carbsPer100g = food.carbsPer100g
        source = food.source
    }

    /// "2 × slice, thick · 26 g carbs".
    var summary: String {
        let amount = portion ?? "\(LogFormat.number(grams.rounded())) g"
        return "\(amount) · \(LogFormat.grams(carbs)) carbs"
    }

    /// Enough to pick the same food again from Recents.
    var food: FoodItem {
        FoodItem(id: foodID, name: name, carbsPer100g: carbsPer100g, portions: [], source: source)
    }
}

/// A food the user saved: a favourite, or one they made. Synced as a logbook record.
struct SavedFood: Codable, Hashable, Identifiable {
    var id = UUID()
    var food: FoodItem
    var favourite: Bool
    /// The portion they last used, to start from next time.
    var lastGrams: Double?
    var lastPortion: String?
    var modified: Date = Date()

    /// The record id for saving `food`, the same on every device, so the same food starred on the
    /// Mac and the iPhone syncs as one record rather than two.
    static func stableID(for food: FoodItem) -> UUID {
        // Two FNV-1a passes with different seeds give 128 bits; marked as a name-based (v5-style) UUID.
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in food.id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, h) in [fnv(0xcbf29ce484222325), fnv(0x84222325cbf29ce4)].enumerated() {
            for j in 0..<8 { bytes[i * 8 + j] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(j))) }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
