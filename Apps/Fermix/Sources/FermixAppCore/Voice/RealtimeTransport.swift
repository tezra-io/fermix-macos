import Foundation

/// Why a live realtime connection ended: a line socket failure whose
/// undecodable lines carry the realtime wire's own decode failure.
public typealias RealtimeTransportFailure = LineSocketFailure<RealtimeDecodeFailure>

/// The realtime socket, as everything above it sees it.
///
/// The seam exists so the session's handshake, timeouts, and event routing are
/// provable without a daemon: the production implementation is
/// `RealtimeSocketClient` over a `LineSocketClient`, and tests drive the same
/// adapter over a recording line socket.
public protocol RealtimeTransport: AnyObject, Sendable {
    var onEvent: ((RealtimeServerEvent) -> Void)? { get set }
    var onFailure: ((RealtimeTransportFailure) -> Void)? { get set }

    /// Connects off the caller's thread and reports the outcome. Connecting a
    /// Unix socket blocks, so this never runs on the main actor.
    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void)
    func send(_ event: RealtimeClientEvent)
    func sendAudioChunk(_ data: Data)
    func close()
}
