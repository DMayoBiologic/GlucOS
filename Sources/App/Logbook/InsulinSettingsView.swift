import SwiftUI

// Settings → Your Insulins, on the Mac and the iPhone: the insulins the log sheet offers as
// one-tap picks. Saved in the logbook, so they sync between devices.

/// The list, as a `Form` section.
struct InsulinListSection: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings

    @State private var editing: InsulinEditTarget?
    @State private var tidiedCount: Int?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    private var viaPump: Bool { settings.therapy == .pump }

    /// The system's rows under VoiceOver (its move actions stay as they were) and in iPhone Edit
    /// mode (delete buttons and grab handles); the lifting rows otherwise.
    private var usesSystemList: Bool {
        #if os(iOS)
        if editMode?.wrappedValue.isEditing == true { return true }
        #endif
        return voiceOver
    }

    var body: some View {
        Section {
            if logbook.insulins.isEmpty {
                Text("Add the insulins you take, and pick one with a tap each time you log a dose. Any name you type when you log is added here too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let preferred = logbook.preferredInsulin(viaPump: viaPump)
            if usesSystemList {
                // VoiceOver and the iPhone's Edit mode keep the system rows, with their own move
                // and delete actions, exactly as before.
                ForEach(logbook.insulins) { insulin in
                    Button { editing = InsulinEditTarget(insulin: insulin) } label: {
                        InsulinRowLabel(insulin: insulin, preferred: insulin.id == preferred?.id, viaPump: viaPump)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit")
                }
                .onDelete { offsets in offsets.map { logbook.insulins[$0].id }.forEach(logbook.deleteInsulin(id:)) }
                .onMove { logbook.moveInsulins(from: $0, to: $1) }
            } else if !logbook.insulins.isEmpty {
                InsulinReorderRows(
                    insulins: logbook.insulins,
                    onTap: { editing = InsulinEditTarget(insulin: $0) },
                    onMove: { logbook.moveInsulins(from: $0, to: $1) },
                    onDelete: { logbook.deleteInsulin(id: $0.id) }
                ) { insulin in
                    InsulinRowLabel(insulin: insulin, preferred: insulin.id == preferred?.id, viaPump: viaPump)
                }
                .listRowInsets(EdgeInsets())
            }

            Button { editing = InsulinEditTarget(insulin: nil) } label: {
                Label("Add Insulin", systemImage: "plus.circle")
            }

            let respellings = logbook.insulinRespellingCount
            if respellings > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        tidiedCount = logbook.normaliseInsulinNames()
                    } label: {
                        Label("Use these spellings in \(respellings) earlier \(respellings == 1 ? "entry" : "entries")",
                              systemImage: "textformat")
                    }
                    Text("Some logged doses or presets name one of these insulins in another way, like “Novorapid” for “NovoRapid”. Only the name changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let tidiedCount {
                Label("Updated \(tidiedCount) \(tidiedCount == 1 ? "entry" : "entries")", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader("Your Insulins", systemImage: "cross.vial")
                .settingsAnchor(.insulins)
        } footer: {
            Text("The log sheet picks the mealtime insulin you logged last, or the first one here. Shared with GlucOS on your other devices.")
                .foregroundStyle(.secondary)
        }
        .settingsSection("Your Insulins")
        .sheet(item: $editing) { target in
            InsulinEditor(existing: target.insulin, viaPump: viaPump) { editing = nil }
                .environmentObject(logbook)
        }
    }
}

/// One saved insulin's row: its icon, name and summary.
struct InsulinRowLabel: View {
    let insulin: SavedInsulin
    let preferred: Bool
    let viaPump: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: insulin.kind.isBolus ? "syringe" : "syringe.fill")
                .foregroundStyle(Palette.insulin)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(insulin.name).foregroundStyle(.primary)
                Text(insulin.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if preferred {
                Text("Picked first").font(.caption).foregroundStyle(.secondary)
            }
            if viaPump && !InsulinKind.pumpKinds.contains(insulin.kind) {
                Text("Not for a pump").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The saved insulins as rows you can pick up and drag to a new place (`RowReorderDrag`, round
/// 97). On iPhone a row lifts after a short rest of the finger, with a light tap, and taps again as
/// it drops; on the Mac it lifts once the pointer drags it a few points. While it's held it grows
/// to 1.03x with a soft shadow and follows the finger or pointer, and the rows it passes slide
/// aside to show where it will land. Under Reduce Motion only the shadow shows and the rows jump.
/// Nothing animates until a row is picked up.
struct InsulinReorderRows<RowLabel: View>: View {
    let insulins: [SavedInsulin]
    let onTap: (SavedInsulin) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onDelete: (SavedInsulin) -> Void
    @ViewBuilder let label: (SavedInsulin) -> RowLabel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var picked: UUID?
    /// Where the picked-up row started.
    @State private var from = 0
    /// True while a finger or pointer holds a row; resets by itself if the system cancels the
    /// gesture (a call coming in, the sheet closing), so a row is never left lifted.
    @GestureState private var holding = false
    @State private var translation: Double = 0
    @State private var target = 0
    @State private var heights: [UUID: Double] = [:]
    /// The one row whose Delete is swiped open (iPhone).
    @State private var swipeOpen: UUID?

    private var rowHeights: [Double] { insulins.map { heights[$0.id] ?? 44 } }

    private var pickedIndex: Int? { picked.flatMap { id in insulins.firstIndex { $0.id == id } } }

    private var slide: Animation? {
        reduceMotion ? nil : .snappy(duration: RowReorderDrag.duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(insulins.enumerated()), id: \.element.id) { index, insulin in
                row(insulin, at: index)
            }
        }
        .onChange(of: holding) { _, now in
            if !now { drop() }
        }
    }

    private func row(_ insulin: SavedInsulin, at index: Int) -> some View {
        let lifted = picked == insulin.id
        let look = RowReorderDrag.look(lifted: lifted, reduceMotion: reduceMotion,
                                       increasedContrast: contrast == .increased)
        let shift = pickedIndex.map { RowReorderDrag.shift(of: index, from: $0, target: target, heights: rowHeights) } ?? 0
        return VStack(spacing: 0) {
            if index > 0 {
                Divider().padding(.leading, Self.dividerInset).opacity(lifted ? 0 : 1)
            }
            swipeable(insulin) {
                label(insulin)
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { heights[insulin.id] = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in heights[insulin.id] = h }
            }
        }
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.controlBackground)
                    .shadow(color: .black.opacity(look.shadowOpacity), radius: RowReorderDrag.shadowRadius,
                            y: RowReorderDrag.shadowY)
            }
        }
        .scaleEffect(look.scale)
        .offset(y: lifted ? translation : shift)
        .zIndex(lifted ? 1 : 0)
        .animation(slide, value: shift)
        .animation(slide, value: look)
        .onTapGesture { onTap(insulin) }
        .gesture(pickup(insulin, at: index))
        #if os(macOS)
        .contextMenu {
            Button("Edit…") { onTap(insulin) }
            Button("Delete", role: .destructive) { onDelete(insulin) }
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Edit")
        .accessibilityAction { onTap(insulin) }
    }

    /// On iPhone, swipe left to delete, as the system rows did (the Logbook's own swipe, Delete
    /// only). The row's background covers the red action until it slides.
    @ViewBuilder
    private func swipeable<Content: View>(_ insulin: SavedInsulin, @ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        content()
            .background(Palette.controlBackground)
            .phoneSwipeToDelete(insulin.id, openID: $swipeOpen, reduceMotion: reduceMotion) { onDelete(insulin) }
        #else
        content()
        #endif
    }

    #if os(iOS)
    private static var horizontalPadding: CGFloat { 20 }
    private static var verticalPadding: CGFloat { 8 }
    private static var dividerInset: CGFloat { 50 }
    #else
    private static var horizontalPadding: CGFloat { 10 }
    private static var verticalPadding: CGFloat { 6 }
    private static var dividerInset: CGFloat { 40 }
    #endif

    #if os(iOS)
    private func pickup(_ insulin: SavedInsulin, at index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: RowReorderDrag.pickupDelay)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if picked == nil { lift(insulin, at: index) }
                    follow(drag?.translation.height ?? 0)
                default:
                    break
                }
            }
            .onEnded { _ in drop() }
    }
    #else
    private func pickup(_ insulin: SavedInsulin, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: RowReorderDrag.macPickupDistance, coordinateSpace: .global)
            .updating($holding) { _, state, _ in state = true }
            .onChanged { drag in
                if picked == nil { lift(insulin, at: index) }
                follow(drag.translation.height)
            }
            .onEnded { _ in drop() }
    }
    #endif

    private func lift(_ insulin: SavedInsulin, at index: Int) {
        from = index
        target = index
        translation = 0
        picked = insulin.id
        #if os(iOS)
        Haptics.play(.rowPicked)
        #endif
    }

    private func follow(_ dy: Double) {
        guard picked != nil else { return }
        // Kept inside the list, so the row never slides out past the first or last place.
        let heights = rowHeights
        let above = heights.prefix(from).reduce(0, +)
        let below = heights.dropFirst(from + 1).reduce(0, +)
        translation = min(max(dy, -above), below)
        let next = RowReorderDrag.target(from: from, translation: translation, heights: heights)
        if next != target { target = next }
    }

    private func drop() {
        guard picked != nil else { return }
        let index = from
        let destination = RowReorderDrag.moveDestination(from: index, target: target)
        // The row settles from under the finger into its new place while the list reorders.
        var transaction = Transaction(animation: slide)
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            if let destination { onMove(IndexSet(integer: index), destination) }
            picked = nil
            translation = 0
            target = 0
        }
        #if os(iOS)
        Haptics.play(.rowDropped)
        #endif
    }
}

struct InsulinEditTarget: Identifiable {
    let id = UUID()
    let insulin: SavedInsulin?
}

/// Adds or edits one insulin.
struct InsulinEditor: View {
    @EnvironmentObject var logbook: LogbookStore

    let existing: SavedInsulin?
    let viaPump: Bool
    let onClose: () -> Void

    @State private var name: String
    @State private var kind: InsulinKind
    @State private var doseStep: Double?
    @State private var confirmingDelete = false

    init(existing: SavedInsulin?, viaPump: Bool, onClose: @escaping () -> Void) {
        self.existing = existing
        self.viaPump = viaPump
        self.onClose = onClose
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: existing?.kind ?? .rapid)
        _doseStep = State(initialValue: existing?.doseStep)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Another saved insulin with the same name.
    private var duplicate: SavedInsulin? {
        guard let m = logbook.savedInsulin(named: trimmed), m.id != existing?.id else { return nil }
        return m
    }

    private var canSave: Bool { !trimmed.isEmpty && duplicate == nil }

    private var kinds: [InsulinKind] {
        var list = viaPump ? InsulinKind.pumpKinds : InsulinKind.allCases
        if !list.contains(kind) { list.append(kind) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(kind.examples))
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .autocorrectionDisabled()
                    if let duplicate {
                        Text("\(duplicate.name) is already in your list.")
                            .font(.caption)
                            .foregroundStyle(Tone.warning.textColor)
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(kinds) { Text($0.title).tag($0) }
                    }
                    Picker("Dose step", selection: $doseStep) {
                        Text("Usual (\(LogFormat.units(InsulinLibrary.defaultStep(viaPump: viaPump))))").tag(Double?.none)
                        ForEach(InsulinLibrary.doseSteps, id: \.self) { step in
                            Text(LogFormat.units(step)).tag(Double?.some(step))
                        }
                    }
                } footer: {
                    Text("Dose step is how far − and + move the units when you log this insulin, e.g. 0.5 u for a half-unit pen.")
                        .foregroundStyle(.secondary)
                }
                if existing != nil {
                    Section {
                        Button("Delete Insulin", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Doses already logged keep their insulin name.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Insulin" : "Edit Insulin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(existing?.name ?? "this insulin")?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    if let existing { logbook.deleteInsulin(id: existing.id) }
                    onClose()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 280, idealHeight: 320)
        #endif
    }

    private func save() {
        guard canSave else { return }
        var insulin = existing ?? SavedInsulin(name: trimmed, kind: kind)
        // A new name can work out to the id of one that was renamed since.
        if existing == nil, logbook.insulins.contains(where: { $0.id == insulin.id }) { insulin.id = UUID() }
        insulin.name = trimmed
        insulin.kind = kind
        insulin.doseStep = doseStep
        logbook.saveInsulin(insulin)
        onClose()
    }
}

#if os(iOS)
/// Settings → Your Insulins on iPhone.
struct PhoneInsulinsScreen: View {
    var body: some View {
        Form { InsulinListSection() }
            .navigationTitle("Your Insulins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
    }
}
#endif
