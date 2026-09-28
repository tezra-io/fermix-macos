import Foundation

/// The wire client's seam onto the browser pane's one owner: exactly what a
/// `browser_host` request needs, so the client is provable against a fake
/// rather than a whole `BrowserCoordinator` and its engine, profile and
/// workspace dependencies. `BrowserCoordinator` already answers every one of
/// these (`BrowserCoordinator.swift`'s conformance is empty).
@MainActor
public protocol BrowserHostCoordinating: AnyObject {
    var model: BrowserModel { get }
    func hostAttached(_ link: any BrowserHostLink, caps: BrowserTabCaps?) -> BrowserHostConnection?
    func hostDetached(_ connection: BrowserHostConnection)
    /// `tab.open`'s own caps, adopted for the connection's life the first
    /// time they are seen; false where they differ from what was already
    /// established.
    func establishTabCaps(_ caps: BrowserTabCaps) -> Bool
    /// `visible` is `tab.open`'s own flag: true when the task runs on the
    /// visible profile, which is what "launch the browser" means.
    func openTaskTab(_ url: URL, for task: BrowserTaskID, visible: Bool) -> Result<BrowserTab.ID, BrowserTabRefusal>
    func closeTaskTab(_ tab: BrowserTab.ID)
    func releaseTask(_ task: BrowserTaskID)
    func select(_ tab: BrowserTab)
    func answer(_ answer: BrowserDialogAnswer)
}

public typealias BrowserHostTransportFailure = LineSocketFailure<BrowserHostDecodeFailure>

/// The `browser_host` wire client (plan §4.0, §4.1, §4.10): this build's
/// protocol version, the `client_hello`/`server_hello` handshake, attaching as
/// the host, dispatching every daemon request onto `BrowserHostCoordinating`
/// and a tab's driving API, forwarding availability, and the quit handshake.
///
/// It connects when the app starts and stays connected: a connection that
/// fails is tried again after a bounded backoff, forever, because the daemon
/// may not be up yet or may restart, and every handshake re-attaches from
/// scratch. Only a daemon this build cannot speak a version with ends that.
///
/// The daemon answers one request at a time on its own side (BROWSER-4), but
/// this client answers out-of-order-safe by `id` regardless: a navigation or
/// a snapshot that takes a moment never blocks a request that could answer at
/// once, and nothing here assumes requests settle in the order they arrived.
///
/// Some of what the wire names has no implementation to dispatch onto yet
/// (`page.screenshot`, `page.pdf`, `cookies.get`, `cookies.clear`, and
/// `page.act`'s `get` and `wait` kinds): `BrowserPageDriving` carries no
/// capture or cookie API, and the app has no page-query or wait mechanism.
/// Each answers its own enumerated error rather than a fabricated success.
@MainActor
public final class BrowserHostClient {
    public typealias LineSocket = any LineSocketTransport<BrowserHostInbound, BrowserHostDecodeFailure>

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
    }

    /// How long each consecutive failure waits before the next attempt, the
    /// companion wire's own sequence.
    static let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// How long a line may wait to be written before the connection is
    /// declared dead.
    static let flushDeadline: TimeInterval = 5

    /// The engine never asks this build to skip taking a look; this is the
    /// value handed to `BrowserTab.act`/`.upload` where the daemon's own
    /// `observe` is false, and it is discarded there regardless.
    private static let noObservation = BrowserSnapshotRequest(mode: .interactive, maxChars: 1, depth: 1)

    private let lines: LineSocket
    private let socketPath: () throws -> String
    private let profileID: () throws -> String
    private let workspaceRoot: () throws -> URL
    private let hostVersion: String
    private let coordinator: any BrowserHostCoordinating
    private let deadlines: any DeadlineScheduling
    private let protocolVersion: Int
    private let log = AppLog.logger(.browserHost)

    private var phase: Phase = .idle
    private var deadline: DeadlineToken?
    private var consecutiveFailures = 0
    private var connection: BrowserHostConnection?
    /// This attempt's own profile id, resolved once per attempt and held for
    /// `attached` and every `host.status`.
    private var resolvedProfileID = ""
    /// The quit hold this answers `host.stop_ack` for, once the coordinator's
    /// own `task.release` writes have gone out ahead of it.
    private var quitAnswered: (@MainActor () -> Void)?

    public init(
        lines: LineSocket,
        socketPath: @escaping () throws -> String,
        profileID: @escaping () throws -> String,
        workspaceRoot: @escaping () throws -> URL,
        hostVersion: String,
        coordinator: any BrowserHostCoordinating,
        deadlines: any DeadlineScheduling,
        protocolVersion: Int = BrowserHostProtocol.version
    ) {
        self.lines = lines
        self.socketPath = socketPath
        self.profileID = profileID
        self.workspaceRoot = workspaceRoot
        self.hostVersion = hostVersion
        self.coordinator = coordinator
        self.deadlines = deadlines
        self.protocolVersion = protocolVersion

        lines.onMessage = { [weak self] inbound in
            self?.receive(inbound)
        }
        lines.onFailure = { [weak self] failure in
            self?.transportFailed(failure)
        }
    }

    /// The line socket this wire runs on, for the composition to wrap in the
    /// main-actor delivery, as the companion socket is.
    static func lineSocket() -> LineSocketClient<BrowserHostInbound, BrowserHostDecodeFailure> {
        LineSocketClient(
            name: "browser-host",
            log: AppLog.logger(.browserHost),
            inbound: BrowserHostProtocol.inboundLimits,
            outbound: LineOutboundLimits(
                flushDeadline: flushDeadline,
                maximumPendingDroppableLines: 1,
                stallDeadline: flushDeadline
            ),
            decode: { line throws(BrowserHostDecodeFailure) in try BrowserHostInbound.decode(line) }
        )
    }

    // MARK: - Connecting

    /// Asks for the connection. Idempotent while one is live or being
    /// retried; after a version refusal nothing happens until the next
    /// launch calls this again.
    public func connect() {
        guard phase == .idle || phase == .refused else { return }

        consecutiveFailures = 0
        attempt()
    }

    private func attempt() {
        let path: String
        let profile: String
        do {
            path = try socketPath()
            profile = try profileID()
        } catch {
            log.error("browser host: no socket path or profile: \(String(describing: error), privacy: .public)")
            retry()
            return
        }

        resolvedProfileID = profile
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
            deadline = deadlines.schedule(after: BrowserHostProtocol.handshakeTimeout) { [weak self] in
                self?.handshakeExpired()
            }
        case .failure(.system(errno: let code)) where code == ENOENT:
            // No socket at all: an engine that predates the browser host wire
            // serves none.
            retry()
        case .failure(let failure):
            log.error("browser host connect failed: \(String(describing: failure), privacy: .public)")
            retry()
        }
    }

    private func handshakeExpired() {
        guard phase == .handshaking else { return }

        deadline = nil
        log.error("browser host daemon never answered client_hello")
        drop()
    }

    // MARK: - The connection's lifetime

    private func receive(_ inbound: BrowserHostInbound) {
        switch phase {
        case .handshaking:
            handshake(inbound)
        case .attached:
            route(inbound)
        case .idle, .connecting, .waiting, .refused:
            log.debug("ignoring a browser host frame outside a session")
        }
    }

    private func handshake(_ inbound: BrowserHostInbound) {
        switch inbound {
        case .serverHello(let minVersion, let maxVersion):
            negotiate(BrowserHostVersionWindow(minimum: minVersion, maximum: maxVersion))
        case .error(let refusal):
            refusedDuringHandshake(refusal)
        case .request:
            log.debug("ignoring a request while awaiting server_hello")
        }
    }

    private func negotiate(_ window: BrowserHostVersionWindow) {
        cancelDeadline()

        guard window.contains(protocolVersion) else {
            refuse(window.direction(for: protocolVersion))
            return
        }

        attach(window: window)
    }

    /// A refusal that names a direction is the version window's; any other is
    /// the daemon's own reason (`host_already_attached`, most likely), and
    /// the connection is tried again.
    private func refusedDuringHandshake(_ refusal: BrowserHostDaemonError) {
        guard let direction = refusal.direction else {
            log.error("browser host daemon refused the handshake: \(refusal.reason, privacy: .public)")
            drop()
            return
        }

        refuse(direction)
    }

    private func refuse(_ direction: BrowserHostVersionDirection) {
        log.error("browser host versions do not overlap: \(direction.rawValue, privacy: .public)")
        cancelDeadline()
        lines.close()
        phase = .refused
    }

    /// Sends `attached`, then attaches locally: `BrowserCoordinator.hostAttached`
    /// answers this client's `reportAvailability(_:)` with the current report
    /// as part of attaching, which is this build's `availability` right
    /// after `attached`, exactly the sequence the contract wants. No caps are
    /// known yet: the first `tab.open` names them (`establishCaps`).
    private func attach(window: BrowserHostVersionWindow) {
        send(.attached(hostVersion: hostVersion, profileId: resolvedProfileID))

        guard let connection = coordinator.hostAttached(self, caps: nil) else {
            log.error("the browser coordinator refused to attach")
            drop()
            return
        }

        self.connection = connection
        phase = .attached
        consecutiveFailures = 0
        log.info("browser host attached, daemon window \(window.minimum, privacy: .public)-\(window.maximum, privacy: .public)")
    }

    private func route(_ inbound: BrowserHostInbound) {
        switch inbound {
        case .serverHello:
            log.debug("ignoring a second server_hello")
        case .error(let error):
            log.error("browser host daemon closed the connection: \(error.reason, privacy: .public)")
            drop()
        case .request(let request):
            dispatch(request)
        }
    }

    private func transportFailed(_ failure: BrowserHostTransportFailure) {
        guard phase == .handshaking || phase == .attached else { return }

        log.error("browser host connection lost: \(String(describing: failure), privacy: .public)")
        drop()
    }

    /// Ends the live connection, detaches locally (releasing every task tab
    /// this connection held), and tries again after the backoff.
    private func drop() {
        cancelDeadline()
        if let connection {
            coordinator.hostDetached(connection)
        }
        connection = nil
        quitAnswered = nil
        lines.close()
        retry()
    }

    private func retry() {
        let delay = Self.reconnectDelays[min(consecutiveFailures, Self.reconnectDelays.count - 1)]
        consecutiveFailures += 1

        phase = .waiting
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

    // MARK: - Sending

    private func send(_ event: BrowserHostEvent) {
        lines.send(Self.line(for: event))
    }

    private func respond(_ response: BrowserHostResponse) {
        lines.send(Self.line(for: response))
    }

    /// Every event this build ever sends fits the contract's own cap; a line
    /// that does not is a programming defect rather than a wire condition.
    private static func line(for event: BrowserHostEvent) -> Data {
        do {
            return try event.line()
        } catch {
            preconditionFailure("browser host event \(event.wireType) could not be encoded: \(error)")
        }
    }

    private static func line(for response: BrowserHostResponse) -> Data {
        do {
            return try response.line()
        } catch {
            preconditionFailure("browser host response \(response.id) could not be encoded: \(error)")
        }
    }

    private static func reasonText(_ availability: BrowserAvailability) -> String? {
        guard case .unavailable(let reason) = availability else { return nil }

        switch reason {
        case .screenLocked: return ProductStrings[.browserHostReasonScreenLocked]
        case .displayAsleep: return ProductStrings[.browserHostReasonDisplayAsleep]
        case .appTerminating: return ProductStrings[.browserHostReasonAppTerminating]
        }
    }

    /// The diagnostic's own word for a report: the wire's reason code, never
    /// the sentence `reasonText` sends the daemon, which is product copy.
    private static func availabilityLogText(_ availability: BrowserAvailability) -> String {
        guard case .unavailable(let reason) = availability else { return "available" }

        return reason.rawValue
    }

    // MARK: - Dispatch

    private func dispatch(_ request: BrowserHostRequest) {
        log.info("browser host request: \(request.wireType, privacy: .public)")

        switch request {
        case .tabOpen(let id, let payload):
            dispatchTabOpen(id: id, payload: payload)
        case .tabNavigate(let id, let payload):
            dispatchTabNavigate(id: id, payload: payload)
        case .tabList(let id, let taskId):
            dispatchTabList(id: id, taskId: taskId)
        case .tabFocus(let id, let tabId):
            dispatchTabFocus(id: id, tabId: tabId)
        case .tabClose(let id, let tabId):
            dispatchTabClose(id: id, tabId: tabId)
        case .taskRelease(let id, let taskId):
            dispatchTaskRelease(id: id, taskId: taskId)
        case .pageSnapshot(let id, let payload):
            dispatchPageSnapshot(id: id, payload: payload)
        case .pageScreenshot(let id, let payload):
            dispatchPageScreenshot(id: id, payload: payload)
        case .pagePdf(let id, let tabId, let path):
            dispatchPagePdf(id: id, tabId: tabId, path: path)
        case .pageAct(let id, let payload):
            dispatchPageAct(id: id, payload: payload)
        case .pageUpload(let id, let tabId, let ref, let path):
            dispatchPageUpload(id: id, tabId: tabId, ref: ref, path: path)
        case .dialogResolve(let id, let tabId, let accept, let text):
            dispatchDialogResolve(id: id, tabId: tabId, accept: accept, text: text)
        case .cookiesGet(let id, let tabId):
            dispatchCookiesGet(id: id, tabId: tabId)
        case .cookiesClear(let id, let tabId):
            dispatchCookiesClear(id: id, tabId: tabId)
        case .hostStatus(let id):
            dispatchHostStatus(id: id)
        case .hostStopAck(let id):
            dispatchHostStopAck(id: id)
        }
    }

    private func dispatchTabOpen(id: Int, payload: BrowserHostTabOpenRequest) {
        let task = BrowserTaskID(payload.taskId)
        guard let url = URL(string: payload.url) else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .navigationRefused, message: "not a URL: \(payload.url)")))
            return
        }
        guard let caps = BrowserTabCaps(taskTabCap: payload.taskTabCap, tabCap: payload.tabCap) else {
            respond(BrowserHostResponse(
                id: id,
                error: BrowserHostError(reason: .invalidRequest, message: "task_tab_cap and tab_cap are not usable caps")
            ))
            return
        }
        guard coordinator.establishTabCaps(caps) else {
            respond(BrowserHostResponse(
                id: id,
                error: BrowserHostError(reason: .invalidRequest, message: "task_tab_cap and tab_cap changed mid-connection")
            ))
            return
        }

        switch coordinator.openTaskTab(url, for: task, visible: payload.visible ?? false) {
        case .failure(let refusal):
            respond(BrowserHostResponse(id: id, error: wireError(for: refusal, task: payload.taskId)))
        case .success(let tabID):
            guard let tab = tab(tabID) else { return }

            Task { [weak self] in
                await self?.answerNavigation(
                    id: id, tab: tab, requestedURL: payload.url,
                    observe: payload.observe, snapshot: payload.snapshot, wrap: BrowserHostResult.tabOpen
                )
            }
        }
    }

    private func dispatchTabNavigate(id: Int, payload: BrowserHostTabNavigateRequest) {
        guard let tab = requiredTab(id: id, wireTabID: payload.tabId) else { return }
        guard let url = URL(string: payload.url) else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .navigationRefused, message: "not a URL: \(payload.url)")))
            return
        }

        tab.load(url)
        Task { [weak self] in
            await self?.answerNavigation(
                id: id, tab: tab, requestedURL: payload.url,
                observe: payload.observe, snapshot: payload.snapshot, wrap: BrowserHostResult.tabNavigate
            )
        }
    }

    private func answerNavigation(
        id: Int,
        tab: BrowserTab,
        requestedURL: String,
        observe: Bool,
        snapshot: BrowserHostSnapshotOptions?,
        wrap: @escaping (BrowserHostTabResult) -> BrowserHostResult
    ) async {
        guard observe, let snapshot else {
            respond(BrowserHostResponse(
                id: id,
                result: wrap(BrowserHostTabResult(tabId: Self.wireID(tab.id), url: tab.url?.absoluteString ?? requestedURL, title: tab.title))
            ))
            return
        }

        do {
            let taken = try await tab.snapshot(mode: snapshot.mode, maxChars: snapshot.maxChars, depth: snapshot.depth)
            respond(BrowserHostResponse(
                id: id,
                result: wrap(BrowserHostTabResult(
                    tabId: Self.wireID(tab.id), url: taken.url, title: taken.title,
                    page: Self.wirePage(taken, isLoading: tab.isLoading)
                ))
            ))
        } catch {
            respond(BrowserHostResponse(id: id, error: wireError(for: error)))
        }
    }

    private func dispatchTabList(id: Int, taskId: String) {
        let task = BrowserTaskID(taskId)
        let listed = coordinator.model.tabs
            .filter { coordinator.model.host.owner(of: $0.id) == .task(task) }
            .map { tab in
                BrowserHostListedTab(
                    tabId: Self.wireID(tab.id),
                    url: tab.url?.absoluteString ?? "",
                    title: tab.title,
                    active: tab.id == coordinator.model.selectedTabID,
                    openerTabId: coordinator.model.host.opener(of: tab.id).map(Self.wireID)
                )
            }

        respond(BrowserHostResponse(id: id, result: .tabList(listed)))
    }

    private func dispatchTabFocus(id: Int, tabId: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }

        coordinator.select(tab)
        respond(BrowserHostResponse(id: id, result: .tabFocus(tabId: tabId, url: tab.url?.absoluteString ?? "", title: tab.title)))
    }

    private func dispatchTabClose(id: Int, tabId: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }

        coordinator.closeTaskTab(tab.id)
        respond(BrowserHostResponse(id: id, result: .tabClose(tabId: tabId)))
    }

    private func dispatchTaskRelease(id: Int, taskId: String) {
        let task = BrowserTaskID(taskId)
        let released = coordinator.model.tabs
            .filter { coordinator.model.host.owner(of: $0.id) == .task(task) }
            .map(\.id)

        coordinator.releaseTask(task)
        respond(BrowserHostResponse(id: id, result: .taskRelease(released.map(Self.wireID))))
    }

    private func dispatchPageSnapshot(id: Int, payload: BrowserHostPageSnapshotRequest) {
        guard let tab = requiredTab(id: id, wireTabID: payload.tabId) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await tab.snapshot(mode: payload.mode, maxChars: payload.maxChars, depth: payload.depth)
                self.respond(BrowserHostResponse(id: id, result: .pageSnapshot(Self.wirePage(snapshot, isLoading: tab.isLoading))))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.wireError(for: error)))
            }
        }
    }

    private func dispatchPageAct(id: Int, payload: BrowserHostPageActRequest) {
        guard let tab = requiredTab(id: id, wireTabID: payload.tabId) else { return }

        guard let action = Self.action(for: payload) else {
            respond(BrowserHostResponse(
                id: id,
                error: BrowserHostError(reason: .invalidRequest, message: "\(payload.kind.rawValue) is missing the fields it needs")
            ))
            return
        }

        let observation = payload.snapshot
            .map { BrowserSnapshotRequest(mode: $0.mode, maxChars: $0.maxChars, depth: $0.depth) } ?? Self.noObservation

        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await tab.act(action, observing: observation)
                self.respond(BrowserHostResponse(id: id, result: .pageAct(Self.actResult(outcome, title: tab.title, observe: payload.observe))))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.wireError(for: error)))
            }
        }
    }

    private func dispatchPageUpload(id: Int, tabId: String, ref: Int, path: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }
        guard validatedPath(path) else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .uploadFailed, message: "the path is outside the engine's workspace")))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await tab.act(.upload(ref: ref, path: path), observing: Self.noObservation)
                self.respond(BrowserHostResponse(id: id, result: .pageUpload(tabId: tabId)))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.wireError(for: error)))
            }
        }
    }

    private func dispatchPageScreenshot(id: Int, payload: BrowserHostPageScreenshotRequest) {
        guard let tab = requiredTab(id: id, wireTabID: payload.tabId) else { return }
        guard validatedPath(payload.path) else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .writeFailed, message: "the path is outside the engine's workspace")))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let capturing = tab.capturing else { throw BrowserPageDriveError.notDrivable }
                let capture = try await capturing.screenshot(fullPage: payload.fullPage)
                try capture.data.write(to: URL(fileURLWithPath: payload.path))
                self.respond(BrowserHostResponse(id: id, result: .pageScreenshot(BrowserHostScreenshotResult(
                    path: payload.path,
                    mimeType: capture.mimeType,
                    bytes: capture.data.count,
                    url: tab.url?.absoluteString ?? "",
                    devicePixelRatio: capture.devicePixelRatio
                ))))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.captureError(for: error)))
            }
        }
    }

    private func dispatchPagePdf(id: Int, tabId: String, path: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }
        guard validatedPath(path) else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .writeFailed, message: "the path is outside the engine's workspace")))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let capturing = tab.capturing else { throw BrowserPageDriveError.notDrivable }
                let data = try await capturing.pdf()
                try data.write(to: URL(fileURLWithPath: path))
                self.respond(BrowserHostResponse(id: id, result: .pagePdf(BrowserHostPdfResult(
                    path: path, bytes: data.count, url: tab.url?.absoluteString ?? ""
                ))))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.captureError(for: error)))
            }
        }
    }

    private func dispatchCookiesGet(id: Int, tabId: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let store = tab.cookieStore else { throw BrowserPageDriveError.notDrivable }
                let cookies = try await store.cookies()
                self.respond(BrowserHostResponse(
                    id: id,
                    result: .cookiesGet(url: tab.url?.absoluteString ?? "", cookies: cookies.map(Self.wireCookie))
                ))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.wireError(for: error)))
            }
        }
    }

    private func dispatchCookiesClear(id: Int, tabId: String) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let store = tab.cookieStore else { throw BrowserPageDriveError.notDrivable }
                let cleared = try await store.clearCookies()
                self.respond(BrowserHostResponse(id: id, result: .cookiesClear(cleared: cleared)))
            } catch {
                self.respond(BrowserHostResponse(id: id, error: self.wireError(for: error)))
            }
        }
    }

    private func dispatchDialogResolve(id: Int, tabId: String, accept: Bool, text: String?) {
        guard let tab = requiredTab(id: id, wireTabID: tabId) else { return }
        guard let dialog = coordinator.model.dialog, dialog.tabID == tab.id else {
            respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .noDialog, message: "no dialog is open on tab \(tabId)")))
            return
        }

        coordinator.answer(Self.dialogAnswer(accept: accept, text: text))
        respond(BrowserHostResponse(id: id, result: .dialogResolve(tabId: tabId)))
    }

    private func dispatchHostStatus(id: Int) {
        let taskTabs = coordinator.model.host.taskTabCount
        respond(BrowserHostResponse(
            id: id,
            result: .hostStatus(BrowserHostStatusResult(
                hostVersion: hostVersion,
                profileId: resolvedProfileID,
                available: coordinator.model.host.availability == .available,
                taskTabs: taskTabs,
                personTabs: coordinator.model.tabs.count - taskTabs
            ))
        ))
    }

    /// The answer to `host_stopping`: every task bound to this connection has
    /// already had its `task.release` answered (the daemon writes that
    /// behind this), so answering it is what ends the app's held quit.
    private func dispatchHostStopAck(id: Int) {
        respond(BrowserHostResponse(id: id, result: .hostStopAck))
        let done = quitAnswered
        quitAnswered = nil
        done?()
    }

    // MARK: - Mechanics

    private func tab(_ id: BrowserTab.ID) -> BrowserTab? {
        coordinator.model.tabs.first { $0.id == id }
    }

    private static func wireID(_ id: BrowserTab.ID) -> String {
        id.uuidString
    }

    /// A tab the request named, refused as `tab_not_found` when no such tab
    /// is open, or as `not_owner` when it exists but is the person's: the
    /// daemon is the sole issuer of every tab id it ever sends back, so this
    /// checks that the tab is some task's rather than which task it is.
    private func hostOwnedTab(_ wireTabID: String) -> Result<BrowserTab.ID, BrowserHostErrorReason> {
        guard let tabID = UUID(uuidString: wireTabID) else { return .failure(.tabNotFound) }

        switch coordinator.model.host.owner(of: tabID) {
        case .none: return .failure(.tabNotFound)
        case .some(.person): return .failure(.notOwner)
        case .some(.task): return .success(tabID)
        }
    }

    /// The tab a request named, or the refusal answered in its place.
    private func requiredTab(id: Int, wireTabID: String) -> BrowserTab? {
        switch hostOwnedTab(wireTabID) {
        case .failure(let reason):
            respond(BrowserHostResponse(id: id, error: ownershipError(reason, tabId: wireTabID)))
            return nil
        case .success(let tabID):
            guard let tab = tab(tabID) else {
                respond(BrowserHostResponse(id: id, error: BrowserHostError(reason: .tabNotFound, message: "no tab \(wireTabID) in this host")))
                return nil
            }
            return tab
        }
    }

    private func ownershipError(_ reason: BrowserHostErrorReason, tabId: String) -> BrowserHostError {
        switch reason {
        case .tabNotFound:
            return BrowserHostError(reason: .tabNotFound, message: "no tab \(tabId) in this host")
        case .notOwner:
            return BrowserHostError(reason: .notOwner, message: "tab \(tabId) is the person's")
        default:
            return BrowserHostError(reason: reason, message: "tab \(tabId) is not available")
        }
    }

    /// A screenshot or a PDF that could not be captured or written; the
    /// contract's one reason for both (`write_failed`).
    private func captureError(for error: Error) -> BrowserHostError {
        BrowserHostError(reason: .writeFailed, message: "\(error)")
    }

    private static func wireCookie(_ cookie: BrowserCookie) -> BrowserHostCookie {
        BrowserHostCookie(
            name: cookie.name,
            domain: cookie.domain,
            path: cookie.path,
            secure: cookie.secure,
            httpOnly: cookie.httpOnly,
            sameSite: cookie.sameSite,
            expires: cookie.expires,
            session: cookie.session
        )
    }

    /// Whether `path` falls inside the engine's own workspace, the one root a
    /// screenshot, a PDF or an upload path may write inside.
    private func validatedPath(_ path: String) -> Bool {
        guard let root = try? workspaceRoot() else { return false }

        let standardizedRoot = root.standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/")
    }

    private func wireError(for refusal: BrowserTabRefusal, task: String) -> BrowserHostError {
        switch refusal {
        case .notAttached:
            return BrowserHostError(reason: .hostUnavailable, message: ProductStrings[.browserHostReasonNotAttached])
        case .stopping:
            return BrowserHostError(reason: .hostUnavailable, message: ProductStrings[.browserHostReasonAppTerminating])
        case .unavailable(let reason):
            return BrowserHostError(reason: .hostUnavailable, message: Self.reasonText(.unavailable(reason)) ?? "")
        case .taskCap:
            let cap = coordinator.model.host.caps?.perTask ?? 0
            return BrowserHostError(reason: .capReached, message: "task \(task) already owns \(cap) tabs")
        case .globalCap:
            let cap = coordinator.model.host.caps?.global ?? 0
            return BrowserHostError(reason: .capReached, message: "the browser host already holds \(cap) tabs")
        case .notTheTasksTab:
            return BrowserHostError(reason: .notOwner, message: "the tab is not this task's")
        case .websiteDataUnreadable:
            return BrowserHostError(reason: .hostUnavailable, message: ProductStrings[.browserNoticeProfileUnavailable])
        }
    }

    private func wireError(for error: Error) -> BrowserHostError {
        guard let drive = error as? BrowserPageDriveError else {
            return BrowserHostError(reason: .actFailed, message: "\(error)")
        }

        switch drive {
        case .notDrivable:
            return BrowserHostError(reason: .hostUnavailable, message: "this tab has no page driver")
        case .staleRef(let ref):
            return BrowserHostError(reason: .staleRef, message: "no element \(ref) on this page")
        case .noRenderedBox(let ref):
            return BrowserHostError(reason: .actFailed, message: "element \(ref) has no box on screen")
        case .outsideView:
            return BrowserHostError(reason: .actFailed, message: "the point lies outside the page")
        case .unknownKey(let key):
            return BrowserHostError(reason: .invalidRequest, message: "unknown key \(key)")
        case .notEditable(let ref):
            return BrowserHostError(reason: .actFailed, message: "element \(ref) is not editable")
        case .notSelect(let ref):
            return BrowserHostError(reason: .actFailed, message: "element \(ref) is not a select")
        case .noOption(let ref):
            return BrowserHostError(reason: .actFailed, message: "no matching option on element \(ref)")
        case .noForm(let ref):
            return BrowserHostError(reason: .actFailed, message: "element \(ref) has no form")
        case .notFileInput(let ref):
            return BrowserHostError(reason: .uploadFailed, message: "element \(ref) is not a file input")
        case .uploadNotAccepted(let ref):
            return BrowserHostError(reason: .uploadFailed, message: "element \(ref) did not accept the file")
        case .detached:
            return BrowserHostError(reason: .actFailed, message: "the page is not in any window")
        case .unresponsive:
            return BrowserHostError(reason: .dialogBlocked, message: "a dialog is blocking the page")
        case .script(let word):
            return BrowserHostError(reason: .actFailed, message: word)
        case .formStopped(let ref, _, let cause):
            return BrowserHostError(reason: .invalidRequest, message: "fill_form stopped at \(ref): \(wireError(for: cause).message)")
        case .waitTimedOut:
            return BrowserHostError(reason: .waitTimeout, message: "the wait condition never became true")
        case .invalidRequest(let message):
            return BrowserHostError(reason: .invalidRequest, message: message)
        }
    }

    private static func action(for payload: BrowserHostPageActRequest) -> BrowserPageAction? {
        switch payload.kind {
        case .click:
            return payload.ref.map { .click(ref: $0) }
        case .hover:
            return payload.ref.map { .hover(ref: $0) }
        case .submit:
            return payload.ref.map { .submit(ref: $0) }
        case .fill:
            guard let ref = payload.ref, let text = payload.text else { return nil }
            return .fill(ref: ref, text: text)
        case .type:
            guard let ref = payload.ref, let text = payload.text else { return nil }
            return .type(ref: ref, text: text)
        case .fillForm:
            guard let fields = payload.fields, !fields.isEmpty else { return nil }
            return .fillForm(fields.map { BrowserFormField(ref: $0.ref, text: $0.text) })
        case .press:
            return payload.key.map { .press(key: $0) }
        case .clickCoords:
            guard let x = payload.x, let y = payload.y else { return nil }
            return .clickCoordinates(x: x, y: y)
        case .get:
            let field = payload.field ?? .text
            return .get(field: BrowserGetField(rawValue: field.rawValue) ?? .text, selector: payload.selector)
        case .wait:
            guard let waitUntil = payload.waitUntil, let timeoutMs = payload.timeoutMs else { return nil }
            return .wait(
                until: BrowserWaitUntil(rawValue: waitUntil.rawValue) ?? .load,
                text: payload.text,
                selector: payload.selector,
                ref: payload.ref,
                timeoutMs: timeoutMs
            )
        }
    }

    private static func actResult(_ outcome: BrowserActOutcome, title: String, observe: Bool) -> BrowserHostActResult {
        let page: BrowserHostPage?
        if observe, case .changed(let snapshot) = outcome.effect {
            page = wirePage(snapshot, isLoading: false)
        } else {
            page = nil
        }

        return BrowserHostActResult(url: outcome.url, title: title, value: wireValue(outcome), page: page)
    }

    /// A `get`'s read takes precedence, in the shape its field answers; every
    /// other kind's own textual `value` (a fill's or a select's) rides along
    /// as a string, as it always has, though the engine reads it for `get`
    /// alone (`act_receipt` in `host_server.ex`).
    private static func wireValue(_ outcome: BrowserActOutcome) -> BrowserHostJSONValue? {
        guard let read = outcome.read else {
            return outcome.value.map(BrowserHostJSONValue.string)
        }

        switch read {
        case .text(let value):
            return .string(value)
        case .count(let value):
            return .integer(value)
        case .rect(let rect):
            return .object([
                "x": .double(rect.x),
                "y": .double(rect.y),
                "width": .double(rect.width),
                "height": .double(rect.height)
            ])
        }
    }

    private static func dialogAnswer(accept: Bool, text: String?) -> BrowserDialogAnswer {
        guard accept else { return .dismissed }
        if let text { return .text(text) }

        return .confirmed
    }

    private static func wirePage(_ snapshot: BrowserPageSnapshot, isLoading: Bool) -> BrowserHostPage {
        BrowserHostPage(
            url: snapshot.url,
            title: snapshot.title,
            readyState: isLoading ? "loading" : "complete",
            nodes: snapshot.nodes.map(wireNode)
        )
    }

    private static func wireNode(_ node: BrowserPageNode) -> BrowserHostNode {
        BrowserHostNode(
            nodeId: .integer(node.id),
            role: BrowserHostAXValue(node.role),
            name: node.name.isEmpty ? nil : BrowserHostAXValue(node.name),
            value: node.value.map(BrowserHostAXValue.init),
            properties: wireProperties(node.properties),
            backendDOMNodeId: node.ref,
            childIds: node.childIds.isEmpty ? nil : node.childIds.map { .integer($0) }
        )
    }

    private static func wireProperties(_ properties: BrowserPageNode.Properties?) -> [BrowserHostAXProperty]? {
        guard let properties else { return nil }

        var result: [BrowserHostAXProperty] = []
        if let editable = properties.editable {
            result.append(BrowserHostAXProperty(name: "editable", value: BrowserHostAXValue(editable)))
        }
        if let url = properties.url {
            result.append(BrowserHostAXProperty(name: "url", value: BrowserHostAXValue(url)))
        }
        if let settable = properties.settable {
            result.append(BrowserHostAXProperty(name: "settable", value: BrowserHostAXValue(settable)))
        }
        if let crossOrigin = properties.crossOrigin {
            result.append(BrowserHostAXProperty(name: "cross_origin", value: BrowserHostAXValue(crossOrigin)))
        }
        return result.isEmpty ? nil : result
    }
}

extension BrowserHostClient: BrowserHostLink {
    /// Sent at attach (from inside `BrowserCoordinator.hostAttached`) and
    /// again on every change the coordinator observes.
    public func reportAvailability(_ availability: BrowserAvailability) {
        let available = availability == .available
        log.info("browser host availability: \(Self.availabilityLogText(availability), privacy: .public)")
        send(.availability(available: available, reason: available ? nil : Self.reasonText(availability)))
    }

    /// A task's tab closed without a `task.release`: its page closed its own
    /// window.
    public func tabClosed(_ tab: BrowserTab.ID, task: BrowserTaskID) {
        send(.tabClosed(tabId: Self.wireID(tab), by: .page))
    }

    /// The person's "Cancel task", from its tab in the pane. The daemon's own
    /// `task.release` behind this is what releases the tabs; this build's
    /// local state keeps the tab until then.
    public func cancelTask(_ task: BrowserTaskID) {
        send(.taskCancel(taskId: task.rawValue, reason: ProductStrings[.browserHostReasonPersonCancelled]))
    }

    public func sendHostStopping(answered: @escaping @MainActor () -> Void) {
        quitAnswered = answered
        send(.hostStopping)
    }
}
