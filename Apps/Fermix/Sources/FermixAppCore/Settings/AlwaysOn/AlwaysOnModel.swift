import Foundation

/// The Always On pane's reads and writes (M75 §14).
///
/// `home.status` is the one source: every stage, row and sentence the pane
/// draws is read off it, and every write is followed by a read of it rather
/// than by a guess at what changed. This owns only when each call is made,
/// and the few things the pane holds for as long as it shows them.
@MainActor
public final class AlwaysOnModel: ObservableObject {
    @Published public private(set) var status: SettingsReadState<ManagementHomeStatus> = .unread
    /// The daemon's refusal of Back up now, said under the button.
    @Published public private(set) var backupRefusal: String?
    @Published public private(set) var isBackingUp = false
    /// The daemon's refusal of a desktop's switch, by device id.
    @Published public private(set) var executorRefusals: [String: String] = [:]
    /// A switch on its way to the daemon, by device id.
    @Published public private(set) var executorWrites: Set<String> = []
    /// The daemon's refusal of the recovery passphrase.
    @Published public private(set) var passphraseRefusal: String?
    /// The daemon's sentence for the passphrase it took: snapshots from now
    /// on open with it, and those written before only with the earlier one.
    @Published public private(set) var passphraseNotice: String?
    @Published public private(set) var isSettingPassphrase = false
    /// Whether the last follow ran out of reads before what it watched
    /// settled, so the pane offers to look again.
    @Published public private(set) var followStopped = false
    /// Bumped to follow again after a follow ran out, which is what the
    /// pane's follow is keyed on beside `moves`.
    @Published public private(set) var followRun = 0

    // Moving the primary (M75 §7).

    /// Where the owner chose to run the server.
    @Published public var destination: AlwaysOnDestination = .aws
    /// The code the window handed out, while the pane shows it.
    @Published public private(set) var handout: EnrollmentHandout?
    @Published public private(set) var isOpeningEnrollment = false
    @Published public private(set) var enrollRefusal: String?
    /// The server the owner chose to move to, whose readiness report and
    /// passphrase form show.
    @Published public private(set) var chosenCandidate: String?
    /// The daemon's readiness report for the chosen server: what blocks and
    /// what warns before the move. The move starts only once it is read and
    /// nothing in it blocks.
    @Published public private(set) var readiness: SettingsReadState<ManagementMoveReadiness> = .unread
    @Published public private(set) var isStartingMove = false
    @Published public private(set) var moveRefusal: String?
    /// The daemon's sentence for a start whose answer was lost on its way
    /// from the server (`unconfirmed`): no failure, said while the pane
    /// follows the picture that shows how it went.
    @Published public private(set) var moveNotice: String?
    /// A move of this engine's home is under way, asked for here or found
    /// under way on the picture: the pane follows it across the engine's
    /// restarts until the engine that comes back says it is done or undone.
    @Published public private(set) var moveRequested = false
    /// The engine is away while it restarts for the move.
    @Published public private(set) var restarting = false
    /// On a desktop, the replacement of the server this pane asked for: it is
    /// followed until the server's picture answers with no move under way,
    /// the new server's or the old one's after an undone move.
    @Published public private(set) var replaceRequested = false

    // The folders the server may read on this Mac (a desktop's own).

    /// `device.grants.list`, read while This Mac shows.
    @Published public private(set) var grants: SettingsReadState<ManagementDeviceGrants> = .unread
    /// A removal on its way to the daemon, by folder.
    @Published public private(set) var grantRemovals: Set<String> = []
    /// The daemon's refusal of a removal, by folder.
    @Published public private(set) var grantRefusals: [String: String] = [:]
    /// The daemon's sentence for the last folder removed.
    @Published public private(set) var grantNotice: String?
    /// The role the last answer named while a move is followed, so an engine
    /// that came back in another role is read as a restart even where no read
    /// fell in the gap.
    private var followedRole: ManagementHomeRole?

    /// The one settings model, which owns the gateway and the restart this
    /// pane re-reads after. It owns this model, so it outlives it.
    private unowned let settings: SettingsModel
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.app)

    public init(settings: SettingsModel, sleeper: any Sleeping) {
        self.settings = settings
        self.sleeper = sleeper
    }

    private var gateway: any DaemonQuerying { settings.gateway }

    public var stage: AlwaysOnStage { AlwaysOnStage.stage(status) }

    // MARK: - Reads

    /// Reads `home.status`. A value on screen stays while it is read again,
    /// and while the engine is away for a move it is said to be restarting,
    /// not to have refused.
    public func refresh() async {
        if status.value == nil { publish(.loading, to: \.status) }

        do {
            let home = try await gateway.homeStatus()
            publish(.loaded(home), to: \.status)
            await settleInventory(home)
        } catch {
            if awayForTheMove(error) {
                publish(true, to: \.restarting)
                return
            }
            publish(.failure(error), to: \.status)
            settings.noteRead(error, "home.status")
        }
    }

    /// Reads `home.status` while it can move by itself (`moves`), a read every
    /// two seconds and fewer while the daemon refuses, up to the follow's
    /// bound. The pane runs it while it shows and cancels it when it goes.
    public func follow() async {
        var follow = AlwaysOnFollow()
        publish(false, to: \.followStopped)

        while !follow.exhausted {
            await readOnce(&follow)
            guard moves else { return }

            do {
                try await sleeper.sleep(seconds: follow.wait)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
        }

        publish(true, to: \.followStopped)
    }

    /// Whether anything on the picture can change without the owner: a
    /// snapshot being written, a server checking in to an open window, or a
    /// move under way, the restart it takes included; on a desktop, the same
    /// on the server's own picture, and the server's replacement.
    public var moves: Bool {
        if moveRequested || replaceRequested { return true }
        guard let home = status.value else { return false }

        let own = Self.moves(home, handout: replacesServer ? nil : handout)
        let server = home.server.map { Self.moves($0, handout: handout) } ?? false
        return own || server
    }

    private static func moves(_ home: ManagementHomeStatus, handout: EnrollmentHandout?) -> Bool {
        let windowOpen = home.enrollment?.state == .open || handout != nil
        return home.snapshots.running
            || (windowOpen && home.candidates.isEmpty)
            || home.move?.phase.isPending == true
    }

    /// Follows again after a follow ran out of reads.
    public func followAgain() {
        followRun += 1
    }

    /// The step of moving the primary the pane draws now: on the primary,
    /// moving this home; on a desktop, this home's own move while it is still
    /// under way, then replacing the server, drawn from the server's picture
    /// and nil while that picture is missing and nothing is being replaced.
    public var setupStep: AlwaysOnSetupStep? {
        guard let home = status.value else { return nil }
        guard replacesServer else {
            return AlwaysOnSetupStep.step(home, handout: handout, moveRequested: moveRequested, restarting: restarting)
        }
        guard let server = home.server else { return replaceRequested ? .restarting : nil }

        return AlwaysOnSetupStep.step(server, handout: handout, moveRequested: replaceRequested, restarting: false)
    }

    /// The picture the steps are about: the server's while this desktop
    /// replaces it, this home's otherwise.
    public var setupPicture: ManagementHomeStatus? {
        replacesServer ? status.value?.server : status.value
    }

    /// Whether the steps replace the server: on a desktop whose own move is
    /// over. A desktop's code, servers that checked in and move are then the
    /// server's, reached through it.
    public var replacesServer: Bool {
        guard let home = status.value, home.role == .device else { return false }

        return !moveRequested && home.move?.phase.isPending != true
    }

    /// One read of the follow. While a move is followed, a daemon that is not
    /// there is the restart the move takes, said as such rather than as a
    /// refusal, and the answer after it is read as the engine coming back.
    private func readOnce(_ follow: inout AlwaysOnFollow) async {
        do {
            let home = try await gateway.homeStatus()
            publish(.loaded(home), to: \.status)
            follow.answered()
            await settle(home)
        } catch {
            follow.refused()
            if awayForTheMove(error) {
                publish(true, to: \.restarting)
                return
            }
            settings.noteRead(error, "home.status")
        }
    }

    /// A daemon that is not there while this home's move is followed and a
    /// picture of it is on screen: the restart the move takes.
    private func awayForTheMove(_ error: any Error) -> Bool {
        moveRequested && status.value != nil && ManagementMessage.isUnreachable(error)
    }

    /// What an answer settles: a code its window spent, a move found under
    /// way, a followed move whose engine came back or ended, a replaced server
    /// that answers again, and a server's settings that are back.
    private func settle(_ home: ManagementHomeStatus) async {
        if handout != nil, let picture = codePicture(home), AlwaysOnSetupStep.spendsCode(picture) { forgetCode() }
        if !moveRequested, home.move?.phase.isPending == true {
            followedRole = home.role
            publish(true, to: \.moveRequested)
        }
        await settleMove(home)
        await settleReplacement(home)
        await settleInventory(home)
    }

    /// The window a handed code belongs to: the server's while this desktop
    /// replaces it, this home's otherwise; nil while the server's is missing.
    private func codePicture(_ home: ManagementHomeStatus) -> ManagementHomeStatus? {
        home.role == .device ? home.server : home
    }

    /// A followed move of this home. An engine that came back is re-read as
    /// after any restart, since everything Settings shows is boot bound and
    /// the role may have changed under it. An ending (`done`, `aborted`) is
    /// written only by the engine that came back, so reading one is reading
    /// that engine even where no read fell in the restart; `committed` and
    /// `undoing` are the engine about to restart, and are followed through.
    private func settleMove(_ home: ManagementHomeStatus) async {
        guard moveRequested else { return }

        let ended = home.move.map { !$0.phase.isPending } ?? false
        let cameBack = restarting || ended || (followedRole != nil && followedRole != home.role)
        followedRole = home.role
        publish(false, to: \.restarting)
        if ended {
            publish(false, to: \.moveRequested)
            publish(nil, to: \.moveNotice)
            followedRole = nil
        }
        if cameBack { await settings.restartCompleted() }
    }

    /// A replacement of the server, followed while the server's picture is
    /// missing or its move under way. It ends when the server answers with
    /// none under way: the new server, or the old one after an undone move.
    /// Every setting the panes show is the server's, so all of it is re-read.
    private func settleReplacement(_ home: ManagementHomeStatus) async {
        guard replaceRequested, let server = home.server, server.move?.phase.isPending != true else { return }

        publish(false, to: \.replaceRequested)
        publish(nil, to: \.moveNotice)
        await settings.restartCompleted()
    }

    /// The server answers again after Settings listed its sections as
    /// missing: the index is read again, with the pane on screen's sections.
    private func settleInventory(_ home: ManagementHomeStatus) async {
        guard settings.primaryMissing != nil, home.server != nil else { return }

        await settings.loadInventory()
        await settings.paneAppeared(settings.selectedPane)
    }

    /// A restart finished: what the picture says is boot bound, so a pane
    /// that has read it reads it again.
    func restartCompleted() async {
        guard status != .unread else { return }

        await refresh()
    }

    // MARK: - Moving the primary

    /// Opens the enrollment window and holds its code for the pane to show
    /// once. A second call replaces the window and the code.
    public func openEnrollment() async {
        guard !isOpeningEnrollment else { return }

        isOpeningEnrollment = true
        defer { isOpeningEnrollment = false }
        publish(nil, to: \.enrollRefusal)

        do {
            let opened = try await gateway.openEnrollment()
            handout = EnrollmentHandout(code: opened.code, expiresAt: opened.expiresAt)
            await refresh()
        } catch {
            publish(settings.refusal(error), to: \.enrollRefusal)
            log.error("home.enroll.open refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
        }
    }

    /// Forgets the handed code: the pane left it, or its window spent it.
    /// Nothing can show it again.
    public func forgetCode() {
        handout = nil
    }

    /// The server the owner chose: its readiness report is read, and its
    /// passphrase form shows beside it.
    public func choose(candidate id: String) async {
        precondition(!id.isEmpty, "a server is chosen by id")
        chosenCandidate = id
        publish(nil, to: \.moveRefusal)
        publish(.loading, to: \.readiness)

        do {
            let report = try await gateway.moveReadiness(candidateId: id)
            guard chosenCandidate == id else { return }

            publish(.loaded(report), to: \.readiness)
        } catch {
            guard chosenCandidate == id else { return }

            publish(.failure(error), to: \.readiness)
            settings.noteRead(error, "home.move.readiness")
        }
    }

    public func withdrawChoice() {
        chosenCandidate = nil
        publish(.unread, to: \.readiness)
        publish(nil, to: \.moveRefusal)
    }

    /// Whether the move to the chosen server may start: its readiness report
    /// is read and nothing in it blocks.
    public var mayStartMove: Bool {
        readiness.value?.ready == true
    }

    /// Starts the move to the chosen server with a passphrase the caller
    /// took from an entry that matched and has already forgotten. The engine
    /// answers and restarts to carry it out, which the follow picks up. On a
    /// desktop it is the server that moves, and it is not kept as a desktop.
    public func startMove(passphrase: String) async {
        precondition(!passphrase.isEmpty, "a blank passphrase is never sent")
        guard let candidate = chosenCandidate, mayStartMove, !isStartingMove else { return }

        let replacing = replacesServer
        isStartingMove = true
        defer { isStartingMove = false }
        publish(nil, to: \.moveRefusal)
        publish(nil, to: \.moveNotice)

        do {
            _ = try await gateway.startMove(candidateId: candidate, passphrase: passphrase, keepAsDesktop: !replacing)
            started(replacing: replacing)
        } catch {
            guard ManagementMessage.code(of: error) == .unconfirmed else {
                publish(settings.refusal(error), to: \.moveRefusal)
                log.error("home.move.start refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
                return
            }

            // The server had the start and its answer was lost: no failure.
            // The picture shows how it went, and a second start never starts
            // a second move.
            publish(ManagementMessage.sentence(for: error), to: \.moveNotice)
            started(replacing: replacing)
        }
    }

    /// A start the engine took, or one whose answer was lost: the choice and
    /// the code are done with, and the move is followed.
    private func started(replacing: Bool) {
        withdrawChoice()
        forgetCode()
        follow(started: replacing)
    }

    /// What a started move follows: the server's replacement, or this home's
    /// move across the engine's restart.
    private func follow(started replacing: Bool) {
        guard !replacing else {
            publish(true, to: \.replaceRequested)
            return
        }

        followedRole = status.value?.role
        publish(true, to: \.moveRequested)
    }

    // MARK: - Recovery

    /// Starts a snapshot now, then follows the picture until it is written.
    public func backUpNow() async {
        guard !isBackingUp else { return }

        isBackingUp = true
        defer { isBackingUp = false }
        publish(nil, to: \.backupRefusal)

        do {
            _ = try await gateway.runSnapshot()
            await refresh()
        } catch {
            publish(settings.refusal(error), to: \.backupRefusal)
            log.error("home.snapshots.run refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
        }
    }

    /// Sends the recovery passphrase, which the caller took from an entry
    /// that matched and has already forgotten. Answers whether the daemon
    /// took it; nothing here keeps it.
    public func setRecoveryPassphrase(_ passphrase: String) async -> Bool {
        precondition(!passphrase.isEmpty, "a blank passphrase is never sent")
        guard !isSettingPassphrase else { return false }

        isSettingPassphrase = true
        defer { isSettingPassphrase = false }
        publish(nil, to: \.passphraseRefusal)
        publish(nil, to: \.passphraseNotice)

        do {
            let key = try await gateway.setRecoveryPassphrase(passphrase)
            publish(key.sentence, to: \.passphraseNotice)
            await settings.loadSection(AlwaysOnSections.snapshots)
            await refresh()
            return true
        } catch {
            publish(settings.refusal(error), to: \.passphraseRefusal)
            log.error("home.snapshots.passphrase refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Desktops

    /// A desktop's executor switch, both ways, then the picture again.
    public func setExecutor(_ isOn: Bool, deviceId: String) async {
        precondition(!deviceId.isEmpty, "a desktop is switched by id")
        guard !executorWrites.contains(deviceId) else { return }

        executorWrites.insert(deviceId)
        defer { executorWrites.remove(deviceId) }
        executorRefusals[deviceId] = nil

        do {
            _ = try await gateway.setDeviceExecutor(id: deviceId, executor: isOn)
        } catch {
            executorRefusals[deviceId] = settings.refusal(error)
        }
        await refresh()
    }

    // MARK: - The folders the server may read here

    /// Reads the folders the server may read on this Mac. A list on screen
    /// stays while it is read again.
    public func refreshGrants() async {
        if grants.value == nil { publish(.loading, to: \.grants) }

        do {
            publish(.loaded(try await gateway.deviceGrants()), to: \.grants)
        } catch {
            publish(.failure(error), to: \.grants)
            settings.noteRead(error, "device.grants.list")
        }
    }

    /// Removes one folder, as listed, then reads the list again. It holds for
    /// the server's next read here.
    public func removeGrant(path: String) async {
        precondition(!path.isEmpty, "a grant is removed by its folder")
        guard !grantRemovals.contains(path) else { return }

        grantRemovals.insert(path)
        defer { grantRemovals.remove(path) }
        grantRefusals[path] = nil
        publish(nil, to: \.grantNotice)

        do {
            let removed = try await gateway.removeDeviceGrant(path: path)
            publish(removed.sentence, to: \.grantNotice)
        } catch {
            grantRefusals[path] = settings.refusal(error)
            log.error("device.grants.remove refused: \(ManagementMessage.diagnostic(for: error), privacy: .public)")
        }
        await refreshGrants()
    }

    // MARK: - Bookkeeping

    private func publish<Value: Equatable>(
        _ value: Value,
        to property: ReferenceWritableKeyPath<AlwaysOnModel, Value>
    ) {
        guard self[keyPath: property] != value else { return }

        self[keyPath: property] = value
    }
}

/// The settings sections the Always On pane places itself, by the ids the
/// daemon publishes under its pane.
public enum AlwaysOnSections {
    /// The recovery snapshots: the key, the cadence and the S3 target.
    public static let snapshots = "snapshots"
    /// This machine's own engine: the executor switch on a desktop.
    public static let engine = "engine"
}

/// Always On in Settings: the one gate that decides whether the pane is drawn
/// at all.
extension SettingsModel {
    /// The pane is drawn only where the daemon lists `home.status` in its
    /// `hello`: an engine from before Always On has neither the method nor
    /// the pane, and the sidebar then lists no row and says nothing.
    public var drawsAlwaysOnPane: Bool {
        servedMethods.contains(.homeStatus)
    }

    /// Whether a route to Always On lands on Providers instead: on a daemon
    /// this window has read and found without the home. Before the methods
    /// are read, the route is taken and the gate decides as the window
    /// appears (`refreshAlwaysOnGate`).
    public func refusesAlwaysOnRoute() -> Bool {
        !servedMethods.isEmpty && !drawsAlwaysOnPane
    }

    /// Opens the Always On guide on fermix.ai, which links the AWS template.
    /// Answers a sentence where the browser could not open.
    public func openAlwaysOnGuide() -> String? {
        opener.open(AlwaysOnGuide.url) ? nil : ProductStrings[.alwaysOnGuideOpenFailed]
    }

    /// A restored selection of the pane, on a daemon without the home, goes
    /// back to the first pane, so the window never opens on nothing.
    func refreshAlwaysOnGate() {
        guard selectedPane == .alwaysOn, !drawsAlwaysOnPane else { return }

        selectedPane = .providers
    }
}
