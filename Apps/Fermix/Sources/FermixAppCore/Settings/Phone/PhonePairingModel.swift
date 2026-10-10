import Foundation

/// The Phone row's two reads and the Phone sheet's pairing window (M60 §4).
///
/// Every step the sheet shows is the reducer's answer to what the daemon said;
/// this owns only when each call is made. It reads the window the sheet is
/// showing once a second, which is the contract's own cadence, and cancels it
/// when the sheet closes in Scan or Compare so no window is left waiting for a
/// scan. A quit cancels nothing: the window closes on the daemon's clock.
///
/// The code drawn from the pairing link lives in the step and nowhere else, so
/// it leaves memory when the sheet leaves Scan.
@MainActor
public final class PhonePairingModel: ObservableObject {
    @Published public private(set) var status: SettingsReadState<ManagementMobileStatus> = .unread
    @Published public private(set) var devices: SettingsReadState<ManagementMobileDevices> = .unread
    @Published public private(set) var step: PhoneSheetStep = .waiting(session: nil)
    /// Whether the sheet is up. The Channels pane presents it, and every way
    /// in asks for it through `present`.
    @Published public var isPresented = false
    /// A decision on its way to the daemon, which holds both buttons.
    @Published public private(set) var isDeciding = false

    private let gateway: any DaemonQuerying
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.app)
    /// The sheet's one piece of work at a time: opening a window, deciding,
    /// and following the window to its end. A new one replaces the last.
    private var work: Task<Void, Never>?
    /// The cancel a closing sheet sends, which outlives the sheet.
    private var closing: Task<Void, Never>?

    public init(gateway: any DaemonQuerying, sleeper: any Sleeping) {
        self.gateway = gateway
        self.sleeper = sleeper
    }

    /// What the Phone row says and opens (§3.2).
    public var row: PhoneRow { PhoneRowProjection.row(status: status, devices: devices) }

    // MARK: - The row

    /// Reads the channel and its phones, which is everything the row states.
    public func readRow() async {
        _ = await readStatus()
        await readDevices()
    }

    /// A restart finished. The channel starts only at boot, so a row that has
    /// been read is read again.
    func restartCompleted() async {
        guard status != .unread else { return }

        await readRow()
    }

    // MARK: - The sheet

    /// Puts the sheet up for what the row's button, or the last setup screen,
    /// asked for.
    public func present(_ intent: PhoneSheetIntent) {
        isPresented = true
        switch intent {
        case .pair:
            run { await self.pair() }
        case .phones:
            step = .phones
            run { await self.readRow() }
        }
    }

    /// Asks the sheet to go. What going cancels is `closed`'s, since the
    /// sheet can also go by Escape or with its window.
    public func dismiss() {
        isPresented = false
    }

    /// The sheet left the screen, however it left: the window it was showing
    /// is cancelled, and nothing it was following is followed any more.
    public func closed() {
        work?.cancel()
        isDeciding = false

        let open = step.openSession
        step = .waiting(session: nil)
        guard let open else { return }

        closing = Task { await self.cancel(open) }
    }

    public func approve() {
        decide(approved: true)
    }

    public func deny() {
        decide(approved: false)
    }

    /// Ended's one way on: Pair again, or Start over, which cancels the window
    /// open somewhere else before opening a new one.
    public func takeEndingAction() {
        guard case .ended(let ending) = step else { return }

        switch ending.action {
        case .pairAgain:
            run { await self.pair() }
        case .startOver(let session):
            run {
                if let session { await self.cancel(session) }
                await self.open()
            }
        }
    }

    /// Waits for the sheet's work and a closing cancel. The window this opens
    /// is what a test uses to observe work the sheet starts and forgets.
    func settle() async {
        await work?.value
        await closing?.value
    }

    // MARK: - Pairing

    private func run(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { await body() }
    }

    private func pair() async {
        step = .waiting(session: nil)
        await open()
    }

    /// Opens the window and follows it. A window open somewhere else is read
    /// from `mobile.status`, which names it.
    private func open() async {
        step = .waiting(session: nil)

        do {
            let started = try await gateway.startPairing()
            guard !Task.isCancelled else { return await abandon(started) }

            await take(.started(started))
        } catch where ManagementMessage.code(of: error) == .busy {
            await take(await elsewhere())
        } catch {
            await take(.refused(refusal(error, "mobile.pair.start")))
        }

        await follow()
    }

    /// A start that answered after the sheet closed opened a window nobody
    /// will see, so it is cancelled at once.
    private func abandon(_ started: ManagementPairingStart) async {
        guard let session = started.session.sessionId, !started.session.state.isTerminal else { return }

        await cancel(session)
    }

    private func elsewhere() async -> PhoneAnswer {
        do {
            return .busy(try await gateway.mobileStatus().pairing)
        } catch {
            return .refused(refusal(error, "mobile.status"))
        }
    }

    /// Reads the window the sheet is showing once a second until it ends. A
    /// resumed window is read at once, since nothing of it is on screen yet.
    private func follow() async {
        if case .waiting(let session?) = step {
            await read(session)
        }

        while let session = step.openSession {
            do {
                try await sleeper.sleep(seconds: PhoneChannel.pollSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled, step.openSession == session else { return }

            await read(session)
        }
    }

    private func read(_ session: String) async {
        do {
            await take(.session(try await gateway.pairingSession(id: session)))
        } catch {
            await take(.refused(refusal(error, "mobile.pair.get")))
        }
    }

    private func decide(approved: Bool) {
        guard case .compare(let compare) = step, !isDeciding else { return }

        isDeciding = true
        run {
            defer { self.isDeciding = false }

            do {
                await self.take(.session(try await self.gateway.decidePairing(id: compare.session, approved: approved)))
            } catch {
                await self.take(.refused(self.refusal(error, "mobile.pair.decide")))
            }
        }
    }

    /// One answer, through the reducer. An answer that reaches a sheet that
    /// has moved on is dropped, and a window the answer leaves open that
    /// nothing will show is cancelled.
    private func take(_ answer: PhoneAnswer) async {
        guard !Task.isCancelled else { return }

        let transition = PhonePairing.reduce(step, answer)
        step = transition.step
        guard let abandoned = transition.abandons else { return }

        await cancel(abandoned)
    }

    /// Cancels a window. A refusal is logged and nothing more: the window
    /// closes on the daemon's own clock within two minutes regardless.
    private func cancel(_ session: String) async {
        do {
            _ = try await gateway.cancelPairing(id: session)
        } catch {
            _ = refusal(error, "mobile.pair.cancel")
        }
    }

    // MARK: - Reads

    private func readStatus() async -> ManagementMobileStatus? {
        if status.value == nil { publish(.loading, to: \.status) }

        do {
            let answer = try await gateway.mobileStatus()
            publish(.loaded(answer), to: \.status)
            return answer
        } catch {
            publish(.failure(error), to: \.status)
            _ = refusal(error, "mobile.status")
            return nil
        }
    }

    private func readDevices() async {
        if devices.value == nil { publish(.loading, to: \.devices) }

        do {
            publish(.loaded(try await gateway.mobileDevices()), to: \.devices)
        } catch {
            publish(.failure(error), to: \.devices)
            _ = refusal(error, "mobile.devices.list")
        }
    }

    /// Writes one published value only where it changed, so a re-read that
    /// found what was already known redraws nothing.
    private func publish<Value: Equatable>(
        _ value: Value,
        to property: ReferenceWritableKeyPath<PhonePairingModel, Value>
    ) {
        guard self[keyPath: property] != value else { return }

        self[keyPath: property] = value
    }

    /// The daemon's sentence for a refusal, logged with what refused. Nothing
    /// a request carried is logged, so neither is the pairing link.
    private func refusal(_ error: any Error, _ method: String) -> String {
        log.error(
            "\(method, privacy: .public) refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)"
        )

        return ManagementMessage.sentence(for: error)
    }
}
