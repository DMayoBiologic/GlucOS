import XCTest
@testable import GlucOSEngine

final class FoodDatabaseTests: XCTestCase {
    static let bundled: FoodDatabase = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Food/ausnut-foods.json")
        return (try? FoodDatabase(json: Data(contentsOf: url))) ?? .empty
    }()

    var db: FoodDatabase { Self.bundled }

    func testBundledListLoads() {
        XCTAssertGreaterThan(db.foods.count, 3000)
        XCTAssertTrue(db.attribution.contains("Food Standards Australia New Zealand"))
        XCTAssertTrue(db.foods.allSatisfy { (0...100).contains($0.carbsPer100g) })
        XCTAssertGreaterThan(db.foods.filter { !$0.portions.isEmpty }.count, 2000)
        XCTAssertTrue(db.foods.allSatisfy { $0.portions.allSatisfy { $0.grams > 0 && !$0.name.isEmpty } })
        XCTAssertEqual(Set(db.foods.map(\.id)).count, db.foods.count, "ids are unique")
    }

    func testSearchFindsEverydayFoods() throws {
        let banana = try XCTUnwrap(db.search("banana").first)
        XCTAssertTrue(banana.name.lowercased().hasPrefix("banana"), banana.name)
        XCTAssertEqual(banana.carbsPer100g, 20, accuracy: 6)
        XCTAssertFalse(banana.portions.isEmpty)

        let bread = db.search("white bread")
        XCTAssertFalse(bread.isEmpty)
        XCTAssertTrue(bread.prefix(5).contains { $0.name.lowercased().contains("bread") })

        XCTAssertFalse(db.search("apples").isEmpty, "plurals match")
        XCTAssertFalse(db.search("MILK").isEmpty, "case doesn't matter")
        XCTAssertTrue(db.search("zzzqqq").isEmpty)
        XCTAssertTrue(db.search("  ").isEmpty)
        XCTAssertLessThanOrEqual(db.search("a", limit: 10).count, 10)
    }

    func testPortionMaths() {
        let food = FoodItem(id: "t:1", name: "Bread", carbsPer100g: 45, portions: [FoodPortion(name: "slice", grams: 30)], source: .custom)
        XCTAssertEqual(food.carbs(grams: 60), 27, accuracy: 1e-9)
        XCTAssertEqual(FoodPortionMath.grams(quantity: 2, portion: food.portions[0], grams: nil), 60)
        XCTAssertEqual(FoodPortionMath.grams(quantity: 0.5, portion: food.portions[0], grams: nil), 15)
        XCTAssertNil(FoodPortionMath.grams(quantity: 0, portion: food.portions[0], grams: nil))
        XCTAssertEqual(FoodPortionMath.grams(quantity: 1, portion: nil, grams: 125), 125)
        XCTAssertNil(FoodPortionMath.grams(quantity: 1, portion: nil, grams: -3))
        XCTAssertEqual(FoodPortionMath.label(quantity: 2, portion: food.portions[0]), "2 × slice")
        XCTAssertEqual(FoodPortionMath.label(quantity: 0.5, portion: food.portions[0]), "½ × slice")
        let item = MealItem(food: food, grams: 60, portion: "2 × slice")
        XCTAssertEqual(item.carbs, 27)
        XCTAssertEqual(item.summary, "2 × slice · 27 g carbs")
    }

    func testRecentFoodItemsFromMeals() {
        let a = FoodItem(id: "t:a", name: "A", carbsPer100g: 10, source: .ausnut)
        let b = FoodItem(id: "t:b", name: "B", carbsPer100g: 20, source: .ausnut)
        let meals = [
            MealEntry(timestamp: Date(timeIntervalSince1970: 100), carbs: 5, items: [MealItem(food: a, grams: 50, portion: nil)]),
            MealEntry(timestamp: Date(timeIntervalSince1970: 200), carbs: 30,
                      items: [MealItem(food: b, grams: 100, portion: nil), MealItem(food: a, grams: 100, portion: nil)]),
            MealEntry(timestamp: Date(timeIntervalSince1970: 300), carbs: 12),
        ]
        XCTAssertEqual(meals.recentFoodItems().map(\.foodID), ["t:b", "t:a"])
        XCTAssertEqual(meals.recentFoodItems().last?.grams, 100, "the latest use of each food")
    }

    func testMealsWithoutItemsStillDecode() throws {
        let old = #"{"id":"6F1A2B6E-3C3D-4A54-9A7B-0A0B0C0D0E0F","timestamp":1790000000,"carbs":45,"food":"Toast","note":""}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let m = try d.decode(MealEntry.self, from: Data(old.utf8))
        XCTAssertNil(m.items)
        XCTAssertEqual(m.carbs, 45)
        let dose = #"{"id":"6F1A2B6E-3C3D-4A54-9A7B-0A0B0C0D0E0F","timestamp":1790000000,"units":4,"kind":"rapid","name":"","viaPump":false,"note":""}"#
        XCTAssertNil(try d.decode(InsulinDose.self, from: Data(dose.utf8)).calculation)
    }

    func testOpenFoodFactsResults() throws {
        let json = #"""
        {"count":3,"products":[
          {"code":"9300633603379","product_name":"Wholemeal Bread","brands":"Tip Top, George Weston",
           "nutriments":{"carbohydrates_100g":38.5},"serving_size":"2 slices (76 g)","serving_quantity":76},
          {"code":"1","product_name":"","nutriments":{"carbohydrates_100g":10}},
          {"code":"2","product_name":"Mystery","nutriments":{}},
          {"code":"3","product_name":"Juice","nutriments":{"carbohydrates_100g":"10,5"}}
        ]}
        """#
        let items = try OpenFoodFacts.parse(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["off:9300633603379", "off:3"])
        XCTAssertEqual(items[0].brand, "Tip Top")
        XCTAssertEqual(items[0].carbsPer100g, 38.5)
        XCTAssertEqual(items[0].portions.first?.grams, 76)
        XCTAssertEqual(items[1].carbsPer100g, 10.5)
        XCTAssertThrowsError(try OpenFoodFacts.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try OpenFoodFacts.parse(Data(#"{"error":"busy"}"#.utf8)))
        XCTAssertEqual(try OpenFoodFacts.parse(Data(#"{"count":0,"products":[]}"#.utf8)), [])
        let url = OpenFoodFacts.searchURL("weet bix")?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("https://au.openfoodfacts.org/"))
        XCTAssertTrue(url.contains("weet%20bix"))
    }

    func testCustomFoodWithoutAWeightIsCountedInServes() {
        let pie = FoodItem.custom(name: "Pie", carbsPerServe: 32, serveName: " slice ", serveGrams: nil)
        XCTAssertTrue(pie.isServingOnly)
        XCTAssertEqual(pie.portions.first?.name, "slice")
        XCTAssertEqual(pie.carbs(grams: pie.portions[0].grams), 32, accuracy: 0.001)
        let weighed = FoodItem.custom(name: "Pie", carbsPerServe: 32, serveName: "", serveGrams: 160)
        XCTAssertFalse(weighed.isServingOnly)
        XCTAssertEqual(weighed.carbsPer100g, 20, accuracy: 0.001)
        XCTAssertEqual(weighed.portions.first?.name, "serve")
    }

    func testOldFoodRecordsDecodeWithoutServingOnly() throws {
        let json = #"{"id":"ausnut:F1","name":"Banana","brand":"","carbsPer100g":20,"portions":[],"source":"ausnut"}"#
        let food = try JSONDecoder().decode(FoodItem.self, from: Data(json.utf8))
        XCTAssertFalse(food.isServingOnly)
    }

    func testSavedFoodIDIsTheSameOnEveryDevice() {
        let banana = FoodItem(id: "ausnut:F1", name: "Banana", carbsPer100g: 20, source: .ausnut)
        let apple = FoodItem(id: "ausnut:F2", name: "Apple", carbsPer100g: 12, source: .ausnut)
        XCTAssertEqual(SavedFood.stableID(for: banana), SavedFood.stableID(for: banana))
        XCTAssertNotEqual(SavedFood.stableID(for: banana), SavedFood.stableID(for: apple))
        XCTAssertEqual(SavedFood.stableID(for: banana).uuidString.dropFirst(14).first, "5")
    }
}
