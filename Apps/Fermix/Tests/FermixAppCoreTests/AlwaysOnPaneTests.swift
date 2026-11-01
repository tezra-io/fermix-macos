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
        #expect(try Self.summary("home_status_problem").notice?.id == "cannot_reach:2031-05-04T11:49:00Z")
        #expect(try Self.summary("home_status_on").detail.actions?.map(\.id) == [.backUpNow, .replaceServer])
        #expect(ready.detail.alternatives?.map(\.id) == [.deleteServer], "a server Fermix created that waits can be deleted")
        let outcomes = try ["home_status_creating", "home_status_ready", "home_status_problem"].map { try Self.summary($0).outcome }
        #expect(outcomes == [.running, .done, .failed])
    }

    @Test("home.act answers the summary after the step, and a step's result is the code once or the move begun")
    func actGoldenDecodes() throws {
        let acted: ManagementHomeActed = try AlwaysOnTests.golden("home_act")
        #expect(acted.summary.state == .choose && acted.result == nil)
        #expect(acted.summary.action?.needs == [.choice] && acted.summary.action?.key == "F09RF8MofBF6hdXN7NWtuA")

        let code = try Self.acted(Self.offSummary, result: [
            "code": Self.code, "expires_at": "2031-05-04T12:30:00Z", "command": Self.command
        ])
        #expect(code.result == .ownServer(ManagementOwnServerCode(code: Self.code, expiresAt: "2031-05-04T12:30:00Z", command: Self.command)))
        let move = try Self.acted(Self.offSummary, result: ["move_id": "mv-01a17cb1f5c04c1e9a7b"])
        #expect(move.result == .move(id: "mv-01a17cb1f5c04c1e9a7b"))
    }

    @Test("the token, the passphrase and the code are withheld from every print")
    func secretsWithheld() throws {
        let input = ManagementHomeActInput(token: "invented-hetzner-token-6d1f0c9a2b7e4f3a", recoveryPassphrase: "invented-harbor-juniper-lantern")
        let code = ManagementOwnServerCode(code: Self.code, expiresAt: "2031-05-04T12:30:00Z", command: Self.command)

        for printed in [String(describing: input), String(reflecting: input), "\(input)", String(describing: code), String(reflecting: code)] {
            #expect(!printed.contains("invented-hetzner-token") && !printed.contains("invented-harbor") && !printed.contains(Self.code), "\(printed)")
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

    /// A token check takes up to about 45 seconds and a review sent to the
    /// server up to 60, so a press waits 90; the offers call the provider.
    @Test("a press waits 90 seconds, the offers 35, and the summary the usual time")
    func timeouts() {
        let policy = DefaultManagementTimeoutPolicy()

        #expect(policy.timeout(for: .homeAct) == .seconds(90))
        #expect(policy.timeout(for: .homeProvisionOptions) == .seconds(35))
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
    /// home.status golden for (handoff A's appendix).
    @Test("off, connect and retired draw as their goldens")
    func appendixSummariesDraw() throws {
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.offSummary)))) == [
            "sentence: Keep Fermix running when this Mac sleeps. It moves to a server you own.",
            "action: Set up, needs token",
            "link: Use my own Linux server",
            "token screen: Hetzner, Hetzner API token"
        ])
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.connectSummary)))) == [
            "sentence: Paste a Hetzner API token to let Fermix create your server.",
            "action: Set up, needs token",
            "link: Use my own Linux server",
            "link: Cancel the code",
            "token screen: Hetzner, Hetzner API token"
        ])
        #expect(AlwaysOnRendering.lines(.screen(AlwaysOnScreen(try Self.decodeSummary(Self.retiredSummary)))) == [
            "sentence: Fermix moved to your server, and this Mac is no longer connected to it.",
            "action: Learn more, opens https://fermix.ai/docs/always-on/#hetzner"
        ])
    }

    @Test("an action this build does not know, or one whose need it cannot collect, is not drawn")
    func unknownActionsNotDrawn() throws {
        var summary = Self.offSummary
        summary["action"] = Self.action("grow_disk", "Grow the disk")
        summary["detail"] = ["alternatives": [Self.action("own_server", "Use my own Linux server", needs: ["fingerprint"])]]

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

    @Test("a press with a confirm asks it first: declined sends nothing, accepted sends one home.act")
    func confirmFirst() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_creating") as ManagementHomeStatus)
        let cancel = try #require(pane.model.page.screen?.action)

        await pane.model.press(cancel)
        #expect(pane.model.asking == .confirm(cancel) && pane.gateway.homeActs.isEmpty)
        #expect(cancel.confirm == "Cancel and delete your server? Everything Fermix created for it is deleted.")

        pane.model.dismissAsk()
        #expect(pane.model.asking == nil && pane.gateway.homeActs.isEmpty)

        await pane.model.press(cancel)
        await pane.model.accept(cancel)
        #expect(pane.gateway.homeActs == [HomeAct(action: .cancel, key: "lW7Sx3Zz1dpg_Diwa6TmhA", input: nil)])
        #expect(pane.model.asking == nil)
    }

    @Test("Set up opens the token field for the one provider, and a pasted token is one home.act that names none")
    func tokenForTheOneProvider() async throws {
        let pane = try await Self.opened(try Self.home(Self.offSummary))
        let setUp = try #require(pane.model.page.screen?.action)

        await pane.model.press(setUp)
        #expect(pane.model.asking == .token(setUp) && pane.gateway.homeActs.isEmpty)
        let screen = try #require(pane.model.page.screen)
        #expect(screen.tokenTarget(picked: nil) == .provider(Self.hetzner))

        await pane.model.submitToken("  invented-hetzner-token-6d1f0c9a2b7e4f3a\n", for: Self.hetzner)

        #expect(pane.gateway.homeActs == [
            HomeAct(action: .pasteToken, key: "ypJXbXCwrSQSdVK8_tXftA", input: ManagementHomeActInput(token: "invented-hetzner-token-6d1f0c9a2b7e4f3a"))
        ])
        #expect(pane.model.page.screen?.state == .choose, "the answer's summary is drawn")
        #expect(pane.model.asking == nil, "the summary no longer offers the token")
    }

    /// A provider the engine adds is one more record: the app draws it and
    /// names it, with nothing of its own to change.
    @Test("with two providers the owner picks first, and the token names the one picked")
    func tokenForAPickedProvider() async throws {
        var off = Self.offSummary
        off["detail"] = ["providers": [Self.hetznerRecord, Self.nimbusRecord]]
        let pane = try await Self.opened(try Self.home(off))
        let setUp = try #require(pane.model.page.screen?.action)

        await pane.model.press(setUp)
        let screen = try #require(pane.model.page.screen)
        #expect(screen.tokenTarget(picked: pane.model.picked) == .pick([Self.hetzner, Self.nimbus]))

        pane.model.pick(provider: Self.nimbus)
        #expect(screen.tokenTarget(picked: pane.model.picked) == .provider(Self.nimbus))
        await pane.model.submitToken("invented-nimbus-key-0a1b2c3d4e5f", for: Self.nimbus)

        #expect(pane.gateway.homeActs.map(\.input) == [ManagementHomeActInput(token: "invented-nimbus-key-0a1b2c3d4e5f", provider: "nimbus")])
    }

    @Test("a token the provider refuses is the engine's sentence under the field, which stays open, and the summary is read again")
    func tokenRefused() async throws {
        let off = try Self.home(Self.offSummary)
        let pane = try await Self.opened(off)
        let sentence = "Hetzner does not accept this token, so paste a Read & Write API token from the Hetzner project you made for Fermix."
        pane.gateway.homeActScript = [.failure(Self.refusal(.invalidParams, sentence, field: "token"))]
        let setUp = try #require(pane.model.page.screen?.action)
        await pane.model.press(setUp)
        let mark = pane.gateway.calls.count

        await pane.model.submitToken("invented-hetzner-token-6d1f0c9a2b7e4f3a", for: Self.hetzner)

        #expect(pane.model.refusal == sentence)
        #expect(pane.model.asking == .token(setUp), "the field stays while the summary offers it")
        #expect(Self.methods(pane.gateway, after: mark) == [.homeAct, .homeStatus])
    }

    /// The engine knows the provider in use, so the choice names none, even
    /// on a pane opened straight on `choose`.
    @Test("Create server reads what the provider in use sells, naming none, and sends the recommendation unless changed")
    func createServer() async throws {
        let pane = try await Self.opened(try Self.home(Self.summaryObject("home_act")))
        let create = try #require(pane.model.page.screen?.action)

        await pane.model.press(create)
        #expect(pane.model.asking == .choice(create) && pane.gateway.homeActs.isEmpty)
        #expect(pane.gateway.provisionOptionsReads == 1)
        await pane.model.submitChoice(nil)

        await pane.model.press(create)
        await pane.model.submitChoice(ManagementProvisionPick(type: "cpx32", location: "hel1"))

        #expect(pane.gateway.homeActs.map(\.input) == [
            ManagementHomeActInput(type: "cpx22", location: "fsn1"), ManagementHomeActInput(type: "cpx32", location: "hel1")
        ])
        #expect(pane.gateway.homeActs.map(\.key) == ["F09RF8MofBF6hdXN7NWtuA", "F09RF8MofBF6hdXN7NWtuA"])
    }

    /// The engine makes no choice itself: a choice with no row to send,
    /// none picked and none recommended, sends nothing.
    @Test("a choice with nothing recommended and nothing picked sends nothing")
    func choiceWithNoRow() async throws {
        let pane = try await Self.opened(try Self.home(Self.summaryObject("home_act")))
        var none = try AlwaysOnTests.goldenObject("home_provision_options")
        none["recommended"] = NSNull()
        none["more_room"] = NSNull()
        none["offers"] = [[String: Any]]()
        pane.gateway.provisionOptionsResult = try AlwaysOnTests.decode(ManagementProvisionOptions.self, none)
        let create = try #require(pane.model.page.screen?.action)

        await pane.model.press(create)
        await pane.model.submitChoice(nil)

        #expect(pane.gateway.homeActs.isEmpty && pane.model.asking == .choice(create))
    }

    /// Start again needs a choice only where the engine keeps no size and
    /// place: the same sheet as Create server, and the row it sends.
    @Test("Start again that needs a choice opens the same sheet and sends the recommended row")
    func startAgainWithAChoice() async throws {
        var problem = try Self.summaryObject("home_status_problem")
        problem["action"] = Self.action("start_again", "Start again", needs: ["choice"],
                                        confirm: "Delete what Fermix made and create your server again?", key: "invented-start-again-7a1c")
        let pane = try await Self.opened(try Self.home(problem))
        let again = try #require(pane.model.page.screen?.action)

        await pane.model.press(again)
        #expect(pane.model.asking == .choice(again) && pane.gateway.provisionOptionsReads == 1)
        await pane.model.submitChoice(nil)

        #expect(pane.gateway.homeActs == [
            HomeAct(action: .startAgain, key: "invented-start-again-7a1c", input: ManagementHomeActInput(type: "cpx22", location: "fsn1"))
        ])
    }

    @Test("Delete your server beside Move now asks its confirm, then deletes the waiting server")
    func deleteWaitingServer() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus)
        let delete = try #require(pane.model.page.screen?.alternatives.first)

        await pane.model.press(delete)
        #expect(pane.model.asking == .confirm(delete) && pane.gateway.homeActs.isEmpty)
        await pane.model.accept(delete)

        #expect(pane.gateway.homeActs == [HomeAct(action: .deleteServer, key: "c1yXdvadZiiMCMzJaPBJhg", input: nil)])
    }

    /// The bar is the engine's word that the screen moves on by itself: a
    /// step's job, the server setting up, a move from its request on.
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

    @Test("Replace the server opens the same choice, and sends what it collected under its own key")
    func replaceServer() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)
        let replace = try #require(pane.model.page.screen?.detailActions.last)

        await pane.model.press(replace)
        #expect(pane.model.asking == .choice(replace))
        await pane.model.submitChoice(ManagementProvisionPick(type: "cpx32", location: "hel1"))

        #expect(pane.gateway.homeActs == [
            HomeAct(action: .replaceServer, key: "ysD6fueqfNRZpiywBU6HPA", input: ManagementHomeActInput(type: "cpx32", location: "hel1"))
        ])
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

    @Test("a linked desktop's replace answers moving, and nothing restarts here")
    func replaceMoveDoesNotRestart() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.success(try Self.acted(Self.movingSummary, result: ["move_id": "mv-01a17cb1f5c04c1e9a7b"]))]
        let move = try #require(pane.model.page.screen?.action)

        await pane.model.press(move)
        _ = await pane.model.submitPassphrase("invented-harbor-juniper-lantern", again: nil)

        #expect(pane.model.restartingFrom == nil)
        #expect(pane.model.page.screen?.state == .moving && pane.model.page.screen?.showsBar == true)
    }

    @Test("a press drawn on an older screen is changed: its sentence under the action, and the summary read again")
    func changedReadsAgain() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_problem") as ManagementHomeStatus)
        pane.gateway.homeActScript = [.failure(Self.refusal(.changed, Self.changedSentence))]
        let restart = try #require(pane.model.page.screen?.action)
        await pane.model.press(restart)
        let mark = pane.gateway.calls.count

        await pane.model.accept(restart)

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

    @Test("Use my own Linux server shows the command and the code once, until the pane goes")
    func ownServer() async throws {
        let pane = try await Self.opened(try Self.home(Self.offSummary))
        pane.gateway.homeActScript = [.success(try Self.acted(Self.connectSummary, result: [
            "code": Self.code, "expires_at": "2031-05-04T12:30:00Z", "command": Self.command
        ]))]
        let own = try #require(pane.model.page.screen?.alternatives.first)

        await pane.model.press(own)

        #expect(pane.gateway.homeActs == [HomeAct(action: .ownServer, key: "Mx_U6542oONDPqGb3qliTQ", input: nil)])
        #expect(pane.model.ownServer?.command == "curl -fsSL https://fermix.ai/always-on | sudo sh", "the command carries no code")
        #expect(pane.model.ownServer?.code == Self.code)
        pane.model.paneDisappeared()
        #expect(pane.model.ownServer == nil)
    }

    @Test("Learn more and Open console open the page the engine gave, and Update the app's own update, sending nothing")
    func pagesOpenedHere() async throws {
        let opener = RecordingExternalOpener()
        let pane = try await Self.opened(try Self.home(Self.retiredSummary), opener: opener)
        var updated = 0
        pane.model.checkForUpdates = { updated += 1 }
        let learnMore = try #require(pane.model.page.screen?.action)
        let console = try Self.decodeAction(Self.action("open_console", "Open Hetzner", url: "https://console.hetzner.cloud/"))
        let update = try Self.decodeAction(Self.action("update", "Update"))
        let before = pane.gateway.calls.count

        await pane.model.press(learnMore)
        await pane.model.press(console)
        await pane.model.press(update)
        pane.model.open(Self.hetzner.docsUrl)

        #expect(opener.urls.map(\.absoluteString) == [
            "https://fermix.ai/docs/always-on/#hetzner", "https://console.hetzner.cloud/", "https://fermix.ai/docs/always-on/#hetzner"
        ])
        #expect(updated == 1 && pane.gateway.calls.count == before)
    }

    @Test("a summary that no longer offers the action asked for lets go of the press")
    func staleAskCloses() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_creating") as ManagementHomeStatus, then: [
            try AlwaysOnTests.golden("home_status_ready")
        ])
        let cancel = try #require(pane.model.page.screen?.action)
        await pane.model.press(cancel)

        await pane.model.refresh()

        #expect(pane.model.asking == nil && pane.gateway.homeActs.isEmpty)
    }

    // MARK: - The choice

    /// What the provider in use sells, as the engine words each offer: the
    /// sheet draws its label and price as sent, under the city of its place.
    @Test("the choice draws each offer's label and price as the engine sent them, by city, the recommendation marked")
    func choiceDraws() throws {
        let options: ManagementProvisionOptions = try AlwaysOnTests.golden("home_provision_options")

        #expect(AlwaysOnRendering.lines(AlwaysOnChoice(options)) == Self.choiceGolden)

        var soldOut = try AlwaysOnTests.goldenObject("home_provision_options")
        soldOut["offers"] = (soldOut["offers"] as? [[String: Any]])?.filter { $0["location"] as? String != "nbg1" }
        let cities = AlwaysOnChoice(try AlwaysOnTests.decode(ManagementProvisionOptions.self, soldOut)).cities.map(\.city)
        #expect(cities == ["Falkenstein", "Helsinki"], "a city with nothing in stock has no rows to draw")
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
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_creating") as ManagementHomeStatus)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        pane.gateway.homeActScript = [.success(try Self.acted("home_status_ready"))]
        let cancel = try #require(pane.model.page.screen?.action)

        await pane.model.press(cancel)
        await pane.model.accept(cancel)

        #expect(notifier.posted.map(\.body) == ["Your server is ready for the move."])
    }

    // MARK: - When the summary is read

    /// The owner's rule: while Always On is off the app forgets it. The
    /// engine sends nothing on the chat wire while it stays off, so a launch,
    /// the chat connecting, Settings showing another pane, a restart and
    /// every timer the app has run ask the engine nothing about Always On.
    @Test("while Always On is off and the pane is closed, the app asks the engine nothing about it")
    func offAsksNothing() async throws {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = [.success(try Self.home(Self.offSummary))]
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

    @Test("the pane's own words are eighteen, keep the copy rules, and none names a cloud provider")
    func copy() {
        let own = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("alwaysOn.") }

        #expect(own.count == 18, "every word the engine says is the engine's")
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
            "sentence: Installing Fermix on your server…",
            "bar",
            "action: Cancel, confirms",
            "line: Server: fermix-general-a3f9",
            "line: Size: CPX22",
            "line: Place: Falkenstein",
            "line: Address: 203.0.113.7",
            "line: Last checked: Sunday, May 4, 2031 at 1:59 PM CEST",
            "line: Costs: €8.33 a month, billed by the hour until deleted"
        ],
        "home_status_ready": [
            "sentence: Your server is ready for the move. There is no way back to this Mac in this version.",
            "warn: iMessage, voice calls and meetings stop after the move: neither this Mac nor fermix-general-a3f9 runs them.",
            "action: Move now, needs recovery_passphrase, confirms",
            "link: Delete your server, confirms",
            "line: Server: fermix-general-a3f9",
            "line: Size: CPX22",
            "line: Place: Falkenstein",
            "line: Address: 203.0.113.7",
            "line: System: linux x86_64",
            "line: Version: 1.2.3",
            "line: Waits until: Monday, May 5, 2031 at 1:00 PM CEST",
            "line: Last checked: Sunday, May 4, 2031 at 1:59 PM CEST",
            "line: Costs: €8.33 a month, billed by the hour until deleted"
        ],
        "home_status_ready_first_move": [
            "sentence: Your server is ready for the move. There is no way back to this Mac in this version.",
            "warn: iMessage, voice calls and meetings stop after the move: neither this Mac nor fermix-general-a3f9 runs them.",
            "action: Move now, needs new_recovery_passphrase, confirms",
            "link: Delete your server, confirms",
            "line: Server: fermix-general-a3f9",
            "line: Size: CPX22",
            "line: Place: Falkenstein",
            "line: Address: 203.0.113.7",
            "line: System: linux x86_64",
            "line: Version: 1.2.3",
            "line: Waits until: Monday, May 5, 2031 at 1:00 PM CEST",
            "line: Last checked: Sunday, May 4, 2031 at 1:59 PM CEST",
            "line: Costs: €8.33 a month, billed by the hour until deleted"
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
            "line: Place: Falkenstein",
            "line: Version: 1.2.3",
            "line: Last backup to S3: Sunday, May 4, 2031 at 12:00 PM CEST",
            "line: Backups on this Mac: 1 MiB",
            "line: Server disk: 42% used",
            "line: Last checked: Sunday, May 4, 2031 at 1:59 PM CEST",
            "line: Costs: €8.33 a month, billed by the hour until deleted",
            "data: Your conversations and memories, the secrets, the browser and traces live on your server, and Hetzner can technically read its disk. Backups are encrypted to your recovery passphrase.",
            "details link: Back up now",
            "details link: Replace the server, needs choice, confirms"
        ],
        "home_status_problem": [
            "sentence: Fermix cannot reach your server. Your messages wait until it is back.",
            "action: Restart server, confirms",
            "line: Server: fermix-general-a3f9",
            "line: Size: CPX22",
            "line: Place: Falkenstein",
            "line: Address: 203.0.113.7",
            "line: Last checked: Sunday, May 4, 2031 at 1:59 PM CEST",
            "line: Costs: €8.33 a month, billed by the hour until deleted"
        ],
        "home_act": [
            "sentence: Your Hetzner token works, so choose the server Fermix creates.",
            "note: Hetzner bills by the hour until the server is deleted.",
            "action: Create server, needs choice, confirms"
        ]
    ]

    /// What the choice draws for the options the contract publishes.
    static let choiceGolden = [
        "sentence: Recommended: CPX22 in Falkenstein, €20 a month.",
        "city: Falkenstein",
        "offer: CPX22: 2 cores, 4 GB memory, 80 GB disk, €20.09 a month, billed by the hour until deleted, recommended",
        "offer: CPX32: 4 cores, 8 GB memory, 160 GB disk, €36.09 a month, billed by the hour until deleted",
        "offer: CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk, €42.24 a month, billed by the hour until deleted",
        "city: Nuremberg",
        "offer: CPX22: 2 cores, 4 GB memory, 80 GB disk, €20.09 a month, billed by the hour until deleted",
        "offer: CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk, €42.24 a month, billed by the hour until deleted",
        "city: Helsinki",
        "offer: CPX22: 2 cores, 4 GB memory, 80 GB disk, €20.09 a month, billed by the hour until deleted",
        "offer: CPX32: 4 cores, 8 GB memory, 160 GB disk, €36.09 a month, billed by the hour until deleted",
        "offer: CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk, €42.24 a month, billed by the hour until deleted"
    ]

    static let changedSentence = "Always On changed since this was shown, so look at it again."
    static let code = "fxenroll1.aW52ZW50ZWQtY29kZS1mb3ItdGhlLXBhbmU"
    static let command = "curl -fsSL https://fermix.ai/always-on | sudo sh"
    static let away = ManagementError.transport(.socketMissing(path: "/tmp/fermix-test.sock"))
    static let steps = [
        "Sign in to Hetzner's console and turn on two-factor sign-in for your account.",
        "Make a new project for Fermix alone, so the token reaches nothing else.",
        "In that project, open Security, then API Tokens, and generate a token with Read & Write permission.",
        "Paste the token here: Fermix checks it at once."
    ]
    static let hetznerRecord: [String: Any] = [
        "id": "hetzner", "name": "Hetzner", "token_label": "Hetzner API token",
        "sentence": "Paste a Hetzner API token to let Fermix create your server.", "steps": steps,
        "console_url": "https://console.hetzner.cloud/", "docs_url": "https://fermix.ai/docs/always-on/#hetzner"
    ]
    /// An invented second provider, as a later engine could list one.
    static let nimbusRecord: [String: Any] = [
        "id": "nimbus", "name": "Nimbus", "token_label": "Nimbus access key",
        "sentence": "Paste a Nimbus access key to let Fermix create your server.",
        "steps": ["Sign in to Nimbus and turn on two-factor sign-in.", "Make an access key for Fermix alone."],
        "console_url": "https://console.nimbus.example/", "docs_url": "https://fermix.ai/docs/always-on/#nimbus"
    ]
    static var hetzner: ManagementHomeSummaryProvider { provider(hetznerRecord) }
    static var nimbus: ManagementHomeSummaryProvider { provider(nimbusRecord) }

    /// `off`, `connect` and `retired` as the engine words them (handoff A's
    /// appendix, generated from the engine's code).
    static let offSummary: [String: Any] = [
        "key": "WwwCtpM5-2otfTa1t5s38A", "state": "off", "notice": NSNull(), "outcome": "done",
        "sentence": "Keep Fermix running when this Mac sleeps. It moves to a server you own.",
        "action": action("paste_token", "Set up", needs: ["token"], key: "ypJXbXCwrSQSdVK8_tXftA"),
        "detail": [
            "alternatives": [action("own_server", "Use my own Linux server", key: "Mx_U6542oONDPqGb3qliTQ")],
            "providers": [hetznerRecord]
        ]
    ]
    static let connectSummary: [String: Any] = [
        "key": "1beYgzYKYRJoEBvPpLz31A", "state": "connect", "notice": NSNull(), "outcome": "waiting",
        "sentence": "Paste a Hetzner API token to let Fermix create your server.",
        "action": action("paste_token", "Set up", needs: ["token"], key: "ypJXbXCwrSQSdVK8_tXftA"),
        "detail": [
            "alternatives": [
                action("own_server", "Use my own Linux server", key: "Mx_U6542oONDPqGb3qliTQ"),
                action("cancel", "Cancel the code", key: "PGFKmgUa3i48MJgwQSKf-g")
            ],
            "providers": [hetznerRecord]
        ]
    ]
    static let retiredSummary: [String: Any] = [
        "key": "pE4etWKyHkFBceL_axOMzw", "state": "retired", "notice": NSNull(), "outcome": "done",
        "sentence": "Fermix moved to your server, and this Mac is no longer connected to it.",
        "action": action("learn_more", "Learn more", key: "AevTAJ1PC7bJ23Nb6779IQ", url: "https://fermix.ai/docs/always-on/#hetzner"),
        "detail": [String: Any]()
    ]
    /// A linked desktop's replace, once its move is sent to the server.
    static let movingSummary: [String: Any] = [
        "key": "DXMsAJ5oa8GcFfqMnPOUWQ", "state": "moving", "notice": NSNull(), "action": NSNull(), "outcome": "running",
        "sentence": "Moving. This Mac restarts and reconnects to your server. Messages wait until it is done.",
        "detail": [String: Any]()
    ]

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

    static func provider(_ record: [String: Any]) -> ManagementHomeSummaryProvider {
        guard let provider = try? AlwaysOnTests.decode(ManagementHomeSummaryProvider.self, record) else {
            preconditionFailure("an invented provider record decodes")
        }

        return provider
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
        drawn += screen.notes.map { "note: \($0)" }
        drawn += screen.readiness.map { "\($0.status.wireValue): \($0.sentence)" }
        if let action = screen.action { drawn.append("action: \(describe(action))") }
        drawn += screen.alternatives.map { "link: \(describe($0))" }
        drawn += screen.providers.map { "token screen: \($0.name), \($0.tokenLabel)" }
        drawn += screen.lines.map { "line: \($0.label): \($0.value)" }
        if let data = screen.data { drawn.append("data: \(data)") }
        drawn += screen.detailActions.map { "details link: \(describe($0))" }
        return drawn
    }

    static func lines(_ choice: AlwaysOnChoice) -> [String] {
        var drawn = ["sentence: \(choice.sentence)"]
        for city in choice.cities {
            drawn.append("city: \(city.city)")
            drawn += city.offers.map { offer in
                let pick = ManagementProvisionPick(type: offer.type, location: offer.location)
                return "offer: \(offer.label), \(offer.price)" + (pick == choice.recommended ? ", recommended" : "")
            }
        }
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
