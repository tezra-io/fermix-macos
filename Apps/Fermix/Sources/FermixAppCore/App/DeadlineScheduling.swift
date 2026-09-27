import Foundation

/// A scheduled piece of work that can still be called off.
public protocol DeadlineToken: AnyObject {
    func cancel()
}

/// The timer seam. Deadlines are policy, so they are injected: a handshake's
/// three seconds, a reconnect's backoff and a playback drain's grace are all
/// provable without waiting for them.
@MainActor
public protocol DeadlineScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken
}

/// The production scheduler: one main-queue work item per deadline.
@MainActor
public struct MainQueueDeadlineScheduler: DeadlineScheduling {
    public init() {}

    public func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemToken(item)
    }

    private final class WorkItemToken: DeadlineToken {
        private let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() {
            item.cancel()
        }
    }
}

/// A scheduler on the main run loop itself, in its common modes.
///
/// For a deadline that must fire while AppKit holds a termination: the held
/// quit spins a nested run loop, and work queued on the main queue behind the
/// block that entered it never runs, while a run-loop timer does (plan §4.8).
@MainActor
public struct RunLoopDeadlineScheduler: DeadlineScheduling {
    public init() {}

    public func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> DeadlineToken {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)

        return TimerToken(timer)
    }

    private final class TimerToken: DeadlineToken {
        private let timer: Timer

        init(_ timer: Timer) {
            self.timer = timer
        }

        func cancel() {
            timer.invalidate()
        }
    }
}
