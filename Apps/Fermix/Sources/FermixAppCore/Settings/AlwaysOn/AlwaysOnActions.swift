import Foundation

/// The Always On pages on the web: the docs page Learn more opens, Hetzner's
/// console, and the installer the owner's own Linux server runs. Constants,
/// like the cues guide: the product's own pages, the same for every home.
public enum AlwaysOnLinks {
    public static let guide = url("https://fermix.ai/docs/always-on/")
    public static let hetznerConsole = url("https://console.hetzner.cloud/")

    /// The one command an owner's own Linux server runs, with the code
    /// inside (§7): the installer reads the code from `FERMIX_ENROLL_CODE`
    /// rather than asking for it. The code is single use and lives 30 minutes.
    public static func ownServerCommand(code: String) -> String {
        precondition(code.hasPrefix("fxenroll1."), "an enrollment code goes into the command")

        return "curl -fsSL https://fermix.ai/always-on | sudo FERMIX_ENROLL_CODE=\(code) sh"
    }

    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("an Always On link forms a url: \(text)") }

        return url
    }
}

/// The server a move goes to, as the engine names it.
public enum AlwaysOnTarget {
    /// The server the code Fermix put inside the created server enrolled,
    /// else the newest one held: the engine's own rule for the server its
    /// summary is ready for. On a linked desktop replacing its server, the
    /// server's own picture holds them.
    public static func candidate(_ status: ManagementHomeStatus?) -> String? {
        guard let status else { return nil }

        let home = status.role == .device ? status.server : status
        guard let home else { return nil }

        let held = home.candidates
        if let bound = home.enrollment?.candidateId, held.contains(where: { $0.candidateId == bound }) {
            return bound
        }
        return held.max { $0.enrolledAt < $1.enrolledAt }?.candidateId
    }
}

/// What each action of the summary does (management PROTOCOL.md, *The Always
/// On summary*), in the order each call is made.
extension AlwaysOnModel {
    /// Polls a job this long apart, up to its budget.
    static let jobPollSeconds: TimeInterval = 2
    /// The most polls one job is followed for: the provisioner's budget is
    /// fifteen minutes.
    static let jobPolls = 450

    /// Runs one action the screen offers.
    public func perform(_ action: ManagementHomeAction) async {
        guard working == nil else { return }

        refusal = nil
        notice = nil
        switch action.id {
        case .setUp: local.settingUp = true
        case .pasteToken: local.pastingToken = true
        case .replaceServer: openReplace()
        case .learnMore: openGuide()
        case .openHetzner: openHetznerConsole()
        case .update: checkForUpdates?()
        case .ownServer: await getCode()
        case .unrecognized: log.error("an action this build does not know was offered: \(action.id.wireValue, privacy: .public)")
        default: await run(action.id)
        }
    }

    /// The actions that wait on the daemon, each holding the screen's
    /// buttons until it answers.
    private func run(_ id: ManagementHomeActionId) async {
        working = id
        defer { working = nil }

        switch id {
        case .createServer: await createServer()
        case .cancel: await cancel()
        case .moveNow, .tryAgain: await moveNow()
        case .checkAgain: await checkAgain()
        case .turnOn: await power(.on)
        case .restartServer: await power(.reset)
        case .startAgain: await startAgain()
        case .createIn: await createIn()
        case .deleteServer: await deleteServer()
        case .backUpNow: await backUpNow()
        default: preconditionFailure("\(id.wireValue) does not wait on the daemon")
        }
    }

    // MARK: - The token

    /// Checks a pasted token: Hetzner reads the project, and Fermix keeps the
    /// token on this computer only. A refusal is the engine's sentence under
    /// the field.
    public func checkToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !checkingToken else { return }

        checkingToken = true
        defer { checkingToken = false }
        tokenRefusal = nil
        do {
            _ = try await gateway.provisionConnect(token: trimmed)
        } catch {
            tokenRefusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.provision.connect")
            return
        }

        local.pastingToken = false
        await refresh()
        if status?.summary?.state == .choose { await readOptions() }
    }

    // MARK: - Creating the server

    /// The size and location Create server makes: the owner's choice, else
    /// the recommendation.
    public var pick: ManagementProvisionPick? { chosen ?? options.value?.recommended }

    public func choose(_ pick: ManagementProvisionPick) {
        chosen = pick
    }

    private func createServer() async {
        if options.value == nil { await readOptions() }
        guard let pick else {
            refusal = optionsSentence
            return
        }

        await create(pick, replace: false)
    }

    /// Why there is no size and location to create: nothing is in stock, or
    /// what Hetzner sells could not be read.
    private var optionsSentence: String? {
        switch options {
        case .loaded(let options): return options.sentence
        case .unavailable(let sentence): return sentence
        case .requiresNewerEngine: return settings.newerEngineSentence
        case .unread, .loading: return nil
        }
    }

    /// Creates the server, as a job the summary follows from here.
    private func create(_ pick: ManagementProvisionPick, replace: Bool) async {
        do {
            _ = try await gateway.provisionCreate(pick, replace: replace)
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.provision.create")
        }
        await refresh()
    }

    /// Stops the `home_provision` job still running, wherever it was started,
    /// then deletes what it made: delete is refused while a job runs.
    private func cancel() async {
        do {
            let jobs = try await gateway.jobs().jobs
            if let running = jobs.first(where: { $0.kind == .homeProvision && $0.status == .running }) {
                _ = await finished(try await gateway.cancelJob(id: running.jobId))
            }
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "job.cancel")
            return
        }
        await deleteServer()
    }

    /// Deletes the server, then Start again creates one of the same type in
    /// the same location, as the record names them. A create that stopped
    /// before any server stood names none, and the size and location the
    /// owner chose, else the recommendation, are made again.
    private func startAgain() async {
        let made: ManagementProvisionPick?
        do {
            made = try await gateway.provisionResources().server.map { ManagementProvisionPick(type: $0.type, location: $0.location) }
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.provision.resources")
            return
        }
        guard await deleteServer() else { return }

        if options.value == nil, made == nil { await readOptions() }
        guard let again = made ?? pick else { return }

        await create(again, replace: onDesktop)
    }

    /// Creates the type asked for in the next location in stock: the one the
    /// owner chose, else the recommended one, since a create Hetzner had no
    /// room for left no server to name it.
    private func createIn() async {
        guard let location = status?.summary?.detail.nextLocation else { return }
        if options.value == nil, chosen == nil { await readOptions() }
        guard let type = pick?.type else { return }

        await create(ManagementProvisionPick(type: type, location: location), replace: onDesktop)
    }

    /// The pane runs on the desktop whose home lives on the server: a server
    /// it creates is always the replacement of that one.
    private var onDesktop: Bool { status?.role == .device }

    /// Deletes what Fermix created, as a job followed to its end. Answers
    /// whether it was.
    @discardableResult
    private func deleteServer() async -> Bool {
        let ended: Bool
        do {
            ended = await finished(try await gateway.provisionDelete())
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.provision.delete")
            ended = false
        }
        await refresh()
        return ended
    }

    private func power(_ action: ManagementProvisionPower) async {
        do {
            _ = await finished(try await gateway.provisionPower(action))
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.provision.power")
        }
        await reconcile()
    }

    /// Follows a job until it ends, up to its budget. Answers whether it
    /// completed; its failure is the engine's sentence under the action.
    private func finished(_ started: ManagementJob) async -> Bool {
        var job = started
        let polls = min(Self.jobPolls, Int(Double(job.budgetMs) / 1_000 / Self.jobPollSeconds) + 1)

        for _ in 0..<polls where !job.status.isTerminal {
            do {
                try await sleeper.sleep(seconds: Self.jobPollSeconds)
                job = try await gateway.job(id: job.jobId)
            } catch {
                refusal = ManagementMessage.sentence(for: error)
                return false
            }
        }

        if let failure = job.failure { refusal = failure.sentence }
        if !job.status.isTerminal { refusal = ProductStrings[.settingsJobTimedOut] }
        return job.status == .completed
    }

    // MARK: - Replacing the server

    /// Replace's sheet reads what Hetzner sells as it appears.
    private func openReplace() {
        replacing = true
    }

    public func closeReplace() {
        replacing = false
    }

    /// Creates the new server for the one the home lives on; the move to it is
    /// the same Move now (L15, §4.3).
    public func replaceServer(with pick: ManagementProvisionPick) async {
        guard working == nil else { return }

        working = .replaceServer
        defer { working = nil }
        refusal = nil
        replacing = false
        await create(pick, replace: true)
    }

    // MARK: - The move

    /// The recovery passphrase, typed twice while the server starts. Snapshots
    /// are encrypted to it from now on, and the move takes it again.
    public func setPassphrase(_ passphrase: String, again: String) async -> Bool {
        guard passphrase == again else {
            passphraseRefusal = ProductStrings[.alwaysOnPassphraseMismatch]
            return false
        }
        guard !passphrase.isEmpty, !settingPassphrase else { return false }

        settingPassphrase = true
        defer { settingPassphrase = false }
        passphraseRefusal = nil
        // The answer's sentence names the recovery key by its id, which no
        // Always On screen shows (§7): the summary says what changed.
        do {
            _ = try await gateway.setRecoveryPassphrase(passphrase)
        } catch {
            passphraseRefusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.snapshots.passphrase")
            return false
        }

        self.passphrase = passphrase
        await refresh()
        return true
    }

    /// The passphrase Move now asked for, then the move.
    public func moveWithPassphrase(_ passphrase: String, again: String) async {
        guard passphrase == again else {
            passphraseRefusal = ProductStrings[.alwaysOnPassphraseMismatch]
            return
        }
        guard !passphrase.isEmpty, working == nil else { return }

        passphraseRefusal = nil
        refusal = nil
        notice = nil
        self.passphrase = passphrase
        asksMovePassphrase = false
        await run(.moveNow)
    }

    public func dismissMovePassphrase() {
        asksMovePassphrase = false
        passphraseRefusal = nil
    }

    /// The review, then the start. A review that blocks, or that warns of
    /// something the screen did not show, stops here and the summary shows
    /// it; the next Move now starts the move.
    private func moveNow() async {
        guard let candidate = AlwaysOnTarget.candidate(status) else {
            await refresh()
            return
        }
        guard let passphrase else {
            asksMovePassphrase = true
            return
        }

        let shown = Set((page.screen.map(readiness) ?? []).map(\.id))
        do {
            let review = try await gateway.moveReadiness(candidateId: candidate)
            let unseen = review.items.filter { $0.status != .ok && !shown.contains($0.id) }
            guard review.ready, unseen.isEmpty else {
                reviewed = review.items.filter { $0.status != .ok }
                await refresh()
                return
            }
            await start(candidate, passphrase: passphrase)
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.move.readiness")
        }
    }

    /// Starts the move. A server being replaced keeps nothing once the new
    /// one runs; every other move keeps this Mac as a desktop.
    private func start(_ candidate: String, passphrase: String) async {
        let replacing = status?.role == .device
        do {
            let started = try await gateway.startMove(candidateId: candidate, passphrase: passphrase, keepAsDesktop: !replacing)
            beginOwnMove(started.sentence)
        } catch where ManagementMessage.code(of: error) == .unconfirmed {
            // No failure: the move may have started, and the summary says so
            // once the server answers again.
            let sentence = ManagementMessage.sentence(for: error)
            notice = sentence
            beginOwnMove(sentence)
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.move.start")
        }
    }

    private func beginOwnMove(_ sentence: String) {
        passphrase = nil
        local.moveStarted = sentence
    }

    /// The warnings and blocks the ready screen lists: the summary's, else
    /// those of the review this app asked for.
    public func readiness(on screen: AlwaysOnScreen) -> [ManagementReadinessItem] {
        screen.warnings.isEmpty ? reviewed : screen.warnings
    }

    private func checkAgain() async {
        guard let candidate = AlwaysOnTarget.candidate(status) else { return }

        do {
            _ = try await gateway.moveReadiness(candidateId: candidate)
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.move.readiness")
        }
        await refresh()
    }

    // MARK: - Backups and the own server

    private func backUpNow() async {
        do {
            _ = try await gateway.runSnapshot()
        } catch {
            refusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.snapshots.run")
        }
        await refresh()
    }

    /// The code for a server of the owner's own, shown once inside the
    /// command it runs.
    private func getCode() async {
        guard !gettingCode else { return }

        gettingCode = true
        defer { gettingCode = false }
        codeRefusal = nil
        do {
            handout = try await gateway.openEnrollment()
        } catch {
            codeRefusal = ManagementMessage.sentence(for: error)
            settings.noteRead(error, "home.enroll.open")
        }
        await refresh()
    }

    public func forgetCode() {
        handout = nil
    }

    /// Learn more: the Always On docs page.
    public func openGuide() {
        open(AlwaysOnLinks.guide)
    }

    /// Hetzner's console, where the token is made.
    public func openHetznerConsole() {
        open(AlwaysOnLinks.hetznerConsole)
    }

    /// Opens a page in the browser; a browser that could not open it is said
    /// under the action.
    private func open(_ url: URL) {
        guard !settings.opener.open(url) else { return }

        refusal = ProductStrings[.alwaysOnLinkOpenFailed]
    }
}
