import Foundation

/// Why a connect attempt did not produce a socket. The errno is the system's
/// own answer, carried rather than paraphrased.
public struct RealtimeConnectFailure: Error, Equatable, Sendable {
    public let errorNumber: Int32

    public init(errorNumber: Int32) {
        self.errorNumber = errorNumber
    }
}

/// Why a live connection ended. Every case names the layer that observed it, so
/// a status line can say what happened instead of "disconnected".
public enum RealtimeTransportFailure: Error, Equatable, Sendable {
    case peerClosed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case controlFlushTimedOut(seconds: Double)
    case audioStalled(seconds: Double)
    /// The peer sent a frame, or a run of bytes, this client refuses to hold.
    case framingViolation(RealtimeDecodeFailure)

    public var isFramingViolation: Bool {
        if case .framingViolation = self { return true }

        return false
    }
}

/// The realtime socket, as everything above it sees it.
///
/// The seam exists so the session's handshake, timeouts, and event routing are
/// provable without a daemon: the production implementation is the non-blocking
/// `RealtimeSocketClient`, and tests inject a recorder.
public protocol RealtimeTransport: AnyObject, Sendable {
    var onEvent: ((RealtimeServerEvent) -> Void)? { get set }
    var onFailure: ((RealtimeTransportFailure) -> Void)? { get set }

    /// Connects off the caller's thread and reports the outcome. Connecting a
    /// Unix socket blocks, so this never runs on the main actor.
    func connect(path: String, completion: @escaping (Result<Void, RealtimeConnectFailure>) -> Void)
    func send(_ event: RealtimeClientEvent)
    func sendAudioChunk(_ data: Data)
    func close()
}
