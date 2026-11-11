import Messages
import SwiftUI

struct MessagesRootView: View {
    @EnvironmentObject var model: MessagesModel

    var body: some View {
        Group {
            if model.style == .transcript {
                LiveBubbleView()
            } else if model.token != nil {
                // A live bubble was tapped: the same card, bigger, with a way to follow.
                ScrollView { SelectedShareView().padding(DS.Space.lg) }
            } else {
                ScrollView { ComposerView().padding(DS.Space.lg) }
            }
        }
        .modifier(PhoneTextScale())
    }
}

// MARK: - The drawer: send your glucose

struct ComposerView: View {
    @EnvironmentObject var model: MessagesModel
    // Shared with the app's New Share Link screen.
    @AppStorage("shareLabel", store: SharedStore.defaults) private var label = ""
    @AppStorage("shareDuration", store: SharedStore.defaults) private var duration: ShareDuration = .eightHours
    @FocusState private var nameFocused: Bool

    /// The lengths that make sense from a chat. A week or longer is for the app.
    private static let durations: [ShareDuration] = [.hour, .eightHours, .day, .untilStopped]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if !model.relay.isConfigured {
                Eyebrow(title: "Share your glucose", systemImage: "dot.radiowaves.left.and.right")
                Text("Sharing needs GlucOS's push relay, which keeps the reading live after you send it. Open GlucOS and sign in with the LibreLinkUp account your relay uses, or set it up in Settings. To follow someone, open the link they sent.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                Button("Open GlucOS") { model.openApp(URL(string: "glucos://open")) }
                    .buttonStyle(.ds(.primary, size: .large))
            } else {
                HStack(spacing: DS.Space.sm) {
                    Eyebrow(title: "Share your glucose, live", systemImage: "dot.radiowaves.left.and.right")
                    Spacer(minLength: 0)
                    if let card = model.localCard {
                        RangeBadge(range: card.range, stale: card.isStale())
                    }
                }
                if let card = model.localCard {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        SharedReadingView(card: card, now: context.date, valueSize: 34, dialSize: 40, chartHeight: 0)
                    }
                }
                HStack(spacing: DS.Space.sm) {
                    Text("Your name").dsFont(.callout).foregroundStyle(.secondary)
                    TextField("Shown to them", text: $label)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .dsFont(.body)
                }
                // There's no keyboard in the compact drawer.
                .onChange(of: nameFocused) { _, focused in if focused { model.expand() } }

                DSChipPicker(selection: $duration, options: Self.durations, title: { $0.shortLabel },
                             accessibilityTitle: "Link lasts")

                Button {
                    nameFocused = false
                    Task { await model.send(label: label, duration: duration) }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        if model.isSending { ProgressView().tint(.white) }
                        Label("Send Live Glucose", systemImage: "paperplane.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .large))
                .disabled(model.isSending)

                if let error = model.sendError {
                    Text(error).dsFont(.callout).foregroundStyle(Tone.warning.textColor)
                }
                Text("Anyone with GlucOS sees your reading keep updating in the chat. Everyone else gets a link to a live web page. Stop a link any time in GlucOS → Sharing.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ShareDuration {
    var shortLabel: String {
        switch self {
        case .hour: return "1 hr"
        case .eightHours: return "8 hrs"
        case .day: return "24 hrs"
        case .week: return "7 days"
        case .untilStopped: return "Until I stop"
        }
    }
}

// MARK: - A tapped bubble

struct SelectedShareView: View {
    @EnvironmentObject var model: MessagesModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            LiveShareCard(chartHeight: 90)
            if !model.ended && !model.isOwnShare {
                Button { model.follow() } label: {
                    Label("Follow on Lock Screen", systemImage: "lock.iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .large))
                Text("Opens GlucOS, which keeps their reading on your Lock Screen and in the Dynamic Island.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The live bubble in the chat

struct LiveBubbleView: View {
    @EnvironmentObject var model: MessagesModel
    static let height: CGFloat = 176

    var body: some View {
        LiveShareCard(chartHeight: 44, compact: true)
            .padding(DS.Space.xs)
            .frame(height: Self.height)
    }
}

/// A share's live card: whose it is, the reading, and how long it lasts.
struct LiveShareCard: View {
    @EnvironmentObject var model: MessagesModel
    var chartHeight: CGFloat
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let card = model.snapshot?.card
            let stale = card?.isStale(at: now) ?? true
            let tone: Tone = model.ended || stale ? .stale : .glucose(card?.range ?? .inRange)
            let name = model.snapshot.map { ShareMessage.title(label: $0.label) } ?? "Glucose"
            VStack(alignment: .leading, spacing: compact ? DS.Space.xs : DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Eyebrow(title: name, systemImage: "dot.radiowaves.left.and.right")
                    Spacer(minLength: 0)
                    if let card, !model.ended { RangeBadge(range: card.range, stale: stale) }
                }
                if model.ended {
                    Spacer(minLength: 0)
                    Text("This share has ended.").dsFont(.headline)
                    Text("They stopped sharing, or the link ran out.").dsFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if let card {
                    SharedReadingView(card: card, now: now, valueSize: compact ? 32 : 44,
                                      dialSize: compact ? 36 : 52, chartHeight: chartHeight)
                } else {
                    Spacer(minLength: 0)
                    if let error = model.loadError {
                        Text(error).dsFont(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Spacer(minLength: 0)
                }
                if !model.ended, let snapshot = model.snapshot {
                    HStack(spacing: DS.Space.xs) {
                        Circle().fill(stale ? Color.secondary : Tone.success.color).frame(width: 6, height: 6)
                        Text("Live · \(MessagesModel.untilText(snapshot.expiresAt).lowercasedFirst)")
                        Spacer(minLength: 0)
                        if compact && !model.isOwnShare {
                            Button("Follow") { model.follow() }
                                .buttonStyle(.ds(.secondary, size: .small))
                        }
                    }
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(compact ? DS.Space.md : DS.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
            .background { DSSurface(style: .tinted(tone), radius: DS.Radius.card) }
            .accessibilityElement(children: .contain)
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - The picture for people without GlucOS

struct BubbleImageView: View {
    let card: GlucoseActivityState?
    let label: String

    var body: some View {
        let now = Date()
        let stale = card?.isStale(at: now) ?? true
        let tone: Tone = stale ? .stale : .glucose(card?.range ?? .inRange)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Eyebrow(title: ShareMessage.title(label: label), systemImage: "dot.radiowaves.left.and.right")
            if let card {
                SharedReadingView(card: card, now: now, valueSize: 40, dialSize: 44, chartHeight: 40)
            } else {
                Spacer(minLength: 0)
                Text("Live glucose").dsFont(.title)
                Spacer(minLength: 0)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { DSSurface(style: .tinted(tone), radius: 0) }
        .background(Color.white)
        .environment(\.dsTextScale, 1.3)
    }
}
