import Foundation

@testable import FermixAppCore

/// A deadline scheduler a test drives by hand.
@MainActor
final class ManualDeadlineScheduler: DeadlineScheduling {
    private final class Token: DeadlineToken {
        var work: (() -> Void)?
        var cancelled = false

        func cancel() {
            cancelled = true
            work = nil
        }
    }

    private var tokens: [(seconds: TimeInterval, token: Token)] = []

    var scheduledDelays: [TimeInterval] { tokens.filter { !$0.token.cancelled }.map(\.seconds) }
    var liveCount: Int { tokens.filter { !$0.token.cancelled }.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken {
        let token = Token()
        token.work = work
        tokens.append((seconds, token))
        return token
    }

    /// Fires every deadline that has not been cancelled.
    func fireAll() {
        let live = tokens.filter { !$0.token.cancelled }
        tokens.removeAll()
        for entry in live {
            entry.token.work?()
        }
    }
}
