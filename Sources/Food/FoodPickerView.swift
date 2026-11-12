import SwiftUI

/// Say what you ate and get its carbs. One box takes either a search ("banana", "fries") or a
/// whole meal in words ("2 slices of toast and a banana"), which is read into foods with amounts
/// (`MealDescription`). Favourites and recent picks show before anything is typed, each with a +
/// that adds the usual amount in one tap, and packaged products are looked up online as you type.
/// Used by the log sheets on the Mac and the iPhone.
struct FoodPickerView: View {
    @EnvironmentObject var logbook: LogbookStore

    /// What to start the box with, e.g. what was typed in the log sheet.
    var initialQuery: String = ""
    /// Called with each food the user adds to the meal.
    let onAdd: (MealItem) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected: FoodItem?
    /// The described food being adjusted in the portion view, if that's how it was opened.
    @State private var adjusting: UUID?
    @State private var creating = false
    @State private var hits: [FoodItem] = []
    @State private var described: [DescribedFood] = []
    /// Amounts the user set by hand for described foods.
    @State private var adjusted: [UUID: MealItem] = [:]
    @State private var online: [FoodItem] = []
    @State private var onlineState: OnlineState = .idle
    @State private var added: [MealItem] = []
    @FocusState private var searching: Bool

    enum OnlineState: Equatable { case idle, loading, done, failed }

    private var db: FoodDatabase { FoodDatabase.bundled }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let selected {
                FoodPortionView(food: selected, saved: logbook.savedFood(for: selected.id),
                                onBack: { self.selected = nil; adjusting = nil }) { item in
                    if let id = adjusting {
                        // Back to the described meal with this food's amount set.
                        adjusted[id] = item
                        adjusting = nil
                    } else {
                        add(item)
                        query = ""
                    }
                    self.selected = nil
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
        .frame(minWidth: 440, idealWidth: 500, minHeight: 480, idealHeight: 600)
        #endif
        .onAppear {
            if query.isEmpty { query = initialQuery }
            searching = true
        }
        .task(id: query) { await refresh() }
    }

    private var header: some View {
        HStack {
            Text("What did you eat?").dsFont(.sectionTitle)
            Spacer()
            if !added.isEmpty {
                Text("\(added.count) added · \(LogFormat.grams(added.reduce(0) { $0 + $1.carbs }))")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(DS.Space.md)
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or describe", text: $query, prompt: Text("Search, or describe it: 2 toast and a banana"))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($searching)
                .onSubmit(submit)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(DS.Space.sm + 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The user's own foods and favourites, which rank ahead of the built-in list.
    private var ownFoods: [FoodItem] { logbook.foods.map(\.food) }

    /// Works the results out again a moment after typing stops: the described meal or the search
    /// hits first, then packaged products from online.
    private func refresh() async {
        let q = trimmed
        online = []
        onlineState = .idle
        guard !q.isEmpty else {
            hits = []
            described = []
            adjusted = [:]
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        if MealDescription.isDescription(q) {
            described = MealDescription.parse(q, in: db, saved: ownFoods)
            adjusted = [:]
            hits = []
            return
        }
        described = []
        let own = FoodDatabase(foods: ownFoods, attribution: "").search(q, limit: 10)
        let ids = Set(own.map(\.id))
        hits = own + db.search(q, limit: 40).filter { !ids.contains($0.id) }
        // Packaged and branded products, without being asked: once the typing has settled.
        guard q.count >= 3 else { return }
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }
        await searchOnline(q)
    }

    /// Return adds the whole described meal, or opens the top hit.
    private func submit() {
        if !described.isEmpty {
            if !readyItems.isEmpty { addDescribed() }
        } else if let top = hits.first ?? online.first {
            selected = top
        }
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
                Section {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Label("Type a food, or the whole meal", systemImage: "text.bubble").dsFont(.headline)
                        Text("\u{201C}2 slices of toast and a banana\u{201D}, \u{201C}200g rice, chicken curry\u{201D}, \u{201C}flat white\u{201D}. GlucOS finds each food and its carbs from \(db.foods.count.formatted()) Australian foods and packaged products. Tap + to add, or the name to change the amount.")
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DS.Space.xs)
                }
            } else if !described.isEmpty {
                describedSection
            } else {
                if !hits.isEmpty {
                    Section("Foods") { ForEach(hits) { row($0) } }
                }
                Section("Packaged products") {
                    switch onlineState {
                    case .idle:
                        Button { Task { await searchOnline(trimmed) } } label: {
                            Label("Search packaged products for \u{201C}\(trimmed)\u{201D}", systemImage: "globe")
                        }
                    case .loading:
                        HStack(spacing: DS.Space.sm) { ProgressView().controlSize(.small); Text("Looking up packaged products…") }
                            .foregroundStyle(.secondary)
                    case .done:
                        if online.isEmpty {
                            Text("No packaged products found.").foregroundStyle(.secondary)
                        } else {
                            ForEach(online) { row($0) }
                        }
                    case .failed:
                        Button { Task { await searchOnline(trimmed) } } label: {
                            Label("Couldn't reach the packaged food lists. Try again", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            Section {
                Button { creating = true } label: {
                    Label(trimmed.isEmpty ? "Add a food of your own" : "Can't find it? Add it as your own food", systemImage: "plus.circle")
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Food data: \(db.attribution.isEmpty ? "AUSNUT 2023, Food Standards Australia New Zealand, CC BY 4.0" : db.attribution). Carbs are available carbohydrate, so fibre isn't counted.")
                    if onlineState == .done && !online.isEmpty {
                        ForEach(FoodSources.online.map(\.attribution), id: \.self) { Text($0) }
                    }
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

    // MARK: Described meal

    private func item(for d: DescribedFood) -> MealItem? { adjusted[d.id] ?? d.item }

    private var readyItems: [MealItem] { described.compactMap(item(for:)) }

    @ViewBuilder
    private var describedSection: some View {
        let ready = readyItems
        Section {
            ForEach(described) { d in describedRow(d) }
            Button { addDescribed() } label: {
                Label(addAllTitle(ready), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ds(.primary, size: .large))
            .disabled(ready.isEmpty)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
        } header: {
            Text("Your meal")
        } footer: {
            Text("Matched from what you typed. Check each food and amount: tap one to change how much, or pick another match. Typical values, so check the packet when you have it.")
        }
    }

    private func addAllTitle(_ ready: [MealItem]) -> String {
        guard !ready.isEmpty else { return "Nothing to add yet" }
        let total = (ready.reduce(0) { $0 + $1.carbs } * 10).rounded() / 10
        let what = ready.count == 1 ? "it" : "all \(ready.count)"
        return "Add \(what) · \(LogFormat.grams(total)) carbs"
    }

    private func describedRow(_ d: DescribedFood) -> some View {
        HStack(spacing: DS.Space.sm) {
            if let food = d.food {
                let item = item(for: d)
                Button {
                    adjusting = d.id
                    selected = food
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item?.name ?? food.displayName).dsFont(.body).foregroundStyle(.primary).lineLimit(2)
                        if let item {
                            Text(d.assumedAmount && adjusted[d.id] == nil ? "\(item.summary) · amount assumed, tap to change" : item.summary)
                                .dsFont(.caption)
                                .foregroundStyle(d.assumedAmount && adjusted[d.id] == nil ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                        } else {
                            Label("Tap to say how much", systemImage: "scalemass")
                                .dsFont(.caption)
                                .foregroundStyle(Tone.warning.textColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !d.alternatives.isEmpty {
                    Menu {
                        ForEach(d.alternatives) { alt in
                            Button(alt.displayName) { choose(alt, for: d) }
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Pick another match for \(d.phrase)")
                }
            } else {
                Button { query = MealDescription.read(d.phrase).food } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{201C}\(d.phrase)\u{201D}").dsFont(.body).foregroundStyle(.primary).lineLimit(2)
                        Label("No match. Tap to search for it by itself, packaged products included", systemImage: "magnifyingglass")
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choose(_ food: FoodItem, for d: DescribedFood) {
        guard let i = described.firstIndex(where: { $0.id == d.id }) else { return }
        var next = d.choosing(food)
        // Keep the other matches on offer, the old pick among them.
        next.alternatives = ([d.food].compactMap { $0 } + d.alternatives).filter { $0.id != food.id }
        described[i] = next
        adjusted[d.id] = nil
    }

    private func addDescribed() {
        let items = readyItems
        guard !items.isEmpty else { return }
        items.forEach(add)
        // Anything left without an amount or a match stays in the box to finish.
        let rest = described.filter { item(for: $0) == nil }.map(\.phrase)
        if rest.isEmpty { onClose() } else { query = rest.joined(separator: ", ") }
    }

    // MARK: Rows

    private func add(_ item: MealItem) {
        onAdd(item)
        added.append(item)
        logbook.notePortion(for: item.foodID, grams: item.grams, portion: item.portion)
    }

    /// The amount + adds in one tap: what was used last time, otherwise the food's usual measure.
    /// Nil when there's nothing to go on, so the amount is asked for.
    private func quickItem(_ food: FoodItem) -> MealItem? {
        if let saved = logbook.savedFood(for: food.id), let g = saved.lastGrams, g > 0 {
            return MealItem(food: food, grams: g, portion: saved.lastPortion)
        }
        let a = MealDescription.amount(for: food, parsed: MealDescription.Parsed(food: food.name))
        guard let g = a.grams, g > 0 else { return nil }
        return MealItem(food: food, grams: g,
                        portion: a.portion.map { FoodPortionMath.label(quantity: a.quantity, portion: $0) })
    }

    private func row(_ food: FoodItem) -> some View {
        let favourite = logbook.savedFood(for: food.id)?.favourite ?? false
        let quick = quickItem(food)
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
            Button {
                if let quick { add(quick) } else { selected = food }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.food)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(quick.map { "Add \($0.summary)" } ?? "Choose an amount")
            #if os(macOS)
            .help(quick.map { "Add \($0.summary)" } ?? "Choose an amount")
            #endif
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

    private func searchOnline(_ q: String) async {
        guard q.count >= 2 else { return }
        onlineState = .loading
        do {
            let items = try await FoodSources.searchOnline(q)
            guard q == trimmed else { return }
            let known = Set(hits.map(\.id))
            online = items.filter { !known.contains($0.id) }
            onlineState = .done
        } catch {
            guard q == trimmed, !Task.isCancelled else { return }
            onlineState = .failed
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
