import AppKit
import Combine
import Foundation
import UserNotifications

/// Fermix's notification grant on this Mac, in the three words the native
/// host wire reports it by (`capabilities`, `host.status`,
/// `notifications.authorize`): the raw values are the wire's own.
public enum NotificationGrant: String, CaseIterable, Equatable, Sendable {
    case granted
    case notGranted = "not_granted"
    case notAsked = "not_asked"

    /// The framework's own answer, in the wire's three words.
    ///
    /// A provisional grant takes a post, quietly, so it is a grant; this
    /// build never asks for one (alerts with sound, decision D9), so macOS
    /// never holds one for it. A status a later macOS adds is not a grant this
    /// build can prove, and it reads as the one the person resolves in System
    /// Settings.
    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: self = .granted
        case .denied: self = .notGranted
        case .notDetermined: self = .notAsked
        @unknown default: self = .notGranted
        }
    }
}

/// A button on a notification, by the id the native host wire names it with
/// (`actions[].id`, `notification.action`'s `action`). The raw value is the
/// wire's own, and it is the button's identifier in the framework too, so a
/// press comes back as the word the engine sent.
public enum NotificationActionID: String, CaseIterable, Equatable, Sendable {
    case snooze10m = "snooze_10m"
}

/// One button, in the words the engine wrote for it.
public struct MacNotificationAction: Equatable, Sendable {
    public let id: NotificationActionID
    public let title: String

    public init(id: NotificationActionID, title: String) {
        self.id = id
        self.title = title
    }
}

/// One notification to show, exactly as the engine rendered it: the app adds
/// nothing to the title or the body.
public struct MacNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let sound: Bool
    /// The reminder a press on one of `actions` names.
    public let reminderID: String?
    public let actions: [MacNotificationAction]

    public init(title: String, body: String, sound: Bool, reminderID: String?, actions: [MacNotificationAction]) {
        self.title = title
        self.body = body
        self.sound = sound
        self.reminderID = reminderID
        self.actions = actions
    }
}

/// How one post ended.
public enum NotificationPostOutcome: Equatable, Sendable {
    /// Shown, under this build's own identifier for it.
    case posted(notificationID: String)
    /// Refused before the framework was asked: the grant, as read for this
    /// post, is not `granted`.
    case notAuthorized(NotificationGrant)
    /// The framework refused it, in its own words.
    case failed(String)
}

/// The person pressed `action` on the notification for `reminderID`.
public struct NotificationPress: Equatable, Sendable {
    public let reminderID: String
    public let action: NotificationActionID

    public init(reminderID: String, action: NotificationActionID) {
        self.reminderID = reminderID
        self.action = action
    }
}

/// What the person did with one notification, as the framework's delegate
/// hands it over: the action's identifier (the framework's own for a click on
/// the notification itself) and the reminder the notification carried.
public struct NotificationResponse: Equatable, Sendable {
    public let actionIdentifier: String
    public let reminderID: String?

    public init(actionIdentifier: String, reminderID: String?) {
        self.actionIdentifier = actionIdentifier
        self.reminderID = reminderID
    }
}

/// This bundle's notification center, behind a seam.
///
/// `UNUserNotificationCenter` answers for the running bundle, so a test that
/// touched it would read, and could change, whatever this Mac has granted.
/// The production implementation is `SystemUserNotificationCenter`; tests
/// inject a recorder.
@MainActor
public protocol UserNotificationCentering: AnyObject {
    /// The grant as the framework reports it. Never prompts.
    func grant() async -> NotificationGrant
    /// Raises the system prompt for alerts with sound and answers whether the
    /// person allowed them. Throws the framework's own error.
    func requestAlertsWithSound() async throws -> Bool
    /// The categories registered for this bundle.
    func categories() async -> Set<UNNotificationCategory>
    /// Replaces the registered categories.
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// Shows one notification now.
    func add(_ request: UNNotificationRequest) async throws
    /// Who hears what the person does with a notification, on the main actor.
    var responses: ((NotificationResponse) -> Void)? { get set }
}

/// Fermix's notifications on this Mac (M76 §4.4, §4.8): the grant, the one
/// prompt, posting, and the person's answers to what was posted.
///
/// One owner, because the native host wire and the Permissions row are two
/// readers of one grant and two doors to one prompt: `notifications.authorize`
/// and the row's Grant… both call `authorize()`, so the prompt names Fermix
/// and is raised once, whoever asked. Nothing here decides whether Fermix may
/// ring; it reads the framework and says what it read.
@MainActor
public final class MacNotifications {
    /// The userInfo key a posted notification carries its reminder under.
    public nonisolated static let reminderIDKey = "reminder_id"

    /// The grant as the framework last answered. Nil until the first read.
    public private(set) var grant: NotificationGrant?
    /// The identity the grant is held by: the bundle the framework answers
    /// for, which is where System Settings keeps it.
    public let bundleIdentifier: String
    /// The person pressed a button on a notification.
    public var onPress: ((NotificationPress) -> Void)?
    /// The person clicked a notification itself. There is no wire event for
    /// this: the app comes forward, and that is all.
    public var onOpened: (() -> Void)?

    private let center: any UserNotificationCentering
    private let changes = PassthroughSubject<NotificationGrant, Never>()
    /// The one prompt this process raises. Kept once raised, so a second ask,
    /// while it is up or after it, joins it rather than raising another. A
    /// request the framework refused raised nothing, and is not kept.
    private var prompt: Task<Void, Never>?
    private var activation: AnyCancellable?
    private let log = AppLog.logger(.notifications)

    /// - Parameter activations: where the app's activation is heard. A grant
    ///   can change in System Settings while the app is in the background, so
    ///   every return to the app reads it again.
    public init(
        center: any UserNotificationCentering,
        bundleIdentifier: String,
        activations: NotificationCenter = .default
    ) {
        self.center = center
        self.bundleIdentifier = bundleIdentifier
        center.responses = { [weak self] response in
            self?.received(response)
        }
        activation = activations.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    /// Every change to the grant, sent once it is stored, so a reader that
    /// reads `grant` back sees the new one.
    public var grantChanged: AnyPublisher<NotificationGrant, Never> {
        changes.eraseToAnyPublisher()
    }

    /// Reads the grant from the framework and publishes it where it changed.
    /// Never prompts.
    @discardableResult
    public func refresh() async -> NotificationGrant {
        let read = await center.grant()
        publish(read)
        return read
    }

    /// The grant once the person has been asked, raising the prompt only where
    /// it has never been answered, and never twice in this process.
    public func authorize() async -> NotificationGrant {
        let current = await refresh()
        guard current == .notAsked else { return current }

        await promptOnce().value
        return await refresh()
    }

    /// Shows one notification, as a banner with sound where it asks for
    /// sound, at the default level (decision D9: nothing breaks through
    /// Focus). Refused before the framework is asked where the grant, read
    /// for this post, is not `granted`. Never prompts.
    public func post(_ notification: MacNotification) async -> NotificationPostOutcome {
        let grant = await refresh()
        guard grant == .granted else { return .notAuthorized(grant) }

        let category = Self.category(for: notification.actions)
        if let category { await register(category) }
        let identifier = UUID().uuidString
        do {
            try await center.add(Self.request(for: notification, identifier: identifier, category: category?.identifier))
            return .posted(notificationID: identifier)
        } catch {
            log.error("the framework refused a notification: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - The person's answers

    /// A click on the notification itself brings the app forward. A press on
    /// a button names its reminder; one this build did not post, or one
    /// with no reminder, is nobody's.
    func received(_ response: NotificationResponse) {
        guard response.actionIdentifier != UNNotificationDefaultActionIdentifier else {
            onOpened?()
            return
        }
        guard let action = NotificationActionID(rawValue: response.actionIdentifier), let reminderID = response.reminderID else {
            log.debug("ignoring a notification response nobody asked for: \(response.actionIdentifier, privacy: .public)")
            return
        }

        onPress?(NotificationPress(reminderID: reminderID, action: action))
    }

    // MARK: - Mechanics

    private func publish(_ read: NotificationGrant) {
        guard read != grant else { return }

        grant = read
        log.info("notifications grant: \(read.rawValue, privacy: .public)")
        changes.send(read)
    }

    private func promptOnce() -> Task<Void, Never> {
        if let prompt { return prompt }

        let raised = Task { [weak self, center, log] in
            do {
                _ = try await center.requestAlertsWithSound()
            } catch {
                log.error("the notification prompt failed: \(error.localizedDescription, privacy: .public)")
                // Nothing was shown, so "never twice" has not been spent: the
                // next ask asks again.
                self?.prompt = nil
            }
        }
        prompt = raised
        return raised
    }

    /// Adds `category` to what is registered, where it is not already. The
    /// framework applies a new set out of band, and a post that names a
    /// category it has not applied shows without its buttons, so the set is
    /// read back before the post goes out.
    private func register(_ category: UNNotificationCategory) async {
        let registered = await center.categories()
        guard !registered.contains(where: { $0.identifier == category.identifier }) else { return }

        center.setCategories(registered.union([category]))
        _ = await center.categories()
    }

    /// The buttons a post asks for, as one category named by the buttons
    /// themselves, so two posts that ask for the same buttons share one and a
    /// post in other words gets its own. None for a post with no buttons.
    static func category(for actions: [MacNotificationAction]) -> UNNotificationCategory? {
        guard !actions.isEmpty else { return nil }

        let identifier = "fermix.actions." + actions.map { "\($0.id.rawValue)=\($0.title)" }.joined(separator: "|")
        // No option: a press acts where the notification is, and never opens
        // the app (`foreground`) or asks for the Mac's password.
        let buttons = actions.map { UNNotificationAction(identifier: $0.id.rawValue, title: $0.title, options: []) }
        return UNNotificationCategory(identifier: identifier, actions: buttons, intentIdentifiers: [], options: [])
    }

    static func request(for notification: MacNotification, identifier: String, category: String?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.sound ? .default : nil
        content.interruptionLevel = .active
        if let reminderID = notification.reminderID {
            content.userInfo = [reminderIDKey: reminderID]
        }
        if let category {
            content.categoryIdentifier = category
        }

        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
