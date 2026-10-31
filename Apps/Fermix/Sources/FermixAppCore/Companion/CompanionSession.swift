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
/// `model`, which nothing else writes. The files the engine grants are counted
/// by `grants`, which sends through this, only on a negotiated connection.
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

    /// The engine's grants of phone-side files (M66 decision 1), for the
    /// chat's tiles, the player and the pane to hold a ref's file by.
    public private(set) lazy var grants = MediaGrants { [weak self] event in
        self?.sendForGrants(event) ?? false
    }

    /// What the owner is writing and has not sent. The chat view is rebuilt on
    /// every rail change and when Settings opens, so the text lives here, beside
    /// the outbox it is on its way to. Not the model's, which holds the daemon's
    /// facts, and not published, so a keystroke redraws nothing but the field.
    public var draft = ""

    private let transport: CompanionSocketClient
    private let socketPath: () throws -> String
    private let deadlines: any DeadlineScheduling
    private let messageIds: () -> String
    private let protocolVersion: Int
    /// This Mac's clock, which a proposal's expiry is counted on (M60 §4.7).
    private let now: () -> Date
    private let log = AppLog.logger(.companion)

    private var phase: Phase = .idle
    private var chat = CompanionChat()
    /// The held rows the transcript shows, as it last reported them: the rows
    /// a handshake reads again once its catch-up has drained (M66 §3.6).
    private var onScreen: Set<Int> = []
    /// The handshake deadline or the reconnect timer; never both.
    private var deadline: DeadlineToken?
    /// The daemon's sentence while the server this desktop reaches is away
    /// or its home is moving (M75): every failed attempt after it says it
    /// again, since the engine restarting for a move is part of the same
    /// wait, until a handshake succeeds or the daemon refuses for good.
    private var serverAway: String?
    /// The socket the attempt in flight connects to, resolved at the attempt.
    private var connectionPath = ""
    /// The highest primary epoch a primary has shown at each socket (M75),
    /// kept for the session's life and sent in every hello there: a primary
    /// below it is an older copy of a home that moved. Another socket is
    /// another home, with an epoch of its own.
    private var seenEpochs: [String: Int] = [:]
    private var consecutiveFailures = 0
    /// The next proposal expiry this Mac's clock is waiting for, and its
    /// timer: one at a time, set again only when the next expiry moves.
    private var expiry: (due: Date, token: DeadlineToken)?

    /// The socket path is resolved at every attempt, not at construction: it
    /// comes from the bootstrap record, which activation may not have written
    /// yet when the app starts.
    public init(
        transport: CompanionSocketClient,
        socketPath: @escaping () throws -> String,
        deadlines: any DeadlineScheduling,
        messageIds: @escaping () -> String = { UUID().uuidString },
        protocolVersion: Int = CompanionProtocol.version,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.socketPath = socketPath
        self.deadlines = deadlines
        self.messageIds = messageIds
        self.protocolVersion = protocolVersion
        self.now = now

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

    /// Answers a proposal with the owner's decision, by its id alone. Only
    /// the card's own buttons call this: no automation route, menu command,
    /// URL or script answers a proposal (M60 §5.3).
    public func answerProposal(_ proposalId: String, decision: CompanionProposalDecision) {
        let clientMsgId = messageIds()
        reduce { CompanionReducer.answer(proposal: proposalId, decision, clientMsgId: clientMsgId, into: &$0) }
    }

    /// Asks the transcript to show a proposal's card: the menu line's, which
    /// opens Chat at the oldest card waiting.
    public func revealProposal(_ proposalId: String) {
        update { CompanionReducer.reveal(proposal: proposalId, in: &$0) }
    }

    /// The transcript showed the card it was asked for.
    public func proposalRevealServed() {
        update { $0.proposalReveal = nil }
    }

    /// The page before the oldest held row. It waits for a read out, and
    /// asking again for the same page asks nothing more.
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

    /// The held rows the transcript shows now, reported as the set changes.
    /// A row read before a disconnect is read again as it comes on screen;
    /// while there is no connection the set is kept for the next handshake.
    public func rowsOnScreen(_ seqs: Set<Int>) {
        onScreen = seqs
        guard phase == .connected else { return }

        reduce { CompanionReducer.rowsOnScreen(seqs, into: &$0) }
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
        connectionPath = path
        transport.connect(path: path) { [weak self] result in
            self?.connected(result)
        }
    }

    private func connected(_ result: Result<Void, LineSocketConnectFailure>) {
        guard phase == .connecting else { return }

        switch result {
        case .success:
            phase = .handshaking
            transport.send(.clientHello(protocolVersion: protocolVersion, primaryEpoch: seenEpochs[connectionPath]))
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
        case .serverHello(let minimum, let maximum, let primaryEpoch, let role):
            negotiate(CompanionVersionWindow(minimum: minimum, maximum: maximum), primaryEpoch: primaryEpoch, role: role)
        case .error(let refusal):
            refusedDuringHandshake(refusal)
        default:
            log.debug("ignoring \(event.wireType, privacy: .public) while awaiting server_hello")
        }
    }

    private func negotiate(_ window: CompanionVersionWindow, primaryEpoch: Int?, role: CompanionEngineRole?) {
        cancelDeadline()

        guard window.contains(protocolVersion) else {
            refuse(window.direction(for: protocolVersion))
            return
        }
        guard admits(primaryEpoch: primaryEpoch, role: role) else {
            stalePrimary()
            return
        }

        phase = .connected
        consecutiveFailures = 0
        serverAway = nil
        model.show(.connected)
        reduce { [onScreen] in CompanionReducer.negotiated(&$0, onScreen: onScreen) }
        grants.negotiated()
    }

    /// Keeps a primary's epoch as the highest seen at this socket, and says
    /// whether its hello may connect: a primary below the highest, or with
    /// none once one was seen, is an older copy of a home that moved. A
    /// device's epoch, or one from a role this build does not know, is
    /// neither compared nor kept. A hello with no role comes from a daemon
    /// older than the field, which is a primary.
    private func admits(primaryEpoch: Int?, role: CompanionEngineRole?) -> Bool {
        guard role == nil || role == .primary else { return true }

        let seen = seenEpochs[connectionPath]
        if let seen, (primaryEpoch ?? 0) < seen { return false }

        if let primaryEpoch {
            seenEpochs[connectionPath] = max(seen ?? primaryEpoch, primaryEpoch)
        }
        return true
    }

    /// A refusal that names a direction is the version window's, which no retry
    /// changes. A desktop whose home moved refuses for its own reasons: its
    /// server no longer knows it, its server is out of reach, or this app has
    /// seen a later primary. Any other is the daemon's own reason, said in its
    /// own sentence where it sent one, and the connection is tried again.
    private func refusedDuringHandshake(_ refusal: CompanionServerError) {
        switch refusal.reason {
        case CompanionProtocol.desktopRevokedReason:
            desktopRevoked(Self.sentence(for: refusal))
        case CompanionProtocol.primaryUnreachableReason:
            serverUnreachable(Self.sentence(for: refusal))
        case CompanionProtocol.stalePrimaryReason:
            stalePrimary()
        default:
            guard let direction = refusal.direction else {
                log.error("companion daemon refused the handshake: \(refusal.reason, privacy: .public)")
                drop(showing: .disconnected(Self.sentence(for: refusal)))
                return
            }

            refuse(direction)
        }
    }

    private func route(_ event: CompanionServerEvent) {
        switch event {
        case .serverHello:
            // Negotiation is a single transition, not a re-negotiable state.
            log.debug("ignoring a second server_hello")
        case .unrecognized(let type):
            log.info("no handling for companion event \(type, privacy: .public)")
        case .mediaPath(let path):
            grants.answered(path.ref, .granted(MediaGrant(path)))
        case .mediaMissing(let ref):
            grants.answered(ref, .missing)
        case .error(let refusal):
            routeRefusal(refusal)
        default:
            reduce { CompanionReducer.receive(event, into: &$0) }
        }
    }

    /// A refusal naming a media ref answers that ref's fetch; the server out
    /// of reach or no longer knowing this desktop ends the connection; any
    /// other is the chat's.
    private func routeRefusal(_ refusal: CompanionServerError) {
        if refusal.reason == CompanionProtocol.desktopRevokedReason {
            desktopRevoked(Self.sentence(for: refusal))
            return
        }
        if refusal.reason == CompanionProtocol.primaryUnreachableReason {
            serverUnreachable(Self.sentence(for: refusal))
            return
        }
        guard let ref = refusal.ref else {
            reduce { CompanionReducer.receive(.error(refusal), into: &$0) }
            return
        }

        log.error("the daemon could not grant a media file: \(refusal.reason, privacy: .public)")
        grants.answered(ref, .failed)
    }

    // MARK: - Ending a connection

    private func refuse(_ direction: CompanionVersionDirection) {
        log.error("companion versions do not overlap: \(direction.rawValue, privacy: .public)")
        stop(showing: Self.sentence(for: direction)) { CompanionReducer.disconnected(&$0) }
    }

    /// The engine answering is an older copy of a home that moved (M75): it
    /// said so, or its hello showed a lower epoch than one seen here. Nothing
    /// more is sent to it and nothing is retried; the outbox is kept, and
    /// asking for chat again tries once more.
    private func stalePrimary() {
        log.error("companion: the engine is an older copy of a home that moved")
        stop(showing: ProductStrings[.companionConnectionStalePrimary]) { CompanionReducer.disconnected(&$0) }
    }

    /// The engine here is a desktop its server no longer knows (M75): every
    /// connection is refused until the engine restarts, so the session stops
    /// as for a version refusal, the outbox is dropped with a line saying so
    /// rather than kept as sending, and the composer takes nothing. Asking
    /// for chat again tries once more.
    private func desktopRevoked(_ sentence: String) {
        log.error("companion: the server no longer knows this desktop")
        stop(showing: sentence) { CompanionReducer.revoked(&$0) }
    }

    /// The engine here is a desktop whose server cannot be reached, or whose
    /// home is moving (M75), before or after the handshake. The connection
    /// is ended here, as the daemon is about to end it, so its close is not
    /// read as a second drop; the outbox is kept and sent at the next
    /// handshake, the composer keeps taking messages into it, and the chat
    /// says the daemon's sentence until then.
    private func serverUnreachable(_ sentence: String) {
        log.error("companion: the server this desktop reaches is unreachable")
        serverAway = sentence
        drop(showing: .waiting(sentence))
    }

    /// Ends the connection and stops trying: no retry changes what the daemon
    /// said, until chat is asked for again.
    private func stop(showing sentence: String, _ change: (inout CompanionChat) -> Void) {
        cancelDeadline()
        transport.close()
        phase = .refused
        serverAway = nil
        update(change)
        grants.disconnected()
        model.show(.refused(sentence))
    }

    /// A refusal in the daemon's own sentence, or, where it sent none, in the
    /// app's words for its reason.
    private static func sentence(for refusal: CompanionServerError) -> String {
        guard let message = refusal.message, !message.isEmpty else {
            return String(format: ProductStrings[.companionErrorRefusedFormat], refusal.reason)
        }

        return message
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
        grants.disconnected()
        retry(showing: connection)
    }

    private func retry(showing connection: CompanionConnection) {
        let delay = Self.reconnectDelays[min(consecutiveFailures, Self.reconnectDelays.count - 1)]
        consecutiveFailures += 1

        phase = .waiting
        model.show(serverAway.map(CompanionConnection.waiting) ?? connection)
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
        countDownProposals()
        model.show(chat)

        guard phase == .connected else { return }

        replies.forEach(transport.send)
    }

    /// Expires every proposal this Mac's clock has passed, then waits for the
    /// next one's expiry: one timer, moved only when that expiry moves, so a
    /// reply streaming tens of deltas a second sets nothing.
    private func countDownProposals() {
        CompanionReducer.expire(at: now(), in: &chat)

        let due = CompanionReducer.nextExpiry(of: chat)
        guard due != expiry?.due else { return }

        expiry?.token.cancel()
        expiry = due.map { due in
            let token = deadlines.schedule(after: max(0, due.timeIntervalSince(now()))) { [weak self] in
                self?.proposalExpiryDue()
            }
            return (due, token)
        }
    }

    private func proposalExpiryDue() {
        expiry = nil
        update { _ in }
    }

    /// Sends one of the grants' events on a negotiated connection, and says
    /// whether there was one.
    private func sendForGrants(_ event: CompanionClientEvent) -> Bool {
        guard phase == .connected else { return false }

        transport.send(event)
        return true
    }

    /// A reducer step that answers nothing.
    private func update(_ change: (inout CompanionChat) -> Void) {
        reduce { chat in
            change(&chat)
            return []
        }
    }
}
