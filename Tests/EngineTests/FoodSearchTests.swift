import XCTest
@testable import GlucOSEngine

/// Searching and describing food the way people say it.
final class FoodSearchTests: XCTestCase {
    var db: FoodDatabase { FoodDatabaseTests.bundled }

    private func first(_ query: String) -> String { db.search(query).first?.name.lowercased() ?? "" }

    func testEverydayAndOverseasNamesFindTheFood() {
        XCTAssertTrue(first("fries").hasPrefix("potato, chips"), first("fries"))
        XCTAssertTrue(first("hot chips").hasPrefix("potato, chips"), first("hot chips"))
        XCTAssertTrue(first("coke").contains("cola"), first("coke"))
        XCTAssertTrue(first("oatmeal").hasPrefix("porridge"), first("oatmeal"))
        XCTAssertTrue(first("weetbix").contains("whole wheat, biscuit"), first("weetbix"))
        XCTAssertTrue(first("flat white").hasPrefix("coffee"), first("flat white"))
        XCTAssertTrue(first("yogurt").hasPrefix("yoghurt"), first("yogurt"))
        XCTAssertTrue(first("icecream").hasPrefix("ice cream"), first("icecream"))
        XCTAssertTrue(first("spaghetti bolognese").contains("bolognese"), first("spaghetti bolognese"))
        XCTAssertTrue(first("ketchup").contains("tomato"), first("ketchup"))
    }

    func testPlainSearchesStartOnTheEverydayFood() {
        XCTAssertEqual(first("rice"), "rice, white, cooked")
        XCTAssertTrue(first("egg").hasPrefix("egg, chicken"), first("egg"))
        XCTAssertTrue(first("eggs").hasPrefix("egg, chicken"), first("eggs"))
        XCTAssertTrue(first("toast").hasPrefix("bread, white") && first("toast").contains("toasted"), first("toast"))
        XCTAssertTrue(first("milk").hasPrefix("milk, cow"), first("milk"))
        XCTAssertTrue(first("banana").hasPrefix("banana, cavendish"), first("banana"))
        XCTAssertFalse(first("pasta").contains("uncooked"), first("pasta"))
        // Asking for the unusual one still finds it.
        XCTAssertTrue(first("duck egg").contains("duck"), first("duck egg"))
        XCTAssertTrue(first("rice uncooked").contains("uncooked"), first("rice uncooked"))
    }

    func testTyposAndFillerWordsStillMatch() {
        XCTAssertTrue(first("bannana").hasPrefix("banana"), first("bannana"))
        XCTAssertTrue(first("brocoli").hasPrefix("broccoli"), first("brocoli"))
        XCTAssertTrue(first("tomatoe sauce").contains("tomato"), first("tomatoe sauce"))
        XCTAssertTrue(first("strawberries").hasPrefix("strawberry"), first("strawberries"))
        XCTAssertEqual(FoodSearch.terms("a bowl of the rice"), ["bowl", "rice"])
        XCTAssertEqual(FoodSearch.terms("a"), ["a"], "never left with nothing to search for")
        XCTAssertTrue(db.search("zzzqqq").isEmpty)
        // Short words aren't fuzzed into something else, and "cola" isn't found inside "chocolate".
        XCTAssertFalse(FoodSearch.isNearly("cola", "chocolate"))
        XCTAssertEqual(FoodSearch.match("cola", words: ["chocolate", "milk"], first: true, loose: true), 0)
    }

    func testEditDistance() {
        func d(_ a: String, _ b: String) -> Int { FoodSearch.editDistance(Array(a), Array(b), limit: 2) }
        XCTAssertEqual(d("banana", "banana"), 0)
        XCTAssertEqual(d("bannana", "banana"), 1)
        XCTAssertEqual(d("banaan", "banana"), 1, "swapped neighbours count once")
        XCTAssertEqual(d("brocoli", "broccoli"), 1)
        XCTAssertGreaterThan(d("apple", "orange"), 2)
    }

    func testReadsAmountsAndMeasures() {
        typealias P = MealDescription.Parsed
        XCTAssertEqual(MealDescription.read("2 slices of toast"), P(quantity: 2, grams: nil, hints: ["slice"], food: "toast"))
        XCTAssertEqual(MealDescription.read("a banana"), P(quantity: 1, grams: nil, hints: [], food: "banana"))
        XCTAssertEqual(MealDescription.read("half a cup of rice"), P(quantity: 0.5, grams: nil, hints: ["cup"], food: "rice"))
        XCTAssertEqual(MealDescription.read("200g rice"), P(quantity: nil, grams: 200, hints: [], food: "rice"))
        XCTAssertEqual(MealDescription.read("250 ml orange juice"), P(quantity: nil, grams: 250, hints: [], food: "orange juice"))
        XCTAssertEqual(MealDescription.read("1 1/2 cups pasta"), P(quantity: 1.5, grams: nil, hints: ["cup"], food: "pasta"))
        XCTAssertEqual(MealDescription.read("large apple"), P(quantity: nil, grams: nil, hints: ["large"], food: "apple"))
        XCTAssertEqual(MealDescription.read("can of coke"), P(quantity: nil, grams: nil, hints: ["can"], food: "coke"))
        XCTAssertEqual(MealDescription.read("pizza 3 slices"), P(quantity: 3, grams: nil, hints: ["slice"], food: "pizza"))
        XCTAssertEqual(MealDescription.read("had some rice"), P(quantity: nil, grams: nil, hints: [], food: "rice"))
        // "can" and "bar" inside a food's name stay part of the food.
        XCTAssertEqual(MealDescription.read("muesli bar").food, "muesli bar")
    }

    func testDescribedMealBecomesFoodsWithAmounts() throws {
        let meal = MealDescription.parse("2 slices of toast and a banana", in: db)
        XCTAssertEqual(meal.count, 2)
        let toast = try XCTUnwrap(meal[0].item), banana = try XCTUnwrap(meal[1].item)
        XCTAssertTrue(toast.name.lowercased().contains("toasted"), toast.name)
        XCTAssertEqual(meal[0].quantity, 2)
        XCTAssertEqual(toast.carbs, 30, accuracy: 12)
        XCTAssertTrue(banana.name.lowercased().hasPrefix("banana"), banana.name)
        XCTAssertEqual(banana.carbs, 23, accuracy: 8)
        XCTAssertFalse(meal[0].assumedAmount)
        XCTAssertFalse(meal[0].alternatives.isEmpty)

        let weighed = try XCTUnwrap(MealDescription.parse("200g rice", in: db).first)
        XCTAssertEqual(weighed.grams, 200)
        XCTAssertNil(weighed.portion)
        XCTAssertEqual(try XCTUnwrap(weighed.item).carbs, 69.4, accuracy: 1)

        let breakfast = MealDescription.parse("3 weetbix with 1 cup of milk", in: db)
        XCTAssertEqual(breakfast.map(\.quantity), [3, 1])
        XCTAssertEqual(breakfast[1].portion?.name, "cup (250 ml)")
    }

    func testADishNamedWithAndStaysOneFood() {
        let roll = MealDescription.parse("bacon and egg roll", in: db)
        XCTAssertEqual(roll.count, 1)
        XCTAssertEqual(roll.first?.food?.name, "Bacon & egg roll")
        XCTAssertEqual(MealDescription.parse("meat pie with tomato sauce", in: db).count, 2)
    }

    func testAmountsAreNeverInventedForSolids() throws {
        // No "cup" measure for boiled pasta in the list: the amount is left for the user.
        let pasta = try XCTUnwrap(MealDescription.parse("1 cup pasta", in: db).first)
        XCTAssertNotNil(pasta.food)
        if pasta.portion == nil {
            XCTAssertNil(pasta.grams)
            XCTAssertNil(pasta.item)
            XCTAssertTrue(pasta.assumedAmount)
        }
        // "chips" with no number is a serve, not one chip.
        let chips = try XCTUnwrap(MealDescription.parse("chips", in: db).first)
        XCTAssertGreaterThan(chips.grams ?? 0, 50)
        XCTAssertTrue(chips.assumedAmount)
        // A drink with no measure listed is taken as a cup, and says it was assumed.
        let coffee = try XCTUnwrap(MealDescription.parse("flat white", in: db).first)
        XCTAssertEqual(coffee.grams, 250)
        XCTAssertTrue(coffee.assumedAmount)
        // Nothing found is reported, not dropped.
        let unknown = MealDescription.parse("zzzqqq, banana", in: db)
        XCTAssertEqual(unknown.count, 2)
        XCTAssertNil(unknown[0].food)
        XCTAssertNil(unknown[0].item)
    }

    func testOwnFoodsWinAndCanBeSwapped() throws {
        let mine = FoodItem(id: "custom:1", name: "Mum's banana bread", carbsPer100g: 50,
                            portions: [FoodPortion(name: "slice", grams: 60)], source: .custom)
        let d = try XCTUnwrap(MealDescription.parse("2 slices banana bread", in: db, saved: [mine]).first)
        XCTAssertEqual(d.food?.id, "custom:1")
        XCTAssertEqual(d.item?.carbs, 60)
        let other = try XCTUnwrap(db.search("bread white").first)
        let swapped = d.choosing(other)
        XCTAssertEqual(swapped.food?.id, other.id)
        XCTAssertEqual(swapped.quantity, 2)
        XCTAssertNotNil(swapped.item)
    }

    func testTellsADescriptionFromASearch() {
        XCTAssertFalse(MealDescription.isDescription("banana"))
        XCTAssertFalse(MealDescription.isDescription("white bread"))
        XCTAssertFalse(MealDescription.isDescription(""))
        XCTAssertTrue(MealDescription.isDescription("2 bananas"))
        XCTAssertTrue(MealDescription.isDescription("toast and a banana"))
        XCTAssertTrue(MealDescription.isDescription("rice, chicken curry"))
        XCTAssertTrue(MealDescription.isDescription("200g rice"))
    }
}
