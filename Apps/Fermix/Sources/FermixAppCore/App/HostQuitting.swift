import Foundation

/// A host's part of a quit, as the app coordinator asks for it: the browser
/// pane's on the browser host wire, and the native host's on its own.
@MainActor
public protocol HostQuitting: AnyObject {
    /// Starts the host's part of a quit. `done` runs once: at once where there
    /// is no daemon to tell, and otherwise when the daemon answers
    /// `host_stopping` or the bound elapses, whichever comes first.
    ///
    /// Called from the run loop, never from inside a main-actor task: AppKit
    /// spins a nested run loop while a termination is held, and main-actor work
    /// queued behind the block that entered it never runs (plan §4.8).
    func stopHost(done: @escaping @MainActor () -> Void)
}

extension HostQuitting {
    /// How long a host holds the quit for the daemon's answer to
    /// `host_stopping` before it ends the hold itself, should the answer be
    /// lost. One bound for every host, owned here, so a quit held for two
    /// hosts waits no longer than one held for either.
    public nonisolated static var quitBound: TimeInterval { 2 }
}

/// Every host's part of a quit, run side by side, so the quit holds no
/// longer for two hosts than for the slower one. `done` runs once, when the
/// last of them has ended its own hold.
@MainActor
final class HostQuitHolds: HostQuitting {
    private let hosts: [any HostQuitting]

    init(_ hosts: [any HostQuitting]) {
        self.hosts = hosts
    }

    func stopHost(done: @escaping @MainActor () -> Void) {
        var holding = hosts.count
        guard holding > 0 else {
            done()
            return
        }

        for host in hosts {
            host.stopHost {
                holding -= 1
                if holding == 0 { done() }
            }
        }
    }
}
