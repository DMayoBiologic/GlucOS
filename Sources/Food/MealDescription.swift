import Foundation

// Reads a meal the way someone would say it ("2 slices of toast, a banana and a flat white") into
// foods from the food lists with amounts, so nobody has to look each one up and fill in a portion.
// It only looks foods up: every carb figure still comes from the food's own entry, and the user
// sees and can change each match before it's added.
//
// Plain Foundation so `swift test` covers it.

/// One food read out of a description.
struct DescribedFood: Identifiable, Hashable {
    var id = UUID()
    /// The words this came from, e.g. "2 slices of toast".
    var phrase: String
    /// The best match, or nil when nothing in the lists fits.
    var food: FoodItem?
    var quantity: Double = 1
    /// The household measure used, or nil when the amount is a weight.
    var portion: FoodPortion?
    var grams: Double?
    /// The amount was assumed (no amount was said, or the measure isn't one this food has).
    var assumedAmount = false
    /// Other foods the words could mean, best first.
    var alternatives: [FoodItem] = []

    /// Ready to add to a meal, when a food and an amount were found.
    var item: MealItem? {
        guard let food, let grams, grams > 0 else { return nil }
        return MealItem(food: food, grams: grams,
                        portion: portion.map { FoodPortionMath.label(quantity: quantity, portion: $0) })
    }

    /// The same words matched to another food, with the amount worked out again for it.
    func choosing(_ other: FoodItem) -> DescribedFood {
        var out = self
        let amount = MealDescription.amount(for: other, parsed: MealDescription.read(phrase))
        out.food = other
        out.quantity = amount.quantity
        out.portion = amount.portion
        out.grams = amount.grams
        out.assumedAmount = amount.assumed
        return out
    }
}

enum MealDescription {
    /// What one phrase says before any food is looked up.
    struct Parsed: Equatable {
        var quantity: Double?
        /// A weight or volume that was said outright ("200 g", "250 ml"), in grams.
        var grams: Double?
        /// Measure and size words: "slice", "cup", "large".
        var hints: [String] = []
        /// What's left: the food.
        var food: String = ""
    }

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "half": 0.5, "quarter": 0.25,
        "couple": 2, "few": 3, "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3,
    ]

    /// Grams for one of a unit that's a real weight or volume (drinks are near enough 1 g per ml).
    private static let weights: [String: Double] = [
        "g": 1, "gram": 1, "grams": 1, "gm": 1, "kg": 1000, "kilo": 1000, "kilos": 1000,
        "ml": 1, "mls": 1, "l": 1000, "litre": 1000, "litres": 1000, "liter": 1000, "liters": 1000,
    ]

    /// Measure words, as the food lists spell them.
    private static let measures: [String: String] = [
        "slice": "slice", "slices": "slice", "cup": "cup", "cups": "cup", "glass": "cup", "glasses": "cup",
        "mug": "cup", "mugs": "cup", "bowl": "cup", "bowls": "cup",
        "tablespoon": "tablespoon", "tablespoons": "tablespoon", "tbsp": "tablespoon", "tbsps": "tablespoon",
        "teaspoon": "teaspoon", "teaspoons": "teaspoon", "tsp": "teaspoon", "tsps": "teaspoon",
        "piece": "piece", "pieces": "piece", "handful": "handful", "handfuls": "handful",
        "serve": "serve", "serves": "serve", "serving": "serve", "servings": "serve",
        "packet": "packet", "packets": "packet", "pack": "packet", "packs": "packet", "bag": "packet", "bags": "packet",
        "can": "can", "cans": "can", "bottle": "bottle", "bottles": "bottle", "bar": "bar", "bars": "bar",
        "scoop": "scoop", "scoops": "scoop", "tub": "tub", "tubs": "tub", "stick": "stick", "sticks": "stick",
        "small": "small", "medium": "medium", "regular": "regular", "large": "large", "big": "large",
        "thin": "thin", "thick": "thick", "mini": "mini",
    ]

    private static let sizes: Set<String> = ["small", "medium", "regular", "large", "thin", "thick", "mini"]

    /// Foods that come by the glass: with no amount said and no measure listed, assume a cup.
    private static let drinks: Set<String> = ["coffee", "tea", "milk", "juice", "beverage", "smoothie", "milkshake",
                                              "cordial", "beer", "wine", "cider", "drink", "kombucha", "water"]

    /// Rough weights for a measure a food has no entry for.
    private static let fallbackGrams: [String: Double] = ["cup": 250, "tablespoon": 20, "teaspoon": 5]

    // MARK: Reading

    /// The separate foods in a description: split at commas and line breaks.
    static func chunks(_ text: String) -> [String] {
        text.replacingOccurrences(of: " + ", with: ",")
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A chunk split again at "and" / "with" / "&", for when it isn't one dish's name.
    static func joined(_ chunk: String) -> [String] {
        var parts = [chunk]
        for word in [" and ", " with ", " & ", " plus ", " then "] {
            parts = parts.flatMap { $0.components(separatedBy: word) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func number(_ token: String) -> Double? {
        if let w = numberWords[token] { return w }
        let t = token.replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v.isFinite, v > 0 { return v }
        let f = t.split(separator: "/")
        if f.count == 2, let a = Double(f[0]), let b = Double(f[1]), a > 0, b > 0 { return a / b }
        return nil
    }

    /// "200g" → (200, "g"); "2x" → (2, "x").
    private static func glued(_ token: String) -> (Double, String)? {
        guard let split = token.firstIndex(where: { $0.isLetter }), split != token.startIndex,
              let v = number(String(token[..<split])) else { return nil }
        return (v, String(token[split...]))
    }

    /// The amount, measure words and food in one phrase.
    static func read(_ phrase: String) -> Parsed {
        var tokens = phrase.lowercased()
            .split { $0.isWhitespace }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?:()\"")) }
            .filter { !$0.isEmpty }
        var out = Parsed()
        var food: [String] = []
        // Words like "had", "some" before the amount.
        while let first = tokens.first, FoodSearch.fillers.contains(first), numberWords[first] == nil { tokens.removeFirst() }
        var amountDone = false
        while !tokens.isEmpty {
            let t = tokens.removeFirst()
            if amountDone { food.append(t); continue }
            if let (v, unit) = glued(t) {
                if let w = weights[unit] { out.grams = v * w } else {
                    out.quantity = (out.quantity ?? 0) + v
                    if let m = measures[unit] { out.hints.append(m) }
                }
                continue
            }
            if let v = number(t) {
                // "a" only counts as one before a food ("a banana"), and "half a cup" is a half.
                if (t == "a" || t == "an"), out.quantity != nil { continue }
                // "1 1/2" adds; "two large" doesn't arrive here twice.
                out.quantity = (out.quantity ?? 0) + v
                continue
            }
            if out.quantity != nil, out.grams == nil, let w = weights[t] {
                out.grams = (out.quantity ?? 1) * w
                out.quantity = nil
                continue
            }
            if t == "x" || t == "of" || t == "×" { continue }
            if let m = measures[t] {
                // "can" and "bar" are also foods' words, so they only count after an amount or
                // before "of" ("can of coke").
                if out.quantity != nil || out.grams != nil || tokens.first == "of" || sizes.contains(m) {
                    out.hints.append(m)
                    continue
                }
            }
            amountDone = true
            food.append(t)
        }
        // An amount said after the food: "pizza 3 slices", "rice 200g".
        if out.quantity == nil, out.grams == nil, out.hints.allSatisfy(sizes.contains),
           let start = food.firstIndex(where: { number($0) != nil && numberWords[$0] == nil || glued($0) != nil }), start > 0 {
            let tail = read(food[start...].joined(separator: " "))
            if tail.food.isEmpty || tail.hints.contains(tail.food) {
                out.quantity = tail.quantity
                out.grams = tail.grams
                out.hints += tail.hints
                food = Array(food[..<start])
            }
        }
        // "2 slices": the measure was the food.
        if food.isEmpty, let last = out.hints.last { food = [last] }
        out.food = food.joined(separator: " ")
        return out
    }

    // MARK: Matching

    /// The portion and weight for `food`, given what the phrase said.
    static func amount(for food: FoodItem, parsed: Parsed)
        -> (quantity: Double, portion: FoodPortion?, grams: Double?, assumed: Bool) {
        if let grams = parsed.grams, !food.isServingOnly {
            return (1, nil, FoodPortionMath.grams(quantity: 1, portion: nil, grams: grams), false)
        }
        let quantity = min(50, max(0.25, parsed.quantity ?? 1))
        let foodWords = Set(FoodSearch.terms(parsed.food).flatMap(FoodSearch.forms))
        func words(_ p: FoodPortion) -> [String] { FoodDatabase.words(p.name) }
        // The measure that was said: the portion sharing the most of its words.
        var best: (FoodPortion, Int)?
        if !parsed.hints.isEmpty {
            for p in food.portions {
                let n = parsed.hints.filter { h in words(p).contains { $0.hasPrefix(h) } }.count
                if n > 0, n > (best?.1 ?? 0) { best = (p, n) }
            }
        }
        if let (p, _) = best { return (quantity, p, quantity * p.grams, false) }
        let isDrink = FoodDatabase.words(food.name).prefix(2).contains(where: drinks.contains)
        // A measure this food has no entry for. A spoonful weighs much the same whatever it is,
        // and a cup of a drink is a cup; a cup of anything else isn't guessed at.
        if let said = parsed.hints.first(where: { fallbackGrams[$0] != nil }), !food.isServingOnly {
            if said != "cup" || isDrink { return (quantity, nil, quantity * (fallbackGrams[said] ?? 0), true) }
            return (quantity, nil, nil, true)
        }
        // No measure: the portion named after the food itself ("banana, medium", "egg"), a
        // middling one first.
        func middling(_ p: FoodPortion) -> Bool { words(p).contains { $0 == "medium" || $0 == "regular" } }
        let named = food.portions.filter { p in words(p).contains { foodWords.contains($0) } }
        if let p = named.first(where: middling) { return (quantity, p, quantity * p.grams, !parsed.hints.isEmpty) }
        // "chips" with no number isn't one chip: only count single small things when a number was said.
        if let p = named.first(where: { parsed.quantity != nil || $0.grams >= 15 }) {
            return (quantity, p, quantity * p.grams, !parsed.hints.isEmpty)
        }
        let serves = food.portions.filter { p in words(p).contains { $0 == "serve" || $0 == "serving" } }
        if let p = serves.first(where: middling) ?? serves.first ?? food.portions.first(where: { $0.grams >= 15 })
            ?? food.portions.first {
            return (quantity, p, quantity * p.grams, true)
        }
        // Nothing to go on: a drink is taken as a cup, anything else is left for the user to say.
        return (quantity, nil, isDrink ? quantity * 250 : nil, true)
    }

    /// Each food in `text`, matched against the user's own foods first and then the food list.
    static func parse(_ text: String, in db: FoodDatabase, saved: [FoodItem] = []) -> [DescribedFood] {
        let own = FoodDatabase(foods: saved, attribution: "")
        func hits(_ food: String, loose: Bool) -> [FoodItem] {
            let terms = FoodSearch.terms(food)
            guard !terms.isEmpty else { return [] }
            let mine = own.matches(terms, loose: loose, limit: 3)
            let ids = Set(mine.map(\.id))
            return mine + db.matches(terms, loose: loose, limit: 6).filter { !ids.contains($0.id) }
        }
        var out: [DescribedFood] = []
        for chunk in chunks(text) {
            // "fish and chips" is one dish if the lists have it; otherwise it's two foods.
            let parts = joined(chunk)
            let whole = read(chunk)
            let phrases = parts.count > 1 && hits(whole.food, loose: false).isEmpty ? parts : [chunk]
            for phrase in phrases {
                let parsed = read(phrase)
                guard !parsed.food.isEmpty else { continue }
                var found = hits(parsed.food, loose: false)
                if found.isEmpty { found = hits(parsed.food, loose: true) }
                var d = DescribedFood(phrase: phrase)
                if let food = found.first {
                    let a = amount(for: food, parsed: parsed)
                    d.food = food
                    d.quantity = a.quantity
                    d.portion = a.portion
                    d.grams = a.grams
                    d.assumedAmount = a.assumed
                    d.alternatives = Array(found.dropFirst())
                }
                out.append(d)
            }
        }
        return out
    }

    /// Whether `text` reads as a meal rather than a single search: more than one food, or an amount.
    static func isDescription(_ text: String) -> Bool {
        let all = chunks(text).flatMap(joined)
        if all.count > 1 { return true }
        guard let only = all.first else { return false }
        let p = read(only)
        return (p.quantity != nil || p.grams != nil || !p.hints.isEmpty) && !p.food.isEmpty
    }
}
