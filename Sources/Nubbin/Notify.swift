import AppKit
import UserNotifications

/// Reaches you when you're not at the Mac: Notification Center, and your phone through ntfy.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Clicking a notification opens its row; set by the app delegate.
    var onOpen: ((String) -> Void)?

    /// Notification Center needs an app bundle; a bare `swift run` binary would crash asking for it.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app"
        ? UNUserNotificationCenter.current() : nil

    override private init() {
        super.init()
        center?.delegate = self
    }

    /// Anything that would chime: forward it if you're away.
    func attention(_ row: Row, _ moment: Moment) {
        let prefs = Preferences.shared
        guard prefs.notifyWhenAway || !prefs.ntfyTopic.isEmpty, Away.isAway else { return }
        debugLog("away: forwarding \(row.id) \(moment)")
        if prefs.notifyWhenAway { post(row, moment) }
        if !prefs.ntfyTopic.isEmpty { push(title: title(row, moment), body: body(row), moment: moment) }
    }

    /// Ask once, when you turn the setting on. Returns whether notifications are allowed.
    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    var available: Bool { center != nil }

    /// Settings' "Send test" button.
    func sendTest() {
        push(title: "Nubbin test", body: "Away notifications reach you here.", moment: .needsYou)
    }

    private func post(_ row: Row, _ moment: Moment) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title(row, moment)
        content.body = body(row)
        content.userInfo = ["row": row.id]
        content.threadIdentifier = row.id
        center.add(UNNotificationRequest(identifier: "\(row.id):\(moment.rawValue)", content: content, trigger: nil))
    }

    private func push(title: String, body: String, moment: Moment) {
        let prefs = Preferences.shared
        let server = prefs.ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(server)/\(prefs.ntfyTopic.trimmingCharacters(in: .whitespaces))") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        // Header values must be Latin-1; ntfy decodes RFC 2047 for anything else.
        request.setValue("=?UTF-8?B?\(Data(title.utf8).base64EncodedString())?=", forHTTPHeaderField: "Title")
        request.setValue(moment == .done ? "default" : "high", forHTTPHeaderField: "Priority")
        let tags = switch moment {
        case .needsYou: "bell"
        case .done: "white_check_mark"
        case .error: "x"
        }
        request.setValue(tags, forHTTPHeaderField: "Tags")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { NSLog("Nubbin: ntfy push failed: \(error.localizedDescription)") }
            else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                NSLog("Nubbin: ntfy push failed: HTTP \(http.statusCode)")
            }
        }.resume()
    }

    private func title(_ row: Row, _ moment: Moment) -> String {
        "\(row.title): \(moment.title.lowercased())"
    }

    private func body(_ row: Row) -> String {
        [row.detail, row.location].compactMap { $0 }.joined(separator: "\n").nonEmpty ?? "Waiting in your terminal."
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["row"] as? String
        Task { @MainActor in
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }

    /// Show it even when Nubbin happens to be frontmost (Settings open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
