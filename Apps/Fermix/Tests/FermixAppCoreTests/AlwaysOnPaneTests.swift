import Foundation
import Testing

@testable import FermixAppCore

/// The Always On pane (Always On setup §8.3): goldens of what the renderer
/// draws for each summary the contract publishes, what each press sends (one
/// `home.act`, with what its needs collected, after its confirm), the
/// restart after this app's own Move now, the notifications from the
/// summary's notice, when the summary is read (never on a timer, never while
/// Always On is off and the pane is closed), and the copy.
@Suite("Always On pane")
@MainActor
struct AlwaysOnPaneTests {
    // MARK: - The contract

    @Test("every home.status golden carries a summary whose actions are records with what they need and their key")
    func summaryGoldensDecode() throws {
        let states: [String: ManagementHomeSummaryState] = [
            "home_status": .undone, "home_status_creating": .creating, "home_status_ready": .ready,
            "home_status_ready_first_move": .ready, "home_status_candidate": .candidate, "home_status_server": .primary,
            "home_status_on": .on, "home_status_problem": .problem
        ]
        for (name, state) in states {
            let summary = try Self.summary(name)
            #expect(summary.state == state, "\(name)")
            #expect(!summary.key.isEmpty && !summary.sentence.isEmpty, "\(name)")
        }

        let ready = try Self.summary("home_status_ready")
        let move = try #require(ready.action)
        #expect(move.id == .moveNow && move.needs == [.recoveryPassphrase] && move.key == "0Unu8V_R8dFwxCLgUqa1fw")
        #expect(move.confirm?.hasPrefix("Move Fermix to your server now?") == true && move.url == nil)
        #expect(ready.notice == ManagementHomeNotice(id: "ready:cand-5e2a9c1f7b3d4086", sentence: "Your server is ready for the move."))
        #expect(try Self.summary("home_status_ready_first_move").action?.needs == [.newRecoveryPassphrase])
        #expect(ready.detail.alternatives == nil, "a server of the owner's own waits with Move now alone")
        #expect(try Self.summary("home_status_on").detail.actions?.map(\.id) == [.backUpNow, .moveBack])
        let moveBack = try #require(try Self.summary("home_status_on").detail.actions?.last)
        #expect(moveBack.label == "Move back to this Mac" && moveBack.needs.isEmpty && moveBack.confirm == nil)
        let problem = try Self.summary("home_status_problem")
        #expect(problem.notice?.id == "cannot_reach:2031-05-04T11:49:00Z")
        #expect(problem.action?.id == .learnMore && problem.action?.url?.absoluteString == Self.docs)
        let restore = try #require(problem.detail.alternatives?.first)
        #expect(restore.id == .restoreHere && restore.needs == [.recoveryPassphrase] && restore.key == "iOYN-a75Nzr_s5renEJm6g")
        #expect(restore.confirm == Self.restoreConfirm && restore.url == nil, "the owner's word that the server is gone")
        let outcomes = try ["home_status_creating", "home_status_ready", "home_status_problem"].map { try Self.summary($0).outcome }
        #expect(outcomes == [.running, .done, .failed])
    }

    @Test("home.act answers the summary after the step, and a step's result is the code once or the move begun")
    func actGoldenDecodes() throws {
        let acted: ManagementHomeActed = try AlwaysOnTests.golden("home_act")
        #expect(acted.summary.state == .off && acted.result == nil)
        let own = try #require(acted.summary.action)
        #expect(own.id == .ownServer && own.needs.isEmpty && own.confirm == nil && own.key == "Mx_U6542oONDPqGb3qliTQ")

        let code = try Self.acted(Self.connectSummary, result: [
            "code": Self.code, "expires_at": "2031-05-04T12:30:00Z", "command": Self.command
        ])
        #expect(code.result == .ownServer(ManagementOwnServerCode(code: Self.code, expiresAt: "2031-05-04T12:30:00Z", command: Self.command)))
        let move = try Self.acted("home_status_ready", result: ["move_id": "mv-01a17cb1f5c04c1e9a7b"])
        #expect(move.result == .move(id: "mv-01a17cb1f5c04c1e9a7b"))
    }

    @Test("the passphrase and the code are withheld from every print")
    func secretsWithheld() throws {
        let input = ManagementHomeActInput(recoveryPassphrase: "invented-harbor-juniper-lantern")
        let code = ManagementOwnServerCode(code: Self.code, expiresAt: "2031-05-04T12:30:00Z", command: Self.command)

        for printed in [String(describing: input), String(reflecting: input), "\(input)", String(describing: code), String(reflecting: code)] {
            #expect(!printed.contains("invented-harbor") && !printed.contains(Self.code), "\(printed)")
        }
        #expect(Mirror(reflecting: input).children.isEmpty && Mirror(reflecting: code).children.isEmpty)
    }

    @Test("a press drawn on an older screen is refused as changed, in the engine's sentence")
    func changedRefusalDecodes() throws {
        let fixture = try #require(try ManagementFixtures.load(.errors, from: .management).first { $0.name == "changed" })
        let published = try #require(try fixture.object("response")["error"] as? [String: Any])
        let failure = try JSONDecoder().decode(ManagementFailure.self, from: try ManagementFixtures.encode(published))

        #expect(failure.code == .changed)
        #expect(ManagementMessage.sentence(for: ManagementError.daemon(failure)) == Self.changedSentence)
    }

    /// A review sent to the server takes up to 60 seconds, so a press waits
    /// 90.
    @Test("a press waits 90 seconds, and the summary the usual time")
    func timeouts() {
        let policy = DefaultManagementTimeoutPolicy()

        #expect(policy.timeout(for: .homeAct) == .seconds(90))
        for method in [ManagementMethod.homeStatus, .homeCandidatesList, .homeSnapshotsStatus] {
            #expect(policy.timeout(for: method) == DefaultManagementTimeoutPolicy.standard, "\(method.rawValue)")
        }
    }

    // MARK: - What the renderer draws

    /// One golden per summary the contract publishes: what the pane draws, in
    /// order, every word the engine's.
    @Test("each published summary draws as its golden")
    func publishedSummariesDraw() throws {
        for (name, golden) in Self.publishedGoldens {
            let summary = name == "home_act"
                ? (try AlwaysOnTests.golden(name) as ManagementHomeActed).summary
                : try Self.summary(name)
            #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(summary))) == golden, "\(name)")
        }
    }

    /// The engine's own summaries of the states the contract publishes no
    /// home.status golden for, in `Management.Copy`'s words at engine
    /// 82a23c0e: `connect` offers no main action, only a new code and
    /// Cancel. `off` is the contract's `home_act` golden.
    @Test("connect and retired draw as their goldens")
    func appendixSummariesDraw() throws {
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.connectSummary)))) == [
            "sentence: Waiting for your server: run the command on it and paste the code when it asks.",
            "link: Use my own Linux server",
            "link: Cancel the code"
        ])
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.retiredSummary)))) == [
            "sentence: Fermix moved to your server, and this Mac is no longer connected to it.",
            "action: Learn more, opens https://fermix.ai/docs/always-on/"
        ])
    }

    /// The engine no longer sends a server's provider steps: an engine from
    /// before that is drawn without them, as any action this build does not
    /// know, so nothing is drawn that this build would open or send wrong.
    @Test("an action this build does not know, one the engine no longer sends, or one whose need it cannot collect, is not drawn")
    func unknownActionsNotDrawn() throws {
        var summary = try Self.offSummary()
        summary["action"] = Self.action("grow_disk", "Grow the disk")
        summary["detail"] = ["alternatives": [
            Self.action("own_server", "Use my own Linux server", needs: ["fingerprint"]),
            Self.action("open_console", "Open the console", url: "https://console.example/"),
            Self.action("paste_token", "Set up", needs: ["token"]),
            Self.action("replace_server", "Replace the server", needs: ["choice"])
        ]]

        let screen = AlwaysOnScreen(try Self.decodeSummary(summary))
        #expect(screen.action == nil && screen.alternatives.isEmpty)
    }

    @Test("the pages around a screen: reading, the daemon's refusal, an engine with no summary, and the restart")
    func pages() {
        let summary = try? Self.summary("home_status_on")

        #expect(AlwaysOnPage.page(summary: nil, olderEngine: false, failure: nil, restarting: false) == .reading)
        #expect(AlwaysOnPage.page(summary: nil, olderEngine: false, failure: .unavailable("Fermix isn’t running"), restarting: false)
            == .unreadable("Fermix isn’t running"))
        #expect(AlwaysOnPage.page(summary: nil, olderEngine: false, failure: .requiresNewerEngine, restarting: false) == .needsUpdate)
        #expect(AlwaysOnPage.page(summary: nil, olderEngine: true, failure: nil, restarting: false) == .needsUpdate)
        #expect(AlwaysOnPage.page(summary: summary, olderEngine: false, failure: nil, restarting: true) == .restarting)
        #expect(AlwaysOnPage.page(summary: summary, olderEngine: false, failure: .unavailable("x"), restarting: false).screen?.state == .on)
    }

    // MARK: - What a press sends

    @Test("a press that needs nothing and confirms nothing is one home.act with its key, and the answer is drawn")
    func pressSendsOneAct() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.success(try Self.acted("home_status_creating"))]
        let mark = pane.gateway.calls.count
        let backUp = try #require(pane.model.page.screen?.detailActions.first)

        await pane.model.press(backUp)

        #expect(pane.gateway.homeActs == [HomeAct(action: .backUpNow, key: "HAtkdLOslkPTtZfhMrpeQg", input: nil)])
        #expect(Self.methods(pane.gateway, after: mark) == [.homeAct], "the answer is the read after the press")
        #expect(pane.model.page.screen?.state == .creating)
    }

    /// No action the engine sends today has a confirm without a need, but the
    /// contract lets one: its confirm is still asked before anything is sent.
    @Test("a press with a confirm and no need asks it first: declined sends nothing, accepted sends one home.act")
    func confirmFirst() async throws {
        var connect = Self.connectSummary
        connect["detail"] = ["alternatives": [
            Self.action("cancel", "Cancel the code", confirm: "Cancel the code? Your server can no longer use it.", key: "invented-cancel-code-4e1b")
        ]]
        let pane = try await Self.opened(try Self.home(connect))
        let cancel = try #require(pane.model.page.screen?.alternatives.first)

        await pane.model.press(cancel)
        #expect(pane.model.asking == .confirm(cancel) && pane.gateway.homeActs.isEmpty)

        pane.model.dismissAsk()
        #expect(pane.model.asking == nil && pane.gateway.homeActs.isEmpty)

        await pane.model.press(cancel)
        await pane.model.accept(cancel)
        #expect(pane.gateway.homeActs == [HomeAct(action: .cancel, key: "invented-cancel-code-4e1b", input: nil)])
        #expect(pane.model.asking == nil)
    }

    /// The bar is the engine's word that the screen moves on by itself: the
    /// server connecting, a move from its request on, a restore.
    @Test("the bar shows while the engine says the screen moves on by itself, and only then")
    func barFollowsTheOutcome() throws {
        var requested = try Self.summaryObject("home_status_ready")
        requested["outcome"] = "running"
        var settled = try Self.summaryObject("home_status_creating")
        settled["outcome"] = "done"

        #expect(AlwaysOnScreen(try Self.decodeSummary(requested)).showsBar, "a move requested here, before the restart")
        #expect(!AlwaysOnScreen(try Self.decodeSummary(settled)).showsBar)
        #expect(AlwaysOnScreen(try Self.summary("home_status_creating")).showsBar)
    }

    @Test("Move now asks for the recovery passphrase once where one is set, and sends it in the one press")
    func moveNowOnce() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus)
        let move = try #require(pane.model.page.screen?.action)

        await pane.model.press(move)
        #expect(pane.model.asking == .passphrase(move, twice: false) && pane.gateway.homeActs.isEmpty)
        #expect(await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil))

        #expect(pane.gateway.homeActs == [
            HomeAct(action: .moveNow, key: "0Unu8V_R8dFwxCLgUqa1fw", input: ManagementHomeActInput(recoveryPassphrase: "invented-harbor-juniper-lantern"))
        ])
    }

    @Test("Move now where none is set asks twice, and two that differ send nothing")
    func moveNowTwice() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready_first_move") as ManagementHomeStatus)
        let move = try #require(pane.model.page.screen?.action)

        await pane.model.press(move)
        #expect(pane.model.asking == .passphrase(move, twice: true))
        #expect(!(await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper")))
        #expect(pane.gateway.homeActs.isEmpty && pane.model.asking == .passphrase(move, twice: true))

        #expect(await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern"))
        #expect(pane.gateway.homeActs.map(\.input) == [ManagementHomeActInput(recoveryPassphrase: "invented-harbor-juniper-lantern")])
        #expect(pane.gateway.homeActs.map(\.key) == ["2AqtcHJopcwn24x76cpKEQ"])
    }

    /// The engine restarts right after answering Move now, so the answer
    /// still reads the screen it was pressed on: the pane says it restarts
    /// while the engine is away and while it still answers that screen, and
    /// lets go once a summary moved, the restart being read as one.
    @Test("after this app's own Move now the pane says it restarts until the engine answers a summary that moved, then Settings is read again")
    func ownMoveRestarts() async throws {
        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let pane = try await Self.opened(ready)
        pane.gateway.homeActScript = [.success(try Self.acted("home_status_ready", result: ["move_id": "mv-01a17cb1f5c04c1e9a7b"]))]
        let move = try #require(pane.model.page.screen?.action)
        await pane.model.press(move)
        _ = await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil)
        #expect(pane.model.page == .restarting)

        pane.gateway.homeStatusScript = [.failure(Self.away), .success(ready), .success(try AlwaysOnTests.golden("home_status_on"))]
        pane.gateway.homeStatusIndex = 0
        await pane.model.refresh()
        #expect(pane.model.page == .restarting, "while the engine is away")
        await pane.model.refresh()
        #expect(pane.model.page == .restarting, "while it still answers the screen the move was pressed on")
        let mark = pane.gateway.calls.count

        await pane.model.refresh()
        #expect(pane.model.page.screen?.state == .on && pane.model.restartingFrom == nil)
        #expect(Self.methods(pane.gateway, after: mark).contains(.settingsSections), "the restart was read as one")
    }

    @Test("a press drawn on an older screen is changed: its sentence under the action, and the summary read again")
    func changedReadsAgain() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.failure(Self.refusal(.changed, Self.changedSentence))]
        let backUp = try #require(pane.model.page.screen?.detailActions.first)
        let mark = pane.gateway.calls.count

        await pane.model.press(backUp)

        #expect(pane.model.refusal == Self.changedSentence)
        #expect(Self.methods(pane.gateway, after: mark) == [.homeAct, .homeStatus])
    }

    @Test("a step the server took whose answer was lost is said as no failure")
    func unconfirmedIsNoFailure() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus)
        let sentence = "The server fermix-vm did not confirm in time whether the move started. Its state shows once the server answers again, and starting it again never starts a second move."
        pane.gateway.homeActScript = [.failure(Self.refusal(.unconfirmed, sentence))]
        let move = try #require(pane.model.page.screen?.action)
        await pane.model.press(move)

        _ = await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil)

        #expect(pane.model.notice == sentence && pane.model.refusal == nil)
        #expect(pane.model.asking == nil, "the sheet closes on the answer")
    }

    /// Off's one action is Use my own Linux server: its answer is the
    /// code and the command, and the screen waits for the server.
    @Test("Use my own Linux server is off's action, and shows the command and the code once, until the pane goes")
    func ownServer() async throws {
        let pane = try await Self.opened(try Self.home(try Self.offSummary()))
        pane.gateway.homeActScript = [.success(try Self.acted(Self.connectSummary, result: [
            "code": Self.code, "expires_at": "2031-05-04T12:30:00Z", "command": Self.command
        ]))]
        let own = try #require(pane.model.page.screen?.action)

        await pane.model.press(own)

        #expect(pane.gateway.homeActs == [HomeAct(action: .ownServer, key: "Mx_U6542oONDPqGb3qliTQ", input: nil)])
        #expect(pane.model.ownServer?.command == Self.command, "the command carries no code")
        #expect(pane.model.ownServer?.code == Self.code)
        #expect(pane.model.page.screen?.state == .connect && pane.model.page.screen?.action == nil)
        pane.model.paneDisappeared()
        #expect(pane.model.ownServer == nil)
    }

    @Test("Learn more opens the page the engine gave, and Update is the app's own update, sending nothing")
    func pagesOpenedHere() async throws {
        let opener = RecordingExternalOpener()
        let pane = try await Self.opened(try Self.home(Self.retiredSummary), opener: opener)
        var updated = 0
        pane.model.checkForUpdates = { updated += 1 }
        let learnMore = try #require(pane.model.page.screen?.action)
        let update = try Self.decodeAction(Self.action("update", "Update"))
        let before = pane.gateway.calls.count

        await pane.model.press(learnMore)
        await pane.model.press(update)

        #expect(opener.urls.map(\.absoluteString) == [Self.docs])
        #expect(updated == 1 && pane.gateway.calls.count == before)
    }

    @Test("a summary that no longer offers the action asked for lets go of the press")
    func staleAskCloses() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus, then: [
            try AlwaysOnTests.golden("home_status_on")
        ])
        let move = try #require(pane.model.page.screen?.action)
        await pane.model.press(move)
        #expect(pane.model.asking == .passphrase(move, twice: false))

        await pane.model.refresh()

        #expect(pane.model.asking == nil && pane.gateway.homeActs.isEmpty)
    }

    // MARK: - Moving back

    /// Move back sits in Details while Fermix runs on the server, and asks
    /// nothing: the press is one `home.act`, and its answer is the move
    /// back's first screen.
    @Test("Move back to this Mac is one home.act with its key, asking nothing, and the answer draws the move back's first screen")
    func moveBackSendsOneAct() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.success(try Self.acted(Self.returnConnectingSummary))]
        let moveBack = try #require(pane.model.page.screen?.detailActions.first { $0.id == .moveBack })

        await pane.model.press(moveBack)

        #expect(pane.gateway.homeActs == [HomeAct(action: .moveBack, key: "A8TBcMzBwNuJLnGg2E5uAw", input: nil)])
        #expect(pane.model.asking == nil && pane.model.restartingFrom == nil)
        #expect(AlwaysOnRendering.lines(pane.model.page) == ["sentence: Connecting this Mac to your server…", "bar", "action: Cancel"])
    }

    /// Restore on this Mac takes the recovery passphrase that is set, typed
    /// once, in the sheet that ends with its confirm, the engine's sentence
    /// asking the owner's word that the server is deleted or stopped for
    /// good, so one press sends it. Fermix deletes no server: the answer is
    /// the restore running.
    @Test("Restore on this Mac asks the passphrase once under the engine's confirm that the server is gone, sends it in one press, and draws the restore running")
    func restoreHereOnce() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_problem") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.success(try Self.acted(Self.restoreMovingSummary))]
        let restore = try #require(pane.model.page.screen?.alternatives.first)

        await pane.model.press(restore)
        #expect(pane.model.asking == .passphrase(restore, twice: false) && pane.gateway.homeActs.isEmpty)
        #expect(pane.model.asking?.action.confirm == Self.restoreConfirm, "the sheet's confirm is the summary's")
        #expect(await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil))

        #expect(pane.gateway.homeActs == [
            HomeAct(action: .restoreHere, key: "iOYN-a75Nzr_s5renEJm6g", input: ManagementHomeActInput(recoveryPassphrase: "invented-harbor-juniper-lantern"))
        ])
        #expect(pane.model.restartingFrom == nil && pane.model.page.screen?.state == .moving)
        #expect(pane.model.page.screen?.progress == "Restoring Fermix from the backup on this Mac…")
    }

    /// The move back and the restore reuse the states the pane already
    /// draws, so each of their screens is the engine's words as they come,
    /// their problem among the kinds this build knows.
    @Test("the move back's and the restore's screens draw as their goldens, and their problem is a kind this build knows")
    func moveBackScreensDraw() throws {
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.returnReadySummary)))) == [
            "sentence: This Mac is ready to take Fermix back.",
            "action: Move now, needs recovery_passphrase, confirms",
            "link: Cancel",
            "line: Server: fermix-general-a3f9",
            "line: Waits until: Monday, May 5, 2031 at 1:00 PM CEST"
        ])
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.returnMovingSummary)))) == [
            "sentence: Moving Fermix back to this Mac. Messages wait until it is done.",
            "bar",
            "progress: Receiving your Fermix from the server…"
        ])

        let failed = try Self.decodeSummary(Self.returnFailedSummary)
        #expect(failed.problem == .returnFailed)
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(failed))) == [
            "sentence: This Mac could not get ready to take Fermix back. Move back to try again.",
            "action: Move back to this Mac",
            "link: Learn more, opens https://fermix.ai/docs/always-on/"
        ])
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.restoreMovingSummary)))) == [
            "sentence: Restoring Fermix on this Mac from its backup. Messages wait until it is done.",
            "bar",
            "progress: Restoring Fermix from the backup on this Mac…"
        ])
    }

    /// Move now on a move back starts the server's move, so its answer is
    /// `moving`: this Mac's engine restarts later, as the home is put in
    /// place, which no press here waits on.
    @Test("a move back's Move now answers moving, and nothing restarts here")
    func returnMoveDoesNotRestart() async throws {
        let pane = try await Self.opened(try Self.home(Self.returnReadySummary))
        pane.gateway.homeActScript = [.success(try Self.acted(Self.returnMovingSummary, result: ["move_id": "mv-01a17cb1f5c04c1e9a7b"]))]
        let move = try #require(pane.model.page.screen?.action)

        await pane.model.press(move)
        #expect(await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil))

        #expect(pane.gateway.homeActs.map(\.action) == [.moveNow])
        #expect(pane.model.restartingFrom == nil && pane.model.page.screen?.state == .moving)
    }

    /// The move back ends with this Mac's engine restarting as the primary
    /// in the same home, at the same socket and a later epoch than its
    /// server's: the chat takes it back as after any restart, and the notice
    /// it sends reads the screen after, Always On off again with the notice
    /// that the server still runs its retired copy, which the engine tells.
    @Test("after the move back this Mac's engine comes back as the primary at the same socket, and its notice reads the screen after")
    func restartAfterMoveBack() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try Self.home(Self.returnMovingSummary)), .success(try Self.home(try Self.backSummary()))]
        let pane = try Self.harness(gateway)
        let chat = AlwaysOnChat.make()
        pane.model.listen(to: chat.session)
        chat.session.connect()
        chat.socket.deliver(CompanionEvents.hello(epoch: 5, role: .primary))
        chat.socket.deliver(.homeStatusChanged)
        await pane.model.cued?.value
        #expect(pane.model.page.screen?.state == .moving)

        chat.socket.fail(.peerClosed)
        chat.scheduler.fireAll()
        chat.socket.deliver(CompanionEvents.hello(epoch: 6, role: .primary))
        chat.socket.deliver(.homeStatusChanged)
        await pane.model.cued?.value

        #expect(chat.session.model.connection == .connected)
        #expect(chat.socket.connectedPaths.count == 2 && Set(chat.socket.connectedPaths).count == 1)
        #expect(pane.model.summary?.state == .off && pane.model.summary?.notice?.id == "back:6")
        #expect(pane.model.restartingFrom == nil)
    }

    /// Back from a server of the owner's own, Always On is off again, and
    /// the engine's notice says the server still runs its retired copy: it
    /// is raised once, as every notice is.
    @Test("back from a server of the owner's own, its notice is raised once")
    func backNoticeOnce() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try Self.home(try Self.backSummary()))]
        let pane = try Self.harness(gateway)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier

        await pane.model.refresh()
        await pane.model.refresh()

        #expect(notifier.posted.map(\.body) == [Self.backSentence])
        #expect(pane.model.page.screen?.state == .off)
    }

    // MARK: - Notifications

    @Test("a notice is raised the first time its id is seen, under the Always On title, and once, an outage between or not")
    func noticesOnce() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let silent: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_problem")
        gateway.homeStatusScript = [
            .success(try AlwaysOnTests.golden("home_status_creating")), .success(ready), .success(ready), .success(silent), .success(ready)
        ]

        for _ in 0..<5 { await pane.model.refresh() }

        #expect(notifier.posted.map(\.title) == ["Always On", "Always On"])
        #expect(notifier.posted.map(\.body) == [
            "Your server is ready for the move.", "Fermix cannot reach your server. Your messages wait until it is back."
        ])
    }

    @Test("the notices raised are kept in the store, the last sixteen, and a relaunch reads them")
    func postedBound() {
        let store = FakeAlwaysOnNoticeStore()
        let posted = AlwaysOnPosted(store: store)
        var raised = 0
        for epoch in 0..<17 where posted.first("moved:\(epoch)") { raised += 1 }

        #expect(raised == 17 && store.postedNotices.count == AlwaysOnPosted.bound)
        #expect(store.postedNotices.first == "moved:1", "oldest first, the oldest forgotten past the bound")
        let relaunched = AlwaysOnPosted(store: store)
        let again = [relaunched.first("moved:16"), relaunched.first("moved:1")]
        #expect(again == [false, false])
        let oldest = relaunched.first("moved:0")
        #expect(oldest)
    }

    /// The owner quits and opens the app while the server is ready: the
    /// notification is not raised a second time.
    @Test("a notice raised before the app last quit is not raised again at launch")
    func noticesAcrossLaunches() async throws {
        let notices = FakeAlwaysOnNoticeStore(postedNotices: ["ready:cand-5e2a9c1f7b3d4086"])
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_ready")), .success(try AlwaysOnTests.golden("home_status_problem"))]
        let pane = try Self.harness(gateway, notices: notices)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier

        await pane.model.refresh()
        await pane.model.refresh()

        #expect(notifier.posted.map(\.body) == ["Fermix cannot reach your server. Your messages wait until it is back."])
        #expect(notices.postedNotices == ["ready:cand-5e2a9c1f7b3d4086", "cannot_reach:2031-05-04T11:49:00Z"])
    }

    @Test("the shipped notice store keeps its ids under its published key")
    func noticeStoreKey() {
        #expect(UserDefaultsAlwaysOnNoticeStore.key == "alwaysOn.notices.posted")
    }

    @Test("a press's answer raises its notice too")
    func pressRaisesNotice() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        pane.gateway.homeActScript = [.success(try Self.acted("home_status_problem"))]
        let backUp = try #require(pane.model.page.screen?.detailActions.first)

        await pane.model.press(backUp)

        #expect(notifier.posted.map(\.body) == ["Fermix cannot reach your server. Your messages wait until it is back."])
    }

    // MARK: - When the summary is read

    /// The owner's rule: while Always On is off the app forgets it. The
    /// engine sends nothing on the chat wire while it stays off, so a launch,
    /// the chat connecting, Settings showing another pane, a restart and
    /// every timer the app has run ask the engine nothing about Always On.
    @Test("while Always On is off and the pane is closed, the app asks the engine nothing about it")
    func offAsksNothing() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try Self.home(try Self.offSummary()))]
        let pane = try Self.harness(gateway)
        let chat = AlwaysOnChat.make()
        pane.model.listen(to: chat.session)

        chat.session.connect()
        chat.socket.deliver(CompanionEvents.hello())
        await pane.settings.windowAppeared()
        await pane.settings.restartCompleted()
        chat.scheduler.fireAll()

        #expect(Self.alwaysOnCalls(gateway).isEmpty, "asked \(Self.alwaysOnCalls(gateway))")
        #expect(pane.model.cued == nil)
        #expect(chat.scheduler.liveCount == 0, "nothing waits to read it later")

        await pane.model.paneAppeared()
        #expect(Self.alwaysOnCalls(gateway) == [.homeStatus], "the pane reads the off line it is never told of")
        pane.model.paneDisappeared()
        await pane.settings.restartCompleted()
        #expect(Self.alwaysOnCalls(gateway) == [.homeStatus], "a restart with the pane closed reads nothing")
    }

    @Test("each notice from the chat wire reads the summary once, and its notice is raised")
    func noticeReads() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_creating")), .success(try AlwaysOnTests.golden("home_status_ready"))]
        let pane = try Self.harness(gateway)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        let chat = AlwaysOnChat.make()
        pane.model.listen(to: chat.session)
        chat.session.connect()
        chat.socket.deliver(CompanionEvents.hello())

        chat.socket.deliver(.homeStatusChanged)
        await pane.model.cued?.value
        #expect(Self.alwaysOnCalls(gateway) == [.homeStatus])
        #expect(notifier.posted.isEmpty, "creating carries no notice")

        chat.socket.deliver(.homeStatusChanged)
        await pane.model.cued?.value
        #expect(Self.alwaysOnCalls(gateway) == [.homeStatus, .homeStatus])
        #expect(notifier.posted.map(\.body) == ["Your server is ready for the move."])
        #expect(chat.scheduler.liveCount == 0, "no read is scheduled after one")
    }

    /// While the server is out of reach the desktop refuses every chat
    /// connection, so no notice can come: each refused reconnect reads.
    @Test("after a move, each reconnect the desktop refuses because its server is out of reach reads the summary")
    func unreachableReads() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_on")), .success(try AlwaysOnTests.golden("home_status_problem"))]
        let pane = try Self.harness(gateway)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        let chat = AlwaysOnChat.make()
        pane.model.listen(to: chat.session)
        chat.session.connect()
        chat.socket.deliver(CompanionEvents.hello())
        chat.socket.deliver(.homeStatusChanged)
        await pane.model.cued?.value

        chat.socket.deliver(AlwaysOnChat.unreachable)
        await pane.model.cued?.value
        chat.scheduler.fireAll()
        chat.socket.deliver(AlwaysOnChat.unreachable)
        await pane.model.cued?.value

        #expect(Self.alwaysOnCalls(gateway) == [.homeStatus, .homeStatus, .homeStatus])
        #expect(notifier.posted.map(\.title) == ["Always On"], "the server that stopped answering, once")
    }

    @Test("a read that fails after one answered keeps the screen and says so")
    func failureKeepsTheScreen() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_on")), .failure(Self.away)]

        await pane.model.refresh()
        await pane.model.refresh()

        #expect(pane.model.page.screen?.state == .on)
        #expect(pane.model.readFailure == .unavailable(ProductStrings[.daemonStateNotRunning]))
    }

    @Test("an engine that answers home.status with no summary gets the update answer")
    func noSummary() async throws {
        var object = try AlwaysOnTests.goldenObject("home_status")
        object["summary"] = nil
        let pane = try await Self.opened(try AlwaysOnTests.decode(ManagementHomeStatus.self, object))

        #expect(pane.model.page == .needsUpdate)
    }

    // MARK: - The copy

    @Test("the pane's own words are twelve, keep the copy rules, and none names a cloud provider")
    func copy() {
        let own = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("alwaysOn.") }

        #expect(own.count == 12, "every word the engine says is the engine's")
        for key in own {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
        }
        for key in ProductStringKey.allCases {
            #expect(!ProductStrings[key].localizedCaseInsensitiveContains("hetzner"), "\(key.rawValue) names a provider")
        }
        #expect(!ProductCopyRules.properNouns.contains("Hetzner"))
    }

    // MARK: - Fixtures

    /// What the renderer draws for each summary the contract publishes.
    static let publishedGoldens: [String: [String]] = [
        "home_status": [
            "sentence: The move was undone. Fermix still runs on this Mac.",
            "action: Try again, needs recovery_passphrase, confirms"
        ],
        "home_status_creating": [
            "sentence: Connecting your server…",
            "bar"
        ],
        "home_status_ready": [
            "sentence: Your server is ready for the move. You can move Fermix back to this Mac from Always On whenever you want.",
            "warn: iMessage, voice calls and meetings stop after the move: neither this Mac nor fermix-general-a3f9 runs them.",
            "action: Move now, needs recovery_passphrase, confirms",
            "line: Server: fermix-general-a3f9",
            "line: System: linux x86_64",
            "line: Version: 1.2.3",
            "line: Waits until: Monday, May 5, 2031 at 1:00 PM CEST"
        ],
        "home_status_ready_first_move": [
            "sentence: Your server is ready for the move. You can move Fermix back to this Mac from Always On whenever you want.",
            "warn: iMessage, voice calls and meetings stop after the move: neither this Mac nor fermix-general-a3f9 runs them.",
            "action: Move now, needs new_recovery_passphrase, confirms",
            "line: Server: fermix-general-a3f9",
            "line: System: linux x86_64",
            "line: Version: 1.2.3",
            "line: Waits until: Monday, May 5, 2031 at 1:00 PM CEST"
        ],
        "home_status_candidate": [
            "sentence: This server is waiting for its move."
        ],
        "home_status_server": [
            "sentence: Fermix runs here."
        ],
        "home_status_on": [
            "sentence: Fermix runs on your server. Last backup 2 hours ago.",
            "line: Server: fermix-general-a3f9",
            "line: Version: 1.2.3",
            "line: Last backup to S3: Sunday, May 4, 2031 at 12:00 PM CEST",
            "line: Backups on this Mac: 1 MiB",
            "line: Server disk: 42% used",
            "data: Your conversations and memories, the secrets, the browser and traces live on your server, and whoever hosts it can technically read its disk. Backups are encrypted to your recovery passphrase.",
            "details link: Back up now",
            "details link: Move back to this Mac"
        ],
        "home_status_problem": [
            "sentence: Fermix cannot reach your server. Your messages wait until it is back.",
            "action: Learn more, opens https://fermix.ai/docs/always-on/",
            "link: Restore on this Mac, needs recovery_passphrase, confirms",
            "line: Backup on this Mac: Sunday, May 4, 2031 at 12:00 PM CEST"
        ],
        "home_act": [
            "sentence: Keep Fermix running when this Mac sleeps. It moves to a server you own.",
            "action: Use my own Linux server"
        ]
    ]

    static let changedSentence = "Always On changed since this was shown, so look at it again."
    static let docs = "https://fermix.ai/docs/always-on/"
    static let restoreConfirm = "Restore Fermix on this Mac from its backup? Confirm only once you deleted your server, "
        + "or stopped it for good: if it runs again, two copies of Fermix answer the same channels. Messages, memory and jobs "
        + "since that backup are gone, and Telegram keeps nothing older than 24 hours."
    static let code = "fxenroll1.aW52ZW50ZWQtY29kZS1mb3ItdGhlLXBhbmU"
    static let command = "curl -fsSL https://fermix.ai/always-on | sudo sh -s -- --version 1.2.3"
    static let away = ManagementError.transport(.socketMissing(path: "/tmp/fermix-test.sock"))

    /// `off` as the engine sends it: the contract's `home_act` golden, whose
    /// one action is Use my own Linux server.
    static func offSummary() throws -> [String: Any] {
        try summaryObject("home_act")
    }

    /// Back on this Mac after a move back from a server of the owner's own:
    /// `off`, with the notice that the server still runs its retired copy.
    static func backSummary() throws -> [String: Any] {
        var back = try offSummary()
        back["notice"] = ["id": "back:6", "sentence": backSentence]

        return back
    }

    /// `connect` and `retired` as the engine words them (`Management.Copy`
    /// at engine 82a23c0e); the action keys are the contract's own, each
    /// summary key invented.
    static let connectSummary: [String: Any] = [
        "key": "invented-connect-6a2f", "state": "connect", "notice": NSNull(), "outcome": "waiting",
        "sentence": "Waiting for your server: run the command on it and paste the code when it asks.",
        "action": NSNull(),
        "detail": [
            "alternatives": [
                action("own_server", "Use my own Linux server", key: "Mx_U6542oONDPqGb3qliTQ"),
                action("cancel", "Cancel the code", key: "PGFKmgUa3i48MJgwQSKf-g")
            ]
        ]
    ]
    static let retiredSummary: [String: Any] = [
        "key": "invented-retired-9b04", "state": "retired", "notice": NSNull(), "outcome": "done",
        "sentence": "Fermix moved to your server, and this Mac is no longer connected to it.",
        "action": action("learn_more", "Learn more", key: "AevTAJ1PC7bJ23Nb6779IQ", url: docs),
        "detail": [String: Any]()
    ]
    /// The move back's and the restore's screens as the engine words them
    /// (`Management.Copy` at engine 82a23c0e), each key invented.
    static let returnConnectingSummary: [String: Any] = [
        "key": "invented-return-connecting-3b9e", "state": "creating", "notice": NSNull(), "outcome": "running",
        "sentence": "Connecting this Mac to your server…",
        "action": action("cancel", "Cancel", key: "invented-return-cancel-5d2a"),
        "detail": [String: Any]()
    ]
    static let returnReadySummary: [String: Any] = [
        "key": "invented-return-ready-8c41", "state": "ready", "outcome": "done",
        "sentence": "This Mac is ready to take Fermix back.",
        "notice": ["id": "ready:cand-7f0b2d9e4a1c3586", "sentence": "This Mac is ready to take Fermix back."],
        "action": action("move_now", "Move now", needs: ["recovery_passphrase"], confirm: returnMoveConfirm, key: "invented-return-move-now-1e6f"),
        "detail": [
            "alternatives": [action("cancel", "Cancel", key: "invented-return-cancel-5d2a")],
            "readiness": [[String: Any]](),
            "lines": [
                ["label": "Server", "value": "fermix-general-a3f9"],
                ["label": "Waits until", "value": "Monday, May 5, 2031 at 1:00 PM CEST"]
            ]
        ]
    ]
    static let returnMoveConfirm = "Move Fermix back to this Mac now? iMessage, voice calls and meetings run here again. "
        + "Coding agents ask for your approval again. Messages sent to Telegram while it moves wait until it is done. "
        + "Your server stays until you delete it."
    static let returnMovingSummary: [String: Any] = [
        "key": "invented-return-moving-0d7a", "state": "moving", "notice": NSNull(), "action": NSNull(), "outcome": "running",
        "sentence": "Moving Fermix back to this Mac. Messages wait until it is done.",
        "detail": ["progress": "Receiving your Fermix from the server…"]
    ]
    static let returnFailedSummary: [String: Any] = [
        "key": "invented-return-failed-6b2c", "state": "problem", "notice": NSNull(), "outcome": "failed",
        "sentence": "This Mac could not get ready to take Fermix back. Move back to try again.",
        "action": action("move_back", "Move back to this Mac", key: "invented-move-back-4a9d"),
        "detail": [
            "kind": "return_failed", "note": NSNull(),
            "alternatives": [action("learn_more", "Learn more", key: "invented-learn-more-2f3e", url: docs)]
        ]
    ]
    static let restoreMovingSummary: [String: Any] = [
        "key": "invented-restore-moving-5a60", "state": "moving", "notice": NSNull(), "action": NSNull(), "outcome": "running",
        "sentence": "Restoring Fermix on this Mac from its backup. Messages wait until it is done.",
        "detail": ["progress": "Restoring Fermix from the backup on this Mac…"]
    ]
    static let backSentence = "Fermix is back on this Mac. Your own server still runs its retired copy: turn it off or delete it."

    static func action(
        _ id: String,
        _ label: String,
        needs: [String] = [],
        confirm: String? = nil,
        key: String = "invented-key-0f1e2d3c",
        url: String? = nil
    ) -> [String: Any] {
        ["id": id, "label": label, "needs": needs, "confirm": confirm ?? NSNull(), "key": key, "url": url ?? NSNull()]
    }

    static func decodeSummary(_ object: [String: Any]) throws -> ManagementHomeSummary {
        try AlwaysOnTests.decode(ManagementHomeSummary.self, object)
    }

    static func decodeAction(_ object: [String: Any]) throws -> ManagementHomeAction {
        try AlwaysOnTests.decode(ManagementHomeAction.self, object)
    }

    /// A golden's summary, decoded.
    static func summary(_ golden: String) throws -> ManagementHomeSummary {
        try #require((try AlwaysOnTests.golden(golden) as ManagementHomeStatus).summary)
    }

    /// A golden's summary as the engine sent it: `home.status`'s, or the one
    /// `home.act` answered.
    static func summaryObject(_ golden: String) throws -> [String: Any] {
        try #require(try AlwaysOnTests.goldenObject(golden)["summary"] as? [String: Any])
    }

    /// `home.act`'s answer: a summary, and a step's result.
    static func acted(_ summary: [String: Any], result: [String: Any]? = nil) throws -> ManagementHomeActed {
        try AlwaysOnTests.decode(ManagementHomeActed.self, ["summary": summary, "result": result ?? NSNull()])
    }

    static func acted(_ golden: String, result: [String: Any]? = nil) throws -> ManagementHomeActed {
        try acted(try summaryObject(golden), result: result)
    }

    /// The contract's own picture with another summary in it.
    static func home(_ summary: [String: Any]) throws -> ManagementHomeStatus {
        var object = try AlwaysOnTests.goldenObject("home_status")
        object["summary"] = summary

        return try AlwaysOnTests.decode(ManagementHomeStatus.self, object)
    }

    /// Every Always On method asked, in order: each `home.*` call.
    static func alwaysOnCalls(_ gateway: FakeDaemonGateway) -> [ManagementMethod] {
        methods(gateway, after: 0).filter { $0.rawValue.hasPrefix("home.") }
    }

    /// The protocol v2 methods asked since `mark`, in order.
    static func methods(_ gateway: FakeDaemonGateway, after mark: Int) -> [ManagementMethod] {
        gateway.calls.dropFirst(mark).compactMap { call in
            if case .v2(let method) = call { return method }
            return nil
        }
    }

    static func refusal(_ code: ManagementErrorCode, _ sentence: String, field: String? = nil) -> ManagementError {
        var details: [String: ManagementScalar] = ["sentence": .string(sentence)]
        if let field { details["field"] = .string(field) }

        return .daemon(ManagementFailure(code: code, message: "The request was refused.", details: ManagementScalarMap(values: details)))
    }

    /// The one settings model and its Always On model. Every read of the
    /// pane's model goes through `settings`, which owns it: the model holds
    /// its owner unowned.
    @MainActor
    struct Harness {
        let settings: SettingsModel
        let gateway: FakeDaemonGateway

        var model: AlwaysOnModel { settings.alwaysOn }
    }

    static func harness(
        _ gateway: FakeDaemonGateway,
        opener: RecordingExternalOpener = RecordingExternalOpener(),
        notices: FakeAlwaysOnNoticeStore? = nil
    ) throws -> Harness {
        Harness(settings: SettingsFixture.model(gateway: gateway, opener: opener, alwaysOnNotices: notices), gateway: gateway)
    }

    /// A model whose pane read `status`, then answers `then` in order, the
    /// last kept.
    static func opened(
        _ status: ManagementHomeStatus,
        then: [ManagementHomeStatus] = [],
        opener: RecordingExternalOpener = RecordingExternalOpener()
    ) async throws -> Harness {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = ([status] + then).map { .success($0) }
        let pane = try Self.harness(gateway, opener: opener)
        await pane.model.refresh()

        return pane
    }
}

/// What the renderer draws, as lines in order: the golden form of a page.
/// It reads the same `AlwaysOnScreen` the pane draws from.
enum AlwaysOnRendering {
    static func lines(_ page: AlwaysOnPage) -> [String] {
        switch page {
        case .reading: return ["reading"]
        case .unreadable(let sentence): return ["unreadable: \(sentence)"]
        case .needsUpdate: return ["update Fermix"]
        case .restarting: return ["restarting"]
        case .screen(let screen): return lines(screen)
        }
    }

    static func lines(_ screen: AlwaysOnScreen) -> [String] {
        var drawn = ["sentence: \(screen.sentence)"]
        if screen.showsBar { drawn.append("bar") }
        if let progress = screen.progress { drawn.append("progress: \(progress)") }
        if let note = screen.note { drawn.append("note: \(note)") }
        drawn += screen.readiness.map { "\($0.status.wireValue): \($0.sentence)" }
        if let action = screen.action { drawn.append("action: \(describe(action))") }
        drawn += screen.alternatives.map { "link: \(describe($0))" }
        drawn += screen.lines.map { "line: \($0.label): \($0.value)" }
        if let data = screen.data { drawn.append("data: \(data)") }
        drawn += screen.detailActions.map { "details link: \(describe($0))" }
        return drawn
    }

    static func describe(_ action: ManagementHomeAction) -> String {
        var text = action.label
        if let need = action.need { text += ", needs \(need.wireValue)" }
        if action.confirm != nil { text += ", confirms" }
        if let url = action.url { text += ", opens \(url.absoluteString)" }
        return text
    }
}

/// A chat session over a fake socket, built as the composition builds it.
@MainActor
struct AlwaysOnChat {
    let socket: FakeCompanionSocket
    let scheduler: ManualDeadlineScheduler
    let session: CompanionSession

    static func make() -> AlwaysOnChat {
        let socket = FakeCompanionSocket()
        let scheduler = ManualDeadlineScheduler()
        let session = CompanionSession(
            transport: CompanionSocketClient(lines: socket),
            socketPath: { "/tmp/fermix-test/companion.sock" },
            deadlines: scheduler
        )

        return AlwaysOnChat(socket: socket, scheduler: scheduler, session: session)
    }

    /// A desktop's server out of reach, as its engine refuses the chat then.
    static let unreachable = CompanionServerEvent.error(CompanionServerError(
        reason: CompanionProtocol.primaryUnreachableReason, message: "The server fermix-vm is unreachable.",
        field: nil, event: nil, clientMsgId: nil, direction: nil, clientVersion: nil, minVersion: nil, maxVersion: nil, ref: nil
    ))
}

/// The notifications a case raised, in order.
@MainActor
final class RecordingAlwaysOnNotifier: AlwaysOnNotifying {
    private(set) var posted: [MacNotification] = []

    func post(_ notification: MacNotification) async -> NotificationPostOutcome {
        posted.append(notification)
        return .posted(notificationID: "notice-\(posted.count)")
    }
}
