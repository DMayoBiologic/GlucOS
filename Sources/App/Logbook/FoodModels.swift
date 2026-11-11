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

    func carbs(grams: Double) -> Double { max(0, carbsPer100g * grams / 100) }

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
}
