import Messages
import SwiftUI

/// What the Messages app shows: the composer in the drawer, or a live bubble's reading.
@MainActor
final class MessagesModel: ObservableObject {
    weak var controller: MessagesViewController?

    @Published var style: MSMessagesAppPresentationStyle = .compact
    /// The share in the bubble being shown, from its link.
    @Published private(set) var token: String?
    @Published private(set) var snapshot: ShareSnapshot?
    /// The share was stopped or ran out.
    @Published private(set) var ended = false
    @Published private(set) var loadError: String?

    @Published private(set) var isSending = false
    @Published var sendError: String?

    private var refresher: Task<Void, Never>?

    /// How often a bubble on screen fetches the reading. The relay gets a new one about once a minute.
    private static let refreshInterval: UInt64 = 30

    // MARK: Lifecycle

    func activate(style: MSMessagesAppPresentationStyle, message: MSMessage?) {
        self.style = style
        let t = message?.url.flatMap(FollowLink.token(from:))
        if t != token {
            token = t
            snapshot = nil
            ended = false
            loadError = nil
        }
        startRefreshing()
    }

    func deactivate() {
        refresher?.cancel()
        refresher = nil
    }

    private func startRefreshing() {
        refresher?.cancel()
        guard let token else { return }
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load(token)
                try? await Task.sleep(nanoseconds: Self.refreshInterval * 1_000_000_000)
            }
        }
    }

    private func load(_ token: String) async {
        do {
            let s = try await ShareClient(token: token).snapshot()
            guard token == self.token else { return }
            snapshot = s
            ended = false
            loadError = nil
        } catch ShareClient.ShareError.ended {
            guard token == self.token else { return }
            ended = true
            refresher?.cancel()
        } catch {
            guard token == self.token else { return }
            loadError = error.localizedDescription
        }
    }

    /// The bubble is one this phone sent, so there's nothing to follow.
    var isOwnShare: Bool {
        guard let id = snapshot?.followID else { return false }
        return MessagesShareLinks.token(for: id) != nil
    }

    // MARK: Your own reading (the composer)

    var relay: RelaySettings { .shared }

    /// The latest reading the app saved for its widgets.
    var localCard: GlucoseActivityState? {
        SharedStore.load().flatMap { GlucoseActivityState.make(from: $0) }
    }

    func expand() {
        guard style == .compact else { return }
        controller?.requestPresentationStyle(.expanded)
    }

    func openApp(_ url: URL?) {
        guard let url else { return }
        controller?.openApp(url)
    }

    func follow() {
        openApp(token.flatMap(FollowLink.appURL(token:)))
    }

    /// Makes a share link and puts the live bubble (and the plain link, for anyone without GlucOS)
    /// in the message field, ready to send.
    func send(label rawLabel: String, duration: ShareDuration) async {
        guard let conversation = controller?.activeConversation else { return }
        guard let client = relay.client else {
            sendError = "Sharing needs GlucOS's push relay. Open GlucOS to set it up."
            return
        }
        isSending = true
        defer { isSending = false }
        let label = ShareMessage.cleanLabel(rawLabel)
        do {
            let made = try await client.createShare(CreateShare(label: label, expiresIn: duration.seconds))
            MessagesShareLinks.save(made.token, for: made.share.id)
            guard let url = FollowLink.url(token: made.token) else { throw ShareClient.ShareError.badResponse }
            let card = (try? await ShareClient(token: made.token).snapshot())?.card ?? localCard

            let alternate = MSMessageTemplateLayout()
            alternate.caption = "\(ShareMessage.title(label: label)), live"
            alternate.subcaption = card.map { "\($0.valueText) \($0.glucoseUnit.label) \($0.glucoseTrend.arrow)" }
            alternate.trailingSubcaption = Self.untilText(made.share.expiresAt)
            alternate.image = BubbleSnapshot.image(card: card, label: label)

            let message = MSMessage(session: MSSession())
            message.url = url
            message.summaryText = "\(ShareMessage.title(label: label)), live"
            message.layout = MSMessageLiveLayout(alternateLayout: alternate)

            try await conversation.insert(message)
            try? await conversation.insertText("\(ShareMessage.text(label: label)) \(url.absoluteString)")
            sendError = nil
            controller?.requestPresentationStyle(.compact)
        } catch {
            sendError = error.localizedDescription
        }
    }

    static func untilText(_ expiresAt: Double?) -> String {
        guard let expiresAt else { return "Until stopped" }
        let date = Date(timeIntervalSince1970: expiresAt)
        let sameDay = Calendar.current.isDateInToday(date)
        return "Until " + (sameDay ? date.formatted(date: .omitted, time: .shortened)
                                   : date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
    }
}

/// The picture in the bubble for people without GlucOS (and for a Mac): the reading at the time
/// it was sent.
enum BubbleSnapshot {
    @MainActor
    static func image(card: GlucoseActivityState?, label: String) -> UIImage? {
        let view = BubbleImageView(card: card, label: label)
            .frame(width: 320, height: 160)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage
    }
}
