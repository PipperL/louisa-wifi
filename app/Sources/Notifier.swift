import AppKit
import UserNotifications

enum Notifier {
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        // Without this, notifications posted while the app is active are dropped.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list])
        }
    }
    private static let presenter = Presenter()

    static func setUp() {
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if !granted { debugLog("notifications not allowed") }
        }
    }

    static func post(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "路易莎 Wi-Fi"
        content.body = text
        let request = UNNotificationRequest(identifier: "status", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Result of something the user asked for: a dialog when they asked from the menu,
    /// so there is always a visible answer; a notification otherwise.
    static func reply(_ text: String, manual: Bool) {
        debugLog(text)
        guard manual else { return post(text) }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "路易莎 Wi-Fi"
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            alert.runModal()
        }
    }
}
