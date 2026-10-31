import Foundation
import Testing

@testable import FermixAppCore

/// Cues in Settings (M60 app surface §4 to §9): the rows the golden records
/// decode to, the one gate that draws the pane, what the rows and the pages
/// say, the add and mandate forms' rules, the order the model calls the
/// daemon in, and the token's rules. Nothing here touches a window or the
/// host: the pasteboard is a double too.
@Suite("Cues")
@MainActor
struct CuesTests {

    // MARK: - Decoding the golden records

    @Test("the status and the source list decode in the daemon's words")
    func statusAndSourcesDecode() throws {
        let status: ManagementCueStatus = try Self.golden("cues_status")
        #expect(status.enabled && status.running)
        #expect(status.state == .running)
        #expect(status.statusSentence == "Cues are running.")
        #expect(status.door.state == .notRunning)
        #expect(status.door.port == 4032)
        #expect(status.counts.proposalsWaiting == 1)

        let list: ManagementCueSourceList = try Self.golden("cues_sources_list")
        #expect(list.sources.map(\.ref) == ["eng-blogs", "gh-hooks", "home-alerts"])
        #expect(list.canAdd && list.limits.maxSources == 64)

        let feed = list.sources[0]
        #expect(feed.kind == .feed && feed.preset == "rss" && feed.state == .polling)
        #expect(feed.actions == [.disable] && feed.primaryAction == nil)
        #expect(feed.location == "example.org" && feed.url == "https://example.org/releases.atom")
        #expect(feed.counts.received == 3 && feed.counts.openGaps == 1)
        #expect(feed.listening == ["release-watch"])

        let webhook = list.sources[1]
        #expect(webhook.kind == .webhook && webhook.hasURL && webhook.url == nil)
        #expect(webhook.secrets.map(\.field) == [.secret, .pathSecret])
        #expect(webhook.actions == [.disable, .getURL])

        let push = list.sources[2]
        #expect(push.kind == .localPush && push.dailyBudget == 500)
        #expect(push.secrets == [ManagementCueSecretSlot(field: .token, label: "Token", present: true)])
    }

    @Test("every cue answer the goldens publish decodes into its typed result")
    func answersDecode() throws {
        let detail: ManagementCueSourceDetail = try Self.golden("cues_sources_get")
        #expect(detail.values.contains { $0.key == "secret" && $0.kind == .secret && $0.present == true })
        #expect(detail.gaps.map(\.sentence) == ["4 items were not delivered: they came faster than the rate limit."])
        #expect(detail.rejected.map(\.sentence) == ["3 refused without a valid signature or token."])

        let form: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        #expect(form.kinds.map(\.id) == ["feed", "stream", "webhook", "local_push"])
        #expect(form.presets.map(\.id) == ["github", "rss", "x_accounts"], "a stream has no preset")
        #expect(form.choices.map(\.id) == ["rss", "x_accounts", "github", "local_push", "feed", "stream", "webhook"])
        #expect(form.requirement == nil, "only X accounts needs something set up first")
        #expect(form.rows.first?.key == "ref", "the name comes first")
        #expect(form.rows.first?.example == "github", "the name Fermix would make")
        #expect(form.rows.allSatisfy { $0.advanced }, "GitHub's form has nothing to type")
        #expect(!form.rows.contains { $0.kind == .secret }, "Fermix makes GitHub's secret")

        let feed: ManagementCueSourceAdded = try Self.golden("cues_sources_add")
        #expect(feed.token == nil && feed.secret == nil)
        let push: ManagementCueSourceAdded = try Self.golden("cues_sources_add_local_push")
        #expect(push.token?.isEmpty == false, "a new local push source's first token is handed out")
        #expect(push.secret == nil)
        let webhook: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        #expect(webhook.source.ref == "github", "a source left unnamed is named by Fermix")
        #expect(webhook.secret?.isEmpty == false && webhook.token == nil, "GitHub's made secret is handed out")
        #expect(webhook.source.primaryAction == .getURL && webhook.source.missingSecret == nil)
        #expect(webhook.source.secrets.first { $0.field == .secret }?.present == true)

        let removed: ManagementCueSourceRemoved = try Self.golden("cues_sources_remove")
        #expect(removed.removed && removed.left.isEmpty && removed.watchers == ["release-watch"])
        let address: ManagementCueSourceAddress = try Self.golden("cues_sources_url_get")
        #expect(address.path.hasPrefix("/cues/hooks/"))
        let token: ManagementCueSourceToken = try Self.golden("cues_sources_token_new")
        #expect(token.ref == "home-alerts")
    }

    @Test("watchers, mandates and proposals decode, the card as its record and summary alone")
    func watchersMandatesAndProposalsDecode() throws {
        let watchers: ManagementCueWatcherList = try Self.golden("cues_watchers_list")
        #expect(watchers.windowS == 86_400 && !watchers.truncated)
        #expect(watchers.watchers.first?.filter == .llm && watchers.watchers.first?.filterModel == nil)

        let detail: ManagementCueWatcherAnswer = try Self.golden("cues_watchers_get")
        #expect(detail.watcher.row.name == "release-watch")
        #expect(detail.watcher.purpose == "A release, an outage or a security advisory for software I run.")
        #expect(detail.watcher.listenFor == ["release", "outage", "security advisory", "CVE"])
        #expect(detail.watcher.instructions.map(\.number) == [1])
        #expect(detail.watcher.examples.pass == 1 && detail.watcher.examples.drop == 0)

        let mandates: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        let mandate = try #require(mandates.mandates.first)
        #expect(mandate.mode == .approve && mandate.approveWithinS == 1800 && mandate.maxCueAgeS == 900)
        #expect(mandate.load.state == .active && mandate.approval.state == .approved)
        #expect(mandate.approval.approvedFrom == "Fermix app")

        let choices: ManagementCueMandateChoices = try Self.golden("cues_mandates_choices")
        #expect(choices.tools.map(\.readOnly) == [false, true])

        let proposals: ManagementCueProposalList = try Self.golden("cues_proposals_list")
        #expect(proposals.waiting == 1 && proposals.proposals.first?.state == .waiting)

        let states = ["cues_proposals_get", "cues_proposals_get_confirmed", "cues_proposals_get_denied",
                      "cues_proposals_get_expired", "cues_proposals_get_refused"]
        let decoded: [ManagementCueProposalCardAnswer] = try states.map { try Self.golden($0) }
        #expect(decoded.map(\.proposal.record.state) == [.waiting, .confirmed, .denied, .expired, .refused])
        #expect(decoded[0].proposal.summary.hasPrefix("A task wants to run github_create_issue"))

        let decided: ManagementCueProposalAnswer = try Self.golden("cues_proposals_decide")
        #expect(decided.proposal.state == .confirmed && decided.proposal.resultStatus == nil)
        #expect(decided.proposal.decidedFrom == .management)
    }

    @Test("the source and watcher states are the sets x-cue-vocabulary publishes")
    func cueVocabulariesMatchTheSchema() throws {
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            ) as? [String: Any]
        )
        let vocabulary = try #require(document["x-cue-vocabulary"] as? [String: Any])
        let published = { (key: String) in Set(try #require(vocabulary[key] as? [String])) }

        #expect(try published("source_states") == Set(ManagementCueSourceState.publishedValues.keys))
        #expect(try published("source_actions") == Set(ManagementCueSourceAction.publishedValues.keys))
        #expect(try published("watcher_states") == Set(ManagementCueWatcherState.publishedValues.keys))
        #expect(try published("mandate_actions") == Set(ManagementCueMandateAction.publishedValues.keys))
        #expect(try published("proposal_states") == Set(ManagementCueProposalState.publishedValues.keys))
        #expect(try published("decided_from") == Set(ManagementCueDecidedFrom.publishedValues.keys))
    }

    @Test("an unknown state, action, kind and mode decode as unrecognised and draw no control")
    func unknownValuesDrawNothing() throws {
        let source = try Self.source(editing: { row in
            row["kind"] = "carrier_pigeon"
            row["state"] = "molting"
            row["actions"] = ["fly_home"]
            row["primary_action"] = "fly_home"
            row["missing_secret"] = "feather"
        })
        #expect(source.kind == .unrecognized("carrier_pigeon"))
        #expect(source.state == .unrecognized("molting"))
        #expect(source.actions == [.unrecognized("fly_home")])
        #expect(!CueSourceProjection.switchShown(source), "an unknown action draws no switch")
        #expect(CuesSheetPage.opening(source) == .source("eng-blogs", at: nil), "an unknown action opens nothing in particular")
        #expect(!source.state.drawsAttention)

        let mandate = try Self.mandate(editing: { row in
            row["mode"] = "whenever"
            row["actions"] = ["dance"]
            row["primary_action"] = nil
        })
        #expect(mandate.mode == .unrecognized("whenever"))
        #expect(CueMandateProjection.modeTitle(mandate.mode) == nil)
        #expect(CueMandateProjection.tag(mandate) == nil, "an unknown mode is not given a name")
        #expect(!CueMandateProjection.offersApprove(mandate))
        #expect(!CueMandateProjection.switchShown(mandate))

        #expect(ManagementCueProposalState(wireValue: "pondering") == .unrecognized("pondering"))
        #expect(ManagementCueDecidedFrom(wireValue: "carrier") == .unrecognized("carrier"))
        #expect(ManagementCueDecision(wireValue: "maybe") == .unrecognized("maybe"))
    }

    // MARK: - Whether the pane is drawn

    @Test("the pane is drawn where the daemon publishes the section, lists cues.status and admits cues")
    func paneDrawnWithBoth() async throws {
        let harness = try Self.harness()

        await harness.model.windowAppeared()

        #expect(harness.model.drawsCuesPane)
        #expect(harness.model.panes(matching: "", in: .connections) == [.channels, .integrations, .cues])
        #expect(harness.model.panes(matching: "webhook", in: .connections) == [.cues], "the pane answers its keywords")
    }

    @Test("a daemon that does not list cues.status draws no pane, no row, and is never asked")
    func noPaneWithoutTheMethod() async throws {
        let gateway = try SettingsFixture.gateway()
        let harness = try SettingsHarness(gateway: gateway)

        await harness.model.windowAppeared()

        #expect(!harness.model.drawsCuesPane)
        #expect(harness.model.panes(matching: "", in: .connections) == [.channels, .integrations])
        #expect(!gateway.calls.contains(.v2(.cuesStatus)))
        #expect(!harness.model.requiresNewerEngine, "a missing cue surface is no notice and no newer-engine state")
    }

    @Test("a daemon that publishes no cues section draws no pane")
    func noPaneWithoutTheSection() async throws {
        let gateway = try Self.gateway()
        let inventory: ManagementSettingsInventory = try Self.golden("settings_sections")
        gateway.settingsSectionsResult = ManagementSettingsInventory(
            sections: inventory.sections.filter { $0.pane != .cues }
        )
        let harness = try SettingsHarness(gateway: gateway)

        await harness.model.windowAppeared()

        #expect(!harness.model.drawsCuesPane)
        #expect(!gateway.calls.contains(.v2(.cuesStatus)))
    }

    @Test("a daemon whose cues.status fails draws no pane, and a restored Cues selection goes back to the first pane")
    func noPaneWhenTheStatusFails() async throws {
        let gateway = try Self.gateway()
        gateway.v2Failures[.cuesStatus] = try ManagementRefusal.published("internal_error")
        let harness = try SettingsHarness(gateway: gateway, store: FakeSettingsPaneStore(lastSettingsPane: "cues"))
        #expect(harness.model.selectedPane == .cues)

        await harness.model.windowAppeared()

        #expect(!harness.model.drawsCuesPane)
        #expect(harness.model.selectedPane == .providers)
    }

    @Test("the pane reads its three lists and the proposals waiting at once, each on its own")
    func paneReadsItsLists() async throws {
        let gateway = try Self.gateway()
        gateway.v2Failures[.cuesWatchersList] = try ManagementRefusal.published("unavailable_cues_memory_off")
        let held = AsyncGate()
        gateway.cueSourcesGate = { await held.wait() }
        let harness = try SettingsHarness(gateway: gateway)

        let refresh = Task { await harness.model.refreshCues() }
        let others: [FakeDaemonGateway.Call] = [.v2(.cuesWatchersList), .v2(.cuesMandatesList), .v2(.cuesProposalsList)]
        let askedAtOnce = await yieldUntil { others.allSatisfy(gateway.calls.contains) }
        held.release()
        await refresh.value

        #expect(askedAtOnce, "the other reads go out while the sources list is still being read")
        #expect(!gateway.calls.contains(.v2(.cuesStatus)), "the status is the window's gate read, not the pane's")
        #expect(harness.model.cueSources.value?.sources.count == 3)
        #expect(harness.model.cueMandates.value?.mandates.count == 1)
        #expect(harness.model.cueProposals.value?.waiting == 1)
        #expect(gateway.cueProposalFilters == [.waiting])
        guard case .unavailable(let sentence) = harness.model.cueWatchers else {
            Issue.record("a refused list keeps the daemon's sentence")
            return
        }
        #expect(sentence == "Cues keep their records in memory, which is off.")
    }

    @Test("after a restart the Cues pane on screen reads its lists again")
    func restartRereadsTheLists() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway, store: FakeSettingsPaneStore(lastSettingsPane: "cues"))
        await harness.model.windowAppeared()
        let before = gateway.calls.filter { $0 == .v2(.cuesSourcesList) }.count

        await harness.model.restartCompleted()

        #expect(harness.model.selectedPane == .cues)
        #expect(gateway.calls.filter { $0 == .v2(.cuesSourcesList) }.count == before + 1)
        #expect(harness.model.cueSources.value?.sources.count == 3)
    }

    @Test("opening on Cues reads cues.status once: the window's gate read is the one the pane draws")
    func statusReadOncePerEntry() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway, store: FakeSettingsPaneStore(lastSettingsPane: "cues"))
        let statusReads = { gateway.calls.filter { $0 == .v2(.cuesStatus) }.count }

        // The window's entry, then the pane's own task as it appears.
        await harness.model.windowAppeared()
        await harness.model.refreshCues()
        #expect(statusReads() == 1)
        #expect(harness.model.cueStatus.value?.statusSentence == "Cues are running.")

        await harness.model.restartCompleted()
        #expect(statusReads() == 2, "a restart reads the status again, once")

        _ = await harness.model.setCueSourceEnabled(false, ref: "eng-blogs")
        #expect(statusReads() == 3, "a write reads the status again")
    }

    // MARK: - What the pane lays out (simpler setup §4)

    @Test("the first-run card stands only for a list of sources that is loaded and empty")
    func firstRunOnlyForALoadedEmptyList() async throws {
        let golden: ManagementCueSourceList = try Self.golden("cues_sources_list")
        let empty = ManagementCueSourceList(sources: [], canAdd: true, limits: golden.limits)

        #expect(CuesPaneLayout.firstRun(.loaded(empty)))
        #expect(!CuesPaneLayout.firstRun(.loaded(golden)))
        #expect(!CuesPaneLayout.firstRun(.unread))
        #expect(!CuesPaneLayout.firstRun(.loading))
        #expect(!CuesPaneLayout.firstRun(.unavailable("The daemon is not answering.")))

        let gateway = try Self.gateway()
        gateway.cueSourcesResult = empty
        let harness = try SettingsHarness(gateway: gateway)
        await harness.model.refreshCues()
        #expect(CuesPaneLayout.firstRun(harness.model.cueSources))
    }

    @Test("watchers show once a source or a watcher exists, and mandates once a watcher or a mandate exists")
    func listsShowOnceTheyMean() throws {
        let sources: ManagementCueSourceList = try Self.golden("cues_sources_list")
        let noSources = ManagementCueSourceList(sources: [], canAdd: true, limits: sources.limits)
        let watchers: ManagementCueWatcherList = try Self.golden("cues_watchers_list")
        let noWatchers = try Self.noWatchers()
        let mandates: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        let noMandates = ManagementCueMandateList(mandates: [], canAdd: true, limits: mandates.limits)
        let refused = SettingsReadState<ManagementCueWatcherList>.unavailable("Cues keep their records in memory, which is off.")

        #expect(!CuesPaneLayout.drawsWatchers(sources: .loaded(noSources), watchers: .loaded(noWatchers)))
        #expect(!CuesPaneLayout.drawsWatchers(sources: .loading, watchers: .loading))
        #expect(CuesPaneLayout.drawsWatchers(sources: .loaded(sources), watchers: .loaded(noWatchers)))
        #expect(CuesPaneLayout.drawsWatchers(sources: .loaded(noSources), watchers: .loaded(watchers)))
        #expect(CuesPaneLayout.drawsWatchers(sources: .loaded(sources), watchers: refused), "a refused list says so once a source exists")

        #expect(!CuesPaneLayout.drawsMandates(watchers: .loaded(noWatchers), mandates: .loaded(noMandates)))
        #expect(!CuesPaneLayout.drawsMandates(watchers: refused, mandates: .loaded(noMandates)))
        #expect(CuesPaneLayout.drawsMandates(watchers: .loaded(watchers), mandates: .loaded(noMandates)))
        #expect(CuesPaneLayout.drawsMandates(watchers: .loaded(noWatchers), mandates: .loaded(mandates)))
    }

    @Test("the top block is the section as published, and how watchers judge items heads the Screen where there is one, the filter model where not")
    func judgingHeadingOverTheScreen() throws {
        let older = try Self.cueSettingRows(withScreen: false)
        #expect(CuesPaneKeys.judgingHeadingKey(in: older) == "filter_provider")

        let newer = try Self.cueSettingRows(withScreen: true)
        #expect(CuesPaneKeys.judgingHeadingKey(in: newer) == "cues_screen_provider")
        let top = DescriptorRowFold(newer)
        #expect(
            top.open.map(\.key) == ["cues_enabled", "cues_mandates_enabled", "cues_screen_provider", "filter_provider", "filter_model"],
            "Let watchers act follows Run cues, and the Screen is drawn where and as the section publishes it"
        )
        #expect(top.folded.map(\.key) == ["cues_door_port"], "the door's port stays under Advanced")
    }

    @Test("a wire method_not_found that names the version it requires is the newer-engine state")
    func methodNotFoundRequiringIsTheNewerEngineState() throws {
        let requiring = try ManagementRefusal.published("method_requires_newer_engine")
        let plain = try ManagementRefusal.published("method_not_found")

        #expect(ManagementMessage.requiresNewerEngine(requiring))
        #expect(SettingsReadState<ManagementCueStatus>.failure(requiring) == .requiresNewerEngine)
        #expect(!ManagementMessage.requiresNewerEngine(plain), "a method this daemon lacks is no restart away")
    }

    // MARK: - What the rows say

    @Test("a source waiting for its secret opens its detail at that secret, every other at the top")
    func sourceRowsOpenTheirDetail() throws {
        let list: ManagementCueSourceList = try Self.golden("cues_sources_list")
        #expect(list.sources.map(CuesSheetPage.opening) == [
            .source("eng-blogs", at: nil), .source("gh-hooks", at: nil), .source("home-alerts", at: nil)
        ])

        let waiting = try Self.waitingWebhook()
        #expect(CuesSheetPage.opening(waiting) == .source("gh-hooks", at: .secret))
        #expect(CueSourceProjection.secrets(waiting, first: .pathSecret).map(\.field) == [.pathSecret, .secret])

        let tokenless = try Self.source(editing: { row in
            row["ref"] = "home-alerts"
            row["kind"] = "local_push"
            row["state"] = "needs_secret"
            row["primary_action"] = "new_token"
            row["actions"] = ["disable", "new_token"]
            row["missing_secret"] = "token"
        })
        #expect(CuesSheetPage.opening(tokenless) == .source("home-alerts", at: .token), "only New token mints one")
    }

    @Test("a source row draws a symbol by kind, labelled by the kind, and a switch where one is published")
    func sourceRowProjection() throws {
        #expect(CueSourceProjection.symbol(for: .feed) == "newspaper")
        #expect(CueSourceProjection.symbol(for: .stream) == "antenna.radiowaves.left.and.right")
        #expect(CueSourceProjection.symbol(for: .webhook) == "link")
        #expect(CueSourceProjection.symbol(for: .localPush) == "terminal")

        let list: ManagementCueSourceList = try Self.golden("cues_sources_list")
        #expect(list.sources.allSatisfy(CueSourceProjection.switchShown))
        #expect(CueSourceDetailWords.lastDay(list.sources[0].counts) == "3 received · 3 reached a watcher")

        // GitHub's and X's own marks by preset, as the plugin rows draw them;
        // every other source keeps its kind's symbol.
        #expect(list.sources.map(\.preset) == ["rss", "github", nil])
        #expect(list.sources.map { CueSourceProjection.mark(for: $0) } == [nil, VendorMarks.mark(.plugin, "github"), nil])
        let accounts = try Self.source(editing: { $0["preset"] = "x_accounts" })
        #expect(CueSourceProjection.mark(for: accounts) == VendorMarks.mark(.plugin, "x"))
        #expect(CueSourceDetailWords.lines([]) == "None")
    }

    @Test("a watcher row and page say the daemon's counts and the owner's words, nothing a watcher read")
    func watcherProjection() throws {
        let detail: ManagementCueWatcherAnswer = try Self.golden("cues_watchers_get")
        let watcher = detail.watcher.row

        #expect(CueWatcherDetailWords.filter(watcher) == "Your main model")
        #expect(CueWatcherDetailWords.task(watcher) == "Release watch · keeps no notes")
        #expect(CueWatcherDetailWords.dailyLimit(watcher) == "None")
        #expect(CueWatcherDetailWords.lastDay(watcher.counts) == "3 offered · 0 waiting · 3 passed · 0 dropped · 1 acted · 0 failed")
        #expect(CueWatcherDetailWords.listenFor(detail.watcher.listenFor) == "release, outage, security advisory, CVE")
        #expect(CueWatcherDetailWords.examples(detail.watcher.examples) == "1 marked useful · 0 marked not useful")
        #expect(CueWatcherDetailWords.instruction(detail.watcher.instructions[0]) == "1. Ignore opinion pieces and tutorials.")
    }

    @Test("a mandate row names its mode in the app's words and offers Approve only where the daemon leads with it")
    func mandateProjection() throws {
        let approved: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        let mandate = try #require(approved.mandates.first)
        #expect(CueMandateProjection.tag(mandate) == CueTagModel(text: "Ask me first", tone: .neutral))
        let auto = try Self.mandate(editing: { $0["mode"] = "auto" })
        #expect(CueMandateProjection.tag(auto) == CueTagModel(text: "Act without asking", tone: .warn), "acting unasked stands out")
        #expect(!CueMandateProjection.offersApprove(mandate))
        #expect(CueMandateProjection.switchShown(mandate))
        #expect(CueMandateDetailWords.waits(mandate) == "30 minutes, then the proposal expires")
        #expect(CueMandateDetailWords.actsOn(mandate) == "items at most 15 minutes old")
        #expect(CueMandateDetailWords.lastDay(mandate.counts) == "0 allowed · 1 proposed · 0 refused")

        let added: ManagementCueMandateAnswer = try Self.golden("cues_mandates_add")
        #expect(CueMandateProjection.offersApprove(added.mandate))
        #expect(CueMandateDetailWords.approval(added.mandate) == "Not approved yet.")

        let inactive = try Self.mandate(editing: { row in
            row["load"] = ["state": "inactive", "sentence": "Its task no longer exists."]
            row["primary_action"] = nil
            row["actions"] = ["disable"]
        })
        #expect(CueMandateDetailWords.approval(inactive) == "Its task no longer exists.", "the load sentence stands where Approval would")
        #expect(!CueMandateProjection.offersApprove(inactive))
    }

    @Test("a row's dot follows what the daemon publishes: a failure is red, a gap amber, off quiet, the rest well")
    func rowTones() throws {
        let sources: ManagementCueSourceList = try Self.golden("cues_sources_list")
        #expect(sources.sources.map(CueTone.source) == [.pass, .pass, .pass])
        #expect(CueTone.source(try Self.waitingWebhook()) == .warn, "a source waiting for its secret")
        #expect(CueTone.source(try Self.source(editing: { $0["state"] = "auth_failed" })) == .fail)
        let off = try Self.source(editing: { row in
            row["enabled"] = false
            row["state"] = "off"
            row["actions"] = ["enable"]
            row["primary_action"] = "enable"
        })
        #expect(CueTone.source(off) == .neutral, "a source switched off is quiet, whatever it leads with")

        let watchers: ManagementCueWatcherList = try Self.golden("cues_watchers_list")
        let watcher = try #require(watchers.watchers.first)
        #expect(CueTone.watcher(watcher) == .pass)

        let mandates: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        #expect(CueTone.mandate(try #require(mandates.mandates.first)) == .pass)
        let added: ManagementCueMandateAnswer = try Self.golden("cues_mandates_add")
        #expect(CueTone.mandate(added.mandate) == .warn, "a mandate waiting for its approval")
        let unloaded = try Self.mandate(editing: { $0["load"] = ["state": "inactive", "sentence": "Its task no longer exists."] })
        #expect(CueTone.mandate(unloaded) == .warn)

        let status: ManagementCueStatus = try Self.golden("cues_status")
        #expect(CueTone.status(status) == .pass)
        #expect(CueTone.door(status.door) == .neutral, "a door with nothing to take is quiet")
        #expect(CueTone.status(try Self.status(editing: { $0["state"] = "needs_restart" })) == .warn)
    }

    @Test("a list row's time is short: the time today, the day this year, the year only beyond it")
    func shortTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parse = ISO8601DateFormatter()
        let now = try #require(parse.date(from: "2026-10-17T09:00:00Z"))
        let today = try #require(parse.date(from: "2026-10-17T08:20:00Z"))
        let earlier = try #require(parse.date(from: "2026-10-12T08:20:00Z"))
        let lastYear = try #require(parse.date(from: "2025-12-30T08:20:00Z"))

        #expect(!CueTimes.time(today, now: now, calendar: calendar).contains("Oct"), "today is the time alone")
        #expect(CueTimes.time(earlier, now: now, calendar: calendar).contains("Oct 12"))
        #expect(!CueTimes.time(earlier, now: now, calendar: calendar).contains("2026"), "this year is not said")
        #expect(CueTimes.time(lastYear, now: now, calendar: calendar).contains("2025"))
    }

    @Test("Learn more opens the cues guide, and says so where the browser does not open")
    func guideOpens() throws {
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: FakeDaemonGateway(), opener: opener)

        #expect(model.openCuesGuide() == nil)
        #expect(opener.urls == [try #require(URL(string: "https://fermix.ai/docs/cues/"))])

        let refusing = SettingsFixture.model(gateway: FakeDaemonGateway(), opener: RecordingExternalOpener(succeeds: false))
        #expect(refusing.openCuesGuide() == ProductStrings[.cuesGuideOpenFailed])
    }

    @Test("the approval row is the daemon's own words, never a line composed here")
    func approvalIsTheDaemons() throws {
        let approved: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        let mandate = try #require(approved.mandates.first)
        #expect(mandate.approval.approvedAt != nil && mandate.approval.detail == nil)
        #expect(CueMandateDetailWords.approval(mandate) == "Approved. Each call asks you first.")

        let detailed = try Self.mandate(editing: { row in
            var approval = row["approval"] as? [String: Any] ?? [:]
            approval["detail"] = "Turned off after its skill changed."
            row["approval"] = approval
        })
        #expect(CueMandateDetailWords.approval(detailed) == "Turned off after its skill changed.")
    }

    /// Every filtering watcher uses the one Cues filter model: the row names
    /// it where the owner chose one, and the main model where not.
    @Test("a watcher's Filter row names the Cues filter model in use, the main model, or no filter")
    func filterNamesTheModelInUse() throws {
        let chosen = try Self.watcher(editing: { $0["filter_model"] = ["provider": "anthropic", "model": "claude-haiku-5-5"] })
        #expect(CueWatcherDetailWords.filter(chosen) == "claude-haiku-5-5")

        let passing = try Self.watcher(editing: { $0["filter"] = "none" })
        #expect(CueWatcherDetailWords.filter(passing) == "No filter")
    }

    /// Saved before words to listen for were required, a watcher gets nothing
    /// until it is changed in chat, and its row asks for that as a held one
    /// does, in the daemon's sentence.
    @Test("a watcher that needs an update in chat is drawn for attention with the daemon's sentence")
    func needsUpdateDrawsAttention() throws {
        let sentence = "Needs words to listen for: update it in chat."
        let watcher = try Self.watcher(editing: { row in
            row["state"] = "needs_update"
            row["status_sentence"] = sentence
        })

        #expect(watcher.state == .needsUpdate)
        #expect(watcher.state.drawsAttention)
        #expect(CueTone.watcher(watcher) == .warn)
        #expect(watcher.statusSentence == sentence)
    }

    @Test("a watcher filter kind this build does not know draws no Filter row")
    func unknownFilterDrawsNothing() throws {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == "cues_watchers_list" })
        let result = try #require(try fixture.object("response")["result"] as? [String: Any])
        var row = try #require((result["watchers"] as? [[String: Any]])?.first)
        row["filter"] = "regex"
        let watcher = try JSONDecoder().decode(ManagementCueWatcher.self, from: try JSONSerialization.data(withJSONObject: row))

        #expect(watcher.filter == .unrecognized("regex"))
        #expect(CueWatcherDetailWords.filter(watcher) == nil)
    }

    // MARK: - The add form

    @Test("the sheet opens on the daemon's choices, featured first and the rest under Something else")
    func sheetOpensOnTheChoices() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        var form = CueSourceFormState()
        #expect(form.choices == nil && form.request == ManagementCueFormRequest(), "the first ask names no choice")

        form.take(golden, answering: form.request)
        #expect(form.featuredChoices.map(\.label) == ["Website or blog", "X accounts", "GitHub", "Your scripts"])
        #expect(form.otherChoices.map(\.label) == ["Any feed address", "Live stream", "Any webhook"])
        #expect(form.choice == nil && form.rows.isEmpty, "no field shows before a choice is made")
        #expect(form.spec == nil)

        #expect(CueChoiceProjection.mark(for: try Self.choice("x_accounts", in: form)) != nil, "X's own mark")
        #expect(CueChoiceProjection.mark(for: try Self.choice("github", in: form)) != nil, "GitHub's own mark")
        #expect(CueChoiceProjection.mark(for: try Self.choice("rss", in: form)) == nil)
        #expect(CueChoiceProjection.symbol(for: try Self.choice("rss", in: form)) == "newspaper", "the rest are drawn by kind")
        #expect(CueChoiceProjection.symbol(for: try Self.choice("local_push", in: form)) == "terminal")
    }

    @Test("a choice asks for its own form, by its preset or its kind, and a check changed asks again")
    func aChoiceAsksItsForm() throws {
        var form = try Self.answeredChoices()

        form.choose(try Self.choice("rss", in: form))
        #expect(form.request == ManagementCueFormRequest(preset: "rss"))
        form.choose(try Self.choice("local_push", in: form))
        #expect(form.request == ManagementCueFormRequest(kind: "local_push"))
        form.choose(try Self.choice("stream", in: form))
        #expect(form.request == ManagementCueFormRequest(kind: "stream"))

        form.choose(try Self.choice("github", in: form))
        form.set(.text("standard_webhooks"), for: "verify")
        #expect(form.request == ManagementCueFormRequest(preset: "github", verify: "standard_webhooks"))
    }

    @Test("Back keeps nothing of the choice it leaves, and the next choice starts empty")
    func backKeepsNothing() throws {
        var form = try Self.answeredChoices()
        let choices = form.choices
        form.choose(try Self.choice("stream", in: form))
        form.take(try Self.golden("cues_sources_form_stream"), answering: form.request)
        form.set(.text("market-wire"), for: "ref")
        form.secrets["key"] = "fixture-key"
        form.refusal = CueRefusal(sentence: "That name is taken.", field: "ref")

        form.backToChoices()
        #expect(form.choice == nil)
        #expect(form.rows.isEmpty && form.values.isEmpty && form.secrets.isEmpty && form.refusal == nil)
        #expect(form.requirement == nil && form.notes.isEmpty && form.consent == nil)
        #expect(form.choices == choices, "the list stays, so step one draws at once")

        form.choose(try Self.choice("x_accounts", in: form))
        #expect(form.values.isEmpty && form.secrets.isEmpty, "nothing of the stream reaches X accounts")
        #expect(form.request == ManagementCueFormRequest(preset: "x_accounts"))
    }

    @Test("the name is optional: Add is ready once the form answers, and an empty name is not sent")
    func nameIsOptional() throws {
        var form = try Self.answeredChoices()
        form.choose(try Self.choice("github", in: form))
        #expect(form.spec == nil, "nothing to add before the form answers")

        form.take(try Self.golden("cues_sources_form"), answering: form.request)
        let unnamed = try #require(form.spec)
        #expect(unnamed.ref == nil, "Fermix names a source left unnamed")
        #expect(unnamed.preset == "github" && unnamed.kind == nil)
        #expect(unnamed.values.isEmpty)

        form.set(.text("   "), for: "ref")
        #expect(form.spec?.ref == nil, "a blank name is not a name")
        form.set(.text("gh-hooks"), for: "ref")
        #expect(form.spec?.ref == "gh-hooks")
        #expect(form.spec?.values.isEmpty == true, "the name travels as the ref, never among the values")
    }

    @Test("a refusal's field marks the form field it names, and anything else is said under the form")
    func refusalMarksItsField() throws {
        var form = try Self.githubForm(try Self.golden("cues_sources_form"))

        form.refusal = CueRefusal(sentence: "That name is taken.", field: "ref")
        #expect(form.refusal(for: "ref") == "That name is taken.")
        #expect(form.refusal(for: "header") == nil)
        #expect(form.formRefusal == nil)

        form.set(.text("gh-hooks"), for: "ref")
        #expect(form.refusal == nil, "a refusal goes with the value it was about")

        form.refusal = CueRefusal(sentence: "Something else.", field: "url")
        #expect(form.formRefusal == "Something else.", "a field this form does not draw is said under it")
        form.refusal = CueRefusal(sentence: "Unknown preset.", field: "preset")
        #expect(form.formRefusal == "Unknown preset.", "with no kind control, a preset refusal is said under the form")
        form.refusal = CueRefusal(sentence: "No field.", field: nil)
        #expect(form.formRefusal == "No field.")
    }

    @Test("Add sends the choice's preset and only the values changed, and never a secret")
    func addSendsWhatChanged() throws {
        var form = try Self.githubForm(try Self.golden("cues_sources_form"))
        form.set(.text("gh-hooks"), for: "ref")
        form.set(.text("X-Hub-Signature-256"), for: "header")
        form.set(.text("X-Signature"), for: "type_header")

        let spec = try #require(form.spec)
        #expect(spec.ref == "gh-hooks")
        #expect(spec.preset == "github" && spec.kind == nil)
        #expect(spec.values == ["type_header": .setting(.text("X-Signature"))], "an unchanged default is not sent")
        #expect(form.typedSecrets.isEmpty, "GitHub's form asks for no secret")
    }

    @Test("a typed value for a secret this app cannot store is refused under its row, and Add sends nothing")
    func unstorableSecretIsRefused() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form_stream")
        var form = try Self.streamForm(try Self.form(golden, renamingSecretTo: "passphrase"))
        form.secrets["passphrase"] = "fixture-passphrase"

        let refused = form.prepareAdd()
        #expect(refused == nil, "nothing is added while a typed secret would be dropped")
        #expect(form.refusal == CueRefusal(sentence: ProductStrings[.cuesSourceSecretUnstorable], field: "passphrase"))
        #expect(form.refusal(for: "passphrase") == ProductStrings[.cuesSourceSecretUnstorable])
        #expect(ProductStrings[.cuesSourceSecretUnstorable] == "This version of the app cannot store this secret; update the app.")

        var known = try Self.streamForm(golden)
        known.secrets["secret"] = "fixture-secret"
        let preparing = known.prepareAdd()
        let prepared = try #require(preparing)
        #expect(prepared.secrets == [CueTypedSecret(field: .secret, value: "fixture-secret")])
        #expect(known.refusal == nil)
    }

    // A stream is the general WebSocket source: its field rows explain
    // themselves behind info and show a sample value while empty, its two
    // secrets come straight after the address, and each is stored under its
    // own row key once the source exists.
    @Test("a stream's form shows each field's example, asks for its secrets after the address and stores them key first")
    func webSocketStreamForm() throws {
        var form = try Self.streamForm(try Self.golden("cues_sources_form_stream"))
        #expect(form.request == ManagementCueFormRequest(kind: "stream"))

        #expect(form.rows.allSatisfy { $0.footer == nil })
        #expect(form.rows.contains { $0.key == "url" && $0.info?.isEmpty == false })
        #expect(Array(form.rows.map(\.key).prefix(4)) == ["ref", "url", "key", "secret"])
        #expect(form.rows.filter { $0.kind == .secret }.map(\.key) == ["key", "secret"])
        #expect(DescriptorRowFold(form.rows).open.map(\.key) == ["url", "key", "secret", "subscribe_message", "id_path"])

        let url = try #require(form.rows.first { $0.key == "url" })
        #expect(DescriptorRowModel(row: url, value: form.value(of: url)).control == .text(value: "", prompt: "wss://news.example.com/stream"))
        let kept = try #require(form.rows.first { $0.key == "item_types" })
        #expect(DescriptorRowModel(row: kept, value: form.value(of: kept)).control == .list(items: [], prompt: "news"))
        #expect(form.rows.filter { $0.kind == .secret || $0.kind == .number }.allSatisfy { $0.example == nil })

        form.secrets["key"] = "fixture-key"
        form.secrets["secret"] = "fixture-secret"
        let preparing = form.prepareAdd()
        let prepared = try #require(preparing)
        #expect(prepared.spec.kind == "stream" && prepared.spec.preset == nil && prepared.spec.ref == nil)
        #expect(prepared.secrets == [
            CueTypedSecret(field: .key, value: "fixture-key"),
            CueTypedSecret(field: .secret, value: "fixture-secret")
        ])
    }

    @Test("what adding a source means and the daemon's notes are one explanation behind the choice's info")
    func formAboutJoinsConsentAndNotes() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        #expect(CueSourceFormState().about == nil, "nothing to explain before the daemon answers")

        let form = try Self.githubForm(golden)
        let about = try #require(form.about)
        #expect(about.hasPrefix(golden.consentSentence), "the consent line leads")
        #expect(!golden.notes.isEmpty)
        for note in golden.notes { #expect(about.contains(note)) }
    }

    @Test("an answer to a request the sheet has moved past draws no rows, so one choice's fields never show under another")
    func staleAnswerDrawsNoRows() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        var form = try Self.answeredChoices()

        form.choose(try Self.choice("github", in: form))
        let asked = form.request
        form.backToChoices()
        form.choose(try Self.choice("rss", in: form))
        form.take(golden, answering: asked)
        #expect(form.rows.isEmpty, "an answer for GitHub is not drawn under Website or blog")

        form.backToChoices()
        form.choose(try Self.choice("github", in: form))
        form.take(golden, answering: form.request)
        #expect(form.rows.first?.key == "ref", "the answer for the current choice draws its rows")
    }

    // MARK: - X accounts (simpler setup D4)

    @Test("the X accounts form says whether X is signed in, and offers the plugin's page only while it asks for a sign-in")
    func xAccountsRequirement() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form_x_accounts")
        var form = try Self.answeredChoices()
        form.choose(try Self.choice("x_accounts", in: form))
        form.take(golden, answering: form.request)

        let needs = try #require(form.requirement)
        #expect(needs.state == .needsSignIn && needs.plugin == "x")
        #expect(needs.sentence == "Connect X to read these accounts.")
        #expect(CueRequirementProjection.offersPlugin(needs))
        #expect(CueTone.requirement(needs) == .warn)
        #expect(DescriptorRowFold(form.rows).open.map(\.key) == ["handles"], "only the accounts are asked in the open")
        #expect(form.spec != nil, "a sign-in still owed never stops the add")

        let ready = try Self.requirement(state: "ready", sentence: "Signed in to X.")
        #expect(!CueRequirementProjection.offersPlugin(ready))
        #expect(CueTone.requirement(ready) == .pass)
        let unknown = try Self.requirement(state: "needs_payment", sentence: "Something else.")
        #expect(!CueRequirementProjection.offersPlugin(unknown), "a state this build does not know offers no button")
    }

    @Test("the plugin a requirement names opens on Integrations, once, where the catalogue lists it")
    func requirementOpensThePluginPage() async throws {
        let harness = try SettingsHarness(gateway: try Self.gateway())

        harness.model.showPluginPage("notion")
        #expect(harness.model.selectedPane == .integrations)
        #expect(harness.model.takeAskedPluginPage() == nil, "nothing opens before the catalogue is read")

        await harness.model.refreshPlugins()
        #expect(harness.model.takeAskedPluginPage()?.name == "notion")
        #expect(harness.model.takeAskedPluginPage() == nil, "it opens once")

        harness.model.showPluginPage("x")
        #expect(harness.model.takeAskedPluginPage() == nil, "a plugin the catalogue does not list leaves the pane as it is")
        #expect(harness.model.askedPluginPage == nil)
    }

    @Test("a form request superseded while it rests asks nothing, and one that rests asks once")
    func formRequestRests() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        let request = ManagementCueFormRequest(preset: "github")

        let superseded = Task { await harness.model.cueSourceForm(request, pause: CuesSheetMetrics.formPause) }
        superseded.cancel()
        #expect(await superseded.value == nil)
        #expect(gateway.cueFormRequests.isEmpty)

        let answer = await harness.model.cueSourceForm(request, pause: CuesSheetMetrics.formPause)
        #expect(answer == .success(try Self.golden("cues_sources_form")))
        #expect(gateway.cueFormRequests == [request])
    }

    @Test("the sheet's first asks go at once, and a change once its fields show rests first")
    func firstFormAskDoesNotWait() async throws {
        let gateway = try Self.gateway()
        let sleeper = RecordingSleeper()
        let model = SettingsFixture.model(gateway: gateway, sleeper: sleeper)
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")

        let opening = CueSourceFormState()
        #expect(opening.askPause == 0)
        _ = await model.cueSourceForm(opening.request, pause: opening.askPause)
        #expect(sleeper.sleeps.isEmpty, "opening the sheet asks at once, so it opens on its fields")

        let shown = try Self.githubForm(golden)
        #expect(shown.askPause == CuesSheetMetrics.formPause, "a check changed on GitHub's fields rests first")
        _ = await model.cueSourceForm(shown.request, pause: shown.askPause)
        #expect(sleeper.sleeps == [CuesSheetMetrics.formPause], "a change once the fields show rests first")
        #expect(gateway.cueFormRequests == [opening.request, shown.request])
    }

    @Test("the add calls cues.sources.add, then one secret.set per typed secret under the name it answered, then reads the list")
    func addThenStore() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        let spec = ManagementCueSourceSpec(ref: nil, choice: .kind("webhook"), values: [:])

        let outcome = await harness.model.addCueSource(
            spec,
            secrets: [CueTypedSecret(field: .secret, value: "fixture-signing-secret")]
        )

        let added: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        #expect(outcome == .added(ref: "github", token: nil, secret: added.secret, unstored: nil))
        #expect(gateway.cueSpecs == [spec])
        #expect(gateway.storedSecrets.map(\.id) == ["cue_source:github:secret"], "stored under the name in force, never the one sent")
        let order = gateway.calls.filter { [.v2(.cuesSourcesAdd), .v2(.secretSet), .v2(.cuesSourcesList)].contains($0) }
        #expect(Array(order.prefix(2)) == [.v2(.cuesSourcesAdd), .v2(.secretSet)])
        #expect(order.contains(.v2(.cuesSourcesList)))
        #expect(gateway.calls.contains(.v2(.cuesSourcesGet)), "a stored secret reads the source's detail again")
    }

    @Test("a secret.set that fails leaves the source as the daemon reports it, with the refusal under its field")
    func failedStoreLeavesTheRow() async throws {
        let gateway = try Self.gateway()
        gateway.v2Failures[.secretSet] = try ManagementRefusal.published("invalid_params_cue_source_token")
        let harness = try SettingsHarness(gateway: gateway)
        let spec = ManagementCueSourceSpec(ref: "gh-hooks", choice: .kind("webhook"), values: [:])

        let outcome = await harness.model.addCueSource(
            spec,
            secrets: [CueTypedSecret(field: .secret, value: "fixture-signing-secret")]
        )

        guard case .added(let ref, nil, _, let unstored?) = outcome else {
            Issue.record("the source exists and its secret is unstored: \(outcome)")
            return
        }
        #expect(ref == "github", "the name the daemon answered")
        #expect(unstored.field == "secret")
        #expect(!unstored.sentence.isEmpty)
        #expect(gateway.calls.last { $0 == .v2(.cuesSourcesList) } != nil, "the list is read again, as the daemon reports it")
        #expect(harness.model.cueSources.value == (try Self.golden("cues_sources_list") as ManagementCueSourceList))

        var sheet = CuesSheetState(page: .addSource)
        sheet.added(outcome)
        #expect(sheet.page == .source("github", at: .secret))
        #expect(sheet.unstored == unstored)
    }

    @Test("a refused add names its field, and no secret is stored")
    func refusedAddStoresNothing() async throws {
        let gateway = try Self.gateway()
        gateway.v2Failures[.cuesSourcesAdd] = try ManagementRefusal.published("invalid_params_cues_unknown_source")
        let harness = try SettingsHarness(gateway: gateway)

        let outcome = await harness.model.addCueSource(
            ManagementCueSourceSpec(ref: "home-alerts", choice: .kind("local_push"), values: [:]),
            secrets: []
        )

        #expect(outcome == .refused(CueRefusal(sentence: "There is no source named home-alerts.", field: "ref")))
        #expect(gateway.storedSecrets.isEmpty)
    }

    @Test("adding a webhook turns the sheet to its page, where its address is one Copy URL away")
    func addedWebhookOffersItsAddress() throws {
        let added: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        var sheet = CuesSheetState(page: .addSource)

        sheet.added(.added(ref: added.source.ref, token: nil, secret: nil, unstored: nil))

        #expect(sheet.page == .source("github", at: nil), "the name Fermix made for it")
        #expect(!added.source.hasURL, "no address is made by the add itself")
        #expect(added.source.secrets.contains { $0.field == .pathSecret }, "the page draws the address row")
        #expect(added.source.actions.contains(.getURL), "and offers Copy URL on it at once")
    }

    // MARK: - The token

    @Test("a token handed out shows on its page once, and turning the page drops it")
    func tokenLeavesWithItsPage() async throws {
        let harness = try SettingsHarness(gateway: try Self.gateway())
        let outcome = await harness.model.addCueSource(
            ManagementCueSourceSpec(ref: "home-alerts", choice: .kind("local_push"), values: [:]),
            secrets: []
        )
        var sheet = CuesSheetState(page: .addSource)

        sheet.added(outcome)
        #expect(sheet.page == .source("home-alerts", at: nil))
        #expect(sheet.token?.ref == "home-alerts")
        #expect(sheet.token?.field == .token)
        #expect(sheet.token?.value.isEmpty == false)

        sheet.turn(to: .editSource("home-alerts"))
        #expect(sheet.token == nil, "the token leaves the view when the page changes")

        sheet.turn(to: .source("home-alerts", at: nil))
        #expect(sheet.token == nil, "and no page shows it again")
    }

    @Test("GitHub's made secret shows once on its page with the form's notes, is never stored by the app, and leaves when the page turns")
    func githubSecretLeavesWithItsPage() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        let form = try Self.githubForm(try Self.golden("cues_sources_form"))
        let prepared = try #require(form.spec)

        let outcome = await harness.model.addCueSource(prepared, secrets: form.typedSecrets)
        let made = try #require((try Self.golden("cues_sources_add_webhook") as ManagementCueSourceAdded).secret)
        #expect(outcome == .added(ref: "github", token: nil, secret: made, unstored: nil))
        #expect(gateway.storedSecrets.isEmpty, "Fermix stored the secret it made; the app writes it nowhere")

        var sheet = CuesSheetState(page: .addSource)
        sheet.added(outcome, notes: form.notes)
        #expect(sheet.page == .source("github", at: nil))
        #expect(sheet.token == CueHandedToken(ref: "github", field: .secret, value: made, notes: form.notes))
        #expect(form.notes.count == 4, "the tunnel note, then GitHub's three steps")
        #expect(form.notes.allSatisfy { !$0.contains("`") }, "plain text, drawn as it is")
        #expect(sheet.token?.notes.last == "Choose application/json as the content type.", "GitHub's own steps, in the daemon's words")

        sheet.turn(to: .editSource("github"))
        #expect(sheet.token == nil, "the secret leaves the view when the page changes")
        sheet.turn(to: .source("github", at: nil))
        #expect(sheet.token == nil, "and no page shows it again")
    }

    @Test("a copied secret is written for this Mac, and taken back once unless something was copied over it")
    func pasteboardRules() {
        let board = RecordingSecretPasteboard()
        var copied = CueSecretCopy()

        copied.copy("token-value", on: board.pasteboard)
        #expect(board.writes == ["token-value"])
        #expect(copied.changeCount == 1)

        copied.takeBack(on: board.pasteboard)
        #expect(board.withdrawals == [1])
        copied.takeBack(on: board.pasteboard)
        #expect(board.withdrawals == [1], "taken back once")
    }

    @Test("the token is never logged, never an accessibility value, and only Copy takes it off the page")
    func tokenStaysOutOfLogsAndValues() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false).filter {
            $0.path.contains("/Cues") || $0.path.hasSuffix("SettingsCues.swift") || $0.path.contains("ManagementCues")
        }
        #expect(files.count >= 7, "the scan found the cue files")

        for file in files {
            for line in file.text.split(separator: "\n") where line.contains("log.") || line.contains("print(") {
                #expect(!line.lowercased().contains("token"), "\(file.path) logs a token: \(line)")
                #expect(!line.lowercased().contains("secret"), "\(file.path) logs a secret: \(line)")
            }
        }

        let block = try #require(files.first { $0.path.hasSuffix("CuesSourceSheet.swift") })
        let body = try #require(block.text.components(separatedBy: "struct CueTokenBlock").last)
        #expect(body.contains(".accessibilityLabel(String(format: ProductStrings[accessibilityFormat], token.ref))"))
        #expect(!body.contains(".accessibilityValue("))
        #expect(body.contains("Clipboard") == false && body.contains("copied.copy(token.value, on: .system)"))
        #expect(body.contains(".onDisappear { copied.takeBack(on: .system) }"))
    }

    // MARK: - The default filter model

    @Test("a model is written with the provider in force, and clearing the provider clears the model")
    func filterPairTravelsTogether() throws {
        let rows: ManagementSettingsSectionRows = try Self.golden("settings_get_cues")

        #expect(
            CueFilterPair.completing(["filter_model": .text("claude-haiku-5-5")], in: "cues", rows: rows.rows)
                == ["filter_model": .text("claude-haiku-5-5"), "filter_provider": .text("anthropic")]
        )
        #expect(
            CueFilterPair.completing(["filter_provider": .text("")], in: "cues", rows: rows.rows)
                == ["filter_provider": .text(""), "filter_model": .text("")]
        )
        #expect(CueFilterPair.completing(["cues_enabled": .flag(false)], in: "cues", rows: rows.rows) == ["cues_enabled": .flag(false)])
        #expect(CueFilterPair.completing(["filter_model": .text("m")], in: "routing", rows: rows.rows) == ["filter_model": .text("m")])
    }

    @Test("the model row's write reaches the daemon as the pair in one apply")
    func filterModelWriteIsOneApply() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        await harness.model.loadSection("cues")

        await harness.model.apply(section: "cues", key: "filter_model", value: .text("claude-haiku-5-5"))
        await harness.model.applyFilterModel(provider: "openai", model: "gpt-fixture")

        #expect(gateway.appliedSettings == [
            SettingsWrite(section: "cues", values: ["filter_model": .text("claude-haiku-5-5"), "filter_provider": .text("anthropic")]),
            SettingsWrite(section: "cues", values: ["filter_model": .text("gpt-fixture"), "filter_provider": .text("openai")])
        ])
    }

    // MARK: - The secret family

    @Test("a cue source's secret id names its source and field, and only a typed field has one")
    func secretIds() {
        #expect(CueSecretId.id(ref: "gh-hooks", field: .secret) == "cue_source:gh-hooks:secret")
        #expect(CueSecretId.id(ref: "eng-blogs", field: .key) == "cue_source:eng-blogs:key")
        #expect(CueSecretId.ref(of: "cue_source:gh-hooks:secret") == "gh-hooks")
        #expect(CueSecretId.ref(of: "mcp:postgres/env/DATABASE_URI") == nil)
        #expect(CueSecretId.ref(of: "cue_source:") == nil)
        #expect(!ManagementCueSecretField.token.isTyped && !ManagementCueSecretField.pathSecret.isTyped)
    }

    // MARK: - The mandate form

    @Test("an add sends every field the form holds, options only where set")
    func mandateAddValues() throws {
        var form = CueMandateFormState()
        form.name = "release-issues"
        form.job = "release_watch_2"
        form.tools = ["github_create_issue", "github_search_issues"]
        form.waits = "30"
        form.actsOn = "15"

        let values = form.values(choices: try Self.golden("cues_mandates_choices"))

        #expect(values == [
            "approve_within_s": .setting(.number(1800)),
            "job": .setting(.text("release_watch_2")),
            "max_cue_age_s": .setting(.number(900)),
            "mode": .setting(.text("approve")),
            "read_tools": .setting(.list(["github_search_issues"])),
            "tools": .setting(.list(["github_create_issue"]))
        ])
        #expect(form.isComplete)
    }

    @Test("an edit sends only what changed, and a pinned argument keeps its own type until retyped")
    func mandateEditValues() throws {
        let list: ManagementCueMandateList = try Self.golden("cues_mandates_list")
        let choices: ManagementCueMandateChoices = try Self.golden("cues_mandates_choices")
        var form = CueMandateFormState(editing: try #require(list.mandates.first))
        #expect(form.values(choices: choices).isEmpty, "an edit that touched nothing sends nothing")

        form.waits = "60"
        form.pins = [CueMandateFormState.Pin(key: "repo", text: "ops")]
        #expect(form.values(choices: choices) == [
            "approve_within_s": .setting(.number(3600)),
            "pin_args": .pins([ManagementCuePin(key: "repo", value: .text("ops"))])
        ])

        let pinned = try Self.mandate(editing: { $0["pin_args"] = [["key": "limit", "value": 5]] })
        let kept = CueMandateFormState(editing: pinned)
        #expect(kept.pins.first?.text == "5")
        #expect(kept.values(choices: choices).isEmpty, "a number left as it was stays a number")
    }

    @Test("a mandate refusal names its field, and anything else is said under the form")
    func mandateRefusal() {
        var form = CueMandateFormState()
        form.refusal = CueRefusal(sentence: "There is no task named x.", field: "job")
        #expect(form.refusal(for: "job") == "There is no task named x.")
        #expect(form.formRefusal == nil)

        form.refusal = CueRefusal(sentence: "Elsewhere.", field: "ref")
        #expect(form.formRefusal == "Elsewhere.", "a mandate is never refused under a source field")
    }

    @Test("the mandate writes call their method and read the row back")
    func mandateWrites() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        await harness.model.refreshCueMandates()

        #expect(await harness.model.approveCueMandate("release-issues") == nil)
        #expect(await harness.model.setCueMandateEnabled(false, name: "release-issues") == nil)
        #expect(harness.model.cueMandate("release-issues")?.actions == [.enable, .approve], "the write's row replaces the list's")
        #expect(await harness.model.addCueMandate("release-issues", values: ["job": .setting(.text("release_watch_2"))]) == nil)

        let writes = gateway.calls.filter {
            [.v2(.cuesMandatesApprove), .v2(.cuesMandatesDisable), .v2(.cuesMandatesAdd)].contains($0)
        }
        #expect(writes == [.v2(.cuesMandatesApprove), .v2(.cuesMandatesDisable), .v2(.cuesMandatesAdd)])
        #expect(gateway.cueMandateWrites == [CueValuesWrite(name: "release-issues", values: ["job": .setting(.text("release_watch_2"))])])
    }

    @Test("Show in chat opens Chat at the proposal's card, Open chat with nothing written")
    func showChat() {
        let model = SettingsFixture.model(gateway: FakeDaemonGateway())
        var opened: [String?] = []
        model.openChat = { opened.append($0) }

        model.showChat(at: "cpr_9f2c41d07a5e6b38c1d2e4f0")
        model.showChat(at: nil)

        #expect(opened == ["cpr_9f2c41d07a5e6b38c1d2e4f0", nil])
    }

    // MARK: - Copy

    @Test("the pane's deck matches the design's copy table")
    func copyDeck() {
        #expect(ProductStrings[.settingsPaneCues] == "Cues")
        #expect(
            ProductStrings[.cuesSubtitle]
                == "Fermix can watch blogs, X accounts, GitHub and your scripts, and wake a task when something matters."
        )
        #expect(ProductStrings[.cuesFirstRunTitle] == "Nothing is watched yet")
        #expect(ProductStrings[.cuesFirstRunSource] == "Add something to watch: a blog, X accounts, GitHub or your scripts.")
        #expect(ProductStrings[.cuesFirstRunWatcher] == "In chat, tell Fermix what to look for. It makes a watcher.")
        #expect(ProductStrings[.cuesFirstRunTask] == "When something matches, your task runs, and asks you before it acts.")
        #expect(ProductStrings[.cuesFirstRunAdd] == "Add a source")
        #expect(ProductStrings[.cuesJudgingTitle] == "How watchers judge items")
        #expect(ProductStrings[.cuesSourceAddTitle] == "What should Fermix watch?")
        #expect(ProductStrings[.cuesSourceSomethingElse] == "Something else")
        #expect(ProductStrings[.cuesBack] == "Back")
        #expect(ProductStrings[.cuesSourceOpenPlugin] == "Open plugin")
        #expect(ProductStrings[.cuesSourceCopySecret] == "Copy secret")
        #expect(ProductStrings[.cuesSourceSecretAccessibilityFormat] == "Secret for %@, shown once")
        #expect(ProductStrings[.cuesWatcherListenFor] == "Keywords", "the engine calls a watcher's words keywords")
        #expect(ProductStrings[.cuesWaitingTitle] == "Waiting for you")
        #expect(ProductStrings[.cuesWaitingShowInChat] == "Show in chat")
        #expect(ProductStrings[.cuesLearnMore] == "Learn more")
        #expect(ProductStrings[.cuesSourceNewTokenConfirm] == "Make a new token for %@? The old one stops working within a minute.")
        #expect(ProductStrings[.cuesSourceTokenOnce] == "Copy it now. Fermix shows it only once.")
        #expect(ProductStrings[.cuesSourceRemoveConfirm] == "Remove %@? Its stored secrets are deleted.")
        #expect(ProductStrings[.cuesWatchersEmpty] == "No watchers yet. Ask Fermix in chat to watch for something.")
        #expect(ProductStrings[.cuesWatchersFooter] == "Watchers are made and changed in chat.")
        #expect(ProductStrings[.cuesMandatesEmpty] == "No mandates. Without one, a task only reports to you.")
        #expect(ProductStrings[.cuesMandateModeApprove] == "Ask me first")
        #expect(ProductStrings[.cuesMandateModeAuto] == "Act without asking")
        #expect(
            ProductStrings[.cuesMandateApproveConfirm]
                == "Approve %@ as it is now? A later change to its task, skill or validator turns it off until you approve it again."
        )
    }

    @Test("every cue string keeps the copy rules and names no command line")
    func copyRules() {
        let keys = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("cues.") || $0 == .settingsPaneCues || $0 == .settingsKeywordsCues }
        #expect(keys.count > 100)

        for key in keys {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
            #expect(!ProductCopyRules.namesACommandLine(ProductStrings[key]), "\(key.rawValue)")
        }
    }

    // MARK: - Fixtures

    @Test("the fixture home answers a cue source's secret under its own id, an add by kind or preset, and a waiting card")
    func fixtureHomeAnswersCues() async throws {
        let transport = try FixtureManagementTransport(machine: FixtureMachine(daemonUp: true), readiness: .gatingFailure)
        func ask(_ method: ManagementMethod, _ params: [String: Any]) async throws -> [String: Any]? {
            let payload = try JSONSerialization.data(withJSONObject: [
                "request_id": "req-fixture-1", "protocol_version": 2, "method": method.rawValue, "params": params
            ])
            let frame = try JSONSerialization.jsonObject(with: try await transport.exchange(payload, timeout: .seconds(1)))
            return (frame as? [String: Any])?["result"] as? [String: Any]
        }

        let stored = try await ask(.secretSet, ["id": "cue_source:gh-hooks:secret", "value": "fixture-signing-secret"])
        #expect(stored?["id"] as? String == "cue_source:gh-hooks:secret")
        let cleared = try await ask(.secretClear, ["id": "cue_source:gh-hooks:secret"])
        #expect(cleared?["present"] as? Bool == false)

        let push = try await ask(.cuesSourcesAdd, ["ref": "home-alerts", "kind": "local_push", "values": [String: Any]()])
        #expect(push?["token"] as? String != nil)
        let webhook = try await ask(.cuesSourcesAdd, ["preset": "github", "values": [String: Any]()])
        #expect((webhook?["source"] as? [String: Any])?["ref"] as? String == "github")
        #expect(webhook?["secret"] as? String != nil, "a GitHub source's made secret")

        let accounts = try await ask(.cuesSourcesForm, ["preset": "x_accounts"])
        #expect((accounts?["requirement"] as? [String: Any])?["state"] as? String == "needs_sign_in")
        let github = try await ask(.cuesSourcesForm, ["preset": "github"])
        #expect(github?["requirement"] is NSNull, "every other form answers its own golden")

        let card = try await ask(.cuesProposalsGet, ["proposal_id": "cpr_9f2c41d07a5e6b38c1d2e4f0"])
        #expect((card?["proposal"] as? [String: Any])?["state"] as? String == "waiting")
    }

    static func golden<Value: Decodable>(_ name: String) throws -> Value {
        try FakeDaemonGateway.fixtureResult(named: name, as: Value.self)
    }

    /// A gateway whose `hello` is the contract's own, which lists every cue
    /// method.
    static func gateway() throws -> FakeDaemonGateway {
        let gateway = try SettingsFixture.gateway()
        gateway.hello = try golden("hello")

        return gateway
    }

    /// The add form on step one, the daemon's choices drawn.
    static func answeredChoices() throws -> CueSourceFormState {
        var form = CueSourceFormState()
        form.take(try golden("cues_sources_form"), answering: form.request)
        return form
    }

    static func choice(_ id: String, in form: CueSourceFormState) throws -> ManagementCueSourceForm.Choice {
        try #require(form.choices?.first { $0.id == id })
    }

    /// The add form as the sheet has it once the golden form, GitHub's,
    /// answers the GitHub choice.
    static func githubForm(_ answer: ManagementCueSourceForm) throws -> CueSourceFormState {
        var form = try answeredChoices()
        form.choose(try choice("github", in: form))
        #expect(form.request == ManagementCueFormRequest(preset: "github"))
        form.take(answer, answering: form.request)
        return form
    }

    /// The add form once the Live stream choice is answered.
    static func streamForm(_ answer: ManagementCueSourceForm) throws -> CueSourceFormState {
        var form = try answeredChoices()
        form.choose(try choice("stream", in: form))
        form.take(answer, answering: form.request)
        return form
    }

    /// A webhook source waiting for its signing secret, as one of any
    /// service still does: GitHub's own never waits, Fermix makes its secret.
    static func waitingWebhook() throws -> ManagementCueSource {
        try edited("cues_sources_add_webhook", path: { $0["source"] as? [String: Any] }) { row in
            row["ref"] = "gh-hooks"
            row["state"] = "needs_secret"
            row["primary_action"] = "set_secret"
            row["missing_secret"] = "secret"
            row["actions"] = ["disable", "set_secret", "get_url"]
            row["secrets"] = [
                ["field": "secret", "label": "Signing secret", "present": false],
                ["field": "path_secret", "label": "Address", "present": false]
            ]
        }
    }

    /// The X accounts requirement in another state.
    static func requirement(state: String, sentence: String) throws -> ManagementCueSourceForm.Requirement {
        try edited("cues_sources_form_x_accounts", path: { $0["requirement"] as? [String: Any] }) { requirement in
            requirement["state"] = state
            requirement["sentence"] = sentence
        }
    }

    static func harness() throws -> SettingsHarness {
        try SettingsHarness(gateway: try gateway())
    }

    /// The golden feed row, with the fields a case needs changed.
    static func source(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueSource {
        try edited("cues_sources_list", path: { result in (result["sources"] as? [[String: Any]])?.first }, edit: edit)
    }

    static func watcher(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueWatcher {
        try edited("cues_watchers_list", path: { result in (result["watchers"] as? [[String: Any]])?.first }, edit: edit)
    }

    static func mandate(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueMandate {
        try edited("cues_mandates_list", path: { result in (result["mandates"] as? [[String: Any]])?.first }, edit: edit)
    }

    static func status(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueStatus {
        try edited("cues_status", path: { $0 }, edit: edit)
    }

    /// A watcher list with no watcher in it.
    static func noWatchers() throws -> ManagementCueWatcherList {
        let empty: [String: Any] = ["watchers": [Any](), "window_s": 86_400, "truncated": false]

        return try JSONDecoder().decode(ManagementCueWatcherList.self, from: try JSONSerialization.data(withJSONObject: empty))
    }

    /// The golden `cues` section's rows, with the Screen row it publishes
    /// just before the filter model, or as an engine from before the Screen
    /// publishes them, without it.
    static func cueSettingRows(withScreen: Bool) throws -> [ManagementSettingRow] {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == "settings_get_cues" })
        let result = try #require(try fixture.object("response")["result"] as? [String: Any])
        let rows = try #require(result["rows"] as? [[String: Any]])
        #expect(rows.contains { $0["key"] as? String == "cues_screen_provider" }, "the golden publishes the Screen")
        let published = withScreen ? rows : rows.filter { $0["key"] as? String != "cues_screen_provider" }

        return try JSONDecoder().decode([ManagementSettingRow].self, from: try JSONSerialization.data(withJSONObject: published))
    }

    /// The golden stream form with its `secret` row under another key.
    static func form(_ golden: ManagementCueSourceForm, renamingSecretTo key: String) throws -> ManagementCueSourceForm {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == "cues_sources_form_stream" })
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        var rows = try #require(result["rows"] as? [[String: Any]])
        for index in rows.indices where rows[index]["key"] as? String == "secret" {
            rows[index]["key"] = key
        }
        result["rows"] = rows

        return try JSONDecoder().decode(ManagementCueSourceForm.self, from: try JSONSerialization.data(withJSONObject: result))
    }

    private static func edited<Value: Decodable>(
        _ name: String,
        path: ([String: Any]) -> [String: Any]?,
        edit: (inout [String: Any]) -> Void
    ) throws -> Value {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == name })
        let result = try #require(try fixture.object("response")["result"] as? [String: Any])
        var object = try #require(path(result))
        edit(&object)

        return try JSONDecoder().decode(Value.self, from: try JSONSerialization.data(withJSONObject: object))
    }
}

/// A pasteboard that records what it was asked, so the token's rules are
/// proven without touching the one this Mac has.
final class RecordingSecretPasteboard: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var withdrawn: [Int] = []

    var writes: [String] { lock.withLock { written } }
    var withdrawals: [Int] { lock.withLock { withdrawn } }

    var pasteboard: CueSecretPasteboard {
        CueSecretPasteboard(
            write: { text in self.lock.withLock { self.written.append(text); return self.written.count } },
            withdraw: { count in self.lock.withLock { self.withdrawn.append(count) } }
        )
    }
}
