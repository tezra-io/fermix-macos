import Foundation

/// What a line socket's reader holds. Both bounds are the owning wire's, because
/// an unbounded reader is a memory fault waiting for a bad peer.
public struct LineInboundLimits: Equatable, Sendable {
    /// The largest single line the reader assembles.
    public let maximumLineBytes: Int
    /// The largest amount of unscanned inbound data held at once.
    public let maximumBufferedBytes: Int

    public init(maximumLineBytes: Int, maximumBufferedBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumBufferedBytes = maximumBufferedBytes
    }
}

/// When a line socket's writer declares the peer gone, and how many droppable
/// lines it holds before shedding the oldest.
public struct LineOutboundLimits: Equatable, Sendable {
    /// How long a line that must arrive may wait to be written.
    public let flushDeadline: TimeInterval
    /// How many droppable lines wait before the oldest is discarded.
    public let maximumPendingDroppableLines: Int
    /// How long droppable lines may be shed with no write progress at all.
    public let stallDeadline: TimeInterval

    public init(flushDeadline: TimeInterval, maximumPendingDroppableLines: Int, stallDeadline: TimeInterval) {
        self.flushDeadline = flushDeadline
        self.maximumPendingDroppableLines = maximumPendingDroppableLines
        self.stallDeadline = stallDeadline
    }
}
