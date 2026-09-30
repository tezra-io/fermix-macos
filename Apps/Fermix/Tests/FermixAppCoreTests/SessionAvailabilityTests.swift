import AppKit
import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// The session's availability, from the notifications the Mac posts. Each case
/// posts to centres of its own, so nothing here listens to this Mac's session.
@Suite("Session availability")
@MainActor
struct SessionAvailabilityTests {
    let distributed = NotificationCenter()
    let workspace = NotificationCenter()

    func session(standing: Set<BrowserUnavailableReason> = []) -> SessionAvailability {
        SessionAvailability(standing: standing, distributed: distributed, workspace: workspace)
    }

    @Test("an unlocked Mac with its display awake is available")
    func availableByDefault() {
        #expect(session().availability == .available)
    }

    @Test("a lock makes the host unavailable, and the unlock gives it back")
    func lockAndUnlock() {
        let session = session()

        distributed.post(name: SessionAvailability.screenLocked, object: nil)
        #expect(session.availability == .unavailable(.screenLocked))

        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)
        #expect(session.availability == .available)
    }

    @Test("a sleeping display makes the host unavailable, and waking gives it back")
    func sleepAndWake() {
        let session = session()

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(session.availability == .unavailable(.displayAsleep))

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(session.availability == .available)
    }

    /// The away-from-the-Mac case the spike measured: locked, then asleep. A
    /// wake on the lock screen is still a locked Mac.
    @Test("a wake while locked stays unavailable, for the lock")
    func wakeWhileLocked() {
        let session = session()

        distributed.post(name: SessionAvailability.screenLocked, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(session.availability == .unavailable(.screenLocked))

        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)
        #expect(session.availability == .available)
    }

    @Test("an unlock with the display asleep stays unavailable, for the display")
    func unlockWhileAsleep() {
        let session = session()

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: SessionAvailability.screenLocked, object: nil)
        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)

        #expect(session.availability == .unavailable(.displayAsleep))
    }

    @Test("a Mac locked at launch starts unavailable")
    func lockedAtLaunch() {
        let session = session(standing: [.screenLocked, .displayAsleep])

        #expect(session.availability == .unavailable(.screenLocked))

        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)
        #expect(session.availability == .unavailable(.displayAsleep))
    }

    @Test("terminating outweighs everything, and nothing undoes it")
    func terminatingIsFinal() {
        let session = session(standing: [.screenLocked])

        session.applicationTerminating()
        #expect(session.availability == .unavailable(.appTerminating))

        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)
        #expect(session.availability == .unavailable(.appTerminating))
    }

    @Test("the changes start with the answer now and carry only what moved")
    func changesCarryWhatMoved() {
        let session = session()
        var seen: [BrowserAvailability] = []
        let subscription = session.changes.sink { seen.append($0) }

        distributed.post(name: SessionAvailability.screenLocked, object: nil)
        distributed.post(name: SessionAvailability.screenLocked, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        distributed.post(name: SessionAvailability.screenUnlocked, object: nil)

        #expect(seen == [.available, .unavailable(.screenLocked), .unavailable(.displayAsleep)])
        subscription.cancel()
    }
}
