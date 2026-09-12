import Foundation
import Testing

@testable import FermixAppCore

/// The management contract, driven by its own golden fixtures.
///
/// Every record in every fixture file is exercised, and each test asserts the
/// set it handled equals the set the file contains, so an added fixture fails
/// here instead of being ignored. These are the same frames the daemon is
/// tested against, vendored byte for byte, so replaying them is the proof that
/// the typed models match the shapes the engine actually sends.
@Suite("Management protocol v2 fixtures")
struct ManagementV2FixtureTests {
    // MARK: - Coverage

    @Test("every published method has a request fixture and a success fixture")
    func everyMethodIsPinned() throws {
        let published = Set(try ManagementContract.vendored().methods)
        let requested = Set(
            try ManagementFixtures.load(.requests, from: .management)
                .map { try $0.string("method") }
        )
        let answered = Set(
            try ManagementFixtures.load(.success, from: .management)
                .map { try $0.string("method") }
        )

        #expect(published.subtracting(requested).isEmpty)
        #expect(published.subtracting(answered).isEmpty)
        #expect(requested.subtracting(published).isEmpty)
        #expect(answered.subtracting(published).isEmpty)
    }

    /// M34 §7.1 as amended: the speakable set is derived from the range the
    /// schema already publishes, and revision 4's second key is withdrawn. A key
    /// that reappeared would be a second copy of one fact inside one artifact.
    @Test("the schema mints no separate speakable-versions key")
    func speakableVersionsHaveNoKeyOfTheirOwn() throws {
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            ) as? [String: Any]
        )
        let range = try #require(document["x-supported-version-range"] as? [String: Int])

        #expect(document["x-speakable-versions"] == nil)
        #expect(range == ["min": 1, "max": 2])
        #expect(try ManagementContract.vendored().speakableVersions == Array(1...2))
    }

    /// `hello.capabilities` is published but is not a second gate, so its two
    /// halves have to agree with the catalog by construction rather than by a
    /// runtime branch that picks one of them.
    @Test("the hello fixture advertises exactly the catalog and its minimums")
    func helloAdvertisesTheCatalog() throws {
        let contract = try ManagementContract.vendored()
        let hello: ManagementHello = try FakeDaemonGateway.fixtureResult(
            named: "hello",
            as: ManagementHello.self
        )

        #expect(Set(hello.capabilities.methods) == Set(contract.methods))
        #expect(hello.capabilities.declaredMinimumVersions == contract.minimumVersions)
        #expect(hello.protocolRange.minimum == 1)
        #expect(hello.protocolRange.maximum == 2)
    }

    /// Every closed vocabulary this build models has to be exactly a set the
    /// artifact publishes. A Swift spelling that drifts from the schema decodes
    /// as `.unrecognized` and routes nowhere, and nothing fails until a live
    /// daemon sends the value: the Coding agents pane was `coding_agents` here
    /// against the `coding` route slug of M34 §3.4, and no gate said so.
    @Test("every modelled vocabulary is exactly a set the schema publishes")
    func vocabulariesMatchTheSchema() throws {
        let published = try Self.publishedEnumerations()
        // This list grows with ManagementV2Vocabulary.swift. A vocabulary added
        // there and not here is unchecked, which is what the count asserts.
        let modelled: [(String, [String])] = [
            ("settings pane", Array(ManagementSettingsPane.publishedValues.keys)),
            ("setting kind", Array(ManagementSettingKind.publishedValues.keys)),
            ("job status", Array(ManagementJobStatus.publishedValues.keys)),
            ("job kind", Array(ManagementJobKind.publishedValues.keys)),
            ("job failure code", Array(ManagementJobFailureCode.publishedValues.keys)),
            ("config state", Array(ManagementConfigState.publishedValues.keys)),
            ("service scope", Array(ManagementServiceScope.publishedValues.keys)),
            ("detect target", Array(ManagementDetectTarget.publishedValues.keys)),
            ("auth import source", Array(ManagementAuthImportSource.publishedValues.keys)),
            ("capability target", Array(ManagementCapabilityTarget.publishedValues.keys)),
            ("remediation action", Array(ManagementRemediationActionKind.publishedValues.keys)),
            ("model source", Array(ManagementModelSource.publishedValues.keys)),
            ("plugin action", Array(ManagementPluginAction.publishedValues.keys)),
            ("plugin runtime kind", Array(ManagementPluginRuntimeKind.publishedValues.keys)),
            ("plugin auth kind", Array(ManagementPluginAuthKind.publishedValues.keys))
        ]

        #expect(modelled.count == 15)
        for (name, values) in modelled {
            #expect(
                published.contains(Set(values)),
                "the \(name) vocabulary is not a set the schema publishes: \(values.sorted())"
            )
        }
    }

    @Test("every golden request is exercised")
    func everyGoldenRequestIsExercised() throws {
        let published = Set(
            try ManagementFixtures.load(.requests, from: .management).map(\.name)
        )

        #expect(Set(ManagementV2Calls.byFixture.keys) == published.subtracting(ManagementV2Calls.unexercised))
        #expect(ManagementV2Calls.unexercised.isSubset(of: published))
    }

    // MARK: - Requests

    @Test("each call emits the contract's golden frame")
    func callsEmitGoldenFrames() async throws {
        let envelopes = try ManagementFixtures.successEnvelopesByMethod(from: .management)
        let contract = try ManagementContract.vendored()

        for fixture in try ManagementFixtures.load(.requests, from: .management) {
            guard !ManagementV2Calls.unexercised.contains(fixture.name) else { continue }

            let invoke = try #require(ManagementV2Calls.byFixture[fixture.name])

            var expected = try fixture.object("frame")
            let identifier = expected["request_id"] as? String ?? ""
            let method = try #require(ManagementMethod(rawValue: try fixture.string("method")))
            // A parameter-free method may omit `params` entirely; the client
            // always sends the empty object the schema defaults it to.
            if expected["params"] == nil { expected["params"] = [String: Any]() }
            // The golden frames illustrate an honest client at each method's own
            // minimum version. This client negotiated 2, and PROTOCOL.md has it
            // stamp the negotiated version on every request past `hello`, so the
            // stamp is asserted as that rather than compared with the
            // illustration. `negotiatedVersionIsStamped` is the other half.
            #expect(
                expected["protocol_version"] as? Int == contract.minimumVersion(for: method),
                "\(fixture.name) is not stamped with its own minimum"
            )
            expected["protocol_version"] = method == .hello ? 1 : 2

            let transport = EchoingFixtureTransport(envelopes: envelopes)
            let client = try ManagementTestClient.make(
                transport: transport,
                contract: contract,
                requestIdentifier: identifier
            )
            _ = try await client.hello()
            try await invoke(client)

            let emitted = try #require(transport.capturedFrames.last)
            #expect(
                ManagementFixtures.equal(emitted, expected),
                "\(fixture.name): emitted \(emitted) expected \(expected)"
            )
        }
    }

    /// The negotiated version is stamped on every request past `hello`, and
    /// `hello` itself is stamped with the floor, which is the version every
    /// daemon inside the supported window serves.
    @Test("a negotiated session stamps 2 on every request past hello")
    func negotiatedVersionIsStamped() async throws {
        let transport = EchoingFixtureTransport(
            envelopes: try ManagementFixtures.successEnvelopesByMethod(from: .management)
        )
        let client = try ManagementTestClient.make(
            transport: transport,
            contract: try ManagementContract.vendored(),
            requestIdentifier: "req-stamp-1"
        )

        _ = try await client.hello()
        _ = try await client.settingsSections()
        _ = try await client.hello()

        let stamps = transport.capturedFrames.map { $0["protocol_version"] as? Int }
        #expect(stamps == [1, 2, 1])
    }

    // MARK: - Results

    @Test("every success fixture decodes into the method's typed result")
    func successFixturesDecode() throws {
        var seen: Set<String> = []

        for fixture in try ManagementFixtures.load(.success, from: .management) {
            let method = try #require(ManagementMethod(rawValue: try fixture.string("method")))
            let envelope = try fixture.object("response")
            let identifier = try #require(envelope["request_id"] as? String)

            try ManagementV2ResultDecoder.decode(
                method: method,
                payload: try ManagementFixtures.encode(envelope),
                identifier: identifier
            )
            seen.insert(fixture.name)
        }

        #expect(seen.count == 67, "every success record was decoded")
    }

    /// A published error code with no fixture is a code nobody has ever seen
    /// decoded, which is how a daemon-emittable code goes missing from the
    /// client's accept list (M34 §7.8 step 1).
    @Test("every published error code has a fixture and decodes as itself")
    func errorFixturesDecode() throws {
        var seen: Set<String> = []

        for fixture in try ManagementFixtures.load(.errors, from: .management) {
            let code = ManagementErrorCode(wireValue: try fixture.string("code"))
            let envelope = try fixture.object("response")
            let identifier = envelope["request_id"] as? String ?? ""

            #expect(code.isPublished, "\(fixture.name) carries an unpublished code")

            do {
                _ = try ManagementResponse.decode(
                    try ManagementFixtures.encode(envelope),
                    expecting: identifier,
                    method: .settingsApply,
                    as: ManagementSettingsApplied.self
                )
                Issue.record("\(fixture.name) decoded as a success")
            } catch ManagementError.daemon(let failure) {
                #expect(failure.code == code)
                #expect(!failure.message.isEmpty)
                seen.insert(failure.code.wireValue)
            }
        }

        #expect(seen == Set(ManagementErrorCode.publishedValues.keys))
        #expect(seen.count == 16)
    }

    /// The per-method refusal of M34 §7.1 carries the version the method needs,
    /// so a front end can say what a restart would buy.
    @Test("method_requires_newer_engine carries the version the method requires")
    func methodNotFoundCarriesItsRequirement() throws {
        let decoded = try Self.failure(named: "method_requires_newer_engine")

        #expect(decoded.code == .methodNotFound)
        #expect(decoded.details.method == "setup.state.get")
        #expect(decoded.details.integer("requires") == 2)
    }

    /// The same code twice, and the app must not read them as one state. A verb
    /// this daemon does not serve at all carries `{method}` and nothing else. A
    /// client that read `requires` as always present would decode nothing for
    /// it, and one that treated the code as the N-1 state would tell the
    /// operator a restart fixes a method that does not exist.
    @Test("a plain method_not_found carries no requirement and is a daemon error")
    func plainMethodNotFoundIsADaemonError() throws {
        let decoded = try Self.failure(named: "method_not_found")

        #expect(decoded.code == .methodNotFound)
        #expect(decoded.details.method == "lifecycle.reboot")
        #expect(decoded.details.integer("requires") == nil)

        let error = ManagementError.daemon(decoded)

        #expect(!ManagementMessage.requiresNewerEngine(error))
        #expect(ManagementMessage.sentence(for: error) == decoded.message)
        #expect(
            ManagementMessage.sentence(for: error)
                != ProductStrings[.daemonErrorRequiresNewerEngine]
        )
    }

    /// The sentence an operator is shown for a daemon refusal is the daemon's
    /// own, for every error record the contract publishes.
    ///
    /// `message` is fixed per code, and two codes carry the sentence that says
    /// what actually happened in `details.sentence`. Rendering `message` alone
    /// showed `Request parameters are invalid.` for the whole `invalid_params`
    /// family — every settings validation, `This provider has no browser
    /// sign-in.`, `A secret cannot be empty.` — and `The settings file could
    /// not be read.` in place of the parser's own line.
    @Test("the sentence shown for a refusal is the one the daemon sent")
    func refusalSentencesAreTheDaemons() throws {
        var carried = 0

        for fixture in try ManagementFixtures.load(.errors, from: .management) {
            let failure = try Self.failure(named: fixture.name)
            let shown = ManagementMessage.sentence(for: ManagementError.daemon(failure))

            guard let sentence = failure.details.sentence else {
                #expect(shown == failure.message, "\(fixture.name) is not shown its own message")
                continue
            }

            #expect(shown == sentence, "\(fixture.name) is not shown the daemon's sentence")
            #expect(shown != failure.message, "\(fixture.name) would read as the fixed message")
            carried += 1
        }

        #expect(carried == 2, "the contract publishes a detail sentence for two codes")
    }

    /// The two codes that carry one, by name, so the accessor cannot quietly
    /// stop reading either of them.
    @Test("invalid_params and config_unreadable both publish a detail sentence")
    func bothSentenceCarryingCodesAreRead() throws {
        let params = try Self.failure(named: "invalid_params_with_sentence")
        let unreadable = try Self.failure(named: "config_unreadable")

        #expect(params.code == .invalidParams)
        #expect(params.details.field == "provider")
        #expect(params.details.sentence == "This provider has no browser sign-in.")
        #expect(ManagementMessage.sentence(for: ManagementError.daemon(params)) == params.details.sentence)

        #expect(unreadable.code == .configUnreadable)
        #expect(unreadable.details.sentence?.isEmpty == false)
        #expect(
            ManagementMessage.sentence(for: ManagementError.daemon(unreadable))
                == unreadable.details.sentence
        )
    }

    // MARK: - Plugin rows

    /// A word is not a routing key. Every button an integration row can draw
    /// runs the id the daemon published beside the word, so the eden row can no
    /// longer draw `Choose workspace` on a button that runs
    /// `plugins.check.start`.
    @Test("every plugin row's buttons run the action the daemon published")
    func pluginButtonsRunThePublishedAction() throws {
        var rows = 0

        for fixture in try ManagementFixtures.load(.success, from: .management)
        where (try? fixture.string("method"))?.hasPrefix("plugins.") == true {
            for row in try Self.pluginRows(in: fixture) {
                rows += 1
                #expect(
                    (row.primaryAction == nil) == (row.verb == nil),
                    "\(row.name): a leading verb and its action arrive together"
                )
                #expect(
                    row.actions.count == row.verbs.count,
                    "\(row.name): one action per verb, in the same order"
                )
                if let leading = row.primaryAction {
                    #expect(
                        row.actions.contains(leading),
                        "\(row.name): the leading action is not one of the row's own"
                    )
                }
                for action in row.buttons {
                    #expect(action.isPublished, "\(row.name) draws a button for \(action)")
                    #expect(action.title?.isEmpty == false, "\(row.name)'s \(action) has no word")
                }
            }
        }

        #expect(rows > 0, "the fixtures publish plugin rows to check")
    }

    /// A row the daemon publishes no verbs for draws no verb buttons. The
    /// contract's `connecting` row is exactly that shape, and the app used to
    /// offer it a `Sign in` it derived itself.
    @Test("a row with no published verbs draws no verb buttons")
    func rowsWithoutVerbsDrawNoButtons() throws {
        let rows = try ManagementFixtures.load(.compatibility, from: .management)
            .filter { $0.name == "plugin_row_without_optional_fields" }
            .flatMap { try Self.pluginRows(in: $0) }
        let bare = try #require(rows.first)

        #expect(bare.verbs.isEmpty)
        #expect(bare.actions.isEmpty)
        #expect(bare.primaryAction == nil)
        #expect(bare.buttons.isEmpty)
    }

    /// Every plugin row in every fixture, as the pane resolves them.
    private static func pluginRows(in fixture: ManagementFixture) throws -> [IntegrationRowModel] {
        let result = try fixture.object("response")["result"]
        guard let object = result as? [String: Any] else { return [] }

        if object["plugins"] != nil {
            let catalog: ManagementPluginCatalog = try decode(object)
            return IntegrationRowProjection.rows(catalog)
        }
        if let row = object["plugin"] {
            let plugin: ManagementPlugin = try decode(row)
            return IntegrationRowProjection.rows(
                ManagementPluginCatalog(plugins: [plugin], oauthClients: [])
            )
        }

        return []
    }

    // MARK: - Jobs, by kind

    /// The phase vocabulary is per kind, and the overlaps are not the same
    /// step: `binding` on an `auth` job opens the loopback port, and `binding`
    /// on a `plugin_workspace_select` job ties the plugin to the workspace.
    /// Keyed on the phase alone the workspace sheet said it was opening a port.
    @Test("every kind and phase the fixtures publish has a sentence of its own")
    func everyPublishedJobStepHasASentence() throws {
        var checked = 0

        for (kind, phase) in try Self.publishedJobSteps() {
            #expect(
                JobPhaseCopy.sentence(kind: kind, phase: phase)?.isEmpty == false,
                "\(kind.wireValue)/\(phase) has no sentence"
            )
            checked += 1
        }

        #expect(checked > 0, "the fixtures publish job phases to check")
        #expect(
            JobPhaseCopy.sentence(kind: .auth, phase: "binding")
                != JobPhaseCopy.sentence(kind: .pluginWorkspaceSelect, phase: "binding"),
            "one word, two steps: they must not share a sentence"
        )
    }

    /// Every (kind, phase) pair any fixture file publishes.
    private static func publishedJobSteps() throws -> [(ManagementJobKind, String)] {
        var steps: [(ManagementJobKind, String)] = []

        for file in [ManagementFixtureFile.success, .compatibility] {
            for fixture in try ManagementFixtures.load(file, from: .management) {
                // The compatibility file carries frames as well as responses
                // (a v0 daemon's `health`, an N-1 client's call), and only a
                // response can carry a job.
                guard let response = try? fixture.object("response") else { continue }

                Self.walk(response) { object in
                    guard let kind = object["kind"] as? String,
                          let phase = object["phase"] as? String
                    else { return }

                    steps.append((ManagementJobKind(wireValue: kind), phase))
                }
            }
        }

        return steps
    }

    /// Every JSON object under a value, with an explicit work list rather than
    /// recursion so the bound is one visible counter.
    private static func walk(_ root: Any, _ visit: ([String: Any]) -> Void) {
        var pending: [Any] = [root]
        var visits = 0

        while visits < maxSchemaNodes, let node = pending.popLast() {
            visits += 1
            if let object = node as? [String: Any] {
                visit(object)
                pending.append(contentsOf: object.values)
            } else if let array = node as? [Any] {
                pending.append(contentsOf: array)
            }
        }
    }

    private static func decode<Value: Decodable>(_ object: Any?) throws -> Value {
        try JSONDecoder().decode(
            Value.self,
            from: try JSONSerialization.data(withJSONObject: try #require(object))
        )
    }

    private static func failure(named name: String) throws -> ManagementFailure {
        let fixture = try #require(
            try ManagementFixtures.load(.errors, from: .management).first { $0.name == name }
        )
        let published = try #require(try fixture.object("response")["error"] as? [String: Any])

        return try JSONDecoder().decode(
            ManagementFailure.self,
            from: try ManagementFixtures.encode(published)
        )
    }

    // MARK: - Jobs

    /// Doctor is not a job. It keeps its own session family with its own scope
    /// and per-check results, so `job.list` never returns one and the app's job
    /// vocabulary carries no `doctor` case to switch on.
    @Test("no job kind is doctor, in the schema or in the app")
    func doctorIsNotAJobKind() throws {
        #expect(ManagementJobKind.publishedValues["doctor"] == nil)
        #expect(ManagementJobKind.publishedValues.count == 10)

        let jobs: ManagementJobList = try FakeDaemonGateway.fixtureResult(
            named: "job_list",
            as: ManagementJobList.self
        )

        #expect(!jobs.jobs.isEmpty)
        for job in jobs.jobs {
            #expect(job.kind.isPublished, "\(job.kind) is not a kind this build models")
            #expect(job.kind != .unrecognized("doctor"))
        }
    }

    /// `failure.code` is closed, so a caller can branch on the kind rather than
    /// read the sentence. It is still an open decoder: a code from a newer
    /// daemon is preserved under its own name rather than folded onto a
    /// neighbour or dropped.
    @Test("a job failure code decodes as its published case, and an unknown one is preserved")
    func jobFailureCodesAreClosedAndPreserving() throws {
        let published = Set(ManagementJobFailureCode.publishedValues.keys)

        #expect(published == ["unavailable", "refused", "timed_out", "internal_error"])
        #expect(ManagementJobFailureCode(wireValue: "timed_out") == .timedOut)
        #expect(ManagementJobFailureCode(wireValue: "teapot") == .unrecognized("teapot"))
        #expect(ManagementJobFailureCode(wireValue: "teapot").wireValue == "teapot")
        #expect(!ManagementJobFailureCode(wireValue: "teapot").isPublished)
    }

    /// Every job this daemon runs reports stages, not bytes, so `progress` is
    /// null everywhere and the field is decoded as absent rather than as a zero
    /// a progress bar would draw.
    @Test("a job publishes no counted progress")
    func jobProgressIsAbsent() throws {
        let started: ManagementJob = try FakeDaemonGateway.fixtureResult(
            named: "capabilities_install_start",
            as: ManagementJob.self
        )
        let listed: ManagementJobList = try FakeDaemonGateway.fixtureResult(
            named: "job_list",
            as: ManagementJobList.self
        )

        #expect(started.progress == nil)
        for job in listed.jobs {
            #expect(job.progress == nil, "\(job.jobId) carries counted progress")
        }
    }

    /// The phase is cleared when a job finishes cleanly and kept when it does
    /// not, so the step a run stopped in is still readable beside its failure
    /// sentence. `status` is the state either way; the phase is never switched
    /// on.
    @Test("a job's phase is cleared on a clean finish and kept on a bad one")
    func jobPhaseFollowsTheOutcome() throws {
        let listed: ManagementJobList = try FakeDaemonGateway.fixtureResult(
            named: "job_list",
            as: ManagementJobList.self
        )
        let completed: ManagementJob = try FakeDaemonGateway.fixtureResult(
            named: "job_get_completed",
            as: ManagementJob.self
        )

        #expect(completed.status == .completed)
        #expect(completed.phase == nil)
        for job in listed.jobs {
            switch job.status {
            case .completed, .cancelled:
                #expect(job.phase == nil, "\(job.jobId) kept a phase after finishing")
            case .failed, .timedOut:
                #expect(job.phase != nil, "\(job.jobId) dropped the phase it stopped in")
            case .running, .unrecognized:
                continue
            }
        }
    }

    // MARK: - Readiness and providers

    /// The daemon mints `ready` and `setup_required`, and `degraded` is
    /// reserved. `attention` is a word this app draws, never a state the daemon
    /// reports, so Home keys its own presentation on "not ready" rather than on
    /// a third status.
    @Test("readiness reports the daemon's own two status words")
    func readinessStatusIsTheDaemons() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let overview: ManagementOverview = try FakeDaemonGateway.fixtureResult(
            named: "overview_get",
            as: ManagementOverview.self
        )

        #expect(state.readiness.status == "setup_required")
        #expect(overview.readiness.status == "ready")

        // The word `attention` appears nowhere in the schema: it is the app's
        // own name for the Home section that lists what is not ready.
        let schema = String(
            decoding: try VendoredContracts.data(.management, "protocol.schema.json"),
            as: UTF8.self
        )

        #expect(!schema.contains("\"attention\""))
    }

    /// Personalization gates. The failure carries `gating` on the wire and the
    /// app reads it there, so a home missing the owner's own description cannot
    /// be reported ready by one surface and not by another.
    @Test("a personalization failure is gating wherever it is published")
    func personalizationAlwaysGates() throws {
        var published = 0

        for fixture in try ManagementFixtures.load(.success, from: .management)
        where (try? fixture.string("method")) == ManagementMethod.setupStateGet.rawValue {
            let state: ManagementSetupState = try Self.decode(try fixture.object("response")["result"])
            for failure in state.readiness.failures where failure.detailKey == "personalization" {
                #expect(failure.gating, "a personalization failure is published as advisory")
                #expect(failure.pane == .personality)
                published += 1
            }
        }

        // The golden home has no communication style, so it publishes exactly
        // one. `>= 0` could not fail, which is what let the loop sit over a
        // fixture that published none.
        #expect(published == 1, "the golden home publishes one personalization failure")
    }

    /// Provider labels and their order are the daemon's. The app draws the
    /// descriptor's own label, so a marketing name written in Swift cannot
    /// disagree with the one the Providers pane and the Attention row show.
    @Test("provider labels and order come from the daemon")
    func providerLabelsAreTheDaemons() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )

        #expect(state.providers.first?.id == "openai_codex")
        #expect(state.providers.first?.label == "OpenAI Codex (ChatGPT)")
        #expect(state.providers.first { $0.id == "anthropic" }?.label == "Anthropic")
        #expect(state.providers.first { $0.id == "xai" }?.label == "SpaceXAI")
        #expect(state.profile == "general")
    }

    // MARK: - Descriptor sections

    /// Every `settings.get` fixture, decoded into the typed section.
    private static func settingsSections() throws -> [ManagementSettingsSectionRows] {
        try ManagementFixtures.load(.success, from: .management)
            .filter { $0.name.hasPrefix("settings_get") }
            .map { fixture in
                let result = try #require(try fixture.object("response")["result"] as? [String: Any])

                return try JSONDecoder().decode(
                    ManagementSettingsSectionRows.self,
                    from: try ManagementFixtures.encode(result)
                )
            }
    }

    /// A choice row that HOLDS a value must be able to show it. A value that is
    /// not one of its own options draws a popup with nothing selected, which
    /// reads as a blank setting rather than as the value the daemon holds:
    /// `personalization.communication_style` shipped exactly that, the label
    /// `Concise` where the options are the three style sentences.
    ///
    /// An empty value is the opposite state and is not a defect: nothing has
    /// been chosen yet, and nothing selected is what that looks like. The gate
    /// is over every choice row in every section, so the next one fails here
    /// rather than on screen.
    @Test("every choice row that holds a value can show it")
    func choiceValuesAreSelectable() throws {
        var checked = 0

        for section in try Self.settingsSections() {
            for row in section.rows where row.kind == .choice && !row.options.isEmpty {
                guard let value = DescriptorValue.optional(row.value), !value.isEmpty else { continue }

                #expect(
                    row.options.contains { $0.value == value },
                    "\(section.id).\(row.key) holds \(value), which is not one of its options"
                )
                checked += 1
            }
        }

        #expect(checked > 0, "the fixtures publish choice rows to check")
    }

    /// A choice row that publishes SUGGESTIONS gets a control that can express
    /// an off-list value, because the daemon accepts one.
    ///
    /// The time zone row gets the searchable list macOS already knows, which is
    /// several hundred zones against 21 suggestions; every other suggestion row
    /// gets a field with the suggestions beside it. A closed popup on either
    /// could only ever send one of the published options back, and the daemon
    /// prepending the value in force to the options is what hid that.
    @Test("a choice row whose options are suggestions can express an off-list value")
    func offListChoiceValuesAreCarriedThrough() throws {
        let section = try #require(
            try Self.settingsSections().first { $0.id == AboutYouAnswers.personalizationSection }
        )
        let timezone = try #require(section.rows.first { $0.key == AboutYouAnswers.timezoneKey })
        let style = try #require(section.rows.first { $0.key == AboutYouAnswers.styleKey })
        let offList = "Antarctica/Troll"

        #expect(timezone.kind == .choice)
        #expect(timezone.suggestions, "the contract publishes the time zone row as suggestions")
        #expect(!timezone.options.contains { $0.value == offList })
        #expect(
            DescriptorRowModel(row: timezone, value: .text(offList)).control == .timeZone(offList)
        )

        #expect(style.kind == .choice)
        #expect(style.suggestions)
        #expect(
            DescriptorRowModel(row: style, value: .text("Answer in haiku")).control
                == .suggestion(value: "Answer in haiku", options: style.options)
        )
    }

    /// A choice row that does NOT publish suggestions keeps its closed menu:
    /// `settings.apply` refuses a value outside its options, so a control that
    /// could send one would be a control whose save always refuses.
    @Test("a choice row without suggestions keeps a closed menu")
    func closedChoiceRowsStayClosed() throws {
        var closed = 0

        for section in try Self.settingsSections() {
            // A read-only row of any kind is a labelled fact, which is the
            // rule that wins over the kind.
            for row in section.rows where row.kind == .choice && !row.suggestions && !row.readOnly {
                let value = DescriptorValue.optional(row.value)

                #expect(
                    DescriptorRowModel(row: row, value: row.value).control
                        == .choice(selected: value, options: row.options),
                    "\(section.id).\(row.key) is a closed choice"
                )
                closed += 1
            }
        }

        #expect(closed > 0, "the fixtures publish closed choice rows to check")
    }

    /// One value, one label. The assistant's About you screen and the
    /// Personality pane write the same assistant name, so a person who meets it
    /// twice must not meet two names for it (M34 §5.7).
    @Test("the assistant name carries one label in both doors")
    func assistantNameHasOneLabel() throws {
        let personalization = try #require(
            try Self.settingsSections().first { $0.id == AboutYouAnswers.personalizationSection }
        )
        let botName = try #require(personalization.rows.first { $0.key == "bot_name" })

        #expect(botName.label == ProductStrings[.aboutYouAssistantName])
    }

    // MARK: - The schema's own vocabularies

    /// The node budget for one walk of the schema. The schema is a fixed,
    /// checksum-pinned artifact, so this is a guard against a malformed one
    /// rather than a knob: the walk asserts it finished inside the budget.
    private static let maxSchemaNodes = 100_000

    /// Every `enum` of strings anywhere in the vendored schema, as sets. Walked
    /// with an explicit work list rather than recursion, so the bound is one
    /// visible counter.
    private static func publishedEnumerations() throws -> Set<Set<String>> {
        var pending: [Any] = [
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            )
        ]
        var found: Set<Set<String>> = []
        var visits = 0

        while visits < maxSchemaNodes, let node = pending.popLast() {
            visits += 1
            if let object = node as? [String: Any] {
                if let values = object["enum"] as? [String] { found.insert(Set(values)) }
                pending.append(contentsOf: object.values)
            } else if let array = node as? [Any] {
                pending.append(contentsOf: array)
            }
        }

        #expect(pending.isEmpty, "the schema walk stopped at its \(maxSchemaNodes) node budget")
        return found
    }
}
