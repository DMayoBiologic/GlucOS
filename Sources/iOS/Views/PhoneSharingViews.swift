import SwiftUI
import UIKit

// Sharing live readings: the owner's share links (send one in Messages, stop it any time) and the
// readings of people this phone follows. See docs/Sharing.md.

// MARK: - Owner: share links

struct PhoneSharingView: View {
    @EnvironmentObject var sharing: OwnerSharing
    @Environment(\.dismiss) private var dismiss
    @State private var showsNew = false
    var showsDone = true

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Palette.brandGradient)
                    Text("Share your glucose live")
                        .dsFont(.sectionTitle)
                    Text("Send a link in Messages. Anyone with it sees your reading, trend and the last 3 hours, updated every minute. With GlucOS on their iPhone it stays on their Lock Screen too. Links can expire, and you can stop one at any time.")
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Space.xs)
                Button {
                    showsNew = true
                } label: {
                    Label("New Share Link", systemImage: "plus.message.fill")
                }
                .disabled(!sharing.isAvailable)
            } footer: {
                if !sharing.isAvailable {
                    Text("Sharing goes through your push relay. Set it up in Settings first.")
                }
            }

            if let error = sharing.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor) }
            }

            if !sharing.shares.isEmpty {
                Section("Sharing now") {
                    ForEach(sharing.shares) { share in
                        ShareRow(share: share)
                    }
                }
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .refreshable { await sharing.refresh() }
        .task { await sharing.refresh() }
        .sheet(isPresented: $showsNew) {
            NavigationStack { NewShareView() }
                .presentationDetents([.medium, .large])
        }
    }
}

private struct ShareRow: View {
    @EnvironmentObject var sharing: OwnerSharing
    let share: ShareInfo
    @State private var confirmsStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(share.label).dsFont(.headline)
                Spacer()
                if let url = sharing.link(for: share) {
                    SwiftUI.ShareLink(item: url, message: Text(ShareMessage.text(label: share.label))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Send link again")
                }
            }
            Text(details).dsFont(.caption).foregroundStyle(.secondary)
            Button("Stop Sharing", role: .destructive) { confirmsStop = true }
                .buttonStyle(.borderless)
                .dsFont(.callout)
        }
        .padding(.vertical, DS.Space.xxs)
        .confirmationDialog("Stop sharing with this link?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive) { Task { await sharing.stop(share) } }
        } message: {
            Text("The link stops working straight away and followers' Lock Screen cards are removed.")
        }
    }

    private var details: String {
        var parts: [String] = []
        if let e = share.expiresAt {
            parts.append("Ends \(Date(timeIntervalSince1970: e).formatted(.relative(presentation: .named)))")
        } else {
            parts.append("Until you stop it")
        }
        parts.append(share.followers == 1 ? "1 iPhone following" : "\(share.followers) iPhones following")
        if let v = share.lastViewedAt {
            parts.append("opened \(Date(timeIntervalSince1970: v).formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

enum ShareMessage {
    static func text(label: String) -> String {
        "Follow \(label == "GlucOS" ? "my" : "\(label)'s") glucose live in GlucOS:"
    }
}

/// Make a link, then send it.
struct NewShareView: View {
    @EnvironmentObject var sharing: OwnerSharing
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareLabel") private var label = ""
    @AppStorage("shareDuration") private var duration: ShareDuration = .day
    @State private var working = false
    @State private var made: URL?

    private var cleanLabel: String {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "GlucOS" : t
    }

    var body: some View {
        Form {
            if let made {
                Section {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Label("Link ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .dsFont(.headline)
                        Text("Send it in Messages. It opens a live view in any browser, and on an iPhone with GlucOS it can go on their Lock Screen.")
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    SwiftUI.ShareLink(item: made, message: Text(ShareMessage.text(label: cleanLabel)),
                                      preview: SharePreview("\(cleanLabel == "GlucOS" ? "My" : "\(cleanLabel)'s") glucose, live")) {
                        Label("Send Link", systemImage: "message.fill")
                    }
                    Button {
                        UIPasteboard.general.url = made
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
            } else {
                Section {
                    TextField("Your name", text: $label, prompt: Text("Shown to followers"))
                        .textContentType(.givenName)
                    Picker("Link lasts", selection: $duration) {
                        ForEach(ShareDuration.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Anyone you send the link to, or who it's forwarded to, can see your readings until it ends or you stop it.")
                }
                if let error = sharing.error {
                    Section { Text(error).foregroundStyle(Tone.warning.textColor) }
                }
                Section {
                    Button {
                        working = true
                        Task {
                            made = await sharing.create(label: cleanLabel, duration: duration)
                            working = false
                        }
                    } label: {
                        HStack {
                            Text("Create Link")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working)
                }
            }
        }
        .navigationTitle("New Share Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(made == nil ? "Cancel" : "Done") { dismiss() } } }
    }
}

// MARK: - Follower: someone else's readings

/// Someone this phone follows: their reading, trend and last 3 hours.
struct PhoneFollowingCard: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let card = follows.snapshots[follow.id]?.card
            let ended = follows.ended.contains(follow.id)
            let stale = card?.isStale(at: now) ?? true
            let tone: Tone = ended || stale ? .stale : .glucose(card?.range ?? .inRange)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Eyebrow(title: follow.label, systemImage: "person.fill")
                    Spacer(minLength: 0)
                    if let card, !ended { RangeBadge(range: card.range, stale: stale) }
                    Menu {
                        Toggle("On Lock Screen", isOn: Binding(
                            get: { follow.liveActivity },
                            set: { on in Task { await follows.setLiveActivity(on, for: follow) } }))
                        Button("Stop Following", role: .destructive) { Task { await follows.remove(follow) } }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.body)
                    }
                    .accessibilityLabel("Options for \(follow.label)")
                }
                if ended {
                    Text("\(follow.label) stopped sharing, or the link ended.")
                        .dsFont(.callout).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { Task { await follows.remove(follow) } }
                        .dsFont(.callout)
                } else if let card {
                    HStack(alignment: .center, spacing: DS.Space.md) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                                Text(card.valueText)
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                                    .strikethrough(stale, color: .secondary)
                                Text(card.glucoseUnit.label).dsFont(.label).foregroundStyle(.secondary)
                            }
                            HStack(spacing: DS.Space.xs) {
                                if !stale, let delta = card.deltaText { Text(delta).monospacedDigit() }
                                Text(card.readingDate, style: .relative) + Text(" ago")
                            }
                            .dsFont(.caption)
                            .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
                        }
                        Spacer(minLength: DS.Space.sm)
                        TrendDial(trend: stale ? .unknown : card.glucoseTrend, tint: tone.color, size: 52)
                            .opacity(stale ? 0.6 : 1)
                            .accessibilityHidden(true)
                    }
                    GlucoseChart(readings: card.historyReadings, unit: card.glucoseUnit, lowMgdl: card.lowMgdl,
                                 highMgdl: card.highMgdl, hours: GlucoseActivityState.historyHours, showAxes: false,
                                 latestIsStale: stale)
                        .frame(height: 70)
                } else {
                    Text(follows.errors[follow.id] ?? "Waiting for \(follow.label)'s first reading…")
                        .dsFont(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { DSSurface(style: .tinted(tone), radius: DS.Radius.card) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Paste a link someone sent.
struct AddFollowView: View {
    @EnvironmentObject var follows: FollowStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Share link", text: $text, prompt: Text("https://dmayobiologic.github.io/GlucOS/share/#…"), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Paste", systemImage: "doc.on.clipboard") {
                    text = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
                }
            } footer: {
                Text("Opening a GlucOS share link in Messages and tapping Open in GlucOS does this for you.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.warning.textColor) } }
            Section {
                Button {
                    guard let token = FollowLink.token(in: text) else {
                        error = "That isn't a GlucOS share link."
                        return
                    }
                    working = true
                    Task {
                        do {
                            try await follows.add(token: token)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    HStack {
                        Text("Follow")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || text.isEmpty)
            }
        }
        .navigationTitle("Follow Someone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// The home screen for a phone that only follows other people (no LibreLinkUp account of its own).
struct FollowingHomeView: View {
    @EnvironmentObject var follows: FollowStore
    @State private var showsAdd = false
    @State private var showsSignIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    ForEach(follows.follows) { PhoneFollowingCard(follow: $0) }
                    Text("Not a medical device. Readings can be delayed; confirm with the sensor app before acting.")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.xxl)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .refreshable { await follows.refresh(canStart: true) }
            .navigationTitle("Following")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Follow Someone…", systemImage: "plus") { showsAdd = true }
                        Button("Sign In With LibreLinkUp…", systemImage: "drop.fill") { showsSignIn = true }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showsAdd) { NavigationStack { AddFollowView() } }
            .sheet(isPresented: $showsSignIn) { NavigationStack { PhoneSignInView() } }
        }
    }
}

/// The people this phone follows, for Settings.
struct FollowingSettingsSection: View {
    @EnvironmentObject var follows: FollowStore
    @State private var showsAdd = false

    var body: some View {
        Section {
            ForEach(follows.follows) { f in
                Toggle(isOn: Binding(get: { f.liveActivity },
                                     set: { on in Task { await follows.setLiveActivity(on, for: f) } })) {
                    VStack(alignment: .leading) {
                        Text(f.label)
                        Text(follows.ended.contains(f.id) ? "Sharing ended" : "On Lock Screen")
                            .dsFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Stop Following", role: .destructive) { Task { await follows.remove(f) } }
                }
            }
            Button("Follow Someone…", systemImage: "plus") { showsAdd = true }
        } header: {
            Text("Following")
        } footer: {
            Text("Readings people have shared with you. Swipe to stop following.")
        }
        .sheet(isPresented: $showsAdd) { NavigationStack { AddFollowView() } }
    }
}
