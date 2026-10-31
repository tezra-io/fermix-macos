import Foundation
import Testing

@testable import FermixAppCore

/// The Always On pane (M75 lean v1 §7): the summary's goldens, the screen each
/// summary maps to, the calls each action makes, the notifications raised
/// from changes of state, the follow's pace, and the gates.
@Suite("Always On pane")
@MainActor
struct AlwaysOnPaneTests {
    // MARK: - The contract

    @Test("every home.status golden carries a summary that decodes under the Swift names")
    func summaryGoldensDecode() throws {
        let states: [String: ManagementHomeSummaryState] = [
            "home_status": .undone, "home_status_creating": .creating, "home_status_ready": .ready,
            "home_status_candidate": .candidate, "home_status_server": .primary, "home_status_on": .on,
            "home_status_problem": .problem
        ]
        for (name, state) in states {
            let home: ManagementHomeStatus = try AlwaysOnTests.golden(name)
            #expect(home.summary?.state == state, "\(name)")
            #expect(home.summary?.sentence.isEmpty == false, "\(name)")
            #expect(home.version != nil, "\(name)")
        }

        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let detail = try #require(ready.summary?.detail)
        #expect(ready.summary?.action == ManagementHomeAction(id: .moveNow, label: "Move now"))
        #expect(detail.server?.type == "CPX22" && detail.server?.location == "Falkenstein")
        #expect(detail.readiness?.map(\.id) == ["stays_here"] && detail.waitsUntil == "2031-05-05T11:00:00Z")

        let on: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_on")
        #expect(on.summary?.detail.actions?.map(\.id) == [.backUpNow, .replaceServer])
        #expect(on.summary?.detail.copiesBytes == 144_633 && on.summary?.detail.diskUsed == 0.42)
        #expect(on.summary?.detail.backups == [ManagementHomeSummaryBackup(place: "S3", at: "2031-05-04T10:00:00Z")])

        let problem: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_problem")
        #expect(problem.summary?.problem == .cannotReach && problem.summary?.detail.seenAt == "2031-05-04T11:50:00Z")
        let creating: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_creating")
        #expect(creating.disk == ManagementHomeDisk(used: 0.31, nearlyFull: false))
    }

    @Test("the provisioner's goldens decode, and its jobs are of the home_provision kind")
    func provisionGoldensDecode() throws {
        let connected: ManagementProvisionView = try AlwaysOnTests.golden("home_provision_connect")
        #expect(connected.state == .connected && connected.token == .accepted && connected.otherServers == false)

        let options: ManagementProvisionOptions = try AlwaysOnTests.golden("home_provision_options")
        #expect(options.recommended == ManagementProvisionPick(type: "cpx22", location: .falkenstein))
        #expect(options.moreRoom == ManagementProvisionPick(type: "cpx32", location: .falkenstein))
        #expect(options.sentence == "Recommended: CPX22 in Falkenstein, €20 a month.")
        #expect(options.offer(ManagementProvisionPick(type: "cpx32", location: .nuremberg)) == nil, "not in stock there")
        #expect(options.city(.helsinki) == "Helsinki")

        let resources: ManagementProvisionView = try AlwaysOnTests.golden("home_provision_resources")
        #expect(resources.server?.location == .helsinki && resources.server?.power == "running")
        #expect(resources.resources.map(\.kind) == [.server, .firewall, .primaryIp, .primaryIp, .server, .firewall, .primaryIp, .primaryIp])
        #expect(resources.checked == true)

        for name in ["home_provision_create", "home_provision_power", "home_provision_delete", "job_get_home_provision_completed"] {
            let job: ManagementJob = try AlwaysOnTests.golden(name)
            #expect(job.kind == .homeProvision, "\(name)")
        }
    }

    /// Connect, options and resources call Hetzner in the request, up to
    /// three calls of 10 s each; the jobs answer at once.
    @Test("the provisioner's three Hetzner reads wait 35 seconds, and its jobs the usual time")
    func provisionTimeouts() {
        let policy = DefaultManagementTimeoutPolicy()

        for method in [ManagementMethod.homeProvisionConnect, .homeProvisionOptions, .homeProvisionResources] {
            #expect(policy.timeout(for: method) == .seconds(35), "\(method.rawValue)")
        }
        for method in [ManagementMethod.homeProvisionCreate, .homeProvisionPower, .homeProvisionDelete] {
            #expect(policy.timeout(for: method) == DefaultManagementTimeoutPolicy.standard, "\(method.rawValue)")
        }
    }

    // MARK: - The screens

    @Test("an engine that answers no summary gets the update answer, and one that has not answered is read")
    func noSummary() throws {
        var object = try AlwaysOnTests.goldenObject("home_status")
        object["summary"] = nil
        let old = try AlwaysOnTests.decode(ManagementHomeStatus.self, object)

        #expect(Self.page(old) == .needsUpdate)
        #expect(AlwaysOnPage.page(status: nil, failure: nil, local: AlwaysOnLocal(), served: Self.all) == .reading)
        #expect(AlwaysOnPage.page(status: nil, failure: .unavailable("Fermix is not running."), local: AlwaysOnLocal(), served: Self.all) == .unreadable("Fermix is not running."))
        #expect(AlwaysOnPage.page(status: nil, failure: .requiresNewerEngine, local: AlwaysOnLocal(), served: Self.all) == .needsUpdate)
    }

    @Test("off says the engine's sentence with Set up, and Set up opens the token screen in the engine's words")
    func offAndSetUp() throws {
        let off = try Self.home(Self.off)

        let screen = try #require(Self.page(off).screen)
        #expect(screen.kind == .off && screen.sentence == Self.offSentence)
        #expect(screen.action?.id == .setUp && !screen.tokenField)

        let token = try #require(Self.page(off, local: AlwaysOnLocal(settingUp: true)).screen)
        #expect(token.kind == .token && token.tokenField && token.action == nil)
        #expect(token.sentence == Self.connectSentence)
        #expect(token.steps == Self.steps)
        #expect(token.alternatives.map(\.id) == [.ownServer])
    }

    @Test("connect is the token screen, with the steps and the own-server link")
    func connect() throws {
        let screen = try #require(Self.page(try Self.home(Self.summary("connect", Self.connectSentence, detail: [
            "steps": Self.steps, "alternatives": [Self.action("own_server", "Use my own Linux server")]
        ]))).screen)

        #expect(screen.kind == .token && screen.tokenField && screen.action == nil)
        #expect(screen.steps == Self.steps && screen.alternatives.map(\.label) == ["Use my own Linux server"])
    }

    @Test("choose offers Create server, and only where every provisioner method is listed")
    func choose() throws {
        let choose = try Self.home(Self.summary("choose", "Your Hetzner token works, so choose the server Fermix creates.",
                                                action: Self.action("create_server", "Create server"),
                                                detail: ["billing": "Hetzner bills by the hour until the server is deleted."]))

        let screen = try #require(Self.page(choose).screen)
        #expect(screen.kind == .choose && screen.action?.id == .createServer)
        #expect(screen.detail.billing == "Hetzner bills by the hour until the server is deleted.")

        let withoutDelete = Self.all.subtracting([.homeProvisionDelete])
        #expect(AlwaysOnPage.page(status: choose, failure: nil, local: AlwaysOnLocal(), served: withoutDelete) == .needsUpdate)
        let token = AlwaysOnPage.page(status: try Self.home(Self.off), failure: nil, local: AlwaysOnLocal(settingUp: true), served: withoutDelete)
        #expect(token.screen?.kind == .token, "the own-server path stays")
    }

    @Test("creating shows a bar, Cancel, and the passphrase fields while none is set")
    func creating() throws {
        let golden: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_creating")
        let screen = try #require(Self.page(golden).screen)

        #expect(screen.kind == .creating && screen.showsProgress)
        #expect(screen.sentence == "Installing Fermix on your server…" && screen.action?.id == .cancel)
        #expect(screen.asksPassphrase == !golden.snapshots.recipientSet)

        let unset = try Self.home(Self.summary("creating", "Starting your server…", action: Self.action("cancel", "Cancel")), recipientSet: false)
        #expect(Self.page(unset).screen?.asksPassphrase == true)
        let set = try Self.home(Self.summary("creating", "Starting your server…", action: Self.action("cancel", "Cancel")), recipientSet: true)
        #expect(Self.page(set).screen?.asksPassphrase == false)
    }

    @Test("ready says the no-way-back sentence with Move now, and lists warnings only when there are some")
    func ready() throws {
        let golden: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let screen = try #require(Self.page(golden).screen)

        #expect(screen.kind == .ready && screen.action?.id == .moveNow)
        #expect(screen.sentence.contains("There is no way back to this Mac in this version."))
        #expect(screen.warnings.map(\.id) == ["stays_here"])

        let quiet = try Self.home(Self.summary("ready", "Your server is ready for the move.", action: Self.action("move_now", "Move now"),
                                               detail: ["readiness": [["id": "disk", "status": "ok", "sentence": "There is room."]]]))
        #expect(try #require(Self.page(quiet).screen).warnings.isEmpty)
    }

    @Test("on asks for nothing, and its Details offers Back up now and Replace the server")
    func on() throws {
        let screen = try #require(Self.page(try AlwaysOnTests.golden("home_status_on")).screen)

        #expect(screen.kind == .on && screen.action == nil && !screen.showsProgress)
        #expect(screen.alternatives.map(\.id) == [.backUpNow, .replaceServer])
        #expect(screen.detail.data?.contains("Hetzner can technically read its disk") == true)
        #expect(AlwaysOnDetails.shows(screen))
    }

    @Test("moving, undone and retired map to their screens with the engine's action")
    func movingUndoneRetired() throws {
        let moving = try #require(Self.page(try Self.home(Self.summary("moving", "Moving."))).screen)
        #expect(moving.kind == .moving && moving.showsProgress && moving.action == nil)

        let undone = try #require(Self.page(try AlwaysOnTests.golden("home_status")).screen)
        #expect(undone.kind == .undone && undone.action?.id == .tryAgain)

        let retired = try #require(Self.page(try Self.home(Self.summary("retired", "Fermix moved.", action: Self.action("learn_more", "Learn more")))).screen)
        #expect(retired.kind == .retired && retired.action?.id == .learnMore)

        let later = try #require(Self.page(try Self.home(Self.summary("paused", "Something newer."))).screen)
        #expect(later.kind == .unknown && later.sentence == "Something newer.")
    }

    /// The one action of each problem the design names, as the engine sends
    /// it: the pane draws it under its label and the model runs it
    /// (`problemActionsCallTheirMethods`).
    @Test("every problem kind is its own screen with the engine's one action")
    func problems() throws {
        for (kind, action) in Self.problemActions {
            let screen = try #require(Self.page(try Self.home(Self.problem(kind, action: action))).screen)
            #expect(screen.kind == .problem(ManagementHomeProblemKind(wireValue: kind)), "\(kind)")
            #expect(screen.action?.id == ManagementHomeActionId(wireValue: action), "\(kind)")
        }

        let gone = try Self.home(Self.problem("turned_off", action: "turn_on", alternatives: [Self.action("delete_server", "Delete your server")]))
        #expect(Self.page(gone).screen?.alternatives.map(\.id) == [.deleteServer])
    }

    @Test("Get a code is hidden while a server Fermix created stands, and offered once it is gone")
    func ownServerHidden() throws {
        let standing = try Self.home(Self.problem("not_set_up", action: "start_again", alternatives: [
            Self.action("own_server", "Use my own Linux server"), Self.action("open_hetzner", "Open Hetzner"),
            Self.action("delete_server", "Delete your server")
        ]))
        #expect(Self.page(standing).screen?.alternatives.map(\.id) == [.openHetzner, .deleteServer])

        let none = try Self.home(Self.problem("account_limit", action: "open_hetzner", alternatives: [Self.action("own_server", "Use my own Linux server")]))
        #expect(Self.page(none).screen?.alternatives.map(\.id) == [.ownServer])
    }

    @Test("an action this build does not know is not drawn")
    func unknownActionDropped() throws {
        let screen = try #require(Self.page(try Self.home(Self.problem("disk_full", action: "grow_disk"))).screen)

        #expect(screen.action == nil)
    }

    @Test("Paste a new token opens the field in place of the action")
    func pasteToken() throws {
        let refused = try Self.home(Self.problem("token_refused", action: "paste_token"))

        #expect(Self.page(refused).screen?.tokenField == false)
        let pasting = try #require(Self.page(refused, local: AlwaysOnLocal(pastingToken: true)).screen)
        #expect(pasting.tokenField && pasting.action == nil)
    }

    @Test("after this app's own Move now the pane says it is moving until the engine says where the move is")
    func ownMove() throws {
        let local = AlwaysOnLocal(moveStarted: "Moving to fermix-general-a3f9.")
        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")

        #expect(AlwaysOnPage.page(status: ready, failure: nil, local: local, served: Self.all).screen == .moving("Moving to fermix-general-a3f9."))
        #expect(AlwaysOnPage.page(status: ready, failure: .unavailable("Fermix is not running."), local: local, served: Self.all).screen?.kind == .moving)
        let on: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_on")
        #expect(AlwaysOnPage.page(status: on, failure: nil, local: local, served: Self.all).screen?.kind == .on)
    }

    // MARK: - Notifications

    @Test("the server is ready: raised when a summary turns ready, once, and never for a first read")
    func serverReadyNotice() throws {
        let creating = try Self.reading("home_status_creating")
        let ready = try Self.reading("home_status_ready")

        #expect(AlwaysOnNotices.notice(after: creating, ready, ownMove: false) == AlwaysOnNotice(kind: .serverReady, body: ready.status.summary?.sentence ?? ""))
        #expect(AlwaysOnNotices.notice(after: ready, ready, ownMove: false) == nil)
        #expect(AlwaysOnNotices.notice(after: nil, ready, ownMove: false) == nil)
    }

    @Test("the move is done: raised from moving to on, or after this app's own move")
    func moveDoneNotice() throws {
        let moving = try Self.reading(Self.summary("moving", "Moving."))
        let on = try Self.reading("home_status_on")
        let ready = try Self.reading("home_status_ready")

        #expect(AlwaysOnNotices.notice(after: moving, on, ownMove: false)?.kind == .moveDone)
        #expect(AlwaysOnNotices.notice(after: ready, on, ownMove: true)?.kind == .moveDone)
        #expect(AlwaysOnNotices.notice(after: ready, on, ownMove: false) == nil)
        #expect(AlwaysOnNotices.notice(after: on, on, ownMove: false) == nil)
    }

    @Test("no answer for 10 minutes and must be set up again: raised as each problem begins")
    func problemNotices() throws {
        let on = try Self.reading("home_status_on")
        let silent = try Self.reading("home_status_problem")
        let ready = try Self.reading("home_status_ready")
        let tooLong = try Self.reading(Self.problem("waited_too_long", action: "start_again"))
        let off = try Self.reading(Self.problem("turned_off", action: "turn_on"))

        #expect(AlwaysOnNotices.notice(after: on, silent, ownMove: false) == AlwaysOnNotice(kind: .cannotReach, body: silent.status.summary?.sentence ?? ""))
        #expect(AlwaysOnNotices.notice(after: silent, silent, ownMove: false) == nil)
        #expect(AlwaysOnNotices.notice(after: ready, tooLong, ownMove: false)?.kind == .setUpAgain)
        #expect(AlwaysOnNotices.notice(after: tooLong, tooLong, ownMove: false) == nil)
        #expect(AlwaysOnNotices.notice(after: on, off, ownMove: false) == nil, "the other problems raise nothing")
    }

    @Test("the last backup is 7 days old: raised once that backup's age passes a week")
    func backupNotice() throws {
        let taken = "2031-05-01T10:00:00Z"
        let since = try #require(ManagementCueTime.date(taken))
        let old = Self.problem("backup_old", action: "back_up_now", seenAt: taken)
        let day: TimeInterval = 86_400

        let five = try Self.reading(old, at: since.addingTimeInterval(5 * day))
        let seven = try Self.reading(old, at: since.addingTimeInterval(7 * day + 60))
        let eight = try Self.reading(old, at: since.addingTimeInterval(8 * day))

        #expect(AlwaysOnNotices.notice(after: five, five, ownMove: false) == nil)
        #expect(AlwaysOnNotices.notice(after: five, seven, ownMove: false)?.kind == .backupOld)
        #expect(AlwaysOnNotices.notice(after: seven, eight, ownMove: false) == nil, "once for that backup")
        let on = try Self.reading("home_status_on", at: since.addingTimeInterval(7 * day + 60))
        #expect(AlwaysOnNotices.notice(after: on, seven, ownMove: false)?.kind == .backupOld)
    }

    @Test("the model raises a notification from a change it read, under the Always On title, and none twice")
    func modelPostsNotices() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        let notifier = RecordingAlwaysOnNotifier()
        pane.model.notifier = notifier
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_creating")), .success(try AlwaysOnTests.golden("home_status_ready"))]

        await pane.model.tick()
        await pane.model.tick()
        await pane.model.tick()

        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        #expect(notifier.posted.map(\.title) == ["Always On"])
        #expect(notifier.posted.map(\.body) == [ready.summary?.sentence])
    }

    // MARK: - The follow

    @Test("the follow reads briskly while something moves, slowly once set, and rarely where nothing is set up")
    func cadence() throws {
        let creating: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_creating")
        let on: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_on")
        let off = try Self.home(Self.off)

        #expect(AlwaysOnCadence.wait(after: creating, failed: false, paneVisible: true, ownMove: false) == AlwaysOnCadence.watching)
        #expect(AlwaysOnCadence.wait(after: creating, failed: false, paneVisible: false, ownMove: false) == AlwaysOnCadence.moving)
        #expect(AlwaysOnCadence.wait(after: on, failed: false, paneVisible: false, ownMove: false) == AlwaysOnCadence.settled)
        #expect(AlwaysOnCadence.wait(after: on, failed: false, paneVisible: true, ownMove: false) == AlwaysOnCadence.open)
        #expect(AlwaysOnCadence.wait(after: off, failed: false, paneVisible: false, ownMove: false) == AlwaysOnCadence.idle)
        #expect(AlwaysOnCadence.wait(after: nil, failed: true, paneVisible: false, ownMove: true) == AlwaysOnCadence.watching)
    }

    @Test("following reads now and schedules the next read at the summary's pace")
    func followSchedules() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_on"))]
        let deadlines = ManualDeadlineScheduler()

        await pane.model.follow(with: deadlines)

        #expect(gateway.calls.filter { $0 == .v2(.homeStatus) }.count == 1)
        #expect(deadlines.scheduledDelays == [AlwaysOnCadence.settled])

        await pane.model.paneAppeared()
        #expect(deadlines.scheduledDelays == [AlwaysOnCadence.open], "the pane reschedules, it does not add a read")
    }

    @Test("until hello answers, the follow reads again within a minute, and an engine without the home is asked nothing")
    func followBeforeHello() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        let deadlines = ManualDeadlineScheduler()
        gateway.hello = nil

        await pane.model.follow(with: deadlines)
        #expect(deadlines.scheduledDelays == [AlwaysOnCadence.settled])

        gateway.hello = try Self.helloWithout(.homeStatus)
        await pane.model.tick()
        await pane.model.restartCompleted()
        #expect(!gateway.calls.contains(.v2(.homeStatus)))
        #expect(deadlines.scheduledDelays == [AlwaysOnCadence.idle])
    }

    @Test("a read that fails after one answered keeps the screen and says so")
    func failureKeepsTheScreen() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)
        gateway.homeStatusScript = [.success(try AlwaysOnTests.golden("home_status_on")), .failure(ManagementError.transport(.socketMissing(path: "/tmp/fermix-test.sock")))]

        await pane.model.refresh()
        await pane.model.refresh()

        #expect(pane.model.page.screen?.kind == .on)
        #expect(pane.model.readFailure == .unavailable(ProductStrings[.daemonStateNotRunning]))
    }

    // MARK: - The calls each action makes

    @Test("Set up opens the token screen and asks the daemon nothing")
    func setUpCallsNothing() async throws {
        let pane = try await Self.opened(Self.off)
        let before = pane.gateway.calls.count

        await pane.model.perform(Self.typed("set_up"))

        #expect(pane.model.page.screen?.kind == .token)
        #expect(pane.gateway.calls.count == before)
    }

    @Test("a pasted token is checked with Hetzner, then the summary and the offers are read")
    func tokenChecked() async throws {
        let choose = try Self.home(Self.summary("choose", "Your Hetzner token works.", action: Self.action("create_server", "Create server")))
        let pane = try await Self.opened(Self.off, then: [choose])
        let mark = pane.gateway.calls.count

        await pane.model.checkToken("  invented-hetzner-token-6d1f0c9a2b7e4f3a\n")

        #expect(pane.gateway.provisionTokens == ["invented-hetzner-token-6d1f0c9a2b7e4f3a"])
        #expect(Self.methods(pane.gateway, after: mark) == [.homeProvisionConnect, .homeStatus, .homeProvisionOptions])
        #expect(pane.model.page.screen?.kind == .choose && pane.model.tokenRefusal == nil)
    }

    @Test("a token Hetzner refuses is said under the field in the engine's words")
    func tokenRefused() async throws {
        let pane = try await Self.opened(Self.off)
        let sentence = "Hetzner does not accept this token, so paste a Read & Write API token from the Hetzner project you made for Fermix."
        pane.gateway.v2Failures[.homeProvisionConnect] = Self.refusal(.invalidParams, sentence, field: "token")

        await pane.model.checkToken("invented-hetzner-token-6d1f0c9a2b7e4f3a")

        #expect(pane.model.tokenRefusal == sentence)
    }

    @Test("Create server creates the recommendation, or the owner's own choice once changed")
    func createServer() async throws {
        let choose = Self.summary("choose", "Your Hetzner token works.", action: Self.action("create_server", "Create server"))
        let pane = try await Self.opened(choose)

        await pane.model.perform(Self.typed("create_server"))
        pane.model.choose(ManagementProvisionPick(type: "cpx32", location: .helsinki))
        await pane.model.perform(Self.typed("create_server"))

        #expect(pane.gateway.provisionCreates == [
            ProvisionCreate(pick: ManagementProvisionPick(type: "cpx22", location: .falkenstein), replace: false),
            ProvisionCreate(pick: ManagementProvisionPick(type: "cpx32", location: .helsinki), replace: false)
        ])
    }

    @Test("Cancel stops the running create, then deletes what it made")
    func cancel() async throws {
        let pane = try await Self.opened(Self.summary("creating", "Starting your server…", action: Self.action("cancel", "Cancel")))
        let running: ManagementJob = try AlwaysOnTests.golden("home_provision_create")
        pane.gateway.jobListResult = ManagementJobList(jobs: [running])
        let mark = pane.gateway.calls.count

        await pane.model.perform(Self.typed("cancel"))

        #expect(pane.gateway.cancelledJobs == [running.jobId])
        let asked = Self.methods(pane.gateway, after: mark)
        #expect(asked.first == .jobList && asked.contains(.jobCancel))
        let stopped = try #require(asked.firstIndex(of: .jobCancel))
        let deleted = try #require(asked.firstIndex(of: .homeProvisionDelete))
        #expect(stopped < deleted, "delete is refused while a job runs")
        #expect(asked.last == .homeStatus)
    }

    @Test("Move now with the passphrase set while the server started reviews, then starts the move as a desktop")
    func moveNow() async throws {
        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let pane = try await Self.opened(ready)
        pane.gateway.moveReadinessResult = Self.reviewShown
        #expect(await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern"))

        await pane.model.perform(Self.typed("move_now"))

        let candidate = try #require(ready.candidates.first?.candidateId)
        #expect(pane.gateway.readinessCandidates == [candidate])
        #expect(pane.gateway.moveStarts == [MoveStart(candidateId: candidate, passphrase: "invented-harbor-juniper-lantern", keepAsDesktop: true)])
        let started: ManagementMoveStarted = try AlwaysOnTests.golden("home_move_start")
        #expect(pane.model.page.screen == .moving(started.sentence))
        #expect(pane.model.passphrase == nil, "the passphrase leaves memory once the move starts")
    }

    /// The engine restarts to carry the move out; once it answers where the
    /// move stands, the app's own moving screen goes and everything Settings
    /// shows is read again, the restart being one.
    @Test("the app's own moving screen goes once the engine says where the move is, and Settings is read again")
    func ownMoveSettles() async throws {
        let ready: ManagementHomeStatus = try AlwaysOnTests.golden("home_status_ready")
        let away = ManagementError.transport(.socketMissing(path: "/tmp/fermix-test.sock"))
        let pane = try await Self.opened(ready)
        pane.gateway.moveReadinessResult = Self.reviewShown
        _ = await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern")
        await pane.model.perform(Self.typed("move_now"))
        pane.gateway.homeStatusScript = [.failure(away), .success(try AlwaysOnTests.golden("home_status_on"))]
        pane.gateway.homeStatusIndex = 0

        await pane.model.refresh()
        #expect(pane.model.page.screen?.kind == .moving, "while the engine is away")
        let mark = pane.gateway.calls.count

        await pane.model.refresh()
        #expect(pane.model.local.moveStarted == nil)
        #expect(pane.model.page.screen?.kind == .on)
        #expect(Self.methods(pane.gateway, after: mark).contains(.settingsSections), "the restart was read as one")
    }

    @Test("Move now asks for the passphrase where none is held, and a mismatch sends nothing")
    func moveAsksPassphrase() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_ready") as ManagementHomeStatus)
        pane.gateway.moveReadinessResult = Self.reviewShown

        await pane.model.perform(Self.typed("move_now"))
        #expect(pane.model.asksMovePassphrase && pane.gateway.readinessCandidates.isEmpty)

        await pane.model.moveWithPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper")
        #expect(pane.model.passphraseRefusal == ProductStrings[.alwaysOnPassphraseMismatch] && pane.gateway.moveStarts.isEmpty)

        await pane.model.moveWithPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern")
        #expect(!pane.model.asksMovePassphrase && pane.gateway.moveStarts.map(\.passphrase) == ["invented-harbor-juniper-lantern"])
    }

    @Test("a review that warns of something the screen did not show stops before the start, and the next Move now starts")
    func unseenWarningStops() async throws {
        let quiet = try Self.home(Self.summary("ready", "Your server is ready for the move.", action: Self.action("move_now", "Move now")),
                                  candidates: true)
        // The passphrase's own read answers the quiet summary again; the read
        // after the review answers the summary that lists its warning.
        let pane = try await Self.opened(quiet, then: [quiet, try AlwaysOnTests.golden("home_status_ready")])
        pane.gateway.moveReadinessResult = Self.reviewShown
        _ = await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern")

        await pane.model.perform(Self.typed("move_now"))
        #expect(pane.gateway.moveStarts.isEmpty, "the warning is shown first")

        await pane.model.perform(Self.typed("move_now"))
        #expect(pane.gateway.moveStarts.count == 1)
    }

    @Test("a linked desktop moves to the server its own server's code enrolled")
    func replaceTarget() throws {
        let status = try Self.replacing(Self.summary("ready", "Your new server is ready for the move.", action: Self.action("move_now", "Move now")))

        #expect(status.role == .device)
        #expect(AlwaysOnTarget.candidate(status) == "cand-5e2a9c1f7b3d4086")
    }

    /// During a replace the review is the old server's own, which the
    /// summary never lists: the pane lists the one it asked for, and the
    /// move keeps nothing of the old server.
    @Test("Move now during a replace shows the review it asked for, then moves keeping nothing")
    func replaceMove() async throws {
        let ready = try Self.replacing(Self.summary("ready", "Your new server is ready for the move.", action: Self.action("move_now", "Move now")))
        let pane = try await Self.opened(ready)
        pane.gateway.moveReadinessResult = Self.reviewShown
        _ = await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern")

        await pane.model.perform(Self.typed("move_now"))
        #expect(pane.gateway.moveStarts.isEmpty)
        let screen = try #require(pane.model.page.screen)
        #expect(pane.model.readiness(on: screen).map(\.id) == ["stays_here"], "the review's warning is listed")

        await pane.model.perform(Self.typed("move_now"))
        #expect(pane.gateway.moveStarts == [
            MoveStart(candidateId: "cand-5e2a9c1f7b3d4086", passphrase: "invented-harbor-juniper-lantern", keepAsDesktop: false)
        ])
    }

    @Test("Start again and Create in on a linked desktop create the replacement")
    func replaceProblems() async throws {
        let problem = try Self.replacing(Self.problem("no_capacity", action: "create_in", nextLocation: "hel1"))
        let pane = try await Self.opened(problem)

        await pane.model.perform(Self.typed("create_in"))
        await pane.model.perform(Self.typed("start_again"))

        #expect(pane.gateway.provisionCreates.map(\.replace) == [true, true])
        #expect(pane.gateway.provisionCreates.first?.pick.location == .helsinki)
    }

    @Test("deleting the old server after a replace is a problem of its own, with Delete as its one action")
    func deleteFailed() throws {
        let failed = try Self.replacing(Self.problem("delete_failed", action: "delete_server"))
        let screen = try #require(Self.page(failed).screen)

        #expect(screen.kind == .problem(.deleteFailed) && screen.action?.id == .deleteServer)
    }

    @Test("a replace's record decodes: the old server, which holds the home until the move, and each resource's side")
    func replaceRecordDecodes() throws {
        let view: ManagementProvisionView = try AlwaysOnTests.golden("home_provision_resources")
        let replace = try #require(view.replace)

        #expect(replace.current == .old && replace.old?.name == "fermix-general-a3f9")
        #expect(view.resources.contains { $0.replaced } && view.resources.contains { !$0.replaced })
    }

    /// Each problem's action, in the calls PROTOCOL.md's action table names.
    @Test("each problem's action calls its methods, in order")
    func problemActionsCallTheirMethods() async throws {
        let expected: [(String, [ManagementMethod])] = [
            ("turn_on", [.homeProvisionPower, .jobGet, .homeProvisionResources, .homeStatus]),
            ("restart_server", [.homeProvisionPower, .jobGet, .homeProvisionResources, .homeStatus]),
            ("start_again", [.homeProvisionResources, .homeProvisionDelete, .jobGet, .homeStatus, .homeProvisionCreate, .homeStatus]),
            ("create_in", [.homeProvisionOptions, .homeProvisionCreate, .homeStatus]),
            ("delete_server", [.homeProvisionDelete, .jobGet, .homeStatus]),
            ("back_up_now", [.homeSnapshotsRun, .homeStatus]),
            ("check_again", [.homeMoveReadiness, .homeStatus])
        ]
        for (action, methods) in expected {
            let problem = Self.problem("cannot_reach", action: action, nextLocation: "nbg1")
            let pane = try await Self.opened(try Self.home(problem, candidates: true))
            let mark = pane.gateway.calls.count

            await pane.model.perform(Self.typed(action))

            #expect(Self.methods(pane.gateway, after: mark) == methods, "\(action)")
        }
    }

    @Test("Turn it on and Restart server power the server on and reset it; Start again and Create in name the type and place")
    func provisionArguments() async throws {
        let pane = try await Self.opened(Self.problem("no_capacity", action: "create_in", nextLocation: "nbg1"))

        await pane.model.perform(Self.typed("turn_on"))
        await pane.model.perform(Self.typed("restart_server"))
        await pane.model.perform(Self.typed("start_again"))
        await pane.model.perform(Self.typed("create_in"))

        #expect(pane.gateway.provisionPowers == [.on, .reset])
        #expect(pane.gateway.provisionCreates == [
            ProvisionCreate(pick: ManagementProvisionPick(type: "cpx32", location: .helsinki), replace: false),
            ProvisionCreate(pick: ManagementProvisionPick(type: "cpx22", location: .nuremberg), replace: false)
        ])
    }

    @Test("Learn more, Open Hetzner and Update open their pages and ask the daemon nothing")
    func linksCallNothing() async throws {
        let opener = RecordingExternalOpener()
        let pane = try await Self.opened(Self.problem("deleted", action: "learn_more"), opener: opener)
        var updated = 0
        pane.model.checkForUpdates = { updated += 1 }
        let before = pane.gateway.calls.count

        await pane.model.perform(Self.typed("learn_more"))
        await pane.model.perform(Self.typed("open_hetzner"))
        await pane.model.perform(Self.typed("update"))

        #expect(opener.urls == [AlwaysOnLinks.guide, AlwaysOnLinks.hetznerConsole])
        #expect(updated == 1 && pane.gateway.calls.count == before)
    }

    @Test("Use my own Linux server opens a code and shows the one command with it inside, until the pane goes")
    func ownServer() async throws {
        let pane = try await Self.opened(Self.off)

        await pane.model.perform(Self.typed("own_server"))

        let code: ManagementEnrollmentCode = try AlwaysOnTests.golden("home_enroll_open")
        #expect(pane.gateway.calls.contains(.v2(.homeEnrollOpen)))
        #expect(pane.model.handout == code)
        #expect(AlwaysOnLinks.ownServerCommand(code: code.code) == "curl -fsSL https://fermix.ai/always-on | sudo FERMIX_ENROLL_CODE=\(code.code) sh")

        pane.model.paneDisappeared()
        #expect(pane.model.handout == nil)
    }

    @Test("Replace the server opens its sheet and creates the new server with replace")
    func replaceServer() async throws {
        let pane = try await Self.opened(try AlwaysOnTests.golden("home_status_on") as ManagementHomeStatus)

        await pane.model.perform(Self.typed("replace_server"))
        #expect(pane.model.replacing && pane.gateway.provisionCreates.isEmpty)

        await pane.model.replaceServer(with: ManagementProvisionPick(type: "cpx32", location: .helsinki))
        #expect(!pane.model.replacing)
        #expect(pane.gateway.provisionCreates == [ProvisionCreate(pick: ManagementProvisionPick(type: "cpx32", location: .helsinki), replace: true)])
    }

    @Test("the recovery passphrase is set once typed twice the same, and refused here otherwise")
    func passphrase() async throws {
        let pane = try await Self.opened(Self.summary("creating", "Starting your server…", action: Self.action("cancel", "Cancel")))

        #expect(!(await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented")))
        #expect(pane.gateway.recoveryPassphrases.isEmpty && pane.model.passphraseRefusal == ProductStrings[.alwaysOnPassphraseMismatch])

        #expect(await pane.model.setPassphrase("invented-harbor-juniper-lantern", again: "invented-harbor-juniper-lantern"))
        #expect(pane.gateway.recoveryPassphrases == ["invented-harbor-juniper-lantern"])
        #expect(pane.model.passphrase == "invented-harbor-juniper-lantern", "held for the move")
    }

    // MARK: - The gates and the copy

    @Test("the Hetzner path is served only where hello lists every provisioner method")
    func hetznerGate() async throws {
        let gateway = try AlwaysOnTests.gateway()
        let pane = try Self.harness(gateway)

        await pane.model.paneAppeared()
        #expect(pane.model.servesHetzner)
        #expect(ManagementMethod.homeProvisionMethods.count == 6)
    }

    @Test("the pane's own words keep the copy rules")
    func copy() {
        let own = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("alwaysOn.") }

        #expect(own.count > 20)
        for key in own {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
        }
    }

    // MARK: - Fixtures

    static let all = Set(ManagementMethod.allCases)
    /// A review whose one warning is the one the ready golden shows.
    static let reviewShown = ManagementMoveReadiness(ready: true, items: [
        ManagementReadinessItem(id: "disk", status: .ok, sentence: "There is room for the move."),
        ManagementReadinessItem(id: "stays_here", status: .warn, sentence: "iMessage, voice calls and meetings stop after the move.")
    ])
    static let offSentence = "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage, voice calls and meetings stop after the move."
    static let connectSentence = "Paste a Hetzner API token to let Fermix create your server."
    static let steps = [
        "Sign in to Hetzner's console and turn on two-factor sign-in for your account.",
        "Make a new project for Fermix alone, so the token reaches nothing else.",
        "In that project, open Security, then API Tokens, and generate a token with Read & Write permission.",
        "Paste the token here: Fermix checks it at once."
    ]
    static let off = summary("off", offSentence, action: action("set_up", "Set up"), detail: [
        "connect": ["sentence": connectSentence, "steps": steps, "alternatives": [action("own_server", "Use my own Linux server")]]
    ])

    /// The one action each problem kind the design names, as the engine
    /// sends it.
    static let problemActions: [(String, String)] = [
        ("turned_off", "turn_on"), ("cannot_reach", "restart_server"), ("deleted", "learn_more"),
        ("not_set_up", "start_again"), ("waited_too_long", "start_again"), ("no_capacity", "create_in"),
        ("account_limit", "open_hetzner"), ("read_only_token", "paste_token"), ("token_refused", "paste_token"),
        ("create_failed", "start_again"), ("update", "update"), ("disk_full", "learn_more"),
        ("backup_old", "back_up_now"), ("not_ready", "check_again"), ("unreadable", "learn_more")
    ]

    static func action(_ id: String, _ label: String) -> [String: Any] {
        ["id": id, "label": label]
    }

    static func typed(_ id: String) -> ManagementHomeAction {
        ManagementHomeAction(id: ManagementHomeActionId(wireValue: id), label: id)
    }

    static func summary(_ state: String, _ sentence: String, action: [String: Any]? = nil, detail: [String: Any] = [:]) -> [String: Any] {
        ["state": state, "sentence": sentence, "action": action ?? NSNull(), "detail": detail]
    }

    static func problem(
        _ kind: String,
        action: String,
        alternatives: [[String: Any]] = [],
        seenAt: String? = nil,
        nextLocation: String? = nil
    ) -> [String: Any] {
        var detail: [String: Any] = ["kind": kind, "note": NSNull(), "seen_at": seenAt ?? NSNull(), "alternatives": alternatives]
        if let nextLocation { detail["next_location"] = nextLocation }

        return summary("problem", "Something went wrong with \(kind).", action: Self.action(action, action), detail: detail)
    }

    /// The contract's own picture with another summary in it.
    static func home(_ summary: [String: Any], recipientSet: Bool = true, candidates: Bool = false) throws -> ManagementHomeStatus {
        var object = try AlwaysOnTests.goldenObject(candidates ? "home_status_ready" : "home_status")
        object["summary"] = summary
        if var snapshots = object["snapshots"] as? [String: Any] {
            snapshots["recipient_set"] = recipientSet
            object["snapshots"] = snapshots
        }

        return try AlwaysOnTests.decode(ManagementHomeStatus.self, object)
    }

    /// A linked desktop whose server is being replaced: its own picture with
    /// `summary`, and the server's, whose 24-hour code the new server used.
    static func replacing(_ summary: [String: Any]) throws -> ManagementHomeStatus {
        var server = try AlwaysOnTests.goldenObject("home_status_ready")
        server["enrollment"] = ["state": "used", "expires_at": "2031-05-05T11:00:00Z", "kind": "provisioned",
                                "candidate_id": "cand-5e2a9c1f7b3d4086"]
        var desktop = try AlwaysOnTests.goldenObject("home_status_on")
        desktop["role"] = "device"
        desktop["primary_home"] = server
        desktop["summary"] = summary

        return try AlwaysOnTests.decode(ManagementHomeStatus.self, desktop)
    }

    static func page(_ status: ManagementHomeStatus, local: AlwaysOnLocal = AlwaysOnLocal()) -> AlwaysOnPage {
        AlwaysOnPage.page(status: status, failure: nil, local: local, served: all)
    }

    static func reading(_ golden: String, at: Date = Date(timeIntervalSince1970: 1_950_000_000)) throws -> AlwaysOnReading {
        AlwaysOnReading(status: try AlwaysOnTests.golden(golden), at: at)
    }

    static func reading(_ summary: [String: Any], at: Date = Date(timeIntervalSince1970: 1_950_000_000)) throws -> AlwaysOnReading {
        AlwaysOnReading(status: try home(summary), at: at)
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

    static func harness(_ gateway: FakeDaemonGateway, opener: RecordingExternalOpener = RecordingExternalOpener()) throws -> Harness {
        Harness(settings: SettingsFixture.model(gateway: gateway, opener: opener), gateway: gateway)
    }

    /// A model whose pane has appeared on `summary`, then answers `then` in
    /// order, the last kept.
    static func opened(
        _ summary: [String: Any],
        then: [ManagementHomeStatus] = [],
        opener: RecordingExternalOpener = RecordingExternalOpener()
    ) async throws -> Harness {
        try await opened(try home(summary), then: then, opener: opener)
    }

    static func opened(
        _ status: ManagementHomeStatus,
        then: [ManagementHomeStatus] = [],
        opener: RecordingExternalOpener = RecordingExternalOpener()
    ) async throws -> Harness {
        let gateway = try AlwaysOnTests.gateway()
        gateway.homeStatusScript = ([status] + then).map { .success($0) }
        let pane = try Self.harness(gateway, opener: opener)
        await pane.model.readServed()
        await pane.model.refresh()

        return pane
    }

    /// The contract's `hello` with one method taken out of its catalog: an
    /// engine from before it.
    static func helloWithout(_ method: ManagementMethod) throws -> ManagementHello {
        var object = try AlwaysOnTests.goldenObject("hello")
        var capabilities = try #require(object["capabilities"] as? [String: Any])
        capabilities["methods"] = (capabilities["methods"] as? [String])?.filter { $0 != method.rawValue }
        if var minimums = capabilities["minimum_versions"] as? [String: Any] {
            minimums[method.rawValue] = nil
            capabilities["minimum_versions"] = minimums
        }
        object["capabilities"] = capabilities

        return try AlwaysOnTests.decode(ManagementHello.self, object)
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

        return .daemon(ManagementFailure(code: code, message: "Request parameters are invalid.", details: ManagementScalarMap(values: details)))
    }
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
