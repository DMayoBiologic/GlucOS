import SwiftUI

/// The log sheet's Tags row, on the Mac and the iPhone: the built-in tags and the user's own as
/// chips, plus "New Tag" to type one. Tags only help find entries later (`LogbookTags`).
struct LogTagPicker: View {
    @Binding var picked: [String]
    /// What to offer: `LogbookTags.choices`.
    let choices: [String]
    /// Played on each tap (the iPhone's haptic). Nothing on the Mac.
    var onToggle: () -> Void = {}

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tags", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { tag in chip(tag) }
                    if adding { field } else { addButton }
                }
                .padding(.vertical, 1)
            }
            Text("Tags help you find entries in the Logbook. They don't change Insights or the forecast.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ tag: String) -> some View {
        let on = LogbookTags.contains(picked, tag)
        return Button {
            picked = LogbookTags.toggling(tag, in: picked)
            onToggle()
        } label: {
            Label(tag, systemImage: LogbookTags.symbol(tag))
        }
        .buttonStyle(ChipButtonStyle(selected: on, tint: Palette.context))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel("Tag \(tag)")
    }

    private var addButton: some View {
        Button {
            adding = true
            typing = true
        } label: {
            Label("New Tag", systemImage: "plus")
        }
        .buttonStyle(ChipButtonStyle())
        .disabled(picked.count >= LogbookTags.maxPerEntry)
        .accessibilityHint("Type a tag of your own")
    }

    private var field: some View {
        TextField("Tag", text: $draft, prompt: Text("New tag"))
            .textFieldStyle(.plain)
            .font(.callout)
            .frame(width: 120)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .focused($typing)
            .autocorrectionDisabled()
            .onSubmit(commit)
            .onChange(of: typing) { _, now in if !now { commit() } }
            .onChange(of: draft) { _, now in
                if now.count > LogbookTags.maxLength { draft = String(now.prefix(LogbookTags.maxLength)) }
            }
    }

    /// Adds what was typed (if anything) and goes back to the "New Tag" button.
    private func commit() {
        if let t = LogbookTags.cleaned(draft), !LogbookTags.contains(picked, t) {
            picked = LogbookTags.normalised(picked + [t])
            onToggle()
        }
        draft = ""
        adding = false
    }
}
