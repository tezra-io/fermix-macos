import Foundation

/// Runs one piece of off-actor work to completion from a synchronous
/// main-actor frame, inside a finite bound.
///
/// It exists for the update transaction's Sparkle callbacks. Those are
/// synchronous and main-actor isolated, and after the download every one of
/// them is a frame the process may not outlive: once the installer arms, any
/// exit completes the bundle replacement with no further call into this
/// process. Holding the frame is the only mechanism there is.
///
/// **The work must not be main-actor isolated.** This blocks the calling
/// thread, and a main actor held by a synchronous frame is not re-entrant, so
/// a main-actor step would never get to run: it would spend the whole budget
/// suspended and the caller would proceed having done nothing. That is the
/// bug this type replaced. Blocking the thread is the price, and here it is
/// the right one: the alternative is a bundle replaced under a live engine.
enum BlockingBarrier {
    /// - Parameters:
    ///   - budget: the whole bound, in seconds.
    ///   - expired: the answer when the bound runs out. The work is left
    ///     running: it owns the transaction's record, and the step after this
    ///     one is what waits for it again.
    ///   - work: the off-actor step to run.
    static func run<Value: Sendable>(
        budget: TimeInterval,
        expired: Value,
        _ work: @escaping @Sendable () async -> Value
    ) -> Value {
        precondition(budget > 0, "a barrier needs a bound")

        let outcome = BarrierOutcome(expired)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            outcome.store(await work())
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + budget) == .success else { return expired }

        return outcome.value
    }
}

/// The one value a barrier carries back across its thread boundary.
///
/// Seeded with the expired answer so there is no unwritten state to read, and
/// locked because the write happens on the cooperative pool while the caller's
/// thread is parked on the semaphore.
private final class BarrierOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ expired: Value) {
        stored = expired
    }

    var value: Value { lock.withLock { stored } }

    func store(_ value: Value) {
        lock.withLock { stored = value }
    }
}
