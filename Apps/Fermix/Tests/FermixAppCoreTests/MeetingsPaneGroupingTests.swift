import Testing

@testable import FermixAppCore

@Suite("Meetings settings grouping")
struct MeetingsPaneGroupingTests {
    @Test("shared controls precede Google Meet, then Zoom")
    func sectionOrder() {
        #expect(MeetingsSettingsSection.allCases == [.shared, .googleMeet, .zoom])
    }

    @Test("Zoom credentials never appear as shared or Google Meet requirements")
    func credentialsBelongOnlyToZoom() throws {
        let rows = try DescriptorCoverageTests.rows(inSection: "meetings")
        let zoom = MeetingsSettingsSection.zoom.rows(from: rows)
        let shared = MeetingsSettingsSection.shared.rows(from: rows)

        #expect(zoom.map(\.key) == [
            "meetings_zoom_account_id", "meetings_zoom_client_id",
            "meetings_zoom_client_secret", "meetings_zoom_ws_subscription_id"
        ])
        #expect(!shared.contains { $0.key.hasPrefix("meetings_zoom_") })
        #expect(MeetingsSettingsSection.googleMeet.rows(from: rows).isEmpty)
        #expect(zoom.first { $0.key == "meetings_zoom_client_secret" }?.kind == .secret)
    }

    @Test("grouping keeps every published key, value, option and restart rule exactly once")
    func allPublishedSettingsRemainIntact() throws {
        let rows = try DescriptorCoverageTests.rows(inSection: "meetings")
        let grouped = MeetingsSettingsSection.allCases.flatMap { $0.rows(from: rows) }
        #expect(grouped.sorted { $0.key < $1.key } == rows.sorted { $0.key < $1.key })
        let shared = MeetingsSettingsSection.shared.rows(from: rows)
        #expect(shared.contains { $0.key == "meetings_enabled" })
        #expect(shared.contains { $0.key == "meetings_transcription_backend" })
    }
}

/// The marks on the Meetings pane's platform sections.
///
/// Two of the three sections are about one vendor each, and redline section 5.8
/// puts that vendor's mark on a surface that is about it. The third is the
/// settings both platforms share, so it is about neither and carries none: a
/// mark there would name one of the two platforms over settings that serve both.
@Suite("Meetings platform marks")
struct MeetingsPlatformMarkTests {
    @Test("the two platform sections resolve their marks and the shared section does not")
    func sectionsResolveTheirMarks() throws {
        #expect(MeetingsSettingsSection.shared.markKey == nil)

        for section in [MeetingsSettingsSection.googleMeet, .zoom] {
            let key = try #require(
                section.markKey, "\(section.rawValue) is about one platform and names none"
            )
            let mark = try #require(
                VendorMarks.mark(.meetingPlatform, key), "\(key) is not in the mark table"
            )

            // One of exactly two treatments, the second being the vendor's text
            // name beside the neutral symbol where nothing official could be
            // retrieved. The header draws the name either way.
            #expect(
                mark.asset(dark: false) != nil || mark.treatment == .textWithSymbol,
                "\(key) draws neither a recorded file nor the text fallback"
            )
        }
    }

    /// The header speaks the platform's name, and that name is the label the
    /// provenance record carries for the key. Two spellings of one vendor's name
    /// is how a mark ends up announced as something it is not.
    @Test("each platform section is titled with the label its record carries")
    func sectionTitlesAreTheRecordedLabels() throws {
        let recorded = try VendorMarkTests.marks().filter { $0["kind"] as? String == "meeting_platform" }

        for section in [MeetingsSettingsSection.googleMeet, .zoom] {
            let key = try #require(section.markKey)
            let entry = try #require(
                recorded.first { $0["key"] as? String == key }, "\(key) has no record"
            )

            #expect(section.title == entry["accessibility_label"] as? String, "\(key)")
        }
    }

    /// Drawn through the one component that reads the provenance record, at the
    /// one measure settings marks take, from the section header rather than from
    /// a row: the first row of each platform section is a shared job row and a
    /// daemon-published descriptor row, neither of which is about a vendor.
    @Test("the pane draws its platform marks through the recorded table")
    func thePaneDrawsRecordedMarks() throws {
        let text = try #require(
            try SourceTree.swiftFiles(matching: "Settings/Panes/SettingsPaneView.swift").first?.text
        )

        #expect(text.contains("VendorMarks.mark(.meetingPlatform, key)"))
        #expect(text.contains("size: SettingsRowMetrics.markSize"))
        #expect(text.contains("MeetingsSectionHeader(section: section)"))
    }
}

/// The switch that heads the Meetings pane (M34 §5.4).
///
/// The notetaker and its browser have to be on this Mac before the daemon's
/// flag means anything, so turning the switch on runs the install first and
/// writes only once that job has finished. The owner saw the previous shape:
/// a standalone `Install` link in the Google Meet section that nothing on the
/// page explained.
@Suite("Meetings installs on first enable")
@MainActor
struct MeetingsInstallOnEnableTests {
    /// The order is the whole point: the write is what turns the feature on,
    /// and a feature turned on over a notetaker that is not there is a switch
    /// that reads on and answers nothing.
    @Test("turning it on installs first and writes only after the job completes")
    func enableInstallsBeforeItWrites() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()

        await model.setMeetingsEnabled(true, on: runner)

        let install = try #require(gateway.calls.firstIndex(of: .v2(.capabilitiesInstallStart)))
        let write = try #require(gateway.calls.firstIndex(of: .v2(.settingsApply)))

        #expect(install < write, "the write went out before the notetaker was there")
        #expect(runner.completed)
        #expect(gateway.appliedSettings == [
            SettingsWrite(
                section: SettingsBinding.meetingsSection,
                values: [SettingsBinding.meetingsEnabled: .flag(true)]
            )
        ])
    }

    /// A refused install writes nothing and says why, in the daemon's own
    /// sentence, under the switch it was flicked on.
    @Test("a failed install never writes")
    func aFailedInstallNeverWrites() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()
        gateway.jobScript = [
            try ManagementValueFixture.job(
                kind: "capability_install",
                status: "failed",
                phase: "verifying",
                failure: (code: "unavailable", sentence: "The install did not finish: :enospc.")
            )
        ]

        await model.setMeetingsEnabled(true, on: runner)

        #expect(gateway.appliedSettings.isEmpty, "a feature was turned on over a failed install")
        #expect(runner.failure == "The install did not finish: :enospc.")
        #expect(!runner.completed)
        #expect(
            model.value(of: try Self.enableRow(), in: SettingsBinding.meetingsSection) == .flag(false),
            "the switch stayed where the install left it"
        )
    }

    /// A cancelled run is not a finished one. The daemon reports the status and
    /// the switch goes back to where it was.
    @Test("a cancelled install never writes")
    func aCancelledInstallNeverWrites() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()
        gateway.jobScript = [
            try ManagementValueFixture.job(kind: "capability_install", status: "cancelled", phase: nil)
        ]

        await model.setMeetingsEnabled(true, on: runner)

        #expect(runner.job?.status == .cancelled)
        #expect(!runner.completed)
        #expect(gateway.appliedSettings.isEmpty)
        #expect(
            model.value(of: try Self.enableRow(), in: SettingsBinding.meetingsSection) == .flag(false)
        )
    }

    /// Turning it off asks for nothing and installs nothing: it is the plain
    /// write every other switch in the app makes.
    @Test("turning it off writes directly")
    func disableWritesDirectly() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        await model.setMeetingsEnabled(false, on: model.makeJobRunner())

        #expect(!gateway.calls.contains(.v2(.capabilitiesInstallStart)))
        #expect(gateway.appliedSettings == [
            SettingsWrite(
                section: SettingsBinding.meetingsSection,
                values: [SettingsBinding.meetingsEnabled: .flag(false)]
            )
        ])
    }

    /// The one key this pane binds by name, checked against what the daemon
    /// publishes rather than against a spelling written twice.
    @Test("the switch binds to the toggle the daemon publishes")
    func theSwitchBindsToThePublishedToggle() throws {
        let rows = try DescriptorCoverageTests.rows(inSection: SettingsBinding.meetingsSection)
        let toggle = try #require(rows.first { $0.key == SettingsBinding.meetingsEnabled })

        #expect(toggle.kind == .toggle)
        #expect(SettingsBinding.boundKeys.contains(SettingsBinding.meetingsEnabled))
    }

    /// The footer is the app's own sentence, from the design, because it
    /// describes a gesture this app performs: the daemon's own footer for that
    /// row describes the feature and says nothing about the first enable
    /// downloading anything.
    @Test("the switch footer is the app's own sentence and says what the first enable costs")
    func theFooterIsTheAppsOwnSentence() throws {
        let toggle = try Self.enableRow()
        let footer = ProductStrings[.settingsMeetingsEnableFooter]

        #expect(toggle.footer != footer)
        #expect(footer.contains("150 MB"), "the sentence never says what is downloaded")
        #expect(ProductCopyRules.violations(in: footer).isEmpty)
    }

    /// There is no second door. The engine's install is idempotent, so the
    /// switch is the whole of it and the standalone row that used to sit in the
    /// Google Meet section is gone, along with its string.
    @Test("no standalone install row and no string for one")
    func theStandaloneInstallRowIsGone() throws {
        let files = try SourceTree.swiftFiles(matching: "Settings/Panes/SettingsPaneView.swift")
        let text = try #require(files.first?.text)
        let catalogue = try ProductStringsFixture.shippedCatalogue()

        #expect(catalogue["settings.meetings.installTitle"] == nil)
        #expect(!text.contains("settingsMeetingsInstallTitle"))
        // The sign-in row stays: it is the one thing on that section a person
        // still has to do.
        #expect(text.contains("settingsMeetingsSignInAction"))
    }

    private static func enableRow() throws -> ManagementSettingRow {
        let rows = try DescriptorCoverageTests.rows(inSection: SettingsBinding.meetingsSection)

        return try #require(rows.first { $0.key == SettingsBinding.meetingsEnabled })
    }
}
