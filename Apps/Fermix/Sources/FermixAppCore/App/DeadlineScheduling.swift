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
