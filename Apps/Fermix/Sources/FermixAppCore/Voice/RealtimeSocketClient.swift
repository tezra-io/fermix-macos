import Foundation

/// The realtime voice wire over the daemon's AF_UNIX realtime socket.
///
/// The socket, its framing, and both write deadlines belong to the line socket
/// this owns. What is the voice wire's stays here: client events encoded as
/// lines, lines decoded into server events, audio sent as droppable lines and
/// every other event as a line that must arrive, and the bounds and deadlines
/// a call needs. Callbacks arrive on the line socket's queue —
/// `MainActorRealtimeDelivery` is what puts them on the main actor.
public final class RealtimeSocketClient: RealtimeTransport, @unchecked Sendable {
    public typealias LineSocket = any LineSocketTransport<RealtimeServerEvent, RealtimeDecodeFailure>

    public var onEvent: ((RealtimeServerEvent) -> Void)?
    public var onFailure: ((RealtimeTransportFailure) -> Void)?

    /// Default cap on the pending outbound-audio buffer. The capture tap emits
    /// a chunk per 4800-frame buffer (`AudioController.captureBufferFrames`),
    /// which is ~100 ms of audio at a 48 kHz input rate, so 20 chunks ≈ 2 s of
    /// droppable audio held in reserve before the oldest is discarded.
    public static let defaultMaxPendingAudioChunks = 20

    /// Default deadline for flushing a control frame. Control frames are never
    /// dropped, but if the socket is so backed up that one cannot be written
    /// within this window the connection is declared dead.
    public static let defaultControlFlushDeadline: TimeInterval = 5.0

    /// Default deadline for making *any* outbound write progress while the
    /// audio buffer is saturated. Audio is droppable, so a briefly-full buffer
    /// is normal and never fatal — but a steady call generates no control
    /// frames, so without this a peer that wedges mid-call (e.g. a SIGSTOPed
    /// daemon) is never noticed: audio is dropped forever, the mic stays hot,
    /// and nothing tears down. If the buffer stays full and not one byte drains
    /// for this long, the connection is declared dead. Longer than the control
    /// deadline because a transient capture burst can saturate the buffer
    /// without the link being dead.
    public static let defaultAudioStallDeadline: TimeInterval = 8.0

    private let lines: LineSocket

    public init(lines: LineSocket) {
        self.lines = lines

        lines.onMessage = { [weak self] event in
            self?.onEvent?(event)
        }
        lines.onFailure = { [weak self] failure in
            self?.onFailure?(failure)
        }
    }

    /// The realtime socket with this wire's bounds and the call's deadlines.
    public convenience init() {
        self.init(lines: Self.lineSocket())
    }

    /// The line socket the realtime wire runs on. Separate from `init` so a
    /// test can shorten the deadlines and still read the socket's drop count.
    static func lineSocket(
        maxPendingAudioChunks: Int = defaultMaxPendingAudioChunks,
        controlFlushDeadline: TimeInterval = defaultControlFlushDeadline,
        audioStallDeadline: TimeInterval = defaultAudioStallDeadline
    ) -> LineSocketClient<RealtimeServerEvent, RealtimeDecodeFailure> {
        LineSocketClient(
            name: "realtime",
            log: AppLog.logger(.voice),
            inbound: RealtimeProtocol.inboundLimits,
            outbound: LineOutboundLimits(
                flushDeadline: controlFlushDeadline,
                maximumPendingDroppableLines: maxPendingAudioChunks,
                stallDeadline: audioStallDeadline
            ),
            decode: { line throws(RealtimeDecodeFailure) in
                try RealtimeServerEvent.decode(line)
            }
        )
    }

    public func connect(
        path: String,
        completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void
    ) {
        lines.connect(path: path, completion: completion)
    }

    /// A control frame (hello, call_start, interrupt, call_stop, …): never
    /// dropped, and held to the flush deadline.
    public func send(_ event: RealtimeClientEvent) {
        lines.send(Self.line(for: event))
    }

    /// An audio chunk: real-time droppable, so a backed-up socket sheds the
    /// oldest pending chunk rather than the newest.
    public func sendAudioChunk(_ data: Data) {
        lines.sendDroppable(Self.line(for: .audioChunk(base64: data.base64EncodedString())))
    }

    public func close() {
        lines.close()
    }

    /// A client event is a closed set of encodable values, so a line that
    /// cannot be produced is a programming defect rather than a wire condition.
    private static func line(for event: RealtimeClientEvent) -> Data {
        do {
            return try event.line()
        } catch {
            preconditionFailure("realtime event \(event.wireType) could not be encoded: \(error)")
        }
    }
}
