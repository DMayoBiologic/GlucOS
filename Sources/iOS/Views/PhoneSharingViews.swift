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
                    Text("Send a link in Messages. Anyone with it sees your reading and trend, updated every minute. With GlucOS on their iPhone they see your chart, forecast, time in range and recent logbook too, your reading stays on their Lock Screen, and they can check in on you. Links can expire, and you can stop one at any time.")
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
            Toggle(isOn: Binding(get: { share.logbookShown },
                                 set: { on in Task { await sharing.setShowsLogbook(on, for: share) } })) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Show my logbook").dsFont(.callout)
                    Text("Insulin, food, sites and moments from the last two days. Notes stay private.")
                        .dsFont(.caption).foregroundStyle(.secondary)
                }
            }
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

/// Make a link, then send it.
struct NewShareView: View {
    @EnvironmentObject var sharing: OwnerSharing
    @Environment(\.dismiss) private var dismiss
    // In the app group, so the Messages app starts from the same name and length.
    @AppStorage("shareLabel", store: SharedStore.defaults) private var label = ""
    @AppStorage("shareDuration", store: SharedStore.defaults) private var duration: ShareDuration = .day
    @AppStorage("shareShowsLogbook") private var showsLogbook = true
    @State private var working = false
    @State private var made: URL?

    private var cleanLabel: String { ShareMessage.cleanLabel(label) }

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
                                      preview: SharePreview("\(ShareMessage.title(label: cleanLabel)), live")) {
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
                    Toggle("Show my logbook", isOn: $showsLogbook)
                } footer: {
                    Text("Anyone you send the link to, or who it's forwarded to, can see your readings until it ends or you stop it. With the logbook on, followers in GlucOS also see your insulin, food, sites and moments from the last two days, without notes. You can change this later.")
                }
                if let error = sharing.error {
                    Section { Text(error).foregroundStyle(Tone.warning.textColor) }
                }
                Section {
                    Button {
                        working = true
                        Task {
                            made = await sharing.create(label: cleanLabel, duration: duration, showsLogbook: showsLogbook)
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

/// Someone this phone follows, on the owner's own home screen: their reading, trend and last 3
/// hours, opening their whole screen, with Check in under it.
struct PhoneFollowingCard: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow
    @State private var confirmsStop = false

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
                        Toggle("Alerts", isOn: Binding(
                            get: { follow.alerts },
                            set: { on in Task { await follows.setAlerts(on, for: follow) } }))
                        Button("Stop Following…", role: .destructive) { confirmsStop = true }
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
                    // The reading opens their whole screen: chart, logbook, time in range.
                    NavigationLink(value: FollowRoute.person(follow.id)) {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            SharedReadingView(card: card, now: now)
                            FollowRail(card: card, stale: stale)
                            HStack(spacing: DS.Space.xs) {
                                Text("Chart, logbook and time in range")
                                Image(systemName: "chevron.right").imageScale(.small)
                            }
                            .dsFont(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(follow.label)'s readings, logbook and time in range")
                    FollowCheckInRow(follow: follow, card: card)
                } else {
                    Text(follows.errors[follow.id] ?? "Waiting for \(follow.label)'s first reading…")
                        .dsFont(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { FollowCardSurface(tone: tone) }
            // Their urgent low reads without colour too: the octagon pill, the words and a rim.
            .urgentRim(!ended && !stale && card?.range == .urgentLow,
                       in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .accessibilityElement(children: .contain)
        }
        .confirmationDialog("Stop following \(follow.label)?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Following", role: .destructive) { Task { await follows.remove(follow) } }
        } message: {
            Text("Their card and alerts go from this iPhone. To follow again you'll need a new link from them.")
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
                // Typing clears the last error; a paste that fails keeps its error showing.
                TextField("Share link", text: Binding(get: { text }, set: { text = $0; error = nil }), prompt: Text("https://gluc-os-seven.vercel.app/share/#…"), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                // PasteButton reads the clipboard without iOS asking "Allow Paste?" every time, and a
                // pasted link is followed straight away.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    Task { @MainActor in
                        text = pasted
                        follow()
                    }
                }
                .buttonBorderShape(.capsule)
            } footer: {
                Text("Opening a GlucOS share link in Messages and tapping Open in GlucOS does this for you.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.warning.textColor) } }
            Section {
                Button(action: follow) {
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

    private func follow() {
        guard !working else { return }
        guard let token = FollowLink.token(in: text) else {
            error = "That isn't a GlucOS share link. Copy the whole link from Messages and try again."
            return
        }
        working = true
        error = nil
        Task {
            do {
                try await follows.add(token: token)
                Haptics.play(.done)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// A followed person's card background: the tinted surface with a strip of their range field down
/// its leading edge (docs/Redesign.md §7.2), which sweeps to the new colour when their range changes.
private struct FollowCardSurface: View {
    let tone: Tone

    var body: some View {
        DSSurface(style: .tinted(tone), radius: DS.Radius.card)
            .overlay {
                // Still (not `live`): a strip this thin shows no drift, and a list of followed
                // people shouldn't each run a timeline. Clipped on its own so the card keeps its shadow.
                RangeField(tone: tone, intensity: 2.2)
                    .frame(width: 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .allowsHitTesting(false)
            }
    }
}

/// Where a followed person's reading sits between urgent low and very high, with their own range.
private struct FollowRail: View {
    let card: GlucoseActivityState
    let stale: Bool

    var body: some View {
        RangeRail(mgdl: card.mgdl, lowMgdl: card.lowMgdl, highMgdl: card.highMgdl, stale: stale,
                  thickness: 5, unit: card.glucoseUnit)
            .padding(.vertical, DS.Space.xxs)
    }
}

/// The home screen for a phone that only follows other people (no sensor or LibreLinkUp account
/// of its own): the person it follows, shown the way they see themselves (`FollowPersonView`),
/// with Check in along the bottom. Following more than one person puts a row of them at the top
/// to switch between. No logging, no alerts of its own; their alerts come from the relay.
struct FollowingHomeView: View {
    @EnvironmentObject var follows: FollowStore
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.openURL) private var openURL
    @State private var showsAdd = false
    @State private var showsSettings = false
    @State private var stopping: Follow?
    @AppStorage("followSelected") private var selectedID = ""

    private var selected: Follow? {
        follows.follows.first { $0.id == selectedID } ?? follows.follows.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    if store.notificationsBlocked && follows.follows.contains(where: \.alerts) {
                        StatusBanner(severity: .critical, title: "Notifications are off for GlucOS",
                                     message: "Alerts and check-in answers for the people you follow can't reach you.",
                                     action: BannerAction(title: "Turn On") { openURL(AlertManager.notificationSettingsURL) },
                                     density: .compact)
                    }
                    if follows.follows.isEmpty {
                        FollowEmptyState { showsAdd = true }
                    } else {
                        if follows.follows.count > 1 {
                            FollowPicker(selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 }))
                        }
                        if let f = selected {
                            FollowPersonView(follow: f)
                                .id(f.id)
                                .transition(.opacity)
                        }
                    }
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
            .background { FollowBackdrop(follow: selected) }
            .refreshable { await follows.refresh(canStart: true) }
            .task { await store.checkNotificationPermission() }
            // Check in stays in reach however far down the screen is scrolled.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let f = selected, !follows.ended.contains(f.id), follows.snapshots[f.id]?.card != nil {
                    FollowCheckInBar(follow: f)
                }
            }
            .navigationTitle(selected?.label ?? "Following")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let f = selected {
                        FollowOptionsMenu(follow: f, onAdd: { showsAdd = true }, onStop: { stopping = f })
                    } else {
                        Button { showsAdd = true } label: { Image(systemName: "plus.circle") }
                            .accessibilityLabel("Follow someone")
                    }
                }
            }
            .navigationDestination(for: FollowRoute.self) { FollowRouteView(route: $0) }
            .sheet(isPresented: $showsAdd) { NavigationStack { AddFollowView() } }
            .sheet(isPresented: $showsSettings) { NavigationStack { FollowerSettingsView() } }
            .confirmationDialog("Stop following \(stopping?.label ?? "")?",
                                isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                                titleVisibility: .visible, presenting: stopping) { f in
                Button("Stop Following", role: .destructive) { Task { await follows.remove(f) } }
            } message: { _ in
                Text("Their card and alerts go from this iPhone. To follow again you'll need a new link from them.")
            }
        }
    }
}

/// The range field behind a followed person's screen, in their reading's colour.
struct FollowBackdrop: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let follow, let card = follows.snapshots[follow.id]?.card, !follows.ended.contains(follow.id) {
                let stale = card.isStale(at: ctx.date)
                PhoneBackdrop(tone: card.range.tone(stale: stale),
                              rapid: !stale && card.glucoseTrend.isRapid,
                              range: stale ? nil : card.range)
            } else {
                PhoneBackdrop(tone: .neutral)
            }
        }
    }
}

/// The toolbar menu for the person on screen: Lock Screen and alerts, follow someone else, stop.
struct FollowOptionsMenu: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow
    let onAdd: () -> Void
    let onStop: () -> Void

    var body: some View {
        Menu {
            Section(follow.label) {
                Toggle("On Lock Screen", isOn: Binding(get: { follow.liveActivity },
                                                       set: { on in Task { await follows.setLiveActivity(on, for: follow) } }))
                Toggle("Alerts", isOn: Binding(get: { follow.alerts },
                                               set: { on in Task { await follows.setAlerts(on, for: follow) } }))
            }
            Button("Follow Someone Else…", systemImage: "plus") { onAdd() }
            Button("Stop Following \(follow.label)…", systemImage: "person.crop.circle.badge.minus", role: .destructive) { onStop() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Options for \(follow.label)")
    }
}

/// The people this phone follows, side by side, each with their reading: tap one to see them.
/// The highlight slides to the one chosen.
private struct FollowPicker: View {
    @EnvironmentObject var follows: FollowStore
    @Binding var selection: String
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(follows.follows) { f in
                    chip(f)
                }
            }
            .padding(.vertical, DS.Space.xxs)
        }
        .haptic(.choice, trigger: selection)
    }

    private func chip(_ f: Follow) -> some View {
        let card = follows.snapshots[f.id]?.card
        let stale = card?.isStale() ?? true
        let tone: Tone = follows.ended.contains(f.id) || card == nil ? .stale : card!.range.tone(stale: stale)
        let on = f.id == selection
        let waiting = follows.checkIns[f.id]?.status == .noAnswer || follows.checkIns[f.id]?.status == .help
        return Button {
            DS.animate(.standard, reduceMotion: reduceMotion) { selection = f.id }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(tone.color).frame(width: 8, height: 8)
                Text(f.label).dsFont(.headline).lineLimit(1)
                if let card, !follows.ended.contains(f.id) {
                    Text(card.valueText)
                        .dsFont(.headline)
                        .monospacedDigit()
                        .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.textColor))
                        .contentTransition(.numericText(value: card.mgdl))
                }
                if waiting {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background {
                if on {
                    Capsule().fill(.background).shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "chip", in: highlight)
                } else {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(card.map { "\(f.label), \($0.glucoseUnit.format(mgdl: $0.mgdl, withUnit: true))" } ?? f.label)
    }
}

/// A followed person's screen pushed from the owner's own home (their following card).
struct FollowPersonScreen: View {
    @EnvironmentObject var follows: FollowStore
    let followID: String

    var body: some View {
        if let f = follows.follows.first(where: { $0.id == followID }) {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    FollowPersonView(follow: f)
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
            .background { FollowBackdrop(follow: f) }
            .refreshable { await follows.refresh(canStart: true) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !follows.ended.contains(f.id), follows.snapshots[f.id]?.card != nil { FollowCheckInBar(follow: f) }
            }
            .navigationTitle(f.label)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("No longer following", systemImage: "person.crop.circle.badge.xmark")
        }
    }
}

/// Where a `FollowRoute` goes.
struct FollowRouteView: View {
    let route: FollowRoute

    var body: some View {
        switch route {
        case .person(let id): FollowPersonScreen(followID: id)
        case .logbook(let id): FollowLogbookList(followID: id)
        }
    }
}

/// Before the first follow: how to get a link, and an example of what following looks like.
private struct FollowEmptyState: View {
    let paste: () -> Void
    @State private var showsExample = false

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            explainer
            if showsExample {
                ExampleFollowCard()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.brandGradient)
            Text("Follow someone's glucose").dsFont(.sectionTitle)
            Text("Ask them to send you a link from GlucOS: the Share button on their iPhone, or GlucOS in the Messages + menu. Tap the link in Messages and choose Open in GlucOS. You'll see their reading, chart, logbook and time in range here, their reading on your Lock Screen, and their low and high alerts. Check in asks them if they're okay whenever you're worried.")
                .dsFont(.callout)
                .foregroundStyle(.secondary)
            Button(action: paste) {
                Label("Add a Link", systemImage: "link.badge.plus")
                    .dsFont(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button(showsExample ? "Hide Example" : "See an Example") {
                withAnimation { showsExample.toggle() }
            }
            .dsFont(.callout)
            .frame(maxWidth: .infinity)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .standard, radius: DS.Radius.card) }
        .padding(.top, DS.Space.lg)
    }
}

/// Made-up readings showing what a followed person's card looks like. Nothing is fetched.
private struct ExampleFollowCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let card = Self.card(now: context.date)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Eyebrow(title: "Example", systemImage: "person.fill")
                    Spacer(minLength: 0)
                    RangeBadge(range: card.range, stale: false)
                }
                SharedReadingView(card: card, now: context.date)
                FollowRail(card: card, stale: false)
                Text("Example readings, not a real person's.")
                    .dsFont(.caption).foregroundStyle(.secondary)
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { FollowCardSurface(tone: .glucose(card.range)) }
            .accessibilityElement(children: .contain)
        }
    }

    static func card(now: Date) -> GlucoseActivityState {
        let steps = Int(GlucoseActivityState.historyHours * 12)
        var values: [Int] = []
        for i in 0...steps {
            let x = Double(i)
            let wave: Double = 34.0 * sin((x + 10.0) / 7.0)
            let drift: Double = x * 0.4
            values.append(Int(118.0 + wave - drift))
        }
        let history: [Int?] = values.map { Optional($0) }
        let last = Double(values[values.count - 1])
        let previous = Double(values[values.count - 2])
        return GlucoseActivityState(mgdl: last, trend: 3, readingAt: now.timeIntervalSince1970 - 60,
                                    deltaMgdl: last - previous, unit: GlucoseUnit.mmol.rawValue,
                                    lowMgdl: 70, highMgdl: 180, history: history)
    }
}

/// Settings for a phone that only follows: who it follows, notifications, and switching to
/// wearing a sensor.
struct FollowerSettingsView: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("phoneMode") private var mode: PhoneMode = .unset
    @State private var showsSignIn = false

    var body: some View {
        Form {
            FollowingSettingsSection()
            Section {
                Button("Notification Settings", systemImage: "bell.badge") { openURL(AlertManager.notificationSettingsURL) }
            } footer: {
                Text("Alerts for the people you follow come as time-sensitive notifications. Allow them in Focus modes you use at night.")
            }
            Section {
                Button("I Wear a Sensor Too", systemImage: "drop.fill") { showsSignIn = true }
            } footer: {
                Text("Sign in with LibreLinkUp to see your own readings, log, and get your own alerts. You'll keep following everyone here.")
            }
            DiagnosticsSettingsSection()
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("Privacy", destination: URL(string: "https://gluc-os-seven.vercel.app/privacy/")!)
                Text("Not a medical device. Readings and alerts can be delayed or missed; confirm with the sensor app before acting.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showsSignIn) { NavigationStack { PhoneSignInView() } }
    }
}

/// The people this phone follows, for Settings.
struct FollowingSettingsSection: View {
    @EnvironmentObject var follows: FollowStore
    @State private var showsAdd = false
    @State private var stopping: Follow?

    var body: some View {
        Section {
            ForEach(follows.follows) { f in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text(f.label).dsFont(.headline)
                        Spacer()
                        if follows.ended.contains(f.id) {
                            Text("Sharing ended").dsFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("On Lock Screen", isOn: Binding(get: { f.liveActivity },
                                                           set: { on in Task { await follows.setLiveActivity(on, for: f) } }))
                    Toggle("Alerts", isOn: Binding(get: { f.alerts },
                                                   set: { on in Task { await follows.setAlerts(on, for: f) } }))
                }
                .swipeActions {
                    Button("Stop Following", role: .destructive) { stopping = f }
                }
            }
            Button("Follow Someone…", systemImage: "plus") { showsAdd = true }
            if !follows.follows.isEmpty {
                LabeledContent("Your name") {
                    TextField("For check-ins", text: $follows.myName)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                }
            }
        } header: {
            Text("Following")
        } footer: {
            Text("Readings people have shared with you. Alerts are their lows, highs and missing data, sent even when GlucOS is closed. Check in, at the bottom of their screen at any time (and on their Lock Screen card when they're low), asks if they're okay and shows their answer. Your name tells them who's asking. Swipe to stop following.")
        }
        .sheet(isPresented: $showsAdd) { NavigationStack { AddFollowView() } }
        .confirmationDialog("Stop following \(stopping?.label ?? "")?",
                            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { f in
            Button("Stop Following", role: .destructive) { Task { await follows.remove(f) } }
        } message: { _ in
            Text("Their card and alerts go from this iPhone. To follow again you'll need a new link from them.")
        }
    }
}
