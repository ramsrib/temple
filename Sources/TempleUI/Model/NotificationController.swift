import Foundation
import UserNotifications

/// Native macOS notifications for attention events (U7).
///
/// `UNUserNotificationCenter` requires a real app bundle — under bare
/// `swift run` (`Bundle.main.bundleIdentifier == nil`) every method no-ops so
/// nothing crashes. Activity-state derivation itself lives in
/// `OpenSessionsModel` (unit-tested); this type only raises the OS banner and
/// routes a click back to the right tab.
@MainActor
public final class NotificationController: NSObject {
    /// Wired by `AppModel` → focus the session's tab on notification click.
    public var onActivateSession: ((String) -> Void)?

    private var authorized = false

    /// `UNUserNotificationCenter.current()` only works inside a real `.app`
    /// bundle — it aborts under bare `swift run` and under the xctest runner.
    /// (A bundle-id check isn't enough; the xctest tool has one.)
    private var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public override init() {
        super.init()
        requestAuthorizationIfAvailable()
    }

    private func requestAuthorizationIfAvailable() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Post "project · session" + message; clicking it focuses that session.
    public func post(projectName: String, sessionTitle: String, sessionID: String?, body: String) {
        guard isAvailable, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(projectName) · \(sessionTitle)"
        content.body = body
        content.sound = .default
        if let sessionID { content.userInfo = ["sessionID": sessionID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let sessionID { self.onActivateSession?(sessionID) }
            completionHandler()
        }
    }
}
