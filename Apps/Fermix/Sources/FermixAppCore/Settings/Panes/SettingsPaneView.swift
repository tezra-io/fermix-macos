import SwiftUI

/// Which view draws which pane (M34 §5).
///
/// Simple panes render the daemon's descriptors directly. Panes with flows or
/// detected capabilities compose those same rows with native controls.
struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming

    var body: some View {
        switch pane {
        case .providers:
            ProvidersPane(model: model)
        case .channels:
            ChannelsPane(model: model)
        case .integrations:
            // A Features row opens the pane that owns its switch, which is a
            // pane change inside this presentation and not a route.
            IntegrationsPane(model: model) { pane in model.selectedPane = pane }
        case .computer:
            ComputerPane(model: model)
        case .permissions:
            PermissionsPane(model: model)
        case .voice:
            VoicePane(model: model)
        case .meetings:
            MeetingsPane(model: model)
        case .codingAgents:
            CodingAgentsPane(model: model)
        case .personality, .memory, .search, .images, .sandbox:
            DescriptorPane(pane: pane, model: model)
        }
    }
}

/// A pane that is exactly its daemon-published sections, plus whatever the
/// surface adds after them.
struct DescriptorPane<Extra: View>: View {
    let pane: SettingsPane
    @ObservedObject var model: SettingsModel
    @ViewBuilder var extra: Extra

    var body: some View {
        SettingsPaneForm(title: pane.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                DescriptorForm(model: model, sections: model.sections(for: pane))
                extra
            }
        }
    }
}

extension DescriptorPane where Extra == EmptyView {
    init(pane: SettingsPane, model: SettingsModel) {
        self.init(pane: pane, model: model, extra: { EmptyView() })
    }
}

/// The one state a v2 surface renders against a daemon that cannot serve it
/// (M34 §7.1). Never an error, never an empty pane.
///
/// The sentence is the model's, because there are two of them and only the
/// model knows which: a daemon behind the bundle takes the restart that applies
/// the bundled engine, and a daemon that already is the bundled engine takes
/// neither the restart nor the promise of one.
struct NewerEngineSection: View {
    let sentence: String

    var body: some View {
        Section {
            NewerEngineNotice(sentence: sentence)
        }
    }
}

/// The same state without a box of its own, for a pane that keeps rows this
/// process can still answer for beside the ones it cannot.
struct NewerEngineNotice: View {
    let sentence: String

    var body: some View {
        Text(sentence)
            .fermixType(Typography.style(.bodyCompact))
            .foregroundStyle(Palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Voice: the two switch-headed descriptor sections, plus the one capability
/// this pane can install (M34 §5.3).
struct VoicePane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionLedger
    @StateObject private var install: JobRunner
    @StateObject private var grant: JobRunner

    init(model: SettingsModel) {
        self.model = model
        self.permissions = model.permissions
        _install = StateObject(wrappedValue: model.makeJobRunner())
        _grant = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        DescriptorPane(pane: .voice, model: model) {
            Section(ProductStrings[.settingsVoiceLocalSection]) {
                JobRow(
                    title: ProductStrings[.settingsVoiceLocalTitle],
                    actionTitle: ProductStrings[.settingsInstall],
                    kind: .capabilityInstall,
                    runner: install
                ) {
                    await model.startCapabilityInstall(.localSTT, on: install)
                }
            }

            // The microphone right, from the one ledger (M34 §5.9), so this
            // pane and Permissions cannot disagree about it. Reading it prompts
            // nothing; the row's own button is the only thing that does.
            Section(ProductStrings[.settingsVoiceMicrophoneSection]) {
                if let row = permissions.row(.microphone) {
                    PermissionRow(row: row, permissions: permissions, model: model, grant: grant)
                }
            }
        }
        .onAppear { permissions.refreshLocalRights() }
    }
}

enum MeetingsSettingsSection: String, CaseIterable, Identifiable {
    case shared, googleMeet, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shared: return ProductStrings[.settingsMeetingsSharedSection]
        case .googleMeet: return ProductStrings[.settingsMeetingsGoogleSection]
        case .zoom: return ProductStrings[.settingsMeetingsZoomSection]
        }
    }

    /// The vendor whose mark heads this section, where the section is about
    /// one. The shared settings are about both platforms, so they carry none:
    /// a mark belongs where a surface is about a single vendor.
    var markKey: String? {
        switch self {
        case .shared: return nil
        case .googleMeet: return "google_meet"
        case .zoom: return "zoom"
        }
    }

    func rows(from published: [ManagementSettingRow]) -> [ManagementSettingRow] {
        guard self != .googleMeet else { return [] }

        return published.filter { $0.key.hasPrefix("meetings_zoom_") == (self == .zoom) }
    }
}

/// A Meetings section header: the platform's own mark before the section name.
///
/// Redline section 5.8 sizes every settings mark at `SettingsRowMetrics.markSize`
/// and names no separate measure for a section, so a section takes the same 20
/// the rows under it take. The mark is decorative, as it is everywhere else: the
/// header speaks the platform's name, which is the accessibility label the
/// provenance record carries for that key.
struct MeetingsSectionHeader: View {
    let section: MeetingsSettingsSection

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let key = section.markKey {
                VendorMarkView(
                    mark: VendorMarks.mark(.meetingPlatform, key),
                    kind: .meetingPlatform,
                    size: SettingsRowMetrics.markSize
                )
            }

            Text(section.title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
    }
}

/// Shared meeting controls, followed by Google Meet setup and Zoom credentials.
/// Both platforms keep the same engine settings and shared enable switch.
struct MeetingsPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var install: JobRunner
    @StateObject private var signIn: JobRunner

    init(model: SettingsModel) {
        self.model = model
        _install = StateObject(wrappedValue: model.makeJobRunner())
        _signIn = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        SettingsPaneForm(title: SettingsPane.meetings.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                enableSwitch

                ForEach(MeetingsSettingsSection.allCases) { section in
                    Section {
                        if section == .googleMeet {
                            googleMeetControls
                        } else {
                            descriptorRows(section)
                        }
                    } header: {
                        MeetingsSectionHeader(section: section)
                    }
                }
            }
        }
        // The sign-in state is the daemon's. It is read when the pane opens;
        // the two jobs that change it re-read it themselves when they end.
        .task { await model.refreshNotetakerState() }
    }

    /// The switch that heads the pane, in its own untitled section, above every
    /// setting it turns on.
    @ViewBuilder
    private var enableSwitch: some View {
        if let row = enableRow {
            Section {
                MeetingsEnableRow(model: model, install: install, row: row)
            }
        }
    }

    private var enableRow: ManagementSettingRow? {
        model.section(SettingsBinding.meetingsSection).value?.rows
            .first { $0.key == SettingsBinding.meetingsEnabled }
    }

    private func descriptorRows(_ group: MeetingsSettingsSection) -> some View {
        let section = SettingsBinding.meetingsSection
        let published = model.section(section).value?.rows ?? []
        let included = Set(group.rows(from: published).map(\.key))
        let excluded = Set(published.map(\.key))
            .subtracting(included)
            // Drawn by the header switch above, which runs a job before its
            // write. A second control for it would be a second writer of one
            // daemon key.
            .union([SettingsBinding.meetingsEnabled])

        return DescriptorRows(model: model, section: section, excluding: excluded)
    }

    /// The sign-in control, with what the daemon says about the account.
    ///
    /// Signed in, the account stands above the control and the control reads
    /// `Sign in again`: the run, its progress, its Cancel and the sentence a
    /// failed run leaves all still belong to whoever is changing the account,
    /// so the control stays rather than being taken away. Not signed in, the
    /// daemon's sentence sits under it as the reason to press it. With no
    /// answer, the control stands alone.
    @ViewBuilder
    private var googleMeetControls: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            accountRow

            JobRow(
                title: ProductStrings[.settingsMeetingsSignInTitle],
                actionTitle: ProductStrings[signInState.actionTitleKey],
                kind: .meetingsSignin,
                runner: signIn
            ) {
                await model.startMeetingsSignIn(on: signIn)
            }

            if let sentence = signInState.pendingSentence {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Text(ProductStrings[.settingsMeetingsSignInNotice])
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The account, once there is one: this app's label with the daemon's own
    /// sentence as its value, in the pass colour a granted permission draws.
    ///
    /// Status is never colour alone here either: the sentence names the state
    /// in words, and VoiceOver reads it as the value of the label.
    @ViewBuilder
    private var accountRow: some View {
        if let sentence = signInState.accountSentence {
            LabeledContent(ProductStrings[.settingsMeetingsGoogleAccountLabel]) {
                Text(sentence)
                    .foregroundStyle(StatusTone.pass.textColor.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signInState: NotetakerSignIn.State {
        NotetakerSignIn(detection: model.detections.value?.result(for: .meetbot)).state
    }
}

/// What the daemon says about the notetaker's Google sign-in, from the
/// `meetbot` row of `setup.detect`.
///
/// Whether a browser profile holds a Google session is the one notetaker fact
/// no client can read for itself, and the row publishes it twice: `signed_in`
/// is the fact this projection switches on, and `detail` is the sentence the
/// pane renders verbatim. With the notetaker absent there is nothing to be
/// signed in to, and a detection still loading, refused or never read is not an
/// answer either, so each of those is an unanswered state rather than one the
/// app invented.
struct NotetakerSignIn {
    let detection: ManagementDetection?

    /// Where the account stands. Three cases, because the pane draws three
    /// things, and the view reads the case rather than the sentence.
    enum State: Equatable {
        /// An account is in place, with the daemon's sentence for it.
        case signedIn(sentence: String?)
        /// The notetaker is on this Mac and no account is in place yet.
        case notSignedIn(sentence: String?)
        /// The daemon said nothing about the sign-in.
        case unanswered
    }

    var state: State {
        guard let detection, detection.present else { return .unanswered }

        switch detection.signedIn {
        case .some(true): return .signedIn(sentence: detection.detail)
        case .some(false): return .notSignedIn(sentence: detection.detail)
        case .none: return .unanswered
        }
    }
}

extension NotetakerSignIn.State {
    /// The word on the control. Signing in again is a different act from
    /// signing in for the first time, and an account already in place is the
    /// one state where that is what pressing it does.
    var actionTitleKey: ProductStringKey {
        switch self {
        case .signedIn: return .settingsMeetingsSignInAgainAction
        case .notSignedIn, .unanswered: return .settingsMeetingsSignInAction
        }
    }

    /// The value of the account row, which only a sign-in that happened has.
    var accountSentence: String? {
        guard case .signedIn(let sentence) = self else { return nil }

        return sentence
    }

    /// The line under the control, which only a notetaker still waiting for an
    /// account has. Once there is one, that sentence is the account row's
    /// value instead, so it is never drawn twice.
    var pendingSentence: String? {
        guard case .notSignedIn(let sentence) = self else { return nil }

        return sentence
    }
}

/// The switch that heads the Meetings pane (M34 §5.4).
///
/// Turning it on installs the notetaker and its browser first and writes the
/// daemon's flag only once that job has finished, so the pane never reads on
/// over something that is not there. The install's own phase, its progress and
/// its Cancel sit under the switch while it runs; a run that ended badly leaves
/// the daemon's sentence there instead.
///
/// The label is the daemon's, from the descriptor row. The footer is the app's:
/// it describes a gesture this app performs, and the descriptor's own footer
/// describes the feature.
struct MeetingsEnableRow: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var install: JobRunner
    let row: ManagementSettingRow

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Toggle(row.label, isOn: enabled)
                .disabled(model.writesBlocked || install.isRunning)

            Text(ProductStrings[.settingsMeetingsEnableFooter])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            run
            refusal
        }
        // Re-attaches to an install already in flight rather than starting a
        // second one, and stops polling when the pane goes away.
        .task { await install.attach(kind: .capabilityInstall) }
        .onDisappear { install.dismiss() }
    }

    /// The install under the switch, with the one control that stops it.
    private var run: some View {
        HStack(spacing: Spacing.s) {
            JobProgress(runner: install)

            if install.isRunning {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsJobCancel]) {
                    Task { await install.cancelJob() }
                }
                .accessibilityLabel(
                    ProductStrings.commaPair(ProductStrings[.settingsJobCancel], row.label)
                )
            }
        }
    }

    /// A refused write, in the daemon's own sentence, under the row it refused.
    @ViewBuilder
    private var refusal: some View {
        if let message = model.message(for: draftKey) {
            Text(message)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var draftKey: SettingsDraftKey {
        SettingsDraftKey(section: SettingsBinding.meetingsSection, key: row.key)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { DescriptorValue.flag(model.value(of: row, in: SettingsBinding.meetingsSection)) },
            set: { isOn in Task { await model.setMeetingsEnabled(isOn, on: install) } }
        )
    }
}
