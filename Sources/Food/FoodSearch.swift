import Foundation

// How a typed search is read before it's matched against food names, so people can search the way
// they talk: everyday and overseas names ("fries", "oatmeal", "coke"), filler words ("a bowl of"),
// plurals and small typos all find the food. To teach the search a new word, add it to
// `FoodAliases`: nothing else needs to change.
//
// Plain Foundation so `swift test` covers it.

/// Other names for foods: what people say, mapped to the words the food lists use.
enum FoodAliases {
    /// Phrases rewritten before the search is split into words.
    static let phrases: [(String, String)] = [
        ("flat white", "coffee flat white"),
        ("long black", "coffee long black"),
        ("short black", "coffee espresso"),
        ("hot chips", "potato chips"),
        ("french fries", "potato chips"),
        ("bell pepper", "capsicum"),
        ("spag bol", "pasta bolognese"),
        ("spaghetti bolognese", "pasta bolognese"),
        ("spaghetti bolognaise", "pasta bolognese"),
        ("weet bix", "breakfast cereal whole wheat biscuit"),
        ("weetbix", "breakfast cereal whole wheat biscuit"),
        ("jelly beans", "lolly jelly"),
        ("jelly bean", "lolly jelly"),
        ("jellybeans", "lolly jelly"),
        ("icy pole", "ice confection"),
        ("ice block", "ice confection"),
        ("mac and cheese", "macaroni cheese"),
        ("pb and j", "peanut butter jam"),
        ("oj", "orange juice"),
        ("icecream", "ice cream"),
        ("pb", "peanut butter"),
    ]

    /// One typed word and the food-list words that mean the same. Each alternative is every word
    /// a name must have.
    static let words: [String: [[String]]] = [
        "fries": [["potato", "chips"]],
        "crisps": [["potato", "crisps"]],
        "soda": [["soft", "drink"]],
        "pop": [["soft", "drink"]],
        "fizzy": [["soft", "drink"]],
        "coke": [["soft", "drink", "cola"]],
        "pepsi": [["soft", "drink", "cola"]],
        "cola": [["soft", "drink", "cola"]],
        "lemonade": [["soft", "drink", "lemonade"], ["soft", "drink"]],
        "sprite": [["soft", "drink", "lemonade"], ["soft", "drink"]],
        "gatorade": [["sports", "drink"]],
        "powerade": [["sports", "drink"]],
        "candy": [["lolly"]],
        "sweets": [["lolly"]],
        "lollies": [["lolly"]],
        "oatmeal": [["porridge"]],
        "courgette": [["zucchini"]],
        "aubergine": [["eggplant"]],
        "shrimp": [["prawn"]],
        "cilantro": [["coriander"]],
        "ketchup": [["sauce", "tomato"]],
        "kumara": [["sweet", "potato"]],
        "cookie": [["biscuit", "sweet"]],
        "cookies": [["biscuit", "sweet"]],
        "cracker": [["biscuit", "savoury"]],
        "crackers": [["biscuit", "savoury"]],
        "toast": [["bread", "toasted"]],
        "yogurt": [["yoghurt"]],
        "chili": [["chilli"]],
        "omelet": [["omelette"]],
        "donut": [["doughnut"]],
        "donuts": [["doughnut"]],
        "bbq": [["barbecue"], ["barbecued"]],
        "spud": [["potato"]],
        "snag": [["sausage"]],
        "sanga": [["sandwich"]],
        "sambo": [["sandwich"]],
        "sarnie": [["sandwich"]],
        "avo": [["avocado"]],
        "mash": [["potato", "mashed"]],
        "spaghetti": [["pasta"]],
        "bolognaise": [["bolognese"]],
        "cantaloupe": [["rockmelon"]],
        "scallion": [["onion", "spring"]],
        "arugula": [["rocket"]],
        "garbanzo": [["chickpea"]],
        "jello": [["jelly"]],
        "popsicle": [["ice", "confection"]],
        "latte": [["coffee", "latte"]],
        "cappuccino": [["coffee", "cappuccino"]],
        "burger": [["hamburger"]],
        "cereal": [["breakfast", "cereal"]],
        "maccas": [["fast", "food"]],
    ]
}

/// The everyday food a plain search most likely means, so "rice" starts on cooked white rice
/// rather than whichever rice sorts first. Keys are searches as `FoodSearch.key` writes them;
/// values are AUSNUT food keys. A food that isn't in the bundled list is simply ignored.
enum FoodStaples {
    static let raw: [String: String] = [
        "banana": "F000262", "egg": "F003721", "rice": "F007661", "white rice": "F007661",
        "brown rice": "F007641", "pasta": "F006456", "bread": "F001463", "white bread": "F001463",
        "toast": "F001541", "milk": "F005634", "chips": "F007238", "fries": "F007238",
        "potato chips": "F007238", "crisps": "F007193", "porridge": "F007164", "oatmeal": "F007164",
        "breakfast cereal whole wheat biscuit": "F001844", "orange": "F006277",
        "orange juice": "F004739", "apple juice": "F004663", "coffee flat white": "F003045",
        "latte": "F003045", "cappuccino": "F003045", "meat pie": "F006665", "pie": "F006665",
        "burger": "F004362", "hamburger": "F004362", "coke": "F008402", "cola": "F008402",
        "ice cream": "F004508", "potato": "F007353", "mash": "F007335", "mashed potato": "F007335",
        "sweet potato": "F009040", "noodles": "F006048",
    ]

    static let byKey: [String: String] = Dictionary(raw.map { (FoodSearch.key(FoodSearch.terms($0.key)), "ausnut:\($0.value)") },
                                                    uniquingKeysWith: { a, _ in a })

    /// The id of the staple food for these terms, if they name one.
    static func id(for terms: [String]) -> String? { byKey[FoodSearch.key(terms)] }
}

enum FoodSearch {
    /// Terms in one fixed spelling (singular), for looking up `FoodStaples`.
    static func key(_ terms: [String]) -> String {
        terms.map { forms($0).last ?? $0 }.joined(separator: " ")
    }

    /// Name words that make a food an unlikely thing to mean unless they were typed, and how much
    /// each counts against it; and the ones that make it likelier.
    static let unlikely: [String: Double] = [
        "uncooked": 1.5, "dried": 1, "powder": 1, "dry": 1, "flour": 1, "mix": 0.8, "concentrate": 1,
        "emu": 1.5, "duck": 1.5, "quail": 1.5, "goose": 1.5, "turkey": 0.5, "goat": 1, "sheep": 1,
        "infant": 2, "toddler": 2, "beverage": 1, "canned": 0.3, "frozen": 0.4, "base": 0.8,
        "alternative": 0.8, "diet": 0.6, "sweetened": 0.4, "free": 0.4, "reduced": 0.3, "organic": 0.2,
        "based": 0.8, "vegan": 0.8, "sashimi": 0.5,
    ]
    static let likely: [String: Double] = ["cooked": 0.3, "boiled": 0.3, "commercial": 0.2, "raw": 0.1]

    /// The lift or drop for a food's name words, leaving out any the search asked for.
    static func prior(words: [String], terms: [String]) -> Double {
        var total = 0.0
        for w in Set(words) where !terms.contains(where: { forms($0).contains(w) }) {
            total += (likely[w] ?? 0) - (unlikely[w] ?? 0)
        }
        return total
    }

    /// Words that say nothing about which food it is.
    static let fillers: Set<String> = [
        "a", "an", "the", "of", "with", "and", "some", "my", "in", "on", "for", "to", "had", "ate",
        "eating", "having", "just", "plus", "then", "about", "around", "roughly", "bit",
    ]

    /// The words to match for a typed search: aliased phrases swapped in and filler words dropped
    /// (unless that would leave nothing).
    static func terms(_ query: String) -> [String] {
        var text = " " + FoodDatabase.words(query).joined(separator: " ") + " "
        for (phrase, replacement) in FoodAliases.phrases {
            text = text.replacingOccurrences(of: " \(phrase) ", with: " \(replacement) ")
        }
        let all = text.split(separator: " ").map(String.init)
        let kept = all.filter { !fillers.contains($0) }
        return kept.isEmpty ? all : kept
    }

    /// The forms of a typed word to look for: itself and its singular.
    static func forms(_ term: String) -> [String] {
        if term.count > 4, term.hasSuffix("ies") { return [term, String(term.dropLast(3)) + "y"] }
        if term.count > 4, term.hasSuffix("oes") { return [term, String(term.dropLast(2))] }
        if term.count > 3, term.hasSuffix("s"), !term.hasSuffix("ss") { return [term, String(term.dropLast())] }
        return [term]
    }

    /// How well one typed word matches a food's name words: 0 when it doesn't. A whole word beats
    /// the start of one, which beats the middle of one; with `loose`, one wrong letter still counts.
    static func match(_ term: String, words: [String], first: Bool, loose: Bool) -> Double {
        let forms = forms(term)
        var best = 0.0
        for (position, w) in words.enumerated() {
            var s = 0.0
            if forms.contains(w) {
                s = 3
            } else if forms.contains(where: { w.hasPrefix($0) }) {
                s = 1.5
            } else if term.count >= 5, forms.contains(where: { w.contains($0) }) {
                s = 1
            } else if loose, term.count >= 5, isNearly(term, w) {
                s = 0.8
            } else {
                continue
            }
            // Words early in the name ("Banana, …") say what the food is.
            if position == 0 { s += first ? 3 : 2 } else if position < 3 { s += 0.5 }
            best = max(best, s)
        }
        return best
    }

    /// One letter added, missing, swapped or wrong ("bannana", "brocoli"), against the word or the
    /// start of it.
    static func isNearly(_ typed: String, _ word: String) -> Bool {
        let a = Array(typed), full = Array(word)
        if abs(a.count - full.count) <= 1, editDistance(a, full, limit: 1) <= 1 { return true }
        // Still typing a longer word.
        for extra in 0...1 where full.count > a.count + extra {
            if editDistance(a, Array(full.prefix(a.count + extra)), limit: 1) <= 1 { return true }
        }
        return false
    }

    /// Edit distance where swapping two neighbouring letters counts once, stopping early past `limit`.
    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev
            prev = cur
        }
        return prev[b.count]
    }
}
