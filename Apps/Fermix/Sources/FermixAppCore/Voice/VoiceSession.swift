import Foundation

/// A scheduled piece of work that can still be called off.
public protocol DeadlineToken: AnyObject {
    func cancel()
}

/// The timer seam. Deadlines are policy, so they are injected: the handshake's
/// three seconds are provable without waiting three seconds.
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

/// Why a voice session ended.
public enum VoiceSessionFailure: Error, Equatable, Sendable {
    /// This account's Fermix home could not be resolved, so there is no socket
    /// to connect to. Distinct from a refused connection: nothing was tried.
    case socketPathUnavailable
    case connectFailed(RealtimeConnectFailure)
    /// The socket was up but the daemon never said hello inside the window.
    case handshakeTimedOut
    /// The daemon's advertised window excludes the version this build speaks.
    case versionUnsupported(direction: RealtimeVersionDirection, minimum: Int, maximum: Int)
    /// The daemon refused, in its own words.
    case refused(reason: String)
    case transport(RealtimeTransportFailure)
}

/// The realtime voice session: this build's protocol version, the
/// `client_hello` / `server_hello` handshake and its deadline, and the routing
/// of everything that arrives afterwards.
///
/// The session owns the negotiation and nothing else: it holds no audio, no
/// call state, and no presentation. Nothing reaches the application until the
/// daemon's window has been checked, because a client that has not negotiated
/// cannot know whether the events it is reading mean what it thinks.
@MainActor
public final class VoiceSession {
    public enum Phase: Equatable, Sendable {
        case disconnected
        case connecting
        case handshaking
        case negotiated
    }

    public var onNegotiated: ((RealtimeVersionWindow) -> Void)?
    public var onEvent: ((RealtimeServerEvent) -> Void)?
    public var onFailed: ((VoiceSessionFailure) -> Void)?

    public private(set) var phase: Phase = .disconnected

    private let transport: any RealtimeTransport
    private let socketPath: () throws -> String
    private let deadlines: any DeadlineScheduling
    private let protocolVersion: Int
    private let log = AppLog.logger(.voice)
    private var handshakeDeadline: DeadlineToken?

    /// The socket path is resolved at connect time, not at construction: it
    /// comes from the bootstrap record, which activation may not have written
    /// yet when the app starts.
    public init(
        transport: any RealtimeTransport,
        socketPath: @escaping () throws -> String,
        deadlines: any DeadlineScheduling,
        protocolVersion: Int = RealtimeProtocol.version
    ) {
        self.transport = transport
        self.socketPath = socketPath
        self.deadlines = deadlines
        self.protocolVersion = protocolVersion

        transport.onEvent = { [weak self] event in
            self?.receive(event)
        }
        transport.onFailure = { [weak self] failure in
            self?.end(.transport(failure))
        }
    }

    // MARK: - Lifecycle

    public func connect() {
        guard phase == .disconnected else { return }

        let path: String
        do {
            path = try socketPath()
        } catch {
            log.error("no realtime socket path: \(String(describing: error), privacy: .public)")
            report(.socketPathUnavailable)
            return
        }

        phase = .connecting
        transport.connect(path: path) { [weak self] result in
            self?.connected(result)
        }
    }

    public func send(_ event: RealtimeClientEvent) {
        guard phase == .negotiated else {
            log.error("refusing to send \(event.wireType, privacy: .public) before negotiation")
            return
        }
        transport.send(event)
    }

    public func sendAudioChunk(_ chunk: Data) {
        guard phase == .negotiated else { return }
        transport.sendAudioChunk(chunk)
    }

    /// The sink the capture tap writes into.
    ///
    /// It reaches the transport directly because it is invoked on the Core
    /// Audio thread: routing 100 ms chunks through this main-actor object would
    /// queue audio behind a busy main thread with none of the drop-oldest
    /// protection the socket's own outbound buffer provides. The transport
    /// discards chunks once it is closed, and the audio owner detaches the tap
    /// when the call ends, so nothing can outlive the session.
    public func audioSink() -> @Sendable (Data) -> Void {
        let transport = self.transport

        return { chunk in transport.sendAudioChunk(chunk) }
    }

    public func close() {
        cancelDeadline()
        phase = .disconnected
        transport.close()
    }

    // MARK: - Handshake

    private func connected(_ result: Result<Void, RealtimeConnectFailure>) {
        guard phase == .connecting else { return }

        switch result {
        case .success:
            phase = .handshaking
            transport.send(.clientHello(protocolVersion: protocolVersion))
            handshakeDeadline = deadlines.schedule(after: RealtimeProtocol.handshakeTimeout) { [weak self] in
                self?.handshakeExpired()
            }
        case .failure(let failure):
            phase = .disconnected
            report(.connectFailed(failure))
        }
    }

    private func handshakeExpired() {
        guard phase == .handshaking else { return }

        handshakeDeadline = nil
        end(.handshakeTimedOut)
    }

    private func receive(_ event: RealtimeServerEvent) {
        switch phase {
        case .disconnected, .connecting:
            log.debug("ignoring \(event.wireType, privacy: .public) outside a session")
        case .handshaking:
            handshake(event)
        case .negotiated:
            route(event)
        }
    }

    private func handshake(_ event: RealtimeServerEvent) {
        switch event {
        case .serverHello(let minimum, let maximum):
            negotiate(RealtimeVersionWindow(minimum: minimum, maximum: maximum))
        case .error(let failure):
            end(Self.failure(for: failure))
        default:
            // A daemon that predates the handshake answers `state` first. The
            // deadline is what ends that, not a guess about what it meant.
            log.debug("ignoring \(event.wireType, privacy: .public) while awaiting server_hello")
        }
    }

    private func negotiate(_ window: RealtimeVersionWindow) {
        cancelDeadline()

        guard window.contains(protocolVersion) else {
            end(
                .versionUnsupported(
                    direction: window.direction(for: protocolVersion),
                    minimum: window.minimum,
                    maximum: window.maximum
                )
            )
            return
        }

        phase = .negotiated
        onNegotiated?(window)
    }

    private func route(_ event: RealtimeServerEvent) {
        // Negotiation is a single transition, not a re-negotiable state.
        if case .serverHello = event {
            log.debug("ignoring a second server_hello")
            return
        }

        onEvent?(event)
    }

    private static func failure(for error: RealtimeServerError) -> VoiceSessionFailure {
        guard let direction = error.direction, let window = error.window else {
            return .refused(reason: error.reason)
        }

        return .versionUnsupported(direction: direction, minimum: window.minimum, maximum: window.maximum)
    }

    // MARK: - Teardown

    private func end(_ failure: VoiceSessionFailure) {
        guard phase != .disconnected else { return }

        cancelDeadline()
        phase = .disconnected
        transport.close()
        report(failure)
    }

    private func report(_ failure: VoiceSessionFailure) {
        log.error("voice session ended: \(String(describing: failure), privacy: .public)")
        onFailed?(failure)
    }

    private func cancelDeadline() {
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
    }
}

extension VoiceSession {
    /// A session against a fixed path, for a caller that already resolved one.
    public convenience init(
        transport: any RealtimeTransport,
        socketPath: String,
        deadlines: any DeadlineScheduling,
        protocolVersion: Int = RealtimeProtocol.version
    ) {
        precondition(!socketPath.isEmpty, "a voice session needs a socket path")

        self.init(
            transport: transport,
            socketPath: { socketPath },
            deadlines: deadlines,
            protocolVersion: protocolVersion
        )
    }
}
