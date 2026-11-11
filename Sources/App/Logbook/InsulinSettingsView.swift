import SwiftUI

// Settings → Your Insulins, on the Mac and the iPhone: the insulins the log sheet offers as
// one-tap picks. Saved in the logbook, so they sync between devices.

/// The list, as a `Form` section.
struct InsulinListSection: View {
    @EnvironmentObject var logbook: LogbookStore
    @EnvironmentObject var settings: AppSettings

    @State private var editing: InsulinEditTarget?
    @State private var tidiedCount: Int?

    private var viaPump: Bool { settings.therapy == .pump }

    var body: some View {
        Section {
            if logbook.insulins.isEmpty {
                Text("Add the insulins you take, and pick one with a tap each time you log a dose. Any name you type when you log is added here too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let preferred = logbook.preferredInsulin(viaPump: viaPump)
            ForEach(logbook.insulins) { insulin in
                Button { editing = InsulinEditTarget(insulin: insulin) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: insulin.kind.isBolus ? "syringe" : "syringe.fill")
                            .foregroundStyle(Palette.insulin)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(insulin.name).foregroundStyle(.primary)
                            Text(insulin.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if insulin.id == preferred?.id {
                            Text("Picked first").font(.caption).foregroundStyle(.secondary)
                        }
                        if viaPump && !InsulinKind.pumpKinds.contains(insulin.kind) {
                            Text("Not for a pump").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
            }
            .onDelete { offsets in offsets.map { logbook.insulins[$0].id }.forEach(logbook.deleteInsulin(id:)) }
            .onMove { logbook.moveInsulins(from: $0, to: $1) }

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
            Text("Your Insulins")
        } footer: {
            Text("The log sheet picks the mealtime insulin you logged last, or the first one here. Shared with GlucOS on your other devices.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { target in
            InsulinEditor(existing: target.insulin, viaPump: viaPump) { editing = nil }
                .environmentObject(logbook)
        }
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
