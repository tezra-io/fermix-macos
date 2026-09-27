import Darwin
import Foundation

/// The companion chat session: this build's protocol version, the
/// `client_hello` / `server_hello` handshake and its deadline, the connection's
/// lifetime, and every request a surface makes.
///
/// It connects when first asked and then stays connected: a connection that
/// fails is tried again after a bounded backoff, forever, and every handshake
/// begins with the catch-up read and the outbox. Only a daemon that cannot
/// speak this build's version ends that, until chat is asked for again.
///
/// What the chat holds is decided by `CompanionReducer`; this owns the socket
/// and the clock, sends what the reducer answers, and publishes the result to
/// `model`, which nothing else writes.
@MainActor
public final class CompanionSession {
    private enum Phase: Equatable {
        case idle
        case connecting
        case handshaking
        case connected
        /// Waiting out the backoff before the next attempt.
        case waiting
        /// The daemon cannot speak this build's version. Nothing is retried.
        case refused
    }

    /// How long each consecutive failure waits before the next attempt. The
    /// last delay repeats, so a daemon that is down for a day is asked twice a
    /// minute, and a successful handshake starts the sequence again.
    static let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    public let model = CompanionModel()

    private let transport: CompanionSocketClient
    private let socketPath: () throws -> String
    private let deadlines: any DeadlineScheduling
    private let messageIds: () -> String
    private let protocolVersion: Int
    private let log = AppLog.logger(.companion)

    private var phase: Phase = .idle
    private var chat = CompanionChat()
    /// The handshake deadline or the reconnect timer; never both.
    private var deadline: DeadlineToken?
    private var consecutiveFailures = 0

    /// The socket path is resolved at every attempt, not at construction: it
    /// comes from the bootstrap record, which activation may not have written
    /// yet when the app starts.
    public init(
        transport: CompanionSocketClient,
        socketPath: @escaping () throws -> String,
        deadlines: any DeadlineScheduling,
        messageIds: @escaping () -> String = { UUID().uuidString },
        protocolVersion: Int = CompanionProtocol.version
    ) {
        self.transport = transport
        self.socketPath = socketPath
        self.deadlines = deadlines
        self.messageIds = messageIds
        self.protocolVersion = protocolVersion

        transport.onEvent = { [weak self] event in
            self?.receive(event)
        }
        transport.onFailure = { [weak self] failure in
            self?.transportFailed(failure)
        }
    }

    // MARK: - Requests

    /// Asks for chat. Idempotent while a connection is live or being retried;
    /// after a version refusal it tries once more, since an update may have
    /// landed since.
    public func connect() {
        guard phase == .idle || phase == .refused else { return }

        consecutiveFailures = 0
        model.show(.connecting)
        attempt()
    }

    /// A message to the agent. It enters the outbox now and is sent at once on
    /// a live connection, or at the next handshake otherwise.
    public func send(_ text: String) {
        let clientMsgId = messageIds()
        reduce { CompanionReducer.send(text, clientMsgId: clientMsgId, into: &$0) }
    }

    /// Stops the turn of the request with this id, running or waiting.
    public func cancel(clientMsgId: String) {
        reduce { CompanionReducer.cancel(clientMsgId, into: &$0) }
    }

    /// Answers an approval with the route it named for that answer.
    public func answerApproval(_ approvalId: String, approve: Bool) {
        let clientMsgId = messageIds()
        reduce { CompanionReducer.answer(approvalId, approve: approve, clientMsgId: clientMsgId, into: &$0) }
    }

    /// The page before the oldest held row. Refused while a pull is out.
    public func pullOlder() {
        guard phase == .connected else { return }

        reduce { CompanionReducer.pullOlder(&$0) }
    }

    public func search(_ query: String) {
        guard phase == .connected else { return }

        reduce { CompanionReducer.search(query, into: &$0) }
    }

    /// The hits older than the ones shown, where the daemon said some exist.
    public func searchOlder() {
        guard phase == .connected else { return }

        reduce { CompanionReducer.searchOlder(&$0) }
    }

    public func clearSearch() {
        update { CompanionReducer.clearSearch(&$0) }
    }

    /// The surface showed the newest held row.
    public func newestRowSeen() {
        guard phase == .connected else { return }

        reduce { CompanionReducer.newestRowSeen(&$0) }
    }

    // MARK: - The connection

    private func attempt() {
        let path: String
        do {
            path = try socketPath()
        } catch {
            log.error("no companion socket path: \(String(describing: error), privacy: .public)")
            retry(showing: .disconnected(ProductStrings[.companionConnectionHomeUnavailable]))
            return
        }

        phase = .connecting
        transport.connect(path: path) { [weak self] result in
            self?.connected(result)
        }
    }

    private func connected(_ result: Result<Void, LineSocketConnectFailure>) {
        guard phase == .connecting else { return }

        switch result {
        case .success:
            phase = .handshaking
            transport.send(.clientHello(protocolVersion: protocolVersion))
            deadline = deadlines.schedule(after: CompanionProtocol.handshakeTimeout) { [weak self] in
                self?.handshakeExpired()
            }
        case .failure(.system(errno: let code)) where code == ENOENT:
            // No socket at all: an engine that predates chat serves none.
            retry(showing: .engineHasNoChat)
        case .failure(let failure):
            log.error("companion connect failed: \(String(describing: failure), privacy: .public)")
            retry(showing: .disconnected(ProductStrings[.companionConnectionReconnecting]))
        }
    }

    private func handshakeExpired() {
        guard phase == .handshaking else { return }

        deadline = nil
        log.error("companion daemon never answered client_hello")
        drop(showing: .disconnected(ProductStrings[.companionConnectionReconnecting]))
    }

    private func receive(_ event: CompanionServerEvent) {
        switch phase {
        case .handshaking:
            handshake(event)
        case .connected:
            route(event)
        case .idle, .connecting, .waiting, .refused:
            log.debug("ignoring \(event.wireType, privacy: .public) outside a session")
        }
    }

    private func handshake(_ event: CompanionServerEvent) {
        switch event {
        case .serverHello(let minimum, let maximum):
            negotiate(CompanionVersionWindow(minimum: minimum, maximum: maximum))
        case .error(let refusal):
            refusedDuringHandshake(refusal)
        default:
            log.debug("ignoring \(event.wireType, privacy: .public) while awaiting server_hello")
        }
    }

    private func negotiate(_ window: CompanionVersionWindow) {
        cancelDeadline()

        guard window.contains(protocolVersion) else {
            refuse(window.direction(for: protocolVersion))
            return
        }

        phase = .connected
        consecutiveFailures = 0
        model.show(.connected)
        reduce { CompanionReducer.negotiated(&$0) }
    }

    /// A refusal that names a direction is the version window's, which no retry
    /// changes; any other is the daemon's own reason, and the connection is
    /// tried again.
    private func refusedDuringHandshake(_ refusal: CompanionServerError) {
        guard let direction = refusal.direction else {
            log.error("companion daemon refused the handshake: \(refusal.reason, privacy: .public)")
            drop(showing: .disconnected(String(format: ProductStrings[.companionErrorRefusedFormat], refusal.reason)))
            return
        }

        refuse(direction)
    }

    private func route(_ event: CompanionServerEvent) {
        switch event {
        case .serverHello:
            // Negotiation is a single transition, not a re-negotiable state.
            log.debug("ignoring a second server_hello")
        case .unrecognized(let type):
            log.info("no handling for companion event \(type, privacy: .public)")
        default:
            reduce { CompanionReducer.receive(event, into: &$0) }
        }
    }

    // MARK: - Ending a connection

    private func refuse(_ direction: CompanionVersionDirection) {
        log.error("companion versions do not overlap: \(direction.rawValue, privacy: .public)")
        cancelDeadline()
        transport.close()
        phase = .refused
        update { CompanionReducer.disconnected(&$0) }
        model.show(.refused(Self.sentence(for: direction)))
    }

    private func transportFailed(_ failure: CompanionTransportFailure) {
        guard phase == .handshaking || phase == .connected else { return }

        log.error("companion connection lost: \(String(describing: failure), privacy: .public)")
        drop(showing: .disconnected(ProductStrings[.companionConnectionReconnecting]))
    }

    /// Ends the live connection and tries again after the backoff.
    private func drop(showing connection: CompanionConnection) {
        cancelDeadline()
        transport.close()
        update { CompanionReducer.disconnected(&$0) }
        retry(showing: connection)
    }

    private func retry(showing connection: CompanionConnection) {
        let delay = Self.reconnectDelays[min(consecutiveFailures, Self.reconnectDelays.count - 1)]
        consecutiveFailures += 1

        phase = .waiting
        model.show(connection)
        deadline = deadlines.schedule(after: delay) { [weak self] in
            self?.reconnectDue()
        }
    }

    private func reconnectDue() {
        guard phase == .waiting else { return }

        deadline = nil
        attempt()
    }

    private func cancelDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    private static func sentence(for direction: CompanionVersionDirection) -> String {
        switch direction {
        case .clientTooOld: return ProductStrings[.companionConnectionUpdateApp]
        case .clientTooNew: return ProductStrings[.companionConnectionUpdateEngine]
        }
    }

    // MARK: - The chat

    /// Runs one reducer step, publishes the chat it leaves, and sends what it
    /// answered. Nothing is sent before the handshake: the daemon closes a
    /// connection that asks before it, and the outbox resends at the next one.
    private func reduce(_ step: (inout CompanionChat) -> [CompanionClientEvent]) {
        let replies = step(&chat)
        model.show(chat)

        guard phase == .connected else { return }

        replies.forEach(transport.send)
    }

    /// A reducer step that answers nothing.
    private func update(_ change: (inout CompanionChat) -> Void) {
        reduce { chat in
            change(&chat)
            return []
        }
    }
}
