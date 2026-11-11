import Messages
import SwiftUI
import UIKit

/// GlucOS in Messages. Messages makes one of these for the drawer (compact and expanded, where you
/// send your glucose) and one for each live bubble in the chat (transcript), which shows the
/// sender's reading and keeps it current while it's on screen.
final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: MessagesRootView().environmentObject(model))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        model.activate(style: presentationStyle, message: conversation.selectedMessage)
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        model.deactivate()
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        model.activate(style: presentationStyle, message: message)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        model.style = presentationStyle
    }

    /// The live bubble's size in the chat.
    override func contentSizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, 320), height: LiveBubbleView.height)
    }

    /// Opens the GlucOS app (to follow a share, or to set up sharing).
    func openApp(_ url: URL) {
        extensionContext?.open(url, completionHandler: nil)
    }
}
