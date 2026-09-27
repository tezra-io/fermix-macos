import Foundation

/// Why a live companion connection ended: a line socket failure whose
/// undecodable lines carry the companion wire's own decode failure.
public typealias CompanionTransportFailure = LineSocketFailure<CompanionDecodeFailure>

/// The companion chat wire over the daemon's AF_UNIX companion socket.
///
/// The socket, its framing and its write deadline belong to the line socket
/// this owns. What is the chat wire's stays here: client events encoded as
/// lines, lines decoded into server events, and the reader's bounds. Every line
/// on this wire must arrive, so nothing is ever sent droppable. Callbacks
/// arrive wherever the line socket under it calls back: in the app that socket
/// is wrapped in `MainActorLineDelivery`.
public final class CompanionSocketClient: @unchecked Sendable {
    public typealias LineSocket = any LineSocketTransport<CompanionServerEvent, CompanionDecodeFailure>

    public var onEvent: ((CompanionServerEvent) -> Void)?
    public var onFailure: ((CompanionTransportFailure) -> Void)?

    /// How long a line may wait to be written before the connection is
    /// declared dead, the realtime wire's control deadline.
    public static let flushDeadline: TimeInterval = 5

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

    /// The line socket the chat wire runs on, for the composition to wrap in
    /// the main-actor delivery.
    static func lineSocket() -> LineSocketClient<CompanionServerEvent, CompanionDecodeFailure> {
        LineSocketClient(
            name: "companion",
            log: AppLog.logger(.companion),
            inbound: CompanionProtocol.inboundLimits,
            outbound: LineOutboundLimits(
                flushDeadline: flushDeadline,
                // No line on this wire is droppable, so the droppable bounds are
                // the smallest the socket admits and are never reached.
                maximumPendingDroppableLines: 1,
                stallDeadline: flushDeadline
            ),
            decode: { line throws(CompanionDecodeFailure) in
                try CompanionServerEvent.decode(line)
            }
        )
    }

    public func connect(
        path: String,
        completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void
    ) {
        lines.connect(path: path, completion: completion)
    }

    /// Every event is a line that must arrive, held to the flush deadline.
    public func send(_ event: CompanionClientEvent) {
        lines.send(Self.line(for: event))
    }

    public func close() {
        lines.close()
    }

    /// The session measures a message against the line cap as it enters the
    /// outbox, and every other event is bounded by the contract's own limits,
    /// so a line that cannot be produced here is a programming defect rather
    /// than a wire condition.
    private static func line(for event: CompanionClientEvent) -> Data {
        do {
            return try event.line()
        } catch {
            preconditionFailure("companion event \(event.wireType) could not be encoded: \(error)")
        }
    }
}
