import AppKit
import ReviewCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let urlKey = "url"

    // UNUserNotificationCenter crashes outside an app bundle, which is how `swift run` launches the binary.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() async throws {
        _ = try await center?.requestAuthorization(options: [.alert, .sound])
    }

    func isAuthorized() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .authorized
    }

    func post(_ notification: ActivityNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.pullRequest.title
        content.subtitle = "\(notification.pullRequest.repository) #\(notification.pullRequest.number)"
        content.body = notification.summary
        content.sound = .default
        content.userInfo = [Self.urlKey: notification.pullRequest.url.absoluteString]
        let request = UNNotificationRequest(identifier: notification.activityIDs.joined(separator: ","), content: content, trigger: nil)
        try await center?.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo[Self.urlKey] as? String, let url = URL(string: link) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
