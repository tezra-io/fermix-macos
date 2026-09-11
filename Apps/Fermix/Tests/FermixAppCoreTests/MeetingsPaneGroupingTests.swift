import Foundation
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

/// The notetaker's Google sign-in, as the daemon publishes it.
///
/// Nothing on the wire said the sign-in had happened, so the pane kept offering
/// the idle control after a successful one. The `meetbot` row of `setup.detect`
/// now carries `signed_in` beside its detail, and the pane switches on that
/// fact while rendering that sentence: whether a browser profile holds a Google
/// session is the one notetaker fact no client can read for itself, and the
/// words of a sentence are not a state to switch on.
@Suite("Meetings notetaker sign-in")
struct MeetingsNotetakerSignInTests {
    /// The signed-in state, from the contract's own golden rather than from a
    /// literal this test wrote. Its sentence becomes the account row's value,
    /// and nothing is left under the control: the state is stated once.
    @Test("the golden's signed-in row states the account and leaves the control bare")
    func aSignedInRowStatesTheAccount() throws {
        let published = try #require(
            try ManagementValueFixture.detections().result(for: .meetbot),
            "the setup_detect golden carries no meetbot row"
        )

        #expect(published.present)
        #expect(published.signedIn == true)

        let state = NotetakerSignIn(detection: published).state

        #expect(state == .signedIn(sentence: published.detail))
        #expect(state.accountSentence == "Signed in to Google")
        #expect(state.pendingSentence == nil)
    }

    /// Not signed in: the daemon's sentence is the reason to press the control,
    /// so it sits under it and there is no account row to draw.
    @Test("a not-signed-in row puts the daemon's sentence under the control")
    func aNotSignedInRowExplainsWhyToPressIt() throws {
        let row = try Self.row(present: true, signedIn: "false", detail: "\"Not signed in to Google\"")
        let state = NotetakerSignIn(detection: row).state

        #expect(state == .notSignedIn(sentence: "Not signed in to Google"))
        #expect(state.pendingSentence == "Not signed in to Google")
        #expect(state.accountSentence == nil)
    }

    /// Three ways to have no answer, and the app invents a state for none of
    /// them: a probe still out or refused reaches the projection as no
    /// detection at all, an absent notetaker has nothing to be signed in to,
    /// and a present row whose fact the daemon left null is a row this engine
    /// does not publish, which must still not take the pane down.
    @Test("an unanswered probe, an absent notetaker and a null fact all render nothing extra")
    func nothingIsInvented() throws {
        let states = [
            NotetakerSignIn(detection: nil).state,
            NotetakerSignIn(detection: try Self.row(present: false)).state,
            NotetakerSignIn(detection: try Self.row(present: true)).state
        ]

        for state in states {
            #expect(state == .unanswered)
            #expect(state.accountSentence == nil)
            #expect(state.pendingSentence == nil)
        }
    }

    /// The guard is on the published facts, not on the detail: a not-present
    /// row is never read as a sign-in, whatever its sentence says.
    @Test("a not-present row is never read as signed in")
    func aNotPresentRowIsNeverSignedIn() throws {
        let row = try Self.row(present: false, signedIn: "true", detail: "\"Signed in to Google\"")

        #expect(row.detail == "Signed in to Google")
        #expect(NotetakerSignIn(detection: row).state == .unanswered)
    }

    /// The control stays offered in every state, because the run behind it, its
    /// progress, its Cancel and the sentence a failed run leaves are how an
    /// account is changed. Only its word moves, and it moves with the state
    /// rather than with the sentence, which is why the projection yields a case.
    @Test("the control's word comes from the state and never from the sentence")
    func theActionTitleComesFromTheState() throws {
        let signedIn = try Self.row(present: true, signedIn: "true", detail: "\"Signed in to Google\"")
        let waiting = try Self.row(present: true, signedIn: "false", detail: "\"Not signed in to Google\"")

        #expect(
            NotetakerSignIn(detection: signedIn).state.actionTitleKey
                == .settingsMeetingsSignInAgainAction
        )
        #expect(
            NotetakerSignIn(detection: waiting).state.actionTitleKey
                == .settingsMeetingsSignInAction
        )
        #expect(
            NotetakerSignIn(detection: nil).state.actionTitleKey == .settingsMeetingsSignInAction
        )
    }

    /// Both new words are the app's own: the label names a thing in this pane
    /// and the second verb names a different act. Neither reports a state,
    /// which stays the daemon's sentence beside them.
    @Test("the app-authored label and second verb follow the copy rules")
    func theAppAuthoredWordsFollowTheCopyRules() {
        let label = ProductStrings[.settingsMeetingsGoogleAccountLabel]
        let again = ProductStrings[.settingsMeetingsSignInAgainAction]

        #expect(ProductCopyRules.violations(in: label).isEmpty)
        #expect(ProductCopyRules.violations(in: again).isEmpty)
        #expect(again != ProductStrings[.settingsMeetingsSignInAction])
        #expect(
            again.hasSuffix("\u{2026}"),
            "the second verb opens the same window and ends the same way as the first"
        )
    }

    /// Through the model, which is where the pane reads it: no answer before
    /// the probe has answered, the daemon's own state once it has.
    @Test("the pane has no answer before the probe answers and the daemon's after")
    @MainActor
    func theLoadedDetectionCarriesThePaneState() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        #expect(Self.state(in: model) == .unanswered)

        await model.refreshNotetakerState()

        #expect(Self.state(in: model) == .signedIn(sentence: "Signed in to Google"))
    }

    /// Both jobs on the pane change the sign-in state, and the read that
    /// follows either of them asks about the one row that carries it. A probe
    /// that swept in the harness vendors or the provider targets would be work
    /// nothing on this pane renders.
    @Test("finishing the sign-in re-reads the notetaker row and no other target")
    @MainActor
    func finishingTheSignInRefreshesOnlyTheNotetaker() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let signIn = model.makeJobRunner()

        await model.startMeetingsSignIn(on: signIn)
        #expect(signIn.completed)

        #expect(gateway.detectedTargets == [[.meetbot]])
        let started = try #require(gateway.calls.firstIndex(of: .v2(.meetingsSigninStart)))
        let probed = try #require(gateway.calls.lastIndex(of: .v2(.setupDetect)))
        #expect(started < probed, "the notetaker was probed before its sign-in ran")
    }

    /// The pane reads once, on appearance. The end of a run is the model's to
    /// notice, as the owner of the run: a view watching the runner flip reads
    /// only when it happens to observe the flip.
    @Test("the pane reads on appearance and leaves the end of a run to the model")
    func thePaneReadsOnAppearanceOnly() throws {
        let text = try #require(
            try SourceTree.swiftFiles(matching: "Settings/Panes/SettingsPaneView.swift").first?.text
        )

        #expect(text.contains(".task { await model.refreshNotetakerState() }"))
        #expect(!text.contains(".onChange(of: install.isRunning"))
        #expect(
            !text.contains("refreshDetections([.meetbot])"),
            "the pane names the target itself instead of asking through the model"
        )
    }

    /// Enabling installs the notetaker before it writes the flag, and the
    /// install is what puts the notetaker on this Mac: the detection is
    /// re-read once that run ends, before the flag is written.
    @Test("finishing the install refreshes the notetaker before the flag is written")
    @MainActor
    func finishingTheInstallRefreshesTheNotetaker() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let install = model.makeJobRunner()

        await model.setMeetingsEnabled(true, on: install)

        #expect(gateway.detectedTargets == [[.meetbot]])
        let installed = try #require(gateway.calls.firstIndex(of: .v2(.capabilitiesInstallStart)))
        let probed = try #require(gateway.calls.lastIndex(of: .v2(.setupDetect)))
        #expect(installed < probed, "the notetaker was probed before its install ran")
    }

    @MainActor
    private static func state(in model: SettingsModel) -> NotetakerSignIn.State {
        NotetakerSignIn(detection: model.detections.value?.result(for: .meetbot)).state
    }

    /// One hand-made row. Both facts are written as JSON literals so a null is
    /// expressible: null is what the daemon sends for a notetaker that is not
    /// there, and the case the pane must survive.
    private static func row(
        present: Bool,
        signedIn: String = "null",
        detail: String = "null"
    ) throws -> ManagementDetection {
        try JSONDecoder().decode(ManagementDetection.self, from: Data("""
        {"target":"meetbot","present":\(present),"detail":\(detail),
         "signed_in":\(signedIn),"vendors":null,"guidance":null}
        """.utf8))
    }
}
