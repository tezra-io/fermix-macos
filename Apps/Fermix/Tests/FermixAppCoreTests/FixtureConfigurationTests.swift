import Foundation
import Testing

@testable import FermixAppCore

/// The launch argument that selects the fixture configuration.
///
/// Parsing ships in every build; the configuration behind it does not. These
/// cases are about the argument alone, so they hold in a release build too.
@Suite("Fixture launch argument")
struct FixtureLaunchRequestTests {
    @Test("a launch with no flag asks for nothing")
    func absentFlag() throws {
        #expect(try FixtureLaunchRequest.parse(["/path/Fermix"]) == nil)
        #expect(try FixtureLaunchRequest.parse(["/path/Fermix", "--unregister-login-items"]) == nil)
    }

    @Test("the flag alone lands on Home")
    func flagAlone() throws {
        #expect(try FixtureLaunchRequest.parse(["/path/Fermix", "--fixture"]) == "home")
    }

    @Test("the start flag names the surface")
    func namedStart() throws {
        let arguments = ["/path/Fermix", "--fixture", "--fixture-start", "settings/voice"]

        #expect(try FixtureLaunchRequest.parse(arguments) == "settings/voice")
    }

    /// A start without the flag is a half-written command, and resolving it to
    /// the product configuration would open Home and look like it worked.
    @Test("a start without the flag is refused")
    func startWithoutFlag() {
        #expect(throws: FixtureLaunchRequest.Refusal.startWithoutFlag) {
            try FixtureLaunchRequest.parse(["/path/Fermix", "--fixture-start", "home"])
        }
    }

    @Test("a start with no value is refused rather than defaulted")
    func startWithoutValue() {
        #expect(throws: FixtureLaunchRequest.Refusal.startWithoutValue) {
            try FixtureLaunchRequest.parse(["/path/Fermix", "--fixture", "--fixture-start"])
        }
        #expect(throws: FixtureLaunchRequest.Refusal.startWithoutValue) {
            try FixtureLaunchRequest.parse(["/path/Fermix", "--fixture", "--fixture-start", "--verbose"])
        }
    }

    /// Both flags, because a second `--fixture-start` is the one that silently
    /// changes which surface opens. Each refusal names the flag that was
    /// actually repeated.
    @Test("a repeated flag is refused")
    func repeatedFlag() {
        #expect(throws: FixtureLaunchRequest.Refusal.flagRepeated("--fixture")) {
            try FixtureLaunchRequest.parse(["/path/Fermix", "--fixture", "--fixture"])
        }
        #expect(throws: FixtureLaunchRequest.Refusal.flagRepeated("--fixture-start")) {
            try FixtureLaunchRequest.parse([
                "/path/Fermix", "--fixture", "--fixture-start", "home", "--fixture-start", "doctor"
            ])
        }
    }

    /// The release refusal has to say why, not just that. A developer handed
    /// "unrecognised argument" goes looking for a typo.
    @Test("every refusal carries a sentence that names what was inspected")
    func refusalsSpeak() {
        let refusals: [FixtureLaunchRequest.Refusal] = [
            .startWithoutFlag, .startWithoutValue, .flagRepeated("--fixture"),
            .notAvailableInThisBuild, .unknownStart("wat")
        ]

        for refusal in refusals {
            #expect(!refusal.sentence.isEmpty)
        }
        #expect(FixtureLaunchRequest.Refusal.notAvailableInThisBuild.sentence.contains("debug"))
        #expect(FixtureLaunchRequest.Refusal.unknownStart("wat").sentence.contains("wat"))
        #expect(FixtureLaunchRequest.Refusal.flagRepeated("--fixture-start")
            .sentence.hasPrefix("--fixture-start"))
    }
}

#if DEBUG
/// The fixture configuration itself: what it can be asked for, what machine
/// each surface is looked at on, and the answers every surface reads.
@Suite("Fixture configuration")
struct FixtureConfigurationTests {

    // MARK: - The start vocabulary

    /// Derived from the published panes, not from a list here: a fourteenth
    /// pane fails this rather than quietly having no way to be looked at.
    @Test("every settings pane can be opened by name")
    func everyPaneHasAStart() {
        for pane in SettingsPane.allCases {
            #expect(FixtureStart(name: "settings/\(pane.slug)") == .settings(pane))
        }
    }

    @Test("every assistant screen can be opened by name")
    func everyStageHasAStart() {
        for stage in OnboardingStage.allCases {
            #expect(FixtureStart(name: "assistant/\(stage.rawValue)") == .assistant(stage))
        }
    }

    @Test("every route can be opened by name")
    func everyRouteHasAStart() {
        for route in AppRoute.allCases {
            #expect(FixtureStart(name: route.rawValue) == .surface(route))
        }
        #expect(FixtureStart(name: "restart-sheet") == .restartSheet)
        #expect(FixtureStart(name: "chat-empty") == .emptyChat)
        #expect(FixtureStart(name: "browser") == .browser)
        #expect(FixtureStart(name: "chat-call") == .chatCall)
        #expect(FixtureStart(name: "chat-call-failed") == .failedChatCall)
    }

    /// Every step of the Phone sheet a launch can open on, derived from the
    /// published steps rather than listed here.
    @Test("every Phone sheet step can be opened by name, on Channels with the sheet up")
    func everyPhoneStepHasAStart() {
        for step in FixturePhoneStart.allCases {
            let start = FixtureStart(name: "phone/\(step.rawValue)")

            #expect(start == .phone(step))
            #expect(FixtureLaunch(start: .phone(step)).presentation == .channelsWithPhone(step.intent))
            #expect(FixtureLaunch(start: .phone(step)).phoneChannel == step.channel)
            #expect(FixtureHome.forStart(.phone(step)) == .settled)
        }
        #expect(FixtureStart(name: "phone/telepathy") == nil)
        #expect(FixtureLaunch(start: .surface(.home)).phoneChannel == .published)
    }

    /// A name this build does not publish resolves to nothing, so the caller
    /// refuses. Falling back to Home would report a typo as a success.
    @Test("an unpublished name resolves to nothing")
    func unknownNames() {
        #expect(FixtureStart(name: "settings/telepathy") == nil)
        #expect(FixtureStart(name: "assistant/wat") == nil)
        #expect(FixtureStart(name: "hoem") == nil)
        #expect(FixtureStart(name: "") == nil)
    }

    @Test("the published names list every surface exactly once")
    func publishedNamesAreComplete() {
        let names = FixtureStart.publishedNames

        #expect(Set(names).count == names.count)
        #expect(names.count == AppRoute.allCases.count + SettingsPane.allCases.count
            + OnboardingStage.allCases.count + 6 + FixturePhoneStart.allCases.count)
        for name in names {
            #expect(FixtureStart(name: name) != nil, "\(name) is published but does not resolve")
        }
    }

    // MARK: - The machine each screen is looked at on

    /// The screens that exist to show a machine mid-flight, refused, or
    /// finished are shown on the machine that produces them. A Boot failed card
    /// drawn on a healthy Mac would be a caption, not a state, and Ready drawn
    /// on a machine with a gating failure is not Ready at all: the screen
    /// refuses to render while one stands (M34 §4), so on the default home it
    /// drew its refusal notice and the screen itself could not be looked at.
    @Test("the mechanical screens get the machines that produce them")
    func homesFollowTheScreen() {
        #expect(FixtureHome.forStart(.assistant(.starting)) == .daemonStarting)
        #expect(FixtureHome.forStart(.assistant(.bootFailed)) == .notInApplications)
        #expect(FixtureHome.forStart(.assistant(.ready)) == .configured)
        #expect(FixtureHome.forStart(.surface(.home)) == .settled)
        #expect(FixtureHome.forStart(.settings(.providers)) == .settled)
        #expect(FixtureHome.forStart(.restartSheet) == .settled)
        #expect(FixtureHome.forStart(.approvalStep) == .awaitingApproval)
    }

    /// Boot failed is reached by failing, never by being set.
    @Test("the boot failure opens on Starting and is produced by the machine")
    func bootFailureIsProduced() {
        #expect(FixtureLaunch(start: .assistant(.bootFailed)).presentation == .assistant(.starting))
        #expect(FixtureLaunch(start: .assistant(.ready)).presentation == .assistant(.ready))
        #expect(FixtureLaunch(start: .approvalStep).presentation == .assistant(.starting))
    }

    @Test("each start names what it opens")
    func startsNameWhatTheyOpen() {
        #expect(FixtureLaunch(start: .surface(.doctor)).presentation == .route(.doctor))
        #expect(FixtureLaunch(start: .settings(.voice)).presentation == .settings(.voice))
        #expect(FixtureLaunch(start: .restartSheet).presentation == .homeWithRestartSheet)
    }

    /// A named start opens the window it names, through the coordinator's own
    /// verbs. Without this the vocabulary is proven and the routing is not.
    @MainActor
    @Test("every published start opens the window it names")
    func everyStartOpensItsWindow() async throws {
        for name in FixtureStart.publishedNames {
            guard let start = FixtureStart(name: name) else { continue }

            let harness = try CoordinatorHarness(bootstrap: .present)
            // `fermix://setup` lands where the daemon's readiness says, and the
            // machine it is looked at on gates on its primary's credential; the
            // harness's daemon answers the golden, which is ready, so it is
            // given that machine's answer for this one start.
            if start == .surface(.setup) {
                harness.settingsGateway.setupStateResult = try ManagementValueFixture.setupState(primaryConfigured: false)
            }
            var restartSheetShown = false
            var browserOpened = false
            var callsBegun = 0
            var phoneSheet: PhoneSheetIntent?
            FixtureLaunch(start: start).present(
                with: harness.coordinator,
                showRestartSheet: { restartSheetShown = true },
                openBrowser: { browserOpened = true },
                beginCall: { callsBegun += 1 },
                presentPhone: { phoneSheet = $0 }
            )
            // `fermix://setup` asks the daemon where to land before it lands
            // (M34 §3.4), so the window opens on the answer rather than on the
            // click.
            try await harness.coordinator.drainPendingWork()

            expectOpened(start, harness: harness, restartSheetShown: restartSheetShown)
            #expect(browserOpened == (start == .browser), "\(name) opened the browser pane")
            #expect(
                callsBegun == (start == .chatCall || start == .failedChatCall ? 1 : 0),
                "\(name) began \(callsBegun) calls"
            )
            if case .phone(let step) = start {
                #expect(phoneSheet == step.intent, "\(name) did not put the Phone sheet up")
            } else {
                #expect(phoneSheet == nil, "\(name) put the Phone sheet up")
            }
        }
    }

    @MainActor
    private func expectOpened(
        _ start: FixtureStart,
        harness: CoordinatorHarness,
        restartSheetShown: Bool
    ) {
        switch start {
        case .assistant(let stage):
            #expect(harness.windows.presented == [.main])
            #expect(harness.model.onboardingStage == (stage == .bootFailed ? .starting : stage))
        case .surface(.uninstall):
            // Uninstall is drawn on Doctor, carrying its notice. That is the
            // app's own resolution of the route, not this launch losing it.
            #expect(harness.windows.presented == [.main])
            #expect(harness.model.route == .doctor)
        case .surface(let route):
            // Where a route lands is the coordinator's decision, and it is not
            // always the main window: `setup` and `recovery` are assistant
            // screens. What matters here is that every published surface opens
            // exactly one window, and that a main-window route is the one asked
            // for.
            #expect(harness.windows.presented.count == 1, "\(route.rawValue) opened nothing")
            guard harness.windows.presented == [.main] else { return }

            #expect(harness.model.route == route)
        case .settings(let pane):
            // Decision D1: settings is a presentation of the primary window, so
            // a settings start opens that window and enters it.
            #expect(harness.windows.presented == [.main])
            #expect(harness.settings.selectedPane == pane)
            #expect(harness.presentation.isShowing)
        case .restartSheet:
            #expect(harness.windows.presented == [.main])
            #expect(harness.model.route == .home)
            #expect(restartSheetShown)
        case .approvalStep:
            #expect(harness.windows.presented == [.main])
            #expect(harness.model.onboardingStage == .starting)
        case .emptyChat, .browser, .chatCall, .failedChatCall:
            #expect(harness.windows.presented == [.main])
            #expect(harness.model.route == .chat)
        case .phone:
            #expect(harness.windows.presented == [.main])
            #expect(harness.settings.selectedPane == .channels)
            #expect(harness.presentation.isShowing)
        }
    }

    // MARK: - The chat

    /// Chat is looked at in both of its states, and only one start draws the
    /// empty one: Chat reached from any other start shows a conversation.
    @Test("chat-empty opens Chat on an empty timeline and every other start holds the full one")
    func chatStartsNameTheirTimeline() {
        #expect(FixtureLaunch(start: .emptyChat).presentation == .route(.chat))
        #expect(FixtureLaunch(start: .emptyChat).companionTimeline == .empty)
        #expect(FixtureLaunch(start: .surface(.chat)).companionTimeline == .full)
        #expect(FixtureLaunch(start: .surface(.home)).companionTimeline == .full)
        #expect(FixtureHome.forStart(.emptyChat) == .settled)
    }

    /// A call is looked at beside a conversation, so both call starts hold the
    /// full timeline; only the failed one's daemon ends the call. Every other
    /// start's voice talks to the conversation, so a call begun from the Pet
    /// page of any start has a daemon to answer it.
    @Test("chat-call and chat-call-failed open Chat over the full timeline, each with its own call")
    func callStartsNameTheirCall() {
        #expect(FixtureLaunch(start: .chatCall).presentation == .chatWithCall)
        #expect(FixtureLaunch(start: .failedChatCall).presentation == .chatWithCall)
        #expect(FixtureLaunch(start: .chatCall).companionTimeline == .full)
        #expect(FixtureLaunch(start: .failedChatCall).companionTimeline == .full)
        #expect(FixtureLaunch(start: .chatCall).realtimeCall == .conversation)
        #expect(FixtureLaunch(start: .failedChatCall).realtimeCall == .costLimit)
        #expect(FixtureLaunch(start: .surface(.pet)).realtimeCall == .conversation)
        #expect(FixtureLaunch(start: .emptyChat).realtimeCall == .conversation)
        #expect(FixtureHome.forStart(.chatCall) == .settled)
        #expect(FixtureHome.forStart(.failedChatCall) == .settled)
    }

    /// The voice of every fixture launch stands on the scripted daemon and the
    /// silent engine, so no start can reach the realtime socket or ask macOS
    /// for the microphone, whichever surface a call is begun from.
    @MainActor
    @Test("the fixture environment hands the voice its scripted daemon and the silent engine")
    func fixtureVoiceSeams() throws {
        for start in [FixtureStart.chatCall, .failedChatCall, .surface(.pet)] {
            let environment = try AppEnvironment.fixture(FixtureLaunch(start: start), mascot: StillMascot())

            #expect(environment.realtimeLines is FixtureRealtimeTransport)
            #expect(environment.voiceAudio is FixtureAudioEngine)
        }
    }

    /// The pane is looked at beside a conversation, on the fixture's own two
    /// pages, and never over the network.
    @MainActor
    @Test("browser opens Chat with the pane open on two fake tabs, the second private")
    func browserStartOpensThePane() {
        #expect(FixtureLaunch(start: .browser).presentation == .chatWithBrowser)
        #expect(FixtureLaunch(start: .browser).companionTimeline == .full)
        #expect(FixtureHome.forStart(.browser) == .settled)

        let browser = BrowserCoordinator(
            makeEngine: { _ in FixtureBrowserEngine() },
            profile: WebsiteProfileRecord(location: BrowserProfileLocation().location),
            workspace: FixtureWorkspaceOpener(),
            home: { throw CocoaError(.fileNoSuchFile) },
            session: FakeSessionAvailability(),
            deadlines: ManualDeadlineScheduler(),
            paneShown: { _ in },
            presentPrimaryWindow: {}
        )
        FixtureWebPage.openTabs(in: browser)

        #expect(browser.model.isOpen)
        #expect(browser.model.tabs.map(\.title) == ["Example Domain", "IANA-managed Reserved Domains"])
        #expect(browser.model.tabs.map(\.profile) == [.shared, .private])
        #expect(browser.model.tabs.map(\.hasOnlySecureContent) == [true, true])
        #expect(browser.model.selectedTabID == browser.model.tabs.first?.id)
    }

    /// A file opens in a fake page that draws its name and reads nothing
    /// from the operator's disk.
    @MainActor
    @Test("a file opens in a fixture file tab, named by the file")
    func fixtureFileTab() throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let browser = BrowserCoordinator(
            makeEngine: { _ in FixtureBrowserEngine() },
            profile: WebsiteProfileRecord(location: BrowserProfileLocation().location),
            workspace: FixtureWorkspaceOpener(),
            home: { place.home },
            session: FakeSessionAvailability(),
            deadlines: ManualDeadlineScheduler(),
            paneShown: { _ in },
            presentPrimaryWindow: {}
        )

        browser.openFile(try place.write("notes.md", in: place.home))

        #expect(browser.model.tabs.map(\.profile) == [.file])
        #expect(browser.model.tabs.map(\.title) == ["notes.md"])
        #expect(browser.model.tabs.first?.url == browser.model.tabs.first?.file)
        #expect(browser.model.dialog == nil)
    }

    /// The scripted daemon, driven through the real adapter and the session:
    /// the full timeline arrives as the contract's events, and the chat holds a
    /// dozen rows with older ones behind them, a reply being written with a
    /// tool running, and an approval.
    @MainActor
    @Test("the full timeline is a dozen rows, older rows, a running turn and an approval")
    func fullTimelineArrives() {
        let session = fixtureChat(.full)
        session.connect()

        #expect(session.model.connection == .connected)
        #expect(session.model.rows.map(\.serverSeq) == Array(9...20))
        #expect(Set(session.model.rows.compactMap(\.role)) == ["user", "assistant"])
        #expect(session.model.hasOlder)
        #expect(session.model.turn?.inReplyTo == FixtureCompanionScript.askedLast)
        #expect(session.model.turn?.tool?.phase == .start)
        #expect(session.model.approvals.map(\.approvalId) == [FixtureCompanionScript.approvalId])

        session.pullOlder()
        #expect(session.model.rows.map(\.serverSeq) == Array(1...20))
        #expect(!session.model.hasOlder)
    }

    @MainActor
    @Test("the empty timeline holds nothing, and a message becomes a row and a turn")
    func emptyTimelineTakesAMessage() {
        let session = fixtureChat(.empty)
        session.connect()

        #expect(session.model.connection == .connected)
        #expect(session.model.rows.isEmpty)
        #expect(!session.model.hasOlder)
        #expect(session.model.turn == nil)

        session.send("Hello")
        #expect(session.model.pending.isEmpty)
        #expect(session.model.rows.map(\.text) == ["Hello"])
        #expect(session.model.turn?.inReplyTo == "fixture-1")
    }

    @MainActor
    @Test("the fixture daemon searches its own rows, newest first, a page at a time")
    func fixtureSearch() {
        let session = fixtureChat(.full)
        session.connect()

        session.search("calendar")
        let hits = session.model.search?.hits ?? []
        #expect(hits.map(\.serverSeq) == [19, 9, 8])
        #expect(hits.allSatisfy { !$0.ranges.isEmpty })
        #expect(session.model.search?.nextBeforeSeq == nil)
    }

    /// A session over the scripted daemon with no main-actor hop between them,
    /// so every answer lands before the call that asked for it returns.
    @MainActor
    private func fixtureChat(_ timeline: FixtureCompanionTimeline) -> CompanionSession {
        var issued = 0
        return CompanionSession(
            transport: CompanionSocketClient(lines: FixtureCompanionTransport(timeline: timeline)),
            socketPath: { "/fixture/companion.sock" },
            deadlines: ManualDeadlineScheduler(),
            messageIds: {
                issued += 1
                return "fixture-\(issued)"
            }
        )
    }

    /// The throwaway home is under the per-user temporary directory and one per
    /// start, which is what keeps a fixture run out of the operator's account
    /// and two starts out of each other's home.
    @Test("each start gets its own throwaway home under the temporary directory")
    func throwawayHomesAreDistinct() throws {
        let first = try FixtureRoot.prepared(for: "unit-home-a")
        let second = try FixtureRoot.prepared(for: "unit-home-b")

        #expect(first.defaultFermixHome.path.hasPrefix(NSTemporaryDirectory()))
        #expect(first.defaultFermixHome != second.defaultFermixHome)
        #expect(try BootstrapStore(location: first).load().fermixHome == first.defaultFermixHome)
    }

    @Test("two starts never share one throwaway home")
    func startSlugsAreDistinct() {
        let slugs = FixtureStart.publishedNames
            .compactMap(FixtureStart.init(name:))
            .map { FixtureLaunch(start: $0).startSlug }

        #expect(Set(slugs).count == slugs.count)
        #expect(slugs.allSatisfy { !$0.contains("/") })
    }

    // MARK: - The answers

    /// Every method the contract publishes has an answer. Derived from the
    /// method vocabulary, so a method added to the app without a golden answer
    /// fails here instead of rendering an empty pane at runtime.
    ///
    /// `settings.get` answers per section, so it is asked with the params it is
    /// keyed on: every section the inventory publishes, which is what proves
    /// each pane has rows to draw rather than only that the method replies.
    @Test("the fixture transport answers every published method")
    func everyMethodAnswers() async throws {
        let transport = try FixtureManagementTransport(
            machine: FixtureMachine(daemonUp: true),
            readiness: .gatingFailure
        )

        for method in ManagementMethod.allCases {
            let payload = try JSONSerialization.data(withJSONObject: [
                "request_id": "req-fixture-1",
                "protocol_version": 2,
                "method": method.rawValue,
                "params": Self.params(for: method)
            ])
            let answer = try await transport.exchange(payload, timeout: .seconds(1))
            let frame = try JSONSerialization.jsonObject(with: answer) as? [String: Any]

            #expect(frame?["request_id"] as? String == "req-fixture-1", "\(method.rawValue)")
            #expect(frame?["result"] != nil, "\(method.rawValue) has no result")
        }
    }

    /// The params one method is asked with.
    ///
    /// Five methods are keyed on their params, because the contract publishes
    /// more than one golden for each: `settings.get` answers per section,
    /// `settings.apply` per key it changes, `job.get` per job, and `secret.set` and `secret.clear`
    /// answer per secret, so asking any of them with none would be asking for
    /// something the contract does not publish. Every other method answers one
    /// shape.
    static func params(for method: ManagementMethod) -> [String: Any] {
        switch method {
        case .settingsGet: return ["section": "realtime"]
        case .settingsApply: return ["section": "realtime", "values": ["realtime_enabled": true]]
        case .jobGet: return ["job_id": "job:2Kd9mQ"]
        case .secretSet, .secretClear: return ["id": "openai_api_key"]
        default: return [:]
        }
    }

    /// Every section the inventory publishes has rows, so a pane cannot render
    /// an empty form against this home (decision D5).
    @Test("every published section answers with its own rows")
    func everySectionAnswers() async throws {
        let client = try await negotiatedClient()
        let inventory = try await client.settingsSections()

        #expect(inventory.sections.count >= 20, "every pane's sections are published")
        for entry in inventory.sections {
            let rows = try await client.settings(section: entry.id)

            #expect(rows.id == entry.id)
            #expect(!rows.rows.isEmpty, "\(entry.id) has no rows to draw")
        }

        // Every pane but the two that are hand-built lists has at least one
        // section, so no pane opens onto nothing.
        let panes = inventory.sections.map(\.pane)
        for pane in SettingsPane.allCases where pane != .integrations && pane != .permissions {
            #expect(panes.contains(pane.wire), "\(pane.slug) publishes no section")
        }
    }

    /// Every secret the contract publishes an answer for is answered, and each
    /// one gets its own. `secret.set` and `secret.clear` both publish more than
    /// one golden, and answering with whichever the file listed last is a choice
    /// nobody made. The case set is the goldens' own, asked under each golden's
    /// own params, so a secret family added upstream is checked at the re-vendor
    /// that brings it rather than when somebody remembers to list it here.
    @Test("each published secret is answered under its own id")
    func everyPublishedSecretIsAnswered() async throws {
        let transport = try FixtureManagementTransport(
            machine: FixtureMachine(daemonUp: true),
            readiness: .gatingFailure
        )
        let methods = [ManagementMethod.secretSet.rawValue, ManagementMethod.secretClear.rawValue]
        var answered: [String: Set<String>] = [:]

        for fixture in try ManagementFixtures.load(.requests, from: .management) {
            let method = try fixture.string("method")
            guard methods.contains(method) else { continue }

            let params = try #require(try fixture.object("frame")["params"] as? [String: Any])
            let identifier = try #require(params["id"] as? String)
            let payload = try JSONSerialization.data(withJSONObject: [
                "request_id": "req-fixture-1",
                "protocol_version": 2,
                "method": method,
                "params": params
            ])
            let answer = try await transport.exchange(payload, timeout: .seconds(1))
            let frame = try JSONSerialization.jsonObject(with: answer) as? [String: Any]
            let result = frame?["result"] as? [String: Any]

            #expect(result?["id"] as? String == identifier, "\(fixture.name)")
            answered[method, default: []].insert(identifier)
        }

        for method in methods {
            #expect((answered[method]?.count ?? 0) > 1, "\(method) publishes more than one secret to tell apart")
        }
    }

    /// The voice section publishes one golden per engine for the same request,
    /// and Live's carries rows the other never does. The home answers the one
    /// published under the engine its own overview runs, so the Voice pane
    /// never draws Live's backend row beside a Realtime engine.
    @Test("the voice section answers under the engine the overview names")
    func voiceSectionFollowsTheOverviewEngine() async throws {
        let client = try await negotiatedClient()
        let overview = try await client.overview()
        let voice = try await client.settings(section: "realtime")

        #expect(overview.realtime.engine == "openai_realtime")
        #expect(voice.rows.contains { $0.key == "realtime_reasoning_effort" })
        #expect(!voice.rows.contains { $0.key == "realtime_backend" })
    }

    /// A section this home does not publish is loud, not empty: a pane
    /// rendering nothing is exactly what this configuration exists to prevent.
    @Test("a section with no golden answer is refused, not answered empty")
    func unknownSectionIsLoud() async throws {
        let transport = try FixtureManagementTransport(
            machine: FixtureMachine(daemonUp: true),
            readiness: .gatingFailure
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "request_id": "req-fixture-1",
            "protocol_version": 2,
            "method": ManagementMethod.settingsGet.rawValue,
            "params": ["section": "nothing.published"]
        ])

        await #expect(throws: FixtureManagementTransport.Defect.self) {
            _ = try await transport.exchange(payload, timeout: .seconds(1))
        }
    }

    /// A method with no answer is loud. A surface silently rendering nothing is
    /// exactly what this configuration exists to make impossible.
    @Test("a method with no golden answer is refused, not answered empty")
    func unansweredMethodIsLoud() async throws {
        let transport = try FixtureManagementTransport(
            machine: FixtureMachine(daemonUp: true),
            readiness: .gatingFailure
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "request_id": "req-fixture-1",
            "protocol_version": 2,
            "method": "nothing.published",
            "params": [String: Any]()
        ])

        await #expect(throws: FixtureManagementTransport.Defect.methodHasNoAnswer("nothing.published")) {
            _ = try await transport.exchange(payload, timeout: .seconds(1))
        }
    }

    /// Doctor's golden is a run in progress, and one of its landed checks
    /// carries a whole remediation. That check is what this home exists to show:
    /// a remediation nobody ever looks at is the half of Doctor that rots.
    @Test("doctor answers the run whose check carries a remediation")
    func doctorAnswersTheRemediation() async throws {
        let session = try await negotiatedClient().doctorSession(id: "doctor:9Fj2mQ7bT1xK")
        let remediated = session.checks.filter { $0.remediation != nil }

        #expect(session.status == .running)
        #expect(session.completedCount < session.total, "a run still going has checks to come")
        #expect(remediated.count == 1)
        #expect(remediated.first?.status == .warning)
        #expect(remediated.first?.remediation?.title.isEmpty == false)
        // The golden's remediation is the pending restart, which the app owns
        // as its one Restart sheet rather than as a daemon-side job.
        #expect(remediated.first?.remediation?.action.kind == .restart)
        #expect(
            DoctorProjection.action(for: try #require(remediated.first)) == .restartDaemon,
            "the golden remediation resolves to an action this build performs"
        )
    }

    /// The negotiated window. Against this home every v2 surface renders fully,
    /// which is the whole point of looking at it.
    @Test("the fixture daemon speaks protocol two")
    func negotiatesVersionTwo() async throws {
        let hello = try await fixtureClient().hello()

        #expect(hello.protocolRange.minimum == 1)
        #expect(hello.protocolRange.maximum == 2)
    }

    /// The home the slice asked for, read the way the surfaces read it.
    @Test("the fixture home is a realistic Mac")
    func theHomeIsRealistic() async throws {
        let client = try await negotiatedClient()
        let state = try await client.setupState()

        // The primary is the one with no credential, which is the gate the
        // Attention section and Connect your AI are looked at through; the
        // rest are offered and not configured.
        #expect(state.providers.contains { $0.primary && !$0.configured })
        #expect(state.providers.contains { !$0.primary })

        // Every channel the Channels pane draws, one answering and the rest
        // offered: the list is the daemon's, and a home carrying one channel
        // could never render the list at all. The seventh is the phone, which
        // PROTOCOL.md publishes after the inventory channels and the golden
        // predates.
        #expect(state.channels.count == 7)
        #expect(state.channels.last?.name == PhoneChannel.name)
        #expect(state.channels.contains { $0.enabled && $0.configured })
        #expect(state.channels.contains { !$0.configured })

        // A pending restart the operator has to take, with the daemon's own
        // reasons rather than a sentence the app wrote.
        #expect(state.restart.required)
        #expect(!state.restart.reasons.isEmpty)

        // One gating failure and two advisory ones, so Home draws both shapes.
        #expect(state.readiness.failures.filter(\.gating).count == 1)
        #expect(state.readiness.failures.filter { !$0.gating }.count == 2)

        // One coexistence descriptor, which is what the Attention section and
        // Doctor both answer for.
        #expect(state.coexistence.legacyServiceUnit.present)
    }

    /// The three machines a fixture launch runs on, over one golden.
    ///
    /// The engine publishes one `setup.state.get` and one `overview.get`, a
    /// ready home with two advisory rows, so the gated machine, Ready and a
    /// first run are all derived from it rather than from a second golden
    /// nobody upstream maintains. The derivation is what these assert, and each
    /// home is asserted
    /// in BOTH places: Home drew `Running` with four Attention rows and
    /// `Continue setup` at once the last time the two disagreed.
    @Test("each fixture home answers one readiness in both places")
    func eachHomeAnswersOneReadiness() async throws {
        #expect(FixtureHome.settled.readiness == .gatingFailure)
        #expect(FixtureHome.configured.readiness == .ready)
        #expect(FixtureHome.fresh.readiness == .fresh)

        for readiness in [FixtureReadiness.gatingFailure, .ready, .fresh] {
            let client = try await Self.negotiatedClient(readiness: readiness)
            let state = try await client.setupState()
            let overview = try await client.overview()

            #expect(
                overview.readiness.failureCount == state.readiness.failures.count,
                "\(readiness) reports two failure counts"
            )
            #expect(overview.readiness.status == state.readiness.status, "\(readiness)")
        }
    }

    /// Ready is the only machine the assistant's last screen renders on: it
    /// claims the install is live, so it refuses to draw while a gating failure
    /// stands.
    @Test("the configured home has passed every gate")
    func theConfiguredHomeIsReady() async throws {
        let state = try await Self.negotiatedClient(readiness: .ready).setupState()

        #expect(state.readiness.status == "ready")
        #expect(state.readiness.failures.isEmpty)
        // Everything else is the golden's: a machine that passed its gates is
        // still the machine that has a provider, a channel and a restart.
        #expect(state.providers.contains { $0.configured && $0.primary })
        #expect(state.restart.required)
    }

    /// A first run: no configured provider and no channel, with the
    /// personalization the daemon's first boot seeds from the machine. It is
    /// the machine the assistant's decision screens are actually used on,
    /// and no fixture home was ever in it — which is how the two first-run
    /// defects on Connect your AI shipped without anyone seeing them.
    @Test("the fresh home has nothing set up")
    func theFreshHomeHasNothingSetUp() async throws {
        let launch = FixtureLaunch(start: .assistant(.welcome))
        let client = try await Self.negotiatedClient(
            readiness: .fresh,
            machine: FixtureMachine(daemonUp: true, phone: launch.phoneChannel)
        )
        let state = try await client.setupState()
        let overview = try await client.overview()

        #expect(state.readiness.status == "setup_required")
        #expect(!state.providers.isEmpty, "the list is still the daemon's own")
        #expect(!state.providers.contains { $0.configured })
        #expect(!state.providers.contains { $0.primary })
        #expect(state.channels.count == 7)
        #expect(!state.channels.contains { $0.enabled })
        // The phone channel has no credential, so the daemon reports it
        // configured from the first boot (PROTOCOL.md).
        #expect(state.channels.filter(\.configured).map(\.name) == [PhoneChannel.name])
        // Seeded before any screen: the name, the time zone and a default style.
        #expect(state.personalization.present.userName)
        #expect(state.personalization.present.timezone)
        #expect(state.personalization.present.communicationStyle)
        #expect(!state.features.voice)
        #expect(!state.restart.required)
        #expect(!state.coexistence.legacyServiceUnit.present)

        #expect(overview.provider.active == nil)
        #expect(overview.channels.isEmpty)
        #expect(!overview.realtime.enabled)
        #expect(!overview.health.restartRequired)
        #expect(overview.health.providers.isEmpty)
    }

    private static func negotiatedClient(
        readiness: FixtureReadiness = .gatingFailure,
        machine: FixtureMachine = FixtureMachine(daemonUp: true)
    ) async throws -> ManagementClient {
        let client = ManagementClient(
            transport: try FixtureManagementTransport(machine: machine, readiness: readiness),
            contract: try ManagementContract.vendored()
        )
        _ = try await client.hello()

        return client
    }

    /// The catalogue carries every shape the page can draw (decision D5): an
    /// installed row and a not-installed one, a hosted runtime with its own
    /// disclosure, a plugin with manifest settings, and one that binds to a
    /// workspace. The consent sentence is the field the engine's own notes
    /// record as having shipped wrong once, so every row carries one.
    @Test("the fixture home carries the published plugin catalogue")
    func pluginsAndPermissions() async throws {
        let client = try await negotiatedClient()
        let catalogue = try await client.plugins()
        let permissions = try await client.computerUsePermissions()

        #expect(catalogue.plugins.count == 4)
        #expect(catalogue.plugins.contains { $0.installed })
        #expect(catalogue.plugins.contains { !$0.installed })
        #expect(catalogue.plugins.contains { !$0.settings.isEmpty })
        #expect(catalogue.plugins.contains { $0.remoteDisclosure != nil }, "a hosted runtime to disclose")
        #expect(
            catalogue.plugins.allSatisfy { !$0.consentSentence.isEmpty },
            "every row can be installed"
        )
        #expect(catalogue.plugins.contains { !$0.accessProfiles.isEmpty }, "a workspace to choose")
        #expect(catalogue.plugins.contains { !$0.workspaces.isEmpty })
        #expect(catalogue.plugins.allSatisfy { !$0.verbs.isEmpty }, "the detail renders the verbs")
        #expect(catalogue.oauthClients.count == 2, "Google and Notion")
        #expect(catalogue.oauthClients.contains { $0.configured })
        #expect(catalogue.oauthClients.contains { !$0.configured })
        // Mixed on purpose: a ledger where every right agrees never shows the
        // row that asks for one.
        #expect(permissions.screenCapture != permissions.inputControl)
    }

    // MARK: - The phone channel

    /// Each Phone step is read from its own moment of the one golden window,
    /// and the status names that moment.
    @Test("the phone channel answers from the moment its machine declares")
    func phoneMoments() async throws {
        let moments: [(FixturePhoneStart, ManagementPairingState)] = [
            (.scan, .awaitingScan), (.compare, .awaitingDecision), (.paired, .approved), (.ended, .expired)
        ]

        for (step, state) in moments {
            let client = try await Self.negotiatedClient(machine: FixtureMachine(daemonUp: true, phone: step.channel))
            let status = try await client.mobileStatus()
            let read = try await client.pairingSession(id: PhonePairingTests.session)
            let started = try await client.startPairing()

            #expect(status.started, "\(step)")
            #expect(status.pairing?.state == state, "\(step)")
            #expect(read.state == state, "\(step)")
            #expect(started.session.state == .awaitingScan, "\(step) opened no window")
            #expect(started.uri != nil)
        }
    }

    /// A channel that is not running pairs nobody, has no window, and refuses
    /// a start with the daemon's own sentence.
    @Test("a phone channel that is not running answers as one")
    func phoneChannelOff() async throws {
        let off = FixturePhoneChannel(switchedOn: false, running: false, moment: "awaiting_scan")
        let client = try await Self.negotiatedClient(machine: FixtureMachine(daemonUp: true, phone: off))

        let status = try await client.mobileStatus()
        #expect(!status.enabled)
        #expect(!status.started)
        #expect(status.pairedDevices == 0)
        #expect(status.pairing == nil)

        let started = try await client.startPairing()
        #expect(started.session.state == .failed)
        #expect(started.session.failure?.sentence == "The mobile channel is turned off.")

        let state = try await client.setupState()
        let phone = try #require(state.channels.first { $0.name == PhoneChannel.name })
        #expect(!phone.enabled)
        #expect(phone.configured)
    }

    /// Turn on is looked at end to end on the fixture: the switch is written
    /// and the channel waits for the restart, and the restart the app's own
    /// transaction commits starts it, as the daemon's boot does.
    @Test("throwing the phone switch waits for the restart, which starts the channel")
    func phoneSwitchWaitsForTheRestart() async throws {
        let machine = FixtureMachine(daemonUp: true, phone: FixturePhoneStart.turnOn.channel)
        let client = try await Self.negotiatedClient(machine: machine)

        let applied = try await client.applySettings(
            section: PhoneChannel.section,
            values: [PhoneChannel.switchKey: .flag(true)]
        )
        #expect(applied.applied == [PhoneChannel.switchKey])
        #expect(applied.restart.required)

        let owed = try await client.mobileStatus()
        #expect(owed.enabled)
        #expect(!owed.started)
        #expect(try await client.startPairing().session.state == .failed)

        machine.shutdownCommitted()

        #expect(try await client.mobileStatus().started)
        #expect(try await client.startPairing().session.state == .awaitingScan)
    }

    // MARK: - The machine a transaction moves

    /// `Restart now` is the Restart sheet's primary action and one of the
    /// screens this configuration exists to look at. The transaction proves
    /// itself by watching the old pid stop reporting and a different one come
    /// back, so a home whose probes answer "running" forever would spend the
    /// whole 15-second exit budget and refuse — and a capture session would read
    /// that as a product defect.
    @Test("a restart replaces the daemon this home is talking to")
    func restartReplacesTheDaemon() async throws {
        let machine = FixtureMachine(daemonUp: true)
        let lifecycle = try lifecycleCoordinator(on: machine, home: "unit-restart")

        let outcome = try await lifecycle.restartDaemon()

        #expect(outcome == .restarted(
            previousPid: FixtureMachine.firstPid,
            currentPid: machine.currentPid
        ))
        #expect(machine.currentPid != FixtureMachine.firstPid)
        #expect(machine.daemonRunning)
    }

    /// Disabling is the same transaction in the other direction: the
    /// registration goes, launchd unloads the job, and the socket it was
    /// listening on is proven released.
    @Test("disabling the background service takes the daemon down with it")
    func disableTakesTheDaemonDown() async throws {
        let machine = FixtureMachine(daemonUp: true)
        let lifecycle = try lifecycleCoordinator(on: machine, home: "unit-disable")

        #expect(try await lifecycle.disableBackgroundService() == .disabled)
        #expect(!machine.isRegistered(.agent))
        #expect(!machine.daemonRunning)
    }

    /// The machine whose socket never appears stays that way when the agent is
    /// registered, which is what holds the Starting ladder at its own row.
    @Test("registering the agent does not start a daemon launchd never brings up")
    func startingHomeHolds() {
        let machine = FixtureMachine(daemonUp: false)

        machine.registrationChanged(.agent, to: false)
        machine.registrationChanged(.agent, to: true)

        #expect(!machine.daemonRunning)
        #expect(machine.currentPid == FixtureMachine.firstPid)
    }

    /// The GUI's own login item is a separate consent, so Home's toggle sticks
    /// without moving anything about the daemon.
    @Test("the two login items are independent")
    func loginItemsAreIndependent() {
        let machine = FixtureMachine(daemonUp: true)
        let items = FixtureLoginItems(machine: machine)

        #expect(items.status(.agent) == .enabled)
        #expect(items.status(.mainApp) == .notRegistered)

        try? items.register(.mainApp)

        #expect(items.status(.mainApp) == .enabled)
        #expect(machine.daemonRunning)
        #expect(machine.currentPid == FixtureMachine.firstPid)
    }

    /// One machine behind every seam that can see it. The transport commits the
    /// shutdown and the probes report it, so two machines would leave a restart
    /// waiting on a daemon that, as far as the probes know, never stopped.
    @MainActor
    @Test("the fixture environment stands every seam on one machine")
    func oneMachineBehindEverySeam() throws {
        let environment = try AppEnvironment.fixture(FixtureLaunch(start: .surface(.home)), mascot: StillMascot())
        let socket = environment.location.defaultFermixHome
            .appendingPathComponent("daemon.sock").path

        #expect(environment.paths.exists(atPath: socket))
        // Unregistering through the login-item seam unloads the job, which the
        // path probe can only see if both seams read the same machine.
        try environment.loginItems.unregister(.agent)

        #expect(!environment.paths.exists(atPath: socket))
        #expect(environment.loginItems.status(.agent) == .notRegistered)
    }

    /// The lifecycle owner, over exactly the pieces the fixture environment
    /// hands it, so what this proves is what a fixture launch runs.
    private func lifecycleCoordinator(
        on machine: FixtureMachine,
        home name: String
    ) throws -> LifecycleCoordinator {
        let location = try FixtureRoot.prepared(for: name)
        let probes = FixtureProbes(machine: machine)
        let transport = try FixtureManagementTransport(machine: machine, readiness: .gatingFailure)
        let contract = try ManagementContract.vendored()

        return LifecycleCoordinator(
            store: BootstrapStore(location: location),
            journal: LifecycleJournal(location: location),
            services: ServiceController(
                loginItems: FixtureLoginItems(machine: machine),
                plists: AbsentAgentPlistDigest()
            ),
            reconciler: EngineReconciler(bundled: nil, bundledPlistDigest: nil),
            plane: { _ in
                ManagementControlPlane(client: ManagementClient(transport: transport, contract: contract))
            },
            processes: probes,
            paths: probes,
            web: probes,
            sleeper: RecordingSleeper()
        )
    }

    /// A client that has negotiated, which is what every surface holds: the
    /// gateway calls `hello` once and every later method is gated on the window
    /// it reported.
    private func negotiatedClient() async throws -> ManagementClient {
        let client = try fixtureClient()
        _ = try await client.hello()

        return client
    }

    private func fixtureClient() throws -> ManagementClient {
        ManagementClient(
            transport: try FixtureManagementTransport(
                machine: FixtureMachine(daemonUp: true),
                readiness: .gatingFailure
            ),
            contract: try ManagementContract.vendored()
        )
    }
}

/// The structural gates this slice makes true.
@Suite("Fixture configuration source gates")
struct FixtureConfigurationSourceGateTests {
    /// The fixture configuration compiles into debug builds only, whole files
    /// at a time. A type half inside the guard is how a release build acquires
    /// a fixture seam nobody meant to ship.
    ///
    /// The set is derived from the tree rather than listed here, so a third
    /// fixture source joins the gate instead of shipping ungated.
    @Test("every fixture source is wholly inside the debug guard")
    func fixtureSourcesAreGuarded() throws {
        let guarded = try Self.fixtureSources()
            // The parser compiles into every build: it is what a release build
            // refuses the flag with, so it is the one that must not be guarded.
            .filter { !$0.path.hasSuffix("App/FixtureLaunchRequest.swift") }
        #expect(guarded.count >= 2, "the fixture sources have moved")

        for file in guarded {
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.first == "#if DEBUG", "\(file.path) does not open with the guard")
            #expect(lines.last == "#endif", "\(file.path) does not close with the guard")
            #expect(
                file.text.components(separatedBy: "#if DEBUG").count == 2,
                "\(file.path) carries a second guard"
            )
        }
    }

    /// Every source that belongs to the fixture configuration, by the same rule
    /// both gates in this suite read.
    private static func fixtureSources() throws -> [SourceTree.File] {
        let sources = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.path.contains("Fixture") }
        #expect(!sources.isEmpty, "no fixture source is in the tree")

        return sources
    }

    /// No drawn surface is compiled differently in a debug build. The fixture
    /// configuration replaces the machine under the views; a view that read a
    /// build flag would be a second rendering nobody reviews.
    @Test("no view is compiled differently in debug")
    func viewsAreBuildIndependent() throws {
        let offenders = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("#if DEBUG") }
            .filter { file in
                file.path.contains("/Design/") || file.path.contains("/Panes/")
                    || file.path.hasSuffix("View.swift") || file.path.hasSuffix("Surface.swift")
                    || file.path.hasSuffix("Sheet.swift")
            }

        #expect(offenders.isEmpty, "debug-only drawing in: \(offenders.map(\.path))")
    }

    /// The configuration is selected by a launch argument and never by an
    /// environment value: an overlay is inherited, survives in a shell nobody
    /// is looking at, and would put a build into the fixture configuration
    /// without anybody asking for it on that launch.
    @Test("no fixture source reads the environment")
    func fixtureReadsNoEnvironment() throws {
        let offenders = try Self.fixtureSources().filter {
            $0.text.contains("ProcessInfo") || $0.text.contains("getenv")
                || $0.text.contains("environment[")
        }

        #expect(offenders.isEmpty, "environment read in: \(offenders.map(\.path))")
    }

    /// Two composition roots and one graph. A second `AppEnvironment(` call
    /// means a second wiring, which is the drift this shape exists to prevent.
    @Test("the two configurations are two environments, not two graphs")
    func oneGraphTwoEnvironments() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let builders = files
            .map { (path: $0.path, count: $0.text.components(separatedBy: "AppEnvironment(").count - 1) }
            .filter { $0.count > 0 }
            .filter { !$0.path.hasSuffix("App/AppEnvironment.swift") }

        // One outside the declaration site: the fixture environment.
        #expect(builders.count == 1, "built in \(builders.map(\.path))")
        #expect(builders.first?.path.hasSuffix("App/FixtureConfiguration.swift") == true)

        let composition = try SourceTree.swiftFiles(matching: "App/AppComposition.swift")
        #expect(composition[0].text.contains("init(environment: AppEnvironment)"))
        #expect(!composition[0].text.contains("#if DEBUG"), "the product root branches on the build")
    }

    /// The voice stack is built over the two seams the environment hands it,
    /// as chat is over its own: a socket or an audio engine the graph built for
    /// itself is one no configuration governs, and the fixture's claim that it
    /// never touches the microphone would be true only by accident.
    @Test("the composition builds voice over the environment's socket and audio engine")
    func voiceStandsOnTheEnvironment() throws {
        let composition = try SourceTree.swiftFiles(matching: "App/AppComposition.swift")[0].text

        #expect(composition.contains("environment.realtimeLines"))
        #expect(composition.contains("environment.voiceAudio"))
        #expect(!composition.contains("AudioController("), "the composition builds its own audio engine")
        #expect(!composition.contains("lineSocket("), "the composition builds its own socket")
    }

    /// Nothing reaches past the environment to read the machine directly. The
    /// boundary is only a boundary while the graph is its one reader: a surface
    /// that held the environment and read a probe off it would be a second way
    /// to the machine, and neither configuration would govern it.
    @Test("only the composition reads the environment it was handed")
    func onlyTheCompositionReadsTheEnvironment() throws {
        // A field read off a bare `environment`: the lookbehind drops
        // `plan.environment.map` in the agent launcher, and requiring a letter
        // after the dot drops prose that ends a sentence on the word.
        let reads = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])environment\\.[A-Za-z_]")
        let offenders = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { !$0.path.hasSuffix("App/AppComposition.swift") }
            .filter { file in
                reads.firstMatch(in: file.text, range: NSRange(file.text.startIndex..., in: file.text)) != nil
            }

        #expect(offenders.isEmpty, "the environment is read outside the graph in: \(offenders.map(\.path))")
    }
}
#endif
