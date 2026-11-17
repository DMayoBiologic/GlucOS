import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The expanded look of GlucOS's low, high and forecast alerts on iPhone: the alert's text, then
/// the last 3 hours of readings and the forecast (`AlertChartView`), drawn from the `chart` the
/// alert carries. Pushes from the relay and the app's own alerts carry the same values, so this
/// needs no app group, no network and no stored readings. The alert's own buttons (Log treatment,
/// Snooze) come from its category and work as before; this view takes no touches. An alert
/// without a chart (an older relay, too few readings) shows just its text.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        preferredContentSize = CGSize(width: view.bounds.width, height: 0)
    }

    func didReceive(_ notification: UNNotification) {
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        host = nil

        guard let chart = AlertChart(userInfo: notification.request.content.userInfo) else {
            preferredContentSize = CGSize(width: view.bounds.width, height: 0)
            return
        }
        let hosting = UIHostingController(rootView: AnyView(
            AlertChartView(chart: chart)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        ))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        host = hosting
        preferredContentSize = CGSize(width: view.bounds.width, height: 180)
    }
}
