import Combine
import Foundation

public typealias NativeHostTransportFailure = LineSocketFailure<NativeHostDecodeFailure>

/// The `native_host` wire client (M76 §4.4): this build's protocol version,
/// the `client_hello`/`server_hello` handshake, attaching as the host,
/// reporting the app's grants, answering every daemon request by `id` onto
/// `MacNotifications`, the person's presses on a notification, and the quit
/// handshake.
///
/// It connects when the app starts and stays connected, by the browser host
/// client's rule: a connection that fails is tried again after a bounded
/// backoff, forever, because the daemon may not be up yet or may restart, and
/// every handshake re-attaches from scratch. Exactly one attempt is ever in
/// flight, and `ReconnectBackoff` only resets once an attach has held past its
/// grace. Only a daemon this build cannot speak a version with, or the app
/// quitting, ends that.
///
/// It never decides whether Fermix may ring. It reports the grant the
/// framework gives, and answers each request with what the framework did.
@MainActor
public final class NativeHostClient {
    public typealias LineSocket = any LineSocketTransport<NativeHostInbound, NativeHostDecodeFailure>

    private enum Phase: Equatable {
        case idle
        case connecting
        case handshaking
        case attached
        /// Waiting out the backoff before the next attempt.
        case waiting
        /// The daemon cannot speak this build's version. Nothing is retried
        /// until the app is asked to connect again (a fresh launch).
        case refused
        /// The app is quitting. Final: nothing reconnects, and a request
        /// already on the wire is answered `host_unavailable`.
        case stopped
    }

    /// How long a line may wait to be written before the connection is
    /// declared dead.
    static let flushDeadline: TimeInterval = 5

    private let lines: LineSocket
    private let socketPath: () throws -> String
    private let hostVersion: String
    private let notifications: MacNotifications
    private let deadlines: any DeadlineScheduling
    private let protocolVersion: Int
    private let log = AppLog.logger(.nativeHost)

    private var phase: Phase = .idle
    private var deadline: DeadlineToken?
    private var backoff = ReconnectBackoff()
    /// Which attach this is. An answer worked out across a suspension goes
    /// out only on the connection that asked: request ids start over on every
    /// connection, so a late answer on the next one would answer a request it
    /// was never meant for.
    private var connection = 0
    /// The grant this connection last reported. Nil until its first
    /// `capabilities`.
    private var reported: NotificationGrant?
    /// Presses made while no connection had reported its grants, as when a
    /// press on a notification is what launched the app. Each is the
    /// person's own act, so it goes out once a connection has.
    private var pendingPresses: [NotificationPress] = []
    private var quitDone: (@MainActor () -> Void)?
    private var quitBoundToken: DeadlineToken?
    private var grantChanges: AnyCancellable?

    /// - Parameter deadlines: one scheduler for the handshake, the backoff
    ///   and the quit's bound. The bound has to fire while AppKit holds the
    ///   termination, so the composition hands a run-loop scheduler.
    public init(
        lines: LineSocket,
        socketPath: @escaping () throws -> String,
        hostVersion: String,
        notifications: MacNotifications,
        deadlines: any DeadlineScheduling,
        protocolVersion: Int = NativeHostProtocol.version
    ) {
        self.lines = lines
        self.socketPath = socketPath
        self.hostVersion = hostVersion
        self.notifications = notifications
        self.deadlines = deadlines
        self.protocolVersion = protocolVersion

        lines.onMessage = { [weak self] inbound in
            self?.receive(inbound)
        }
        lines.onFailure = { [weak self] failure in
            self?.transportFailed(failure)
        }
        notifications.onPress = { [weak self] press in
            self?.pressed(press)
        }
        grantChanges = notifications.grantChanged.sink { [weak self] grant in
            self?.report(grant)
        }
    }

    /// The line socket this wire runs on, for the composition to wrap in the
    /// main-actor delivery, as the browser host's is.
    static func lineSocket() -> LineSocketClient<NativeHostInbound, NativeHostDecodeFailure> {
        LineSocketClient(
            name: "native-host",
            log: AppLog.logger(.nativeHost),
            inbound: NativeHostProtocol.inboundLimits,
            outbound: LineOutboundLimits(
                flushDeadline: flushDeadline,
                maximumPendingDroppableLines: 1,
                stallDeadline: flushDeadline
            ),
            decode: { line throws(NativeHostDecodeFailure) in try NativeHostInbound.decode(line) }
        )
    }

    // MARK: - Connecting

    /// Asks for the connection. Idempotent while one is live or being
    /// retried; after a version refusal nothing happens until the next launch
    /// calls this again, and after the quit nothing happens at all.
    public func connect() {
        guard phase == .idle || phase == .refused else { return }

        backoff = ReconnectBackoff()
        attempt()
    }

    private func attempt() {
        let path: String
        do {
            path = try socketPath()
        } catch {
            log.error("native host: no socket path: \(String(describing: error), privacy: .public)")
            retry()
            return
        }

        phase = .connecting
        lines.connect(path: path) { [weak self] result in
            self?.connected(result)
        }
    }

    private func connected(_ result: Result<Void, LineSocketConnectFailure>) {
        guard phase == .connecting else { return }

        switch result {
        case .success:
            phase = .handshaking
            send(.clientHello(protocolVersion: protocolVersion))
            deadline = deadlines.schedule(after: NativeHostProtocol.handshakeTimeout) { [weak self] in
                self?.handshakeExpired()
            }
        case .failure(.system(errno: let code)) where code == ENOENT:
            // No socket at all: an engine that predates the native host wire,
            // or one that is not the app's own, serves none.
            retry()
        case .failure(let failure):
            log.error("native host connect failed: \(String(describing: failure), privacy: .public)")
            retry()
        }
    }

    private func handshakeExpired() {
        guard phase == .handshaking else { return }

        deadline = nil
        log.error("native host daemon never answered client_hello")
        drop()
    }

    // MARK: - The connection's lifetime

    private func receive(_ inbound: NativeHostInbound) {
        switch phase {
        case .handshaking:
            handshake(inbound)
        case .attached, .stopped:
            route(inbound)
        case .idle, .connecting, .waiting, .refused:
            log.debug("ignoring a native host frame outside a session")
        }
    }

    private func handshake(_ inbound: NativeHostInbound) {
        switch inbound {
        case .serverHello(let minVersion, let maxVersion):
            negotiate(NativeHostVersionWindow(minimum: minVersion, maximum: maxVersion))
        case .error(let refusal):
            refusedDuringHandshake(refusal)
        case .request:
            log.debug("ignoring a request while awaiting server_hello")
        }
    }

    private func negotiate(_ window: NativeHostVersionWindow) {
        cancelDeadline()

        guard window.contains(protocolVersion) else {
            refuse(window.direction(for: protocolVersion))
            return
        }

        attach(window: window)
    }

    /// A refusal that names a direction is the version window's; any other is
    /// the daemon's own reason (`host_already_attached`, `untrusted_host`),
    /// and the connection is tried again.
    private func refusedDuringHandshake(_ refusal: NativeHostDaemonError) {
        guard let direction = refusal.direction else {
            log.error("native host daemon refused the handshake: \(refusal.reason, privacy: .public)")
            drop()
            return
        }

        refuse(direction)
    }

    private func refuse(_ direction: NativeHostVersionDirection) {
        log.error("native host versions do not overlap: \(direction.rawValue, privacy: .public)")
        cancelDeadline()
        lines.close()
        phase = .refused
    }

    /// Sends `attached`, then the grant as the framework answers it now: the
    /// contract's `capabilities` right after attaching. The grant is read
    /// fresh rather than taken from the last read, because it can change in
    /// System Settings while nothing is listening.
    private func attach(window: NativeHostVersionWindow) {
        send(.attached(hostVersion: hostVersion))
        phase = .attached
        connection += 1
        reported = nil
        log.info("native host attached, daemon window \(window.minimum, privacy: .public)-\(window.maximum, privacy: .public)")
        // The backoff resets only once this attach has held past the grace:
        // a daemon that accepts and drops right away is still a failure, not
        // a fresh start.
        deadline = deadlines.schedule(after: ReconnectBackoff.grace) { [weak self] in
            self?.graceHeld()
        }

        let attachedOn = connection
        Task { [weak self, notifications] in
            let grant = await notifications.refresh()
            guard let self, self.connection == attachedOn else { return }

            self.report(grant)
        }
    }

    /// The grace held with no loss: the next loss starts the backoff over
    /// rather than continuing to grow it.
    private func graceHeld() {
        guard phase == .attached else { return }

        deadline = nil
        backoff.reset()
    }

    private func route(_ inbound: NativeHostInbound) {
        switch inbound {
        case .serverHello:
            log.debug("ignoring a second server_hello")
        case .error(let error):
            log.error("native host daemon closed the connection: \(error.reason, privacy: .public)")
            lost()
        case .request(let request):
            dispatch(request)
        }
    }

    private func transportFailed(_ failure: NativeHostTransportFailure) {
        guard phase == .handshaking || phase == .attached || phase == .stopped else { return }

        log.error("native host connection lost: \(String(describing: failure), privacy: .public)")
        lost()
    }

    /// The connection ended. While quitting nothing can answer `host_stopping`
    /// any more, so the hold ends at once and nothing reconnects; otherwise
    /// the connection is tried again after the backoff.
    private func lost() {
        guard phase != .stopped else {
            lines.close()
            quitHoldEnded()
            return
        }

        drop()
    }

    /// Ends the live connection and tries again after the backoff.
    private func drop() {
        cancelDeadline()
        reported = nil
        lines.close()
        retry()
    }

    private func retry() {
        phase = .waiting
        deadline = deadlines.schedule(after: backoff.nextDelay()) { [weak self] in
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

    // MARK: - What the app says unasked

    /// Sends `capabilities` where the grant differs from what this
    /// connection last reported: at attach, after the person answers the
    /// prompt, and on a return to the app that finds it changed. The first
    /// report on a connection is what the person's held presses wait for.
    private func report(_ grant: NotificationGrant) {
        guard phase == .attached, grant != reported else { return }

        let first = reported == nil
        reported = grant
        log.info("native host capabilities: notifications \(grant.rawValue, privacy: .public)")
        send(.capabilities(notifications: grant))
        if first { sendPendingPresses() }
    }

    private func pressed(_ press: NotificationPress) {
        switch phase {
        case .attached where reported != nil:
            send(.notificationAction(reminderId: press.reminderID, action: press.action))
        case .stopped:
            log.info("native host: a press on a notification arrived as the app quits, and is not sent")
        case .idle, .connecting, .handshaking, .attached, .waiting, .refused:
            pendingPresses.append(press)
        }
    }

    private func sendPendingPresses() {
        let held = pendingPresses
        pendingPresses = []
        for press in held {
            send(.notificationAction(reminderId: press.reminderID, action: press.action))
        }
    }

    // MARK: - Sending

    private func send(_ event: NativeHostEvent) {
        lines.send(Self.line(for: event))
    }

    private func respond(_ response: NativeHostResponse) {
        lines.send(Self.line(for: response))
    }

    /// Answers `id` with what `work` answers, once it has, on the connection
    /// that asked and on no other.
    private func answer(_ id: Int, _ work: @escaping @MainActor () async -> NativeHostResponse) {
        let askedOn = connection
        Task { [weak self] in
            let response = await work()
            guard let self, self.connection == askedOn, self.phase == .attached || self.phase == .stopped else { return }

            self.respond(response)
        }
    }

    /// Every line this build ever sends fits the contract's own cap; a line
    /// that does not is a programming defect rather than a wire condition.
    private static func line(for event: NativeHostEvent) -> Data {
        do {
            return try event.line()
        } catch {
            preconditionFailure("native host event \(event.wireType) could not be encoded: \(error)")
        }
    }

    private static func line(for response: NativeHostResponse) -> Data {
        do {
            return try response.line()
        } catch {
            preconditionFailure("native host response \(response.id) could not be encoded: \(error)")
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ request: NativeHostRequest) {
        log.info("native host request: \(request.wireType, privacy: .public)")

        if case .hostStopAck(let id) = request {
            dispatchHostStopAck(id: id)
            return
        }
        // Only a request written before the daemon read `host_stopping` can
        // still arrive, and the daemon retries its delivery.
        guard phase == .attached else {
            respond(NativeHostResponse(
                id: request.id,
                error: NativeHostError(reason: .hostUnavailable, message: ProductStrings[.nativeHostReasonAppQuitting])
            ))
            return
        }

        switch request {
        case .notificationsAuthorize(let id):
            answer(id) { [notifications] in
                NativeHostResponse(id: id, result: .authorize(state: await notifications.authorize()))
            }
        case .notificationsPost(let id, let payload):
            dispatchPost(id: id, payload: payload)
        case .hostStatus(let id):
            answer(id) { [notifications, hostVersion] in
                NativeHostResponse(id: id, result: .hostStatus(hostVersion: hostVersion, notifications: await notifications.refresh()))
            }
        case .hostStopAck:
            preconditionFailure("host.stop_ack is answered before the dispatch table")
        }
    }

    private func dispatchPost(id: Int, payload: NativeHostPostRequest) {
        switch Self.notification(for: payload) {
        case .failure(let refusal):
            respond(NativeHostResponse(id: id, error: refusal))
        case .success(let notification):
            answer(id) { [notifications] in
                Self.response(id: id, to: await notifications.post(notification))
            }
        }
    }

    /// The daemon's answer to `host_stopping`, which ends the held quit.
    private func dispatchHostStopAck(id: Int) {
        respond(NativeHostResponse(id: id, result: .hostStopAck))
        quitHoldEnded()
    }

    private func quitHoldEnded() {
        quitBoundToken?.cancel()
        quitBoundToken = nil
        let done = quitDone
        quitDone = nil
        done?()
    }

    // MARK: - Mechanics

    /// What a post asks for, as the notification the app shows, or the
    /// `invalid_request` that says why this build cannot show it. The
    /// engine's protocol holds every bound (the lengths and the number of
    /// buttons) before it writes the request, so the app keeps no second copy
    /// of them. What is the app's own: a button this build has no id for or
    /// is asked to draw twice, and buttons with no reminder for a press to
    /// name.
    static func notification(for payload: NativeHostPostRequest) -> Result<MacNotification, NativeHostError> {
        guard payload.actions.isEmpty || payload.reminderId != nil else {
            return .failure(NativeHostError(reason: .invalidRequest, message: "a notification with buttons names the reminder they act on"))
        }

        var actions: [MacNotificationAction] = []
        for action in payload.actions {
            guard let id = NotificationActionID(rawValue: action.id) else {
                return .failure(NativeHostError(reason: .invalidRequest, message: "this app has no \(action.id) button"))
            }
            guard !actions.contains(where: { $0.id == id }) else {
                return .failure(NativeHostError(reason: .invalidRequest, message: "the \(action.id) button is named twice"))
            }
            actions.append(MacNotificationAction(id: id, title: action.title))
        }

        return .success(MacNotification(
            title: payload.title,
            body: payload.body,
            sound: payload.sound,
            reminderID: payload.reminderId,
            actions: actions
        ))
    }

    static func response(id: Int, to outcome: NotificationPostOutcome) -> NativeHostResponse {
        switch outcome {
        case .posted(let notificationID):
            return NativeHostResponse(id: id, result: .post(notificationId: notificationID))
        case .notAuthorized(let grant):
            return NativeHostResponse(id: id, error: NativeHostError(reason: .notAuthorized, message: refusalText(grant)))
        case .failed(let words):
            return NativeHostResponse(id: id, error: NativeHostError(reason: .postFailed, message: words))
        }
    }

    private static func refusalText(_ grant: NotificationGrant) -> String {
        switch grant {
        case .notGranted: return ProductStrings[.nativeHostRefusalTurnedOff]
        case .notAsked: return ProductStrings[.nativeHostRefusalNotAsked]
        case .granted: preconditionFailure("a post is never refused not_authorized while the grant is granted")
        }
    }
}

extension NativeHostClient: HostQuitting {
    /// Attached, sends `host_stopping` and holds the quit until `host.stop_ack`
    /// or the bound, whichever comes first; otherwise there is nobody to tell
    /// and the quit goes on at once. Either way this connection is the last:
    /// nothing reconnects while the app quits.
    public func stopHost(done: @escaping @MainActor () -> Void) {
        let attached = phase == .attached
        cancelDeadline()
        phase = .stopped
        pendingPresses = []
        guard attached else {
            lines.close()
            done()
            return
        }

        quitDone = done
        quitBoundToken = deadlines.schedule(after: Self.quitBound) { [weak self] in
            self?.quitHoldEnded()
        }
        send(.hostStopping)
    }
}
