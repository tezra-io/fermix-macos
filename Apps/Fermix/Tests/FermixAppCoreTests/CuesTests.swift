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
        #expect(status.available && status.enabled && status.running)
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
        #expect(form.presets.map(\.id) == ["bluesky_jetstream", "github", "rss"])
        #expect(form.rows.first?.key == "ref", "the name comes first")
        #expect(form.rows.last?.kind == .secret && form.rows.last?.present == false)

        let feed: ManagementCueSourceAdded = try Self.golden("cues_sources_add")
        #expect(feed.token == nil)
        let push: ManagementCueSourceAdded = try Self.golden("cues_sources_add_local_push")
        #expect(push.token?.isEmpty == false, "a new local push source's first token is handed out")
        let webhook: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        #expect(webhook.source.primaryAction == .setSecret && webhook.source.missingSecret == .secret)

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

    @Test("a build that does not admit cues draws no pane, and a restored Cues selection goes back to the first pane")
    func noPaneWhenUnavailable() async throws {
        let gateway = try Self.gateway()
        gateway.cueStatusResult = try Self.status(editing: { $0["available"] = false; $0["state"] = "unavailable" })
        let harness = try SettingsHarness(gateway: gateway, store: FakeSettingsPaneStore(lastSettingsPane: "cues"))
        #expect(harness.model.selectedPane == .cues)

        await harness.model.windowAppeared()

        #expect(!harness.model.drawsCuesPane)
        #expect(harness.model.selectedPane == .providers)
    }

    @Test("the pane reads the status, its three lists and the proposals waiting, each on its own")
    func paneReadsItsLists() async throws {
        let gateway = try Self.gateway()
        gateway.v2Failures[.cuesWatchersList] = try ManagementRefusal.published("unavailable_cues_memory_off")
        let harness = try SettingsHarness(gateway: gateway)

        await harness.model.refreshCues()

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

        let waiting: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        #expect(CuesSheetPage.opening(waiting.source) == .source("gh-hooks", at: .secret))
        #expect(CueSourceProjection.secrets(waiting.source, first: .pathSecret).map(\.field) == [.pathSecret, .secret])

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
        #expect(CueSourceDetailWords.lines([]) == "None")
    }

    @Test("a watcher row and page say the daemon's counts and the owner's words, nothing a watcher read")
    func watcherProjection() throws {
        let detail: ManagementCueWatcherAnswer = try Self.golden("cues_watchers_get")
        let watcher = detail.watcher.row

        #expect(CueWatcherDetailWords.filter(watcher) == "Default")
        #expect(CueWatcherDetailWords.task(watcher) == "Release watch · keeps no notes")
        #expect(CueWatcherDetailWords.dailyLimit(watcher) == "None")
        #expect(CueWatcherDetailWords.lastDay(watcher.counts) == "0 waiting · 3 passed · 0 dropped · 1 acted · 0 failed")
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
        let waiting: ManagementCueSourceAdded = try Self.golden("cues_sources_add_webhook")
        #expect(CueTone.source(waiting.source) == .warn, "a source waiting for its secret")
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
        form.refusal = CueRefusal(sentence: "No field.", field: nil)
        #expect(form.formRefusal == "No field.")
    }

    @Test("Add sends the name, the preset and only the values changed, and never a secret")
    func addSendsWhatChanged() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        var form = CueSourceFormState()
        form.take(golden, answering: form.request)
        #expect(form.kind == "feed", "with no kind asked for, the form is a feed's")
        #expect(form.spec == nil, "nothing to add without a name")

        form.choose(kind: "webhook")
        form.choose(preset: "github")
        form.take(golden, answering: form.request)
        form.set(.text("gh-hooks"), for: "ref")
        form.set(.text("X-Hub-Signature-256"), for: "header")
        form.set(.text("X-Signature"), for: "type_header")
        form.secrets["secret"] = "fixture-signing-secret"

        let spec = try #require(form.spec)
        #expect(spec.ref == "gh-hooks")
        #expect(spec.preset == "github" && spec.kind == nil)
        #expect(spec.values == ["type_header": .setting(.text("X-Signature"))], "an unchanged default is not sent")
        #expect(form.typedSecrets == [CueTypedSecret(field: .secret, value: "fixture-signing-secret")])
        #expect(form.request == ManagementCueFormRequest(preset: "github"))
    }

    @Test("a typed value for a secret this app cannot store is refused under its row, and Add sends nothing")
    func unstorableSecretIsRefused() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        let renamed = try Self.form(golden, renamingSecretTo: "passphrase")
        var form = try Self.githubForm(renamed)
        form.set(.text("gh-hooks"), for: "ref")
        form.secrets["passphrase"] = "fixture-passphrase"

        let refused = form.prepareAdd()
        #expect(refused == nil, "nothing is added while a typed secret would be dropped")
        #expect(form.refusal == CueRefusal(sentence: ProductStrings[.cuesSourceSecretUnstorable], field: "passphrase"))
        #expect(form.refusal(for: "passphrase") == ProductStrings[.cuesSourceSecretUnstorable])
        #expect(ProductStrings[.cuesSourceSecretUnstorable] == "This version of the app cannot store this secret; update the app.")

        var known = try Self.githubForm(golden)
        known.set(.text("gh-hooks"), for: "ref")
        known.secrets["secret"] = "fixture-signing-secret"
        let preparing = known.prepareAdd()
        let prepared = try #require(preparing)
        #expect(prepared.secrets == [CueTypedSecret(field: .secret, value: "fixture-signing-secret")])
        #expect(known.refusal == nil)
    }

    @Test("changing the kind asks for its own form, without the other kind's preset or check")
    func kindChangeAsksAgain() throws {
        var form = CueSourceFormState()
        form.take(try Self.golden("cues_sources_form"), answering: form.request)
        form.choose(preset: "github")
        form.set(.text("standard_webhooks"), for: "verify")
        #expect(form.request == ManagementCueFormRequest(preset: "github", verify: "standard_webhooks"))

        form.choose(kind: "local_push")
        #expect(form.request == ManagementCueFormRequest(kind: "local_push"))
        #expect(form.kindPresets.isEmpty)
    }

    @Test("the sheet opens on the first kind with its first preset, and a kind chosen brings its own")
    func formOpensOnAPreset() throws {
        var form = CueSourceFormState()
        form.take(try Self.golden("cues_sources_form"), answering: form.request)
        #expect(form.kind == "feed" && form.preset == "rss", "a feed opens on RSS, which fills the interval")
        #expect(form.request == ManagementCueFormRequest(preset: "rss"))

        form.choose(kind: "webhook")
        #expect(form.preset == "github")
        form.choose(kind: "local_push")
        #expect(form.preset == nil, "local push has no preset")
        #expect(form.request == ManagementCueFormRequest(kind: "local_push"))

        form.choose(kind: "stream")
        #expect(form.preset == "bluesky_jetstream")
        form.choose(preset: nil)
        #expect(form.request == ManagementCueFormRequest(kind: "stream"), "None stays a choice")
    }

    @Test("a stream with no preset is offered as Any WebSocket, every other kind's as None")
    func noPresetTitles() {
        #expect(CueSourceProjection.noPresetTitle(for: "stream") == "Any WebSocket")
        for kind in ["feed", "webhook", "local_push", "a-later-kind"] {
            #expect(CueSourceProjection.noPresetTitle(for: kind) == "None", "\(kind)")
        }
        #expect(CueSourceProjection.noPresetTitle(for: nil) == "None")
    }

    // The general WebSocket source: its field rows explain themselves behind
    // info, with no footer under any of them, and it takes two secrets, each
    // stored under its own row key once the source exists.
    @Test("a stream with no preset keeps its rows' notes behind info and stores its key and its secret, key first")
    func webSocketStreamForm() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form_stream")
        var form = CueSourceFormState()
        form.take(golden, answering: form.request)
        form.choose(kind: "stream")
        form.choose(preset: nil)
        #expect(form.request == ManagementCueFormRequest(kind: "stream"))
        form.take(golden, answering: form.request)

        #expect(form.rows.allSatisfy { $0.footer == nil })
        #expect(form.rows.contains { $0.key == "url" && $0.info?.isEmpty == false })
        #expect(form.rows.filter { $0.kind == .secret }.map(\.key) == ["key", "secret"])

        form.set(.text("alpaca-news"), for: "ref")
        form.secrets["key"] = "fixture-key"
        form.secrets["secret"] = "fixture-secret"
        let preparing = form.prepareAdd()
        let prepared = try #require(preparing)
        #expect(prepared.spec.kind == "stream" && prepared.spec.preset == nil)
        #expect(prepared.secrets == [
            CueTypedSecret(field: .key, value: "fixture-key"),
            CueTypedSecret(field: .secret, value: "fixture-secret")
        ])
    }

    @Test("what adding a source means and the daemon's notes are one explanation behind the kind's info")
    func formAboutJoinsConsentAndNotes() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        var form = CueSourceFormState()
        #expect(form.about == nil, "nothing to explain before the daemon answers")

        form.take(golden, answering: form.request)
        form.choose(kind: "webhook")
        #expect(form.request == ManagementCueFormRequest(preset: "github"), "the golden answers GitHub's form")
        form.take(golden, answering: form.request)
        let about = try #require(form.about)
        let consent = try #require(golden.consentSentence)
        #expect(about.hasPrefix(consent), "the consent line leads")
        #expect(!golden.notes.isEmpty)
        for note in golden.notes { #expect(about.contains(note)) }
    }

    @Test("an answer to a request the sheet has moved past draws no rows, so one choice's fields never show under another")
    func staleAnswerDrawsNoRows() throws {
        let golden: ManagementCueSourceForm = try Self.golden("cues_sources_form")
        var form = CueSourceFormState()

        // The first answer is for no choice yet; opening on RSS asks again.
        form.take(golden, answering: form.request)
        #expect(form.preset == "rss")
        #expect(form.rows.isEmpty, "the no-preset rows are not drawn under RSS")
        #expect(!form.kinds.isEmpty && !form.presets.isEmpty, "the choices are drawn at once")

        let asked = form.request
        form.choose(kind: "webhook")
        form.take(golden, answering: asked)
        #expect(form.rows.isEmpty, "an answer for RSS is not drawn under GitHub")

        form.take(golden, answering: form.request)
        #expect(form.rows.first?.key == "ref", "the answer for the current choice draws its rows")
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

    @Test("the add calls cues.sources.add, then one secret.set per typed secret, then reads the list")
    func addThenStore() async throws {
        let gateway = try Self.gateway()
        let harness = try SettingsHarness(gateway: gateway)
        let spec = ManagementCueSourceSpec(ref: "gh-hooks", choice: .preset("github"), values: [:])

        let outcome = await harness.model.addCueSource(
            spec,
            secrets: [CueTypedSecret(field: .secret, value: "fixture-signing-secret")]
        )

        #expect(outcome == .added(ref: "gh-hooks", token: nil, unstored: nil))
        #expect(gateway.cueSpecs == [spec])
        #expect(gateway.storedSecrets.map(\.id) == ["cue_source:gh-hooks:secret"])
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
        let spec = ManagementCueSourceSpec(ref: "gh-hooks", choice: .preset("github"), values: [:])

        let outcome = await harness.model.addCueSource(
            spec,
            secrets: [CueTypedSecret(field: .secret, value: "fixture-signing-secret")]
        )

        guard case .added(let ref, nil, let unstored?) = outcome else {
            Issue.record("the source exists and its secret is unstored: \(outcome)")
            return
        }
        #expect(ref == "gh-hooks")
        #expect(unstored.field == "secret")
        #expect(!unstored.sentence.isEmpty)
        #expect(gateway.calls.last { $0 == .v2(.cuesSourcesList) } != nil, "the list is read again, as the daemon reports it")
        #expect(harness.model.cueSources.value == (try Self.golden("cues_sources_list") as ManagementCueSourceList))

        var sheet = CuesSheetState(page: .addSource)
        sheet.added(outcome)
        #expect(sheet.page == .source("gh-hooks", at: .secret))
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

        sheet.added(.added(ref: added.source.ref, token: nil, unstored: nil))

        #expect(sheet.page == .source("gh-hooks", at: nil))
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
        #expect(sheet.token?.value.isEmpty == false)

        sheet.turn(to: .editSource("home-alerts"))
        #expect(sheet.token == nil, "the token leaves the view when the page changes")

        sheet.turn(to: .source("home-alerts", at: nil))
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
            }
        }

        let block = try #require(files.first { $0.path.hasSuffix("CuesSourceSheet.swift") })
        let body = try #require(block.text.components(separatedBy: "struct CueTokenBlock").last)
        #expect(body.contains(".accessibilityLabel(String(format: ProductStrings[.cuesSourceTokenAccessibilityFormat]"))
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
        #expect(ProductStrings[.cuesSubtitle] == "Outside items that can wake a task: feeds, streams, webhooks and your scripts.")
        #expect(ProductStrings[.cuesWaitingTitle] == "Waiting for you")
        #expect(ProductStrings[.cuesWaitingShowInChat] == "Show in chat")
        #expect(ProductStrings[.cuesSourcesEmpty] == "No sources yet.")
        #expect(ProductStrings[.cuesLearnMore] == "Learn more")
        #expect(ProductStrings[.cuesSourceNewTokenConfirm] == "Make a new token for %@? The old one stops working within a minute.")
        #expect(ProductStrings[.cuesSourceTokenOnce] == "Copy it now. Fermix shows it only once.")
        #expect(ProductStrings[.cuesSourceRemoveConfirm] == "Remove %@? Its stored secrets are deleted.")
        #expect(ProductStrings[.cuesWatchersEmpty] == "No watchers yet.")
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
        let webhook = try await ask(.cuesSourcesAdd, ["ref": "gh-hooks", "preset": "github", "values": [String: Any]()])
        #expect((webhook?["source"] as? [String: Any])?["state"] as? String == "needs_secret")

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

    /// The add form as the sheet has it once the golden form, GitHub's,
    /// answers the GitHub request: opened, Webhook chosen, then answered.
    static func githubForm(_ answer: ManagementCueSourceForm) throws -> CueSourceFormState {
        var form = CueSourceFormState()
        form.take(answer, answering: form.request)
        form.choose(kind: "webhook")
        #expect(form.request == ManagementCueFormRequest(preset: "github"))
        form.take(answer, answering: form.request)
        return form
    }

    static func harness() throws -> SettingsHarness {
        try SettingsHarness(gateway: try gateway())
    }

    /// The golden feed row, with the fields a case needs changed.
    static func source(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueSource {
        try edited("cues_sources_list", path: { result in (result["sources"] as? [[String: Any]])?.first }, edit: edit)
    }

    static func mandate(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueMandate {
        try edited("cues_mandates_list", path: { result in (result["mandates"] as? [[String: Any]])?.first }, edit: edit)
    }

    static func status(editing edit: (inout [String: Any]) -> Void) throws -> ManagementCueStatus {
        try edited("cues_status", path: { $0 }, edit: edit)
    }

    /// The golden form with its secret row under another key.
    static func form(_ golden: ManagementCueSourceForm, renamingSecretTo key: String) throws -> ManagementCueSourceForm {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == "cues_sources_form" })
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        var rows = try #require(result["rows"] as? [[String: Any]])
        for index in rows.indices where rows[index]["kind"] as? String == "secret" {
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
