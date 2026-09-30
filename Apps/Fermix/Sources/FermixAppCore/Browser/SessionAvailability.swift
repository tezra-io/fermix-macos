import AppKit
import Combine
import CoreGraphics
import Foundation

/// Whether the pane's tabs can be driven now, as the host reports it at attach
/// and on every change (plan §4.10).
///
/// A seam, so the browser coordinator and the wire client read one answer and
/// a test can state it.
@MainActor
public protocol SessionAvailabilityReporting: AnyObject {
    var availability: BrowserAvailability { get }
    /// Every change, starting with the answer now.
    var changes: AnyPublisher<BrowserAvailability, Never> { get }
    /// The app is quitting: the last change there is, reported before
    /// `host_stopping` and never after it.
    func applicationTerminating()
}

/// The one owner of the session's availability.
///
/// The spike (plan §4.8) measured what makes the pane's pages stop: a locked
/// screen occludes the corner window, WebKit suspends the page and nothing
/// renders until about two seconds after unlock, and a sleeping display is the
/// same away-from-the-Mac case. So the host is unavailable while the screen is
/// locked, while the display sleeps, and once the app is terminating, and
/// available otherwise. Several can stand at once; the report names the
/// weightiest, in `BrowserUnavailableReason`'s order.
///
/// The lock and unlock arrive as the session's distributed notifications and
/// the display's sleep and wake as the workspace's, observed for the life of
/// the process. The centres are handed in, so a test posts to its own.
@MainActor
public final class SessionAvailability: SessionAvailabilityReporting {
    public static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    public static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    @Published public private(set) var availability: BrowserAvailability
    private var standing: Set<BrowserUnavailableReason>

    /// - Parameter standing: what holds at launch. A task can start the app
    ///   on a locked Mac, and a lock that happened before the app was running
    ///   posts nothing it could hear.
    public init(
        standing: Set<BrowserUnavailableReason>,
        distributed: NotificationCenter,
        workspace: NotificationCenter
    ) {
        self.standing = standing
        availability = Self.availability(standing)

        observe(Self.screenLocked, on: distributed, .screenLocked, standing: true)
        observe(Self.screenUnlocked, on: distributed, .screenLocked, standing: false)
        observe(NSWorkspace.screensDidSleepNotification, on: workspace, .displayAsleep, standing: true)
        observe(NSWorkspace.screensDidWakeNotification, on: workspace, .displayAsleep, standing: false)
    }

    /// This Mac's session: the lock and the display as they are now, and the
    /// system's own two centres.
    public static func onThisMac() -> SessionAvailability {
        SessionAvailability(
            standing: standingNow(),
            distributed: DistributedNotificationCenter.default(),
            workspace: NSWorkspace.shared.notificationCenter
        )
    }

    public var changes: AnyPublisher<BrowserAvailability, Never> {
        $availability.eraseToAnyPublisher()
    }

    public func applicationTerminating() {
        change(.appTerminating, standing: true)
    }

    /// The weightiest reason standing, or available where none does.
    nonisolated static func availability(_ standing: Set<BrowserUnavailableReason>) -> BrowserAvailability {
        guard let reason = BrowserUnavailableReason.allCases.first(where: standing.contains) else {
            return .available
        }

        return .unavailable(reason)
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        _ reason: BrowserUnavailableReason,
        standing isStanding: Bool
    ) {
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.change(reason, standing: isStanding)
            }
        }
    }

    /// Published only where the answer moved, so a second lock or a wake with
    /// the screen still locked reports nothing.
    private func change(_ reason: BrowserUnavailableReason, standing isStanding: Bool) {
        if isStanding {
            standing.insert(reason)
        } else {
            standing.remove(reason)
        }

        let now = Self.availability(standing)
        guard now != availability else { return }

        availability = now
    }

    /// What holds as the app starts. The session dictionary carries
    /// `CGSSessionScreenIsLocked` while the screen is locked, and the display
    /// answers for itself.
    private static func standingNow() -> Set<BrowserUnavailableReason> {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let facts: [BrowserUnavailableReason: Bool] = [
            .screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool == true,
            .displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0
        ]

        return Set(facts.filter(\.value).keys)
    }
}
