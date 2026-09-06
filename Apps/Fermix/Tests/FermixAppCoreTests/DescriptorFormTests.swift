import Foundation
import Testing

@testable import FermixAppCore

/// The descriptor form (M34 §7.7).
///
/// The invariant is that one row becomes exactly one control, chosen from the
/// daemon's own kind and bounds. It is asserted over the projection rather than
/// over a view body, because "which control did this row get, and does it
/// honour the step" is a value and a view body is not where it can be read.
@Suite("Descriptor form")
struct DescriptorFormTests {

    /// Every kind the contract publishes resolves to exactly one control, and
    /// no kind resolves to none.
    @Test("each row kind renders exactly one control")
    func eachKindHasOneControl() throws {
        let cases: [(String, String, DescriptorControl)] = [
            ("toggle", "true", .toggle(true)),
            ("text", "\"cedar\"", .text(value: "cedar", prompt: ProductStrings[.settingsTextEmptyPrompt])),
            ("secret", "null", .secret(present: false)),
            ("list", "[\"a\",\"b\"]", .list(["a", "b"]))
        ]

        for (kind, value, expected) in cases {
            let row = try ManagementValueFixture.settingRow(kind: kind, label: "A label", value: value)
            let model = DescriptorRowModel(row: row, value: row.value)

            #expect(model.control == expected, "\(kind)")
        }

        // An empty text row used to prompt with its own label, so `Zoom account
        // id` was drawn twice: once as the row title and once as what looked
        // like its value.
        let empty = try ManagementValueFixture.settingRow(kind: "text", label: "Zoom account id", value: "null")
        guard case .text(_, let prompt) = DescriptorRowModel(row: empty, value: empty.value).control else {
            Issue.record("a text row renders a text control")
            return
        }
        #expect(prompt != "Zoom account id")
        #expect(prompt == ProductStrings[.settingsTextEmptyPrompt])

        let choice = try ManagementValueFixture.settingRow(
            kind: "choice",
            label: "A label",
            value: "\"cedar\"",
            options: [(value: "cedar", label: "Cedar"), (value: "marin", label: "Marin")]
        )
        let choiceModel = DescriptorRowModel(row: choice, value: choice.value)
        #expect(choiceModel.control == .choice(selected: "cedar", options: choice.options))

        let number = try ManagementValueFixture.settingRow(kind: "number", value: "30", step: 5)
        #expect(
            DescriptorRowModel(row: number, value: number.value).control
                == .stepper(value: 30, minimum: nil, maximum: nil, step: 5, measure: NumberMeasure(unit: nil, format: nil))
        )
    }

    /// The six published kinds are exactly the ones with a control, so a kind
    /// added to the engine fails here rather than rendering a guess.
    @Test("every published kind has a control and an unknown kind has a state")
    func publishedKindsAreCovered() throws {
        for kind in ManagementSettingKind.publishedValues.keys {
            let value = Self.sampleValue(for: kind)
            let row = try ManagementValueFixture.settingRow(kind: kind, value: value)

            if case .unsupported = DescriptorRowModel(row: row, value: row.value).control {
                Issue.record("\(kind) has no control")
            }
        }

        let stranger = try ManagementValueFixture.settingRow(kind: "colour_wheel", value: "null")
        #expect(
            DescriptorRowModel(row: stranger, value: stranger.value).control == .unsupported("colour_wheel")
        )

        // And it says the right half of the pair. An unknown kind means the app
        // is older than the daemon, so the newer-engine sentence — which asks
        // for a restart into the engine this bundle ships — was the answer to
        // the opposite condition.
        let sentence = ProductStrings[.settingsRowUnsupported]
        #expect(sentence != ProductStrings[.settingsRequiresNewerEngine])
        #expect(sentence.contains("Update Fermix"))
        #expect(!sentence.contains("Restart"))
    }

    /// Every row is labelled, and the label is the daemon's. A control with no
    /// label is one VoiceOver cannot announce.
    @Test("every row carries the daemon's own label")
    func everyRowIsLabelled() throws {
        for kind in ManagementSettingKind.publishedValues.keys {
            let row = try ManagementValueFixture.settingRow(
                kind: kind,
                label: "A daemon label",
                footer: "Why it matters.",
                value: Self.sampleValue(for: kind)
            )
            let model = DescriptorRowModel(row: row, value: row.value)

            #expect(model.label == "A daemon label", "\(kind)")
            #expect(model.footer == "Why it matters.", "\(kind)")
            #expect(model.key == row.key)
        }
    }

    /// A number row uses the daemon's own step. A slider is offered only where
    /// the bounds and the step suit one, which is what stops a fine step being
    /// snapped on first touch.
    @Test("a number row honours the daemon's step and picks its control from the bounds")
    func numberRowsHonourStep() throws {
        // M34 §5.7's compaction threshold: 90 steps is a stepper, not a slider.
        let threshold = try ManagementValueFixture.settingRow(
            kind: "number",
            value: "0.83",
            min: 0.1,
            max: 1.0,
            step: 0.01,
            format: "percent"
        )
        // A fraction of its own bounds reads off a track, labelled as a
        // percentage: `0.83` is not a setting anybody can act on (M34 §5).
        #expect(
            DescriptorRowModel(row: threshold, value: threshold.value).control
                == .slider(
                    value: 0.83,
                    minimum: 0.1,
                    maximum: 1.0,
                    step: 0.01,
                    measure: NumberMeasure(unit: nil, format: .percent)
                )
        )
        #expect(NumberMeasure(unit: nil, format: .percent).text(0.83, step: 0.01) == "83%")

        // Every other number is a field with a stepper, so a 1-to-240 bound is
        // typed rather than clicked 239 times, and the unit reads beside it.
        let coarse = try ManagementValueFixture.settingRow(
            kind: "number",
            value: "3",
            min: 1,
            max: 10,
            step: 1,
            unit: "minutes",
            format: "minutes"
        )
        #expect(
            DescriptorRowModel(row: coarse, value: coarse.value).control
                == .stepper(
                    value: 3,
                    minimum: 1,
                    maximum: 10,
                    step: 1,
                    measure: NumberMeasure(unit: "minutes", format: .minutes)
                )
        )
        #expect(NumberMeasure(unit: "minutes", format: .minutes).text(3, step: 1) == "3 minutes")

        // An unbounded row keeps its step and gets no slider to drag.
        let open = try ManagementValueFixture.settingRow(kind: "number", value: "12", step: 1)
        #expect(
            DescriptorRowModel(row: open, value: open.value).control
                == .stepper(
                    value: 12,
                    minimum: nil,
                    maximum: nil,
                    step: 1,
                    measure: NumberMeasure(unit: nil, format: nil)
                )
        )

        // Whole cents read as money rather than as a count under a footer.
        #expect(NumberMeasure(unit: nil, format: .currencyCents).text(200, step: 1).contains("2"))
    }

    /// Bounds published the wrong way round are no bounds at all: they are
    /// dropped rather than handed to a `ClosedRange`, which has no defined
    /// behaviour when the lower end sits above the upper one.
    @Test("bounds the daemon published inverted are dropped rather than used")
    func invertedBoundsAreDropped() throws {
        let inverted = try ManagementValueFixture.settingRow(
            kind: "number",
            value: "4",
            min: 10,
            max: 1,
            step: 1
        )
        #expect(
            DescriptorRowModel(row: inverted, value: inverted.value).control
                == .stepper(value: 4, minimum: nil, maximum: nil, step: 1, measure: NumberMeasure(unit: nil, format: nil))
        )

        // One end on its own is still a bound, because it cannot be inverted.
        let floorOnly = try ManagementValueFixture.settingRow(
            kind: "number",
            value: "4",
            min: 1,
            step: 1
        )
        #expect(
            DescriptorRowModel(row: floorOnly, value: floorOnly.value).control
                == .stepper(value: 4, minimum: 1, maximum: nil, step: 1, measure: NumberMeasure(unit: nil, format: nil))
        )
    }

    /// A number row prints at the step's own precision, so a hundredth step
    /// never renders as a whole number.
    @Test("a number row prints at the step's precision")
    func numberFormatting() {
        #expect(NumberRowFormat.text(0.83, step: 0.01) == "0.83")
        #expect(NumberRowFormat.text(30, step: 5) == "30")
        #expect(NumberRowFormat.text(0.5, step: 0.05) == "0.50")
    }

    /// A row the daemon marks read-only is a labelled fact rather than a
    /// control whose save would always refuse (M34 §7.7's parity gate).
    @Test("a read-only row renders as a labelled fact whatever its kind")
    func readOnlyRows() throws {
        for kind in ManagementSettingKind.publishedValues.keys {
            let row = try ManagementValueFixture.settingRow(
                kind: kind,
                value: Self.sampleValue(for: kind),
                readOnly: true
            )

            guard case .readOnly = DescriptorRowModel(row: row, value: row.value).control else {
                Issue.record("a read-only \(kind) row rendered a control")
                continue
            }
        }
    }

    /// A value the wire carries as null is no value, not an empty string: a
    /// choice with nothing selected has to be distinguishable from one whose
    /// selection is the empty string.
    @Test("an absent value reads as nothing chosen")
    func absentValues() {
        #expect(DescriptorValue.optional(.absent) == nil)
        #expect(DescriptorValue.text(.absent).isEmpty)
        #expect(DescriptorValue.list(.absent).isEmpty)
        #expect(DescriptorValue.flag(.absent) == false)
        #expect(DescriptorValue.number(.absent) == 0)
    }

    /// A value that matches its kind is read at that kind's type.
    @Test("each value reads at the type its control needs")
    func valueReadings() {
        #expect(DescriptorValue.flag(.flag(true)))
        #expect(DescriptorValue.number(.number(0.25)) == 0.25)
        #expect(DescriptorValue.list(.list(["a"])) == ["a"])
        #expect(DescriptorValue.text(.text("cedar")) == "cedar")
        #expect(DescriptorValue.optional(.number(30)) == "30")
    }

    private static func sampleValue(for kind: String) -> String {
        switch kind {
        case "toggle": return "true"
        case "number": return "1"
        case "list": return "[\"a\"]"
        case "secret": return "null"
        default: return "\"a value\""
        }
    }
}

/// The descriptor coverage gate (M34 §8).
///
/// Two directions. Every key Swift binds by name has to exist in the vendored
/// fixture — and the app binds none, which is the stronger form of M34 §7.7's
/// "the app supplies no field inventory". Every key the fixture publishes has to
/// be rendered by a control or sit on an explicit deferred list.
/// The external-change refusal, at the surface (M34 §7.6).
@Suite("Write gate")
@MainActor
struct SettingsWriteGateTests {
    /// A view that writes a settings key must also gate on the refusal.
    ///
    /// `SettingsModel.apply` returns without writing while `config_state` is
    /// `external_change`, and it answers nothing: a control that is left enabled
    /// therefore moves and snaps back, which reads as a bug rather than as the
    /// refusal the banner above it is explaining. The set of files is derived
    /// from the calls themselves, so a pane that starts writing tomorrow either
    /// gates or fails here.
    @Test("every settings view that applies a key is disabled while writes are blocked")
    func writingViewsGateOnTheRefusal() throws {
        let writers = try SourceTree.swiftFiles(matching: "Settings/")
            .filter { $0.text.contains("model.apply(") }

        #expect(writers.count >= 4, "the scan found \(writers.count) writing views")
        for file in writers {
            #expect(
                file.text.contains("writesBlocked"),
                "\((file.path as NSString).lastPathComponent) writes a key and never names the refusal"
            )
        }
    }
}

@Suite("Descriptor coverage")
struct DescriptorCoverageTests {
    /// Every `settings.get` row the vendored contract publishes.
    /// One section's published rows, by section id.
    static func rows(inSection id: String) throws -> [ManagementSettingRow] {
        try ManagementFixtures.load(.success, from: .management)
            .filter { (try? $0.string("method")) == ManagementMethod.settingsGet.rawValue }
            .compactMap { fixture -> ManagementSettingsSectionRows? in
                guard let result = try? fixture.object("response")["result"] else { return nil }

                return try? JSONDecoder().decode(
                    ManagementSettingsSectionRows.self,
                    from: try JSONSerialization.data(withJSONObject: result)
                )
            }
            .first { $0.id == id }?
            .rows ?? []
    }

    static func fixtureRows() throws -> [ManagementSettingRow] {
        try ManagementFixtures.load(.success, from: .management)
            .filter { (try? $0.string("method")) == ManagementMethod.settingsGet.rawValue }
            .flatMap { fixture -> [ManagementSettingRow] in
                guard let result = try fixture.object("response")["result"] else { return [] }

                let rows = try JSONDecoder().decode(
                    ManagementSettingsSectionRows.self,
                    from: try JSONSerialization.data(withJSONObject: result)
                )
                return rows.rows
            }
    }

    /// The one key family Swift binds by name, checked against what the daemon
    /// actually publishes (M34 §7.7).
    ///
    /// The gate this replaces asserted an empty set was empty, which passed with
    /// the feature deleted *and* while `ChannelsPane` was already constructing
    /// `<channel>_enabled` by name. What the gate has to prove is that the one
    /// declared family resolves: for every channel `setup.state.get` publishes,
    /// that channel's own section carries a toggle under the key the pane
    /// builds. A channel whose section renames the key fails here rather than
    /// drawing a switch whose write the daemon refuses.
    @Test("the one bound key family resolves for every published channel")
    func boundKeysResolve() throws {
        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let channels = state.channels.map(\.name)
        #expect(!channels.isEmpty, "the contract publishes no channels to check")

        #expect(SettingsBinding.boundKeys == [
            "<channel>_enabled", "harness_approved", "harness_default_vendor", "meetings_enabled"
        ])

        for channel in channels {
            let section = ChannelRowProjection.sectionId(for: channel)
            guard let rows = try? Self.rows(inSection: section) else {
                Issue.record("\(section) publishes no rows")
                continue
            }
            let key = ChannelRowProjection.enabledKey(for: channel)
            guard let toggle = rows.first(where: { $0.key == key }) else {
                Issue.record("\(section) carries no \(key) row for the pane's switch")
                continue
            }

            #expect(toggle.kind == .toggle, "\(key) is not a toggle")
        }

        #expect(SettingsBinding.boundKeys(forChannels: channels).count == channels.count + 3)
    }

    @Test("coding capability controls bind to the published consent and preferred-tool rows")
    func codingBindingsResolve() throws {
        let rows = try Self.rows(inSection: "harness")
        let expected: [String: ManagementSettingKind] = [
            SettingsBinding.codingConsent: .toggle,
            SettingsBinding.codingPreference: .choice
        ]

        for (key, kind) in expected {
            #expect(SettingsBinding.boundKeys.contains(key))
            #expect(rows.first { $0.key == key }?.kind == kind, "\(key) must resolve to its descriptor")
        }
    }

    /// Every key the fixture publishes is rendered, or explicitly deferred.
    @Test("every fixture row is bound or explicitly deferred")
    func everyFixtureRowIsBound() throws {
        let rows = try Self.fixtureRows()
        #expect(!rows.isEmpty, "the contract publishes no settings rows to check")

        for row in rows {
            guard !SettingsBinding.deferredKeys.contains(row.key) else { continue }

            let control = DescriptorRowModel(row: row, value: row.value).control
            if case .unsupported(let kind) = control {
                Issue.record("\(row.key) has kind \(kind), which no control renders")
            }
        }
    }

    /// Six kinds, and no seventh. An `action` kind — a row that is a button
    /// rather than a value — is not in the schema and not in this build: a row
    /// the app rendered as a button would be a control with no key to write.
    @Test("the published row kinds are the six this build renders, and action is not one")
    func actionIsNotARowKind() throws {
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            ) as? [String: Any]
        )
        let defs = try #require(document["$defs"] as? [String: Any])
        let row = try #require(defs["settingsRow"] as? [String: Any])
        let properties = try #require(row["properties"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let published = Set(try #require(kind["enum"] as? [String]))

        #expect(published == Set(ManagementSettingKind.publishedValues.keys))
        #expect(published == ["toggle", "choice", "text", "number", "secret", "list"])
        #expect(!published.contains("action"))
    }

    /// Every row says whether changing it needs a restart, and a *reason* names
    /// a section rather than a row: the daemon compares whole sections, so the
    /// banner says which section is waiting and never which control was
    /// touched. Both halves are asserted, because a section whose rows all
    /// agreed would let a per-row reading pass by accident.
    @Test("a restart flag is per row and a restart reason names a section")
    func restartIsFlaggedPerRowAndReasonedPerSection() throws {
        var sections = 0
        var mixed: [String] = []

        for fixture in try ManagementFixtures.load(.success, from: .management)
        where (try? fixture.string("method")) == ManagementMethod.settingsGet.rawValue {
            let result = try #require(try fixture.object("response")["result"])
            let rows = try JSONDecoder().decode(
                ManagementSettingsSectionRows.self,
                from: try JSONSerialization.data(withJSONObject: result)
            )

            #expect(!rows.rows.isEmpty, "\(rows.id) has no rows")
            if Set(rows.rows.map(\.restart)).count > 1 { mixed.append(rows.id) }
            for row in rows.rows {
                #expect(DescriptorRowModel(row: row, value: row.value).restart == row.restart)
            }
            sections += 1
        }

        #expect(sections == 25)
        #expect(!mixed.isEmpty, "no section mixes the two, so the flag reads as section-wide")

        let state: ManagementSetupState = try FakeDaemonGateway.fixtureResult(
            named: "setup_state_get",
            as: ManagementSetupState.self
        )
        let published = Set(
            try FakeDaemonGateway.fixtureResult(
                named: "settings_sections",
                as: ManagementSettingsInventory.self
            ).sections.map(\.id)
        )

        #expect(!state.restart.reasons.isEmpty)
        for reason in state.restart.reasons {
            #expect(!reason.sentence.isEmpty, "\(reason.section) carries no sentence")
            #expect(
                published.contains(reason.section) || reason.section == "providers",
                "\(reason.section) is neither a section nor a published family"
            )
        }
    }

    /// The three backend sections publish the key row of the backend in force,
    /// never one row per backend that exists. So the app renders the rows it is
    /// handed: a fixed set in Swift would draw a Tavily key against a Brave
    /// backend, and hide a Google one the moment it is selected.
    @Test("a backend section's key rows are whatever the daemon handed over")
    func backendKeyRowsAreTheDaemons() throws {
        let published: [String: Set<String>] = [
            "web_search": ["web_search_backend", "brave_api_key"],
            "generate_image": ["image_backend", "image_model", "openai_api_key"],
            "transcription": ["transcription_backend", "transcription_model", "transcription_openai_api_key"]
        ]

        for (section, keys) in published {
            let rows = try Self.rows(inSection: section)

            #expect(Set(rows.map(\.key)) == keys, "\(section)")
            for row in rows {
                if case .unsupported(let kind) = DescriptorRowModel(row: row, value: row.value).control {
                    Issue.record("\(section).\(row.key) has kind \(kind), which no control renders")
                }
            }
        }

        // The keys a fixed set in Swift would have insisted on. They are absent
        // here because a different backend is selected, and present the moment
        // one is.
        let searchKeys = Set(try Self.rows(inSection: "web_search").map(\.key))
        let imageKeys = Set(try Self.rows(inSection: "generate_image").map(\.key))

        #expect(!searchKeys.contains("tavily_api_key"))
        #expect(!imageKeys.contains("google_api_key"))
    }

    /// The OpenAI API-key provider carries a reasoning effort like the other
    /// reasoning providers. It arrives as a descriptor row, so it renders with
    /// no Swift beyond the form: this is the case that proves it.
    @Test("the openai provider's reasoning effort renders through the descriptor form")
    func openAIReasoningEffortRenders() throws {
        let rows = try Self.rows(inSection: "providers.openai")
        let effort = try #require(rows.first { $0.key == "reasoning_effort" })

        #expect(effort.kind == .choice)
        #expect(!effort.options.isEmpty)
        guard case .choice(_, let options) = DescriptorRowModel(row: effort, value: effort.value).control
        else {
            Issue.record("reasoning_effort does not render as a choice")
            return
        }

        #expect(options.map(\.value) == effort.options.map(\.value))
    }

    /// The kinds the fixture exercises are the kinds the schema publishes, so
    /// the gate above is not passing because the fixture is thin.
    @Test("the fixture exercises every published row kind")
    func fixtureCoversEveryKind() throws {
        let exercised = Set(try Self.fixtureRows().compactMap { row -> String? in
            ManagementSettingKind.publishedValues.first { $0.value == row.kind }?.key
        })

        #expect(exercised == SettingsBinding.renderedKinds)
        #expect(SettingsBinding.renderedKinds.count == 6)
    }

    /// The daemon writes every label on a settings row, and this window draws
    /// them beside the app's own catalogue, so the two have to share one
    /// dialect: mixed, they read as two writers on one pane — `Model behaviour`
    /// and `Summarise with` above a catalogue that says `authorize` and
    /// `Minimize`.
    ///
    /// The case set is every label, footer and option the contract publishes,
    /// so a row added upstream joins the rule rather than escaping it.
    @Test("every label the contract publishes is written in the app's own dialect")
    func publishedLabelsShareTheAppDialect() throws {
        let british = [
            "behaviour", "catalogue", "colour", "organis", "summaris", "customis",
            "recognis", "personalis", "optimis", "analys", "licence", "favourite"
        ]

        var phrases: [String] = []
        for row in try Self.fixtureRows() {
            phrases.append(row.label)
            row.footer.map { phrases.append($0) }
            phrases.append(contentsOf: row.options.map(\.label))
        }

        #expect(!phrases.isEmpty)
        for phrase in phrases {
            for spelling in british {
                #expect(!phrase.lowercased().contains(spelling), "\(phrase) is written in British English")
            }

            let words = phrase.split { !$0.isLetter && !$0.isNumber }
            #expect(!words.contains("id"), "\(phrase) spells ID in lower case")
            #expect(!words.contains("Id"), "\(phrase) spells ID as a word")
        }
    }

    /// A section the inventory publishes names a pane this build knows, so the
    /// sidebar and the daemon's section list agree by construction.
    @Test("every published section names a pane the sidebar has")
    func sectionsNameKnownPanes() throws {
        let inventory: ManagementSettingsInventory = try FakeDaemonGateway.fixtureResult(
            named: "settings_sections",
            as: ManagementSettingsInventory.self
        )

        #expect(!inventory.sections.isEmpty)
        for section in inventory.sections {
            #expect(SettingsPane.pane(for: section.pane) != nil, "\(section.id)")
            #expect(!section.title.isEmpty, "\(section.id)")
        }
    }
}
