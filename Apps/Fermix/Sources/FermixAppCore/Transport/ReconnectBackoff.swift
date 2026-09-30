import Foundation

/// The reconnect rule for a wire that stays connected forever: the delay
/// before the next attempt after a lost connection, growing with every
/// consecutive loss up to a ceiling that then repeats, and reset only once a
/// connection has held past a short grace. Without the grace, a daemon that
/// accepts a connection and drops it right away looks like a fresh success on
/// every attempt, and the backoff never grows past its first step.
public struct ReconnectBackoff {
    /// How long each consecutive failure waits before the next attempt. The
    /// last delay repeats, so a daemon that is down for a day is asked twice
    /// a minute.
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// How long an attach must hold, unlost, before the growth resets.
    public static let grace: TimeInterval = 2

    private var consecutiveFailures = 0

    public init() {}

    /// The wait before the next attempt, growing with every call since the
    /// last `reset()`.
    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.delays[min(consecutiveFailures, Self.delays.count - 1)]
        consecutiveFailures += 1
        return delay
    }

    /// A connection held past the grace: the next loss starts the growth
    /// over, rather than continuing from where it left off.
    public mutating func reset() {
        consecutiveFailures = 0
    }
}
