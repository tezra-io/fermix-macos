import Foundation
import UserNotifications

/// The shipped center: this bundle's own `UNUserNotificationCenter`.
///
/// Its delegate is set as this is built, during composition, which is inside
/// `applicationDidFinishLaunching` and so before the app has finished
/// launching: the framework delivers a press that launched the app only to a
/// delegate set by then.
@MainActor
final class SystemUserNotificationCenter: UserNotificationCentering {
    var responses: ((NotificationResponse) -> Void)? {
        get { delegate.received }
        set { delegate.received = newValue }
    }

    private let center = UNUserNotificationCenter.current()
    private let delegate = SystemUserNotificationDelegate()

    init() {
        center.delegate = delegate
    }

    func grant() async -> NotificationGrant {
        NotificationGrant(await center.notificationSettings().authorizationStatus)
    }

    func requestAlertsWithSound() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func categories() async -> Set<UNNotificationCategory> {
        await center.notificationCategories()
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

/// The framework's delegate: how a notification shows while the app is
/// frontmost, and what the person did with one. It decides nothing; every
/// answer is handed to `received` on the main actor.
private final class SystemUserNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Set and read on the main actor only.
    var received: ((NotificationResponse) -> Void)?

    /// A reminder rings as a banner with its sound even while Fermix is the
    /// app in front: it is the reminder's moment whichever app has focus.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let answer = NotificationResponse(
            actionIdentifier: response.actionIdentifier,
            reminderID: response.notification.request.content.userInfo[MacNotifications.reminderIDKey] as? String
        )
        DispatchQueue.main.async { [weak self] in
            self?.received?(answer)
            completionHandler()
        }
    }
}
