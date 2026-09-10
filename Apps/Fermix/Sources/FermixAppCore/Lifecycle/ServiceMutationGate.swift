import Foundation

/// Who is mutating the background service right now.
///
/// Named rather than a bare flag, because the refusal has to say what is
/// already running: "an update is stopping the engine" and "you asked for a
/// restart" send an operator to different places.
public enum ServiceMutation: String, CaseIterable, Equatable, Sendable {
    /// An enable, disable or restart the person asked for.
    case lifecycle
    /// The update transaction (M34 §6, R3).
    case update
    /// The launch reconcile, which can re-register the service (M34 §6, R4).
    case reconcile
}

/// The one lock over everything that can register, unregister, drain or restart
/// the background service.
///
/// M34 §6 requires the update transaction to be serialized with ordinary
/// lifecycle actions. This is how: every owner takes the gate before its first
/// mutation and releases it in a `defer`, and the gate is `@MainActor`, so
/// acquiring is a single actor-isolated read-and-write that cannot interleave
/// with another. There is no queue — a second request while one is held is
/// refused rather than deferred, exactly as `AppCoordinator` already refuses a
/// second lifecycle transaction, because two overlapping drains of the same
/// daemon is what the journals exist to prevent.
///
/// It holds no daemon state and takes no lease of its own: the daemon's own
/// `lifecycle.prepare` lease is still what protects a turn in flight. This
/// protects the *account*, which is the thing two transactions in one process
/// can corrupt.
@MainActor
public final class ServiceMutationGate {
    public private(set) var holder: ServiceMutation?

    public init() {}

    public var isHeld: Bool { holder != nil }

    /// Takes the gate for one owner.
    ///
    /// - Returns: whether it was taken. A caller that gets `false` must not
    ///   mutate anything and must not release.
    public func acquire(_ mutation: ServiceMutation) -> Bool {
        guard holder == nil else { return false }

        holder = mutation
        return true
    }

    /// Releases the gate. Releasing one this owner does not hold is a
    /// programming error rather than a no-op: it would hand the gate away from
    /// whoever is mid-transaction.
    public func release(_ mutation: ServiceMutation) {
        precondition(holder == mutation, "\(mutation.rawValue) released a gate held by \(holder?.rawValue ?? "nobody")")

        holder = nil
    }
}
