import Foundation

/// Why a connect attempt did not produce a socket.
public enum LineSocketConnectFailure: Error, Equatable, Sendable {
    /// The path does not fit a Unix socket address, whose `sun_path` holds the
    /// path and its terminator. Refused before any socket is opened.
    case pathTooLong(bytes: Int, maximum: Int)
    /// The system's own answer, carried rather than paraphrased.
    case system(errno: Int32)
}

/// A run of inbound bytes the reader refuses to hold.
public enum LineFramingViolation: Error, Equatable, Sendable {
    /// One line, or an unterminated run already past the cap, longer than the
    /// owner allows a line to be.
    case lineTooLong(bytes: Int)
    /// More unscanned bytes at once than the owner allows the reader to hold.
    case bufferExceeded(bytes: Int)
}

/// Why a live connection ended. Every case names the layer that observed it, so
/// a status line can say what happened instead of "disconnected".
///
/// The decode failure is the owner's: the transport frames lines and never
/// knows what vocabulary is inside them.
public enum LineSocketFailure<DecodeFailure: Error & Equatable & Sendable>: Error, Equatable, Sendable {
    case peerClosed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    /// A line that must arrive could not be written within the flush deadline.
    case flushTimedOut(seconds: Double)
    /// Droppable lines were being shed and not one byte drained for the whole
    /// stall window: the peer stopped reading.
    case writeStalled(seconds: Double)
    case framingViolation(LineFramingViolation)
    /// A complete line the owner's decoder refused.
    case undecodable(DecodeFailure)
}

/// Newline-delimited messages over a Unix socket, as the wire that owns them
/// sees it.
///
/// The seam exists so a session's handshake, timeouts and routing are provable
/// without a daemon: the production implementation is `LineSocketClient`, and
/// tests inject a recorder. Lines cross it without their terminator in both
/// directions; framing is the transport's.
public protocol LineSocketTransport<Message, DecodeFailure>: AnyObject, Sendable {
    associatedtype Message: Sendable
    associatedtype DecodeFailure: Error & Equatable & Sendable

    var onMessage: ((Message) -> Void)? { get set }
    var onFailure: ((LineSocketFailure<DecodeFailure>) -> Void)? { get set }

    /// Connects off the caller's thread and reports the outcome. Connecting a
    /// Unix socket blocks, so this never runs on the main actor.
    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void)
    /// Queues a line that must arrive: never dropped, and the connection is
    /// declared dead if it cannot be written within the flush deadline.
    func send(_ line: Data)
    /// Queues a line that may be shed: when the writer backs up, the oldest
    /// pending droppable line is discarded to make room.
    func sendDroppable(_ line: Data)
    func close()
}
