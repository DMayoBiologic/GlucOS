import SwiftUI

/// Find a food and say how much: searches the built-in AUSNUT 2023 list and the user's own foods,
/// shows favourites and recent picks before anything is typed, and can look up packaged products
/// in Open Food Facts. Used by the log sheets on the Mac and the iPhone.
struct FoodPickerView: View {
    @EnvironmentObject var logbook: LogbookStore

    /// Called with each food the user adds to the meal.
    let onAdd: (MealItem) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected: FoodItem?
    @State private var creating = false
    @State private var online: [FoodItem] = []
    @State private var onlineState: OnlineState = .idle
    @State private var added: [MealItem] = []

    enum OnlineState: Equatable { case idle, loading, done, failed }

    private var db: FoodDatabase { FoodDatabase.bundled }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let selected {
                FoodPortionView(food: selected, saved: logbook.savedFood(for: selected.id),
                                onBack: { self.selected = nil }) { item in
                    onAdd(item)
                    added.append(item)
                    logbook.notePortion(for: item.foodID, grams: item.grams, portion: item.portion)
                    self.selected = nil
                    query = ""
                }
            } else if creating {
                CustomFoodForm(initialName: query, onCancel: { creating = false }) { food in
                    logbook.saveFood(SavedFood(id: SavedFood.stableID(for: food), food: food, favourite: true))
                    creating = false
                    selected = food
                }
            } else {
                searchField
                results
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 560)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Add food").dsFont(.sectionTitle)
            Spacer()
            if !added.isEmpty {
                Text("\(added.count) added · \(LogFormat.grams(added.reduce(0) { $0 + $1.carbs }))")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.md)
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search foods", text: $query, prompt: Text("Search foods, e.g. banana, white bread"))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit { if searchHits.isEmpty { searchOnline() } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(DS.Space.sm + 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .onChange(of: query) { _, _ in
            online = []
            onlineState = .idle
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var savedHits: [FoodItem] {
        let terms = FoodDatabase.words(trimmed)
        return logbook.foods.map(\.food).filter { f in
            FoodDatabase.score(terms: terms, words: FoodDatabase.words(f.name + " " + f.brand), name: f.name) != nil
        }
    }

    private var searchHits: [FoodItem] {
        let saved = savedHits
        let ids = Set(saved.map(\.id))
        return saved + db.search(trimmed, limit: 40).filter { !ids.contains($0.id) }
    }

    /// Recent picks with their full portion lists where the food list has them.
    private var recents: [FoodItem] {
        logbook.meals.recentFoodItems(limit: 15).map { item in
            db.food(id: item.foodID) ?? logbook.savedFood(for: item.foodID)?.food ?? item.food
        }
    }

    @ViewBuilder
    private var results: some View {
        List {
            if trimmed.isEmpty {
                let favourites = logbook.foods.filter(\.favourite).map(\.food)
                if !favourites.isEmpty {
                    Section("Favourites") { ForEach(favourites) { row($0) } }
                }
                let recent = recents.filter { r in !favourites.contains { $0.id == r.id } }
                if !recent.isEmpty {
                    Section("Recent") { ForEach(recent) { row($0) } }
                }
                if favourites.isEmpty && recent.isEmpty {
                    Section {
                        Text("Search \(db.foods.count.formatted()) Australian foods, or add your own. Star a food to keep it here.")
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                let hits = searchHits
                if !hits.isEmpty {
                    Section("Foods") { ForEach(hits) { row($0) } }
                }
                Section("Packaged products") {
                    switch onlineState {
                    case .idle:
                        Button { searchOnline() } label: {
                            Label("Search Open Food Facts for \u{201C}\(trimmed)\u{201D}", systemImage: "globe")
                        }
                    case .loading:
                        HStack(spacing: DS.Space.sm) { ProgressView().controlSize(.small); Text("Searching…") }
                    case .done:
                        if online.isEmpty {
                            Text("No packaged products found.").foregroundStyle(.secondary)
                        } else {
                            ForEach(online) { row($0) }
                        }
                    case .failed:
                        Button { searchOnline() } label: {
                            Label("Couldn't reach Open Food Facts. Try again", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            Section {
                Button { creating = true } label: { Label("Add your own food", systemImage: "plus.circle") }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Food data: \(db.attribution.isEmpty ? "AUSNUT 2023, Food Standards Australia New Zealand, CC BY 4.0" : db.attribution). Carbs are available carbohydrate, so fibre isn't counted.")
                    if onlineState == .done && !online.isEmpty { Text(OpenFoodFacts.attribution) }
                }
                .dsFont(.caption)
                .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        #endif
    }

    private func row(_ food: FoodItem) -> some View {
        let favourite = logbook.savedFood(for: food.id)?.favourite ?? false
        return HStack(spacing: DS.Space.sm) {
            Button { selected = food } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.displayName).dsFont(.body).foregroundStyle(.primary).lineLimit(2)
                    Text(detail(food)).dsFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { logbook.setFavourite(food, !favourite) } label: {
                Image(systemName: favourite ? "star.fill" : "star")
                    .foregroundStyle(favourite ? Tone.warning.color : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favourite ? "Remove from favourites" : "Add to favourites")
        }
    }

    private func detail(_ food: FoodItem) -> String {
        if food.isServingOnly, let p = food.portions.first {
            return "\(LogFormat.grams((food.carbs(grams: p.grams) * 10).rounded() / 10)) carbs per \(p.name) · \(food.source.title)"
        }
        var bits = ["\(LogFormat.number(food.carbsPer100g)) g carbs per 100 g"]
        if let p = food.portions.first {
            bits.append("1 \(p.name): \(LogFormat.grams((food.carbs(grams: p.grams) * 10).rounded() / 10))")
        }
        if food.source != .ausnut { bits.append(food.source.title) }
        return bits.joined(separator: " · ")
    }

    private func searchOnline() {
        let q = trimmed
        guard q.count >= 2 else { return }
        onlineState = .loading
        Task {
            do {
                let items = try await OpenFoodFactsClient.search(q)
                guard q == trimmed else { return }
                online = items
                onlineState = .done
            } catch {
                guard q == trimmed else { return }
                onlineState = .failed
            }
        }
    }
}

// MARK: - Portion

/// How much of one food: a household measure times a number, or grams.
struct FoodPortionView: View {
    let food: FoodItem
    let onBack: () -> Void
    let onAdd: (MealItem) -> Void

    @EnvironmentObject var logbook: LogbookStore
    /// Index into `food.portions`, or nil for grams.
    @State private var portionIndex: Int?
    @State private var quantity: Double
    @State private var gramsText: String

    init(food: FoodItem, saved: SavedFood?, onBack: @escaping () -> Void, onAdd: @escaping (MealItem) -> Void) {
        self.food = food
        self.onBack = onBack
        self.onAdd = onAdd
        var index: Int? = food.portions.isEmpty ? nil : 0
        var quantity = 1.0
        var grams = 100.0
        if let saved {
            if let last = saved.lastPortion, let i = food.portions.firstIndex(where: { last.hasSuffix("× \($0.name)") }) {
                index = i
                quantity = max(0.25, (saved.lastGrams ?? food.portions[i].grams) / food.portions[i].grams)
            } else if let g = saved.lastGrams, !food.isServingOnly {
                index = nil
                grams = g
            }
        }
        _portionIndex = State(initialValue: index)
        _quantity = State(initialValue: (quantity * 4).rounded() / 4)
        _gramsText = State(initialValue: LogFormat.number(grams.rounded()))
    }

    private var portion: FoodPortion? { portionIndex.flatMap { food.portions.indices.contains($0) ? food.portions[$0] : nil } }

    private var grams: Double? {
        FoodPortionMath.grams(quantity: quantity, portion: portion,
                              grams: Double(gramsText.replacingOccurrences(of: ",", with: ".")))
    }

    private var carbs: Double? { grams.map { (food.carbs(grams: $0) * 10).rounded() / 10 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Button(action: onBack) { Label("Foods", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tone.brand.textColor)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(food.displayName).dsFont(.title).fixedSize(horizontal: false, vertical: true)
                    Text(food.isServingOnly
                         ? "\(LogFormat.number((food.carbs(grams: food.portions.first?.grams ?? 100) * 10).rounded() / 10)) g carbohydrate per \(food.portions.first?.name ?? "serve") · \(food.source.title)"
                         : "\(LogFormat.number(food.carbsPer100g)) g carbohydrate per 100 g · \(food.source.title)")
                        .dsFont(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if food.portions.count > 1 || (!food.portions.isEmpty && !food.isServingOnly) {
                        Picker("Portion", selection: $portionIndex) {
                            ForEach(food.portions.indices, id: \.self) { i in
                                Text("\(food.portions[i].name) (\(LogFormat.number(food.portions[i].grams.rounded())) g)").tag(Int?.some(i))
                            }
                            if !food.isServingOnly { Text("Weigh it (grams)").tag(Int?.none) }
                        }
                    }
                    if portion != nil {
                        Stepper(value: $quantity, in: 0.25...20, step: 0.25) {
                            HStack {
                                Text("How many")
                                Spacer()
                                Text(quantityLabel).monospacedDigit().dsFont(.headline)
                            }
                        }
                        HStack(spacing: DS.Space.xs + 2) {
                            ForEach([0.5, 1, 2, 3], id: \.self) { q in
                                Button(q == 0.5 ? "½" : LogFormat.number(q)) { quantity = q }
                                    .buttonStyle(ChipButtonStyle(selected: quantity == q, tint: Palette.food))
                            }
                        }
                    } else {
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("Grams", text: $gramsText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                }
                .dsCard(.inset, padding: DS.Space.md)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(carbs.map { LogFormat.grams($0) } ?? "–")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.food)
                            .monospacedDigit()
                        Text(grams.map { g in
                            food.isServingOnly ? "carbs in \(quantityLabel) \(portion?.name ?? "serve")" : "carbs in \(LogFormat.number(g.rounded())) g"
                        } ?? "Enter an amount")
                            .dsFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let favourite = logbook.savedFood(for: food.id)?.favourite ?? false
                    Button { logbook.setFavourite(food, !favourite) } label: {
                        Label(favourite ? "Favourite" : "Add to favourites", systemImage: favourite ? "star.fill" : "star")
                    }
                    .buttonStyle(.ds(.ghost, size: .small))
                }

                Button {
                    guard let grams else { return }
                    onAdd(MealItem(food: food, grams: grams,
                                   portion: portion.map { FoodPortionMath.label(quantity: quantity, portion: $0) }))
                } label: {
                    Label("Add to meal", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .large))
                .disabled(grams == nil)

                Text(food.source == .openFoodFacts
                     ? OpenFoodFacts.attribution
                     : "Portion weights and carbs are typical values. Check the packet when you have it.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.lg)
        }
    }

    private var quantityLabel: String {
        switch quantity {
        case 0.25: return "¼"
        case 0.5: return "½"
        case 0.75: return "¾"
        default: return LogFormat.number(quantity)
        }
    }
}

// MARK: - Your own food

/// A food the user describes: a name and the carbs in a serve (with its weight, if known).
struct CustomFoodForm: View {
    let initialName: String
    let onCancel: () -> Void
    let onSave: (FoodItem) -> Void

    @State private var name: String
    @State private var serveName = "serve"
    @State private var carbsText = ""
    @State private var weightText = ""

    init(initialName: String, onCancel: @escaping () -> Void, onSave: @escaping (FoodItem) -> Void) {
        self.initialName = initialName
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName.trimmingCharacters(in: .whitespacesAndNewlines).capitalized)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private var food: FoodItem? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let carbs = Self.number(carbsText), (0...300).contains(carbs) else { return nil }
        let weight = Self.number(weightText)
        if !weightText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let weight, weight > 0, weight < 5000, carbs <= weight else { return nil }
        }
        return FoodItem.custom(name: n, carbsPerServe: carbs, serveName: serveName, serveGrams: weight)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Mum's lasagne"))
                TextField("Serve", text: $serveName, prompt: Text("serve, slice, bowl…"))
                TextField("Carbs in one serve (g)", text: $carbsText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                TextField("Weight of one serve (g, optional)", text: $weightText)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            } footer: {
                Text("Saved to your foods and favourites, on all your devices.")
            }
            Section {
                Button("Save food") { if let food { onSave(food) } }
                    .disabled(food == nil)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .formStyle(.grouped)
    }
}
