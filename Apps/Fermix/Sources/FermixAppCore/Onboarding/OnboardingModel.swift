import Combine
import Foundation

/// Choosing a directory, behind a seam. The one place the assistant opens an
/// `NSOpenPanel`, so nothing else in the app can raise a file dialog.
@MainActor
public protocol DirectoryChoosing {
    /// The directory the operator picked, or nil where they cancelled.
    func chooseDirectory(prompt: String) -> URL?
}

/// The journaled daemon restart, behind a seam.
///
/// The assistant decides *when* a restart runs; the app's lifecycle coordinator
/// owns *how*, including the journal and the one-transaction-at-a-time rule.
@MainActor
public protocol DaemonRestarting: AnyObject {
    /// Runs the restart and answers when it has finished: nil where it worked,
    /// and the one sentence the refusal earned where it did not.
    ///
    /// The sentence rather than a flag, because a refusal the assistant cannot
    /// name is a ladder row that stops with nothing said about why.
    func restartDaemonAwaitingCompletion() async -> String?
}

/// How Fermix should answer, as the design's three choices (M34 §4).
///
/// The segmented control shows the word; the daemon stores the sentence, which
/// is what the prompt seeder actually reads.
public enum AssistantStyle: String, CaseIterable, Identifiable, Sendable {
    case concise
    case balanced
    case detailed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .concise: return ProductStrings[.aboutYouStyleConcise]
        case .balanced: return ProductStrings[.aboutYouStyleBalanced]
        case .detailed: return ProductStrings[.aboutYouStyleDetailed]
        }
    }

    /// The value written to `personalization.communication_style`.
    public var sentence: String {
        switch self {
        case .concise: return ProductStrings[.aboutYouStyleConciseSentence]
        case .balanced: return ProductStrings[.aboutYouStyleBalancedSentence]
        case .detailed: return ProductStrings[.aboutYouStyleDetailedSentence]
        }
    }
}

/// What About you writes, and the one section it writes into (M34 §4).
///
/// The four keys are named here and nowhere else. This is the one hand-built
/// form in the app that cannot read its shape off `settings.get`: the gating
/// values it collects are exactly the ones whose absence keeps the assistant
/// open, so the screen exists before the panes that would publish them are
/// worth showing.
///
/// All four are `personalization` rows, including the assistant's own name:
/// `bot_name` is where the daemon keeps it, under the label the Personality
/// pane shows. There is no `agent` section on the wire — writing one earned an
/// `invalid_params` nobody on this screen read, and the typed name was dropped
/// while Ready landed as if it had been saved.
public struct AboutYouAnswers: Equatable, Sendable {
    public static let personalizationSection = "personalization"
    public static let nameKey = "user_name"
    public static let timezoneKey = "timezone"
    public static let styleKey = "communication_style"
    public static let assistantNameKey = "bot_name"

    public var name: String
    public var timezone: String
    public var style: AssistantStyle
    public var assistantName: String

    /// Prefilled from macOS, so zero typing is a valid answer.
    public static func prefilled(
        fullName: String = NSFullUserName(),
        timezone: String = TimeZone.current.identifier,
        assistantName: String = ProductStrings[.productName]
    ) -> AboutYouAnswers {
        AboutYouAnswers(
            name: fullName,
            timezone: timezone,
            style: .balanced,
            assistantName: assistantName
        )
    }

    /// One write, four keys. Everything About you collects lives in one
    /// section, so Applying is one apply the daemon either takes whole or
    /// refuses whole.
    public var personalizationValues: [String: ManagementSettingValue] {
        [
            Self.nameKey: .text(name),
            Self.timezoneKey: .text(timezone),
            Self.styleKey: .text(style.sentence),
            Self.assistantNameKey: .text(assistantName)
        ]
    }
}

/// What Recovery can say about the settings file (M34 §7.5).
///
/// The parser's own sentence, the file it refused, and the copy the daemon kept
/// from before where there is one. Without them the screen says Fermix needs a
/// hand and names nothing, for the one incident class where the file is the
/// whole story.
public struct RecoveryEvidence: Equatable, Sendable {
    public let sentence: String?
    public let settingsFile: String?
    public let previousFile: String?

    public init(sentence: String?, settingsFile: String?, previousFile: String?) {
        self.sentence = sentence
        self.settingsFile = settingsFile
        self.previousFile = previousFile
    }

    /// The file the daemon keeps beside `config.toml` when it rewrites one.
    public static let previousSuffix = ".previous"

    public var isEmpty: Bool { sentence == nil && settingsFile == nil && previousFile == nil }
}

/// The Setup Assistant's model.
///
/// It owns the machine, drives activation, and reads every daemon fact through
/// the one `SettingsModel` (M34 §8), so what the assistant saved and what the
/// Settings window shows are the same snapshot rather than two reads.
@MainActor
public final class OnboardingModel: ObservableObject {
    @Published public private(set) var machine = OnboardingMachine()
    @Published public private(set) var cliPlan: CLILinkPlan
    @Published public private(set) var cliInstalled = false
    @Published public var cliSelected = CLILinkPlanner.startsChecked
    /// The last log lines the boot-failure card draws. Empty until a failure
    /// has something to show.
    @Published public private(set) var failureLogLines: [String] = []
    /// About you's four fields, prefilled and edited in place.
    @Published public var answers = AboutYouAnswers.prefilled()
    /// Why a chosen home was refused, in one sentence naming the path.
    @Published public private(set) var homeRefusal: String?
    /// The daemon's own refusal of row four, where it refused.
    @Published public private(set) var preparationRefusal: String?
    /// Whether the person asked to change the provider this home already has,
    /// which re-opens Connect your AI's own rows in place of the
    /// already-connected form.
    @Published public private(set) var changingProvider = false
    /// Whether the Restart sheet is asking, because something was in flight or
    /// the count could not be read (M34 §14 decision 11).
    @Published public var restartSheetPresented = false
    /// A restart that was asked for and did not finish, in one sentence. The
    /// ladder must never claim a step the transaction refused.
    @Published public private(set) var restartRefusal: String?

    /// The one settings model. Every provider, readiness and restart fact the
    /// assistant renders comes off this.
    public let settings: SettingsModel
    /// The sign-in job the waiting sheet follows.
    public let signIn: JobRunner

    private let gateway: any DaemonQuerying
    private let activation: any ActivationDriving
    private let store: BootstrapStore
    private let handoff: MigrationHandoffReader
    private let chooser: any DirectoryChoosing
    private let restarter: any DaemonRestarting
    private let planner: CLILinkPlanner
    /// Where the settings file is, and whether the daemon kept the copy from
    /// before. A closure because the answer is a filesystem fact the
    /// composition already knows how to read.
    private let settingsFiles: () -> RecoveryEvidence
    /// Shows the settings file in the Finder. The one implementation lives on
    /// `DoctorModel`; this is that one.
    private let revealSettings: () -> Void
    private let route: (AppDestination) -> Void
    private let recoveryResolved: () -> Void
    private let log = AppLog.logger(.app)
    private var activationTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// Every assistant surface observes this model and reads its facts off the
    /// two objects below, so a change published there has to reach here or the
    /// screen keeps drawing the answer from before the read (M34 §8). The same
    /// forwarding `PetFeatureModel` does for the app model.
    private var observed: [AnyCancellable] = []

    public init(
        gateway: any DaemonQuerying,
        activation: any ActivationDriving,
        store: BootstrapStore,
        handoff: MigrationHandoffReader,
        chooser: any DirectoryChoosing,
        restarter: any DaemonRestarting,
        planner: CLILinkPlanner,
        settingsFiles: @escaping () -> RecoveryEvidence = { RecoveryEvidence(sentence: nil, settingsFile: nil, previousFile: nil) },
        revealSettingsFile: @escaping () -> Void = {},
        onRoute: @escaping (AppDestination) -> Void,
        onRecoveryResolved: @escaping () -> Void,
        settings: SettingsModel,
        sleeper: any Sleeping
    ) {
        self.gateway = gateway
        self.activation = activation
        // The ladder is the plan, drawn. Reading it off the driver rather than
        // taking it as a second parameter is what keeps the screen and the
        // transaction from disagreeing about which steps run.
        self.machine = OnboardingMachine(activationPlan: activation.plan)
        self.store = store
        self.handoff = handoff
        self.chooser = chooser
        self.restarter = restarter
        self.planner = planner
        self.settingsFiles = settingsFiles
        self.revealSettings = revealSettingsFile
        self.route = onRoute
        self.recoveryResolved = onRecoveryResolved
        self.settings = settings
        self.signIn = JobRunner(gateway: gateway, sleeper: sleeper)
        self.cliPlan = planner.plan()
        self.observed = [
            settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            signIn.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    public var stage: OnboardingStage { machine.stage }
    public var ladder: ProgressLadderModel? {
        machine.ladder(restartRequired: settings.restart.required)
    }
    /// The line under the Starting ladder, on the plans that earn one.
    ///
    /// It names the background item macOS is about to mention, so a launch that
    /// registers none says nothing rather than promising a prompt that never
    /// arrives.
    public var startingCaption: String? {
        machine.activationPlan.registersLoginItems ? ProductStrings[.startingCaption] : nil
    }

    public var progress: ProgressDotsModel? { machine.progress }
    public var blocked: OnboardingBlock? { machine.blocked }
    public var readiness: OnboardingReadiness { machine.readiness }

    /// What a block says, with the newer-engine sentence taken from the one
    /// value that owns it. Every assistant screen that draws a block draws it
    /// through here, so none of them can name the wrong one of its two states.
    public func message(for block: OnboardingBlock) -> String {
        block.message(newerEngine: settings.newerEngineSentence)
    }

    /// Welcome's secondary link is offered while no *usable* migration handoff
    /// exists (M34 §15.2).
    ///
    /// A journal answers the question the picker would ask only while it can be
    /// adopted. One that cannot is never cleared, on purpose, so hiding the
    /// picker behind its mere existence left `Try again` refusing forever with
    /// no other way to name a home.
    public var offersExistingHomePicker: Bool { ((try? handoff.read()) ?? nil) == nil }

    /// The boot-failure card, built from the cause the activation earned.
    public var failurePanel: ErrorPanelModel? {
        machine.failure.map {
            ErrorPanelModel.bootFailure($0, logLines: failureLogLines, evidence: machine.failureEvidence)
        }
    }

    /// The providers the daemon published, which every row here is built from.
    public var providers: [ManagementSetupProvider] { settings.setupState.value?.providers ?? [] }

    /// The two vendor rows Connect your AI draws (M34 §4). Detections change the
    /// verb a row leads with; they never add a row or a screen.
    ///
    /// Two, not one per descriptor: the screen is a fixed 800 by 520 window with
    /// a bottom bar, and the design's third row is the key door beside these.
    ///
    /// The descriptor rows are read through the shared model, because a key verb
    /// cannot be carried out until the daemon has named the slot it writes to:
    /// with none, `Add key…` would be advertised and permanently dead.
    public var providerRows: [ProviderRowModel] {
        ProviderRowProjection.assistantRows(
            providers: providers,
            detections: settings.detections.value,
            signingIn: settings.signingInProvider,
            descriptorRows: settings.providerDescriptorRows(for: providers)
        )
    }

    /// Every slot the key row's sheet may write to, in the daemon's own order.
    public var keyTargets: [ProviderKeyTarget] {
        ProviderRowProjection.keyTargets(
            providers: providers,
            descriptorRows: settings.providerDescriptorRows(for: providers)
        )
    }

    /// Reads each published provider's own section, so a key verb has its slot.
    public func loadProviderSections() async {
        await settings.loadProviderSections(for: providers)
    }

    /// Whether the bottom bar offers the skip link.
    ///
    /// Whether this home already answers with a provider, which is what turns
    /// Connect your AI into the already-connected form (M34 §4).
    ///
    /// Asking to change it re-opens the decision on this screen rather than
    /// naming a pane: the two windows are exclusive, so opening Settings from
    /// here shut the assistant mid-journey with nothing said about where it
    /// had gone.
    public var alreadyConnected: ManagementSetupProvider? {
        guard !changingProvider else { return nil }

        return settings.setupState.value?.providers.first { $0.primary && $0.configured }
    }

    /// The already-connected form's one link: it puts the three provider rows
    /// back on this screen. It stays set for the life of the screen, so a
    /// sign-in that lands on the same provider does not snap the form shut
    /// under the person who just asked to change it.
    public func changeProvider() {
        changingProvider = true
    }

    // MARK: - The journey

    public func begin() {
        machine.apply(.begin)
        startActivation()
    }

    /// Try again is the user asking the app to get back to a working state, so
    /// it resolves whatever recovery record is outstanding before running
    /// anything: a transaction refuses to start over an unresolved one.
    public func retry() {
        recoveryResolved()
        machine.apply(.retryActivation)
        startActivation()
    }

    public func advance() {
        let savesAnswers = machine.stage == .aboutYou
        machine.apply(.advance)

        guard savesAnswers, machine.stage == .applying else { return }

        startApplying(saveAnswers: true)
    }

    public func back() {
        machine.apply(.back)
    }

    public func enterRecovery() {
        machine.apply(.enterRecovery)
    }

    /// What Recovery states: the daemon's own sentence about the file, the file
    /// itself, and the copy from before where the daemon kept one (M34 §7.5).
    public var recoveryEvidence: RecoveryEvidence {
        let files = settingsFiles()

        return RecoveryEvidence(
            sentence: settings.configSentence,
            settingsFile: files.settingsFile,
            previousFile: files.previousFile
        )
    }

    /// Shows the settings file in the Finder.
    public func revealSettingsFile() {
        revealSettings()
    }

    /// Resumes at the screen a route named (M34 §3.4).
    ///
    /// Starting runs activation; Applying takes the pending restart without
    /// rewriting personalization. An unresolved activation refusal keeps its
    /// Boot failed card and the explicit Try again action.
    public func resume(at stage: OnboardingStage) {
        machine.apply(.resume(stage))

        if machine.stage == .starting { startActivation() }
        if machine.stage == .applying { startApplying(saveAnswers: false) }
    }

    /// The way off the Starting ladder.
    ///
    /// Activation is one bounded transaction with no decision on it, so the one
    /// thing a person can ask for while it runs is to stop. The task is
    /// cancelled and the app returns to Home; the next `Continue setup` comes
    /// back through `resume(at:)` like any other route.
    public func cancelStarting() {
        guard machine.stage == .starting else { return }

        log.log("the person cancelled the starting ladder")
        activationTask?.cancel()
        route(.surface(.home))
    }

    /// The Ready action.
    public func finish() {
        route(.surface(.home))
    }

    /// Ready's next steps, and the advisory row's one action.
    public func open(_ destination: AppDestination) {
        route(destination)
    }

    /// The boot-failure card's primary action. Doctor answers from the running
    /// daemon, so on a daemon that never started it reports exactly that.
    public func openDoctor() {
        route(.surface(.doctor))
    }

    public func openLogs() {
        route(.surface(.logs))
    }

    // MARK: - Welcome

    /// Adopts a home the operator picked, through the same validator and the
    /// same record writer every other path uses. Swift parses nothing inside it.
    public func chooseExistingHome() {
        guard let url = chooser.chooseDirectory(prompt: ProductStrings[.welcomeUseExistingHome]) else { return }

        do {
            try store.save(fermixHome: url)
            // The operator has now answered the question the journal existed to
            // answer, so it is consumed. Leaving it would have the next
            // activation adopt the home they just replaced.
            try handoff.clear()
            homeRefusal = nil
        } catch {
            log.error("the chosen home was refused: \(String(describing: error), privacy: .public)")
            homeRefusal = String(format: ProductStrings[.welcomeHomeRefusedFormat], url.path)
        }
    }

    // MARK: - Readiness

    /// Reads readiness from `setup.state.get` through the one settings model, so
    /// Home, the Settings window and the assistant cannot disagree about what is
    /// configured (M34 §4, §8).
    public func refreshReadiness() async {
        await settings.refreshSetupState()
        applyReadinessFromSettings()
    }

    private func applyReadinessFromSettings() {
        switch settings.setupState {
        case .loaded(let state):
            machine.apply(.readinessChanged(OnboardingReadiness(state: state)))
        case .requiresNewerEngine:
            machine.apply(.readinessChanged(OnboardingReadiness(daemonLive: true, requiresNewerEngine: true)))
        case .unread, .loading, .unavailable:
            machine.apply(.readinessChanged(OnboardingReadiness()))
        }
    }

    // MARK: - Connect your AI

    /// Starts the browser sign-in for one provider and follows it.
    public func startSignIn(provider: String) async {
        if let sentence = await settings.startSignIn(provider: provider, on: signIn) {
            signIn.adopt(failure: sentence)
        }
    }

    /// Adopts a sign-in this Mac already has.
    public func importSignIn(source: ManagementAuthImportSource, provider: String) async {
        if let sentence = await settings.startAuthImport(source: source, provider: provider, on: signIn) {
            signIn.adopt(failure: sentence)
        }
    }

    /// A sign-in ended, however it ended.
    public func signInFinished() async {
        await settings.signInFinished()
        applyReadinessFromSettings()
    }

    // MARK: - Applying

    /// Saves only answers submitted from About you. A restart-only route keeps
    /// the existing personalization and takes the same restart workflow.
    private func startApplying(saveAnswers: Bool) {
        applyTask?.cancel()
        restartRefusal = nil
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if saveAnswers {
                self.machine.apply(.applyingProgressed(.saving))
                let saved = await self.settings.apply(
                    section: AboutYouAnswers.personalizationSection,
                    changes: self.answers.personalizationValues
                )
                guard saved else {
                    self.machine.apply(.personalizationRefused)
                    return
                }
            }
            guard !Task.isCancelled else { return }

            await self.takeRestart()
            await self.refreshReadiness()
            guard !Task.isCancelled else { return }

            self.machine.apply(.applyingFinished)
        }
    }

    /// Decision 11: a fresh install with nothing in flight restarts without
    /// asking. Anything else asks first, including a count nobody answered,
    /// because an unanswered read is not a report that the daemon is quiet.
    ///
    /// Row two of the ladder is entered only when a restart is actually taken:
    /// a home that needs none must not be shown a restart that never happened.
    private func takeRestart() async {
        guard settings.restart.required else { return }

        await settings.readConversationsInFlight()
        guard settings.conversationsInFlight == 0 else {
            restartSheetPresented = true
            return
        }

        machine.apply(.applyingProgressed(.restarting))
        await performRestart()
    }

    /// The restart the Restart sheet asked for, at the moment the sheet chose.
    ///
    /// The sheet decides when; this runs the same transaction the automatic path
    /// runs and re-runs the gate on what the daemon reports afterwards.
    public func takeRestartFromSheet() {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }

            self.machine.apply(.applyingProgressed(.restarting))
            await self.performRestart()
            await self.restartSheetFinished()
        }
    }

    /// Runs the journaled restart and says what happened. A refusal is
    /// published rather than dropped: a ladder row that stayed silent would
    /// claim a restart the daemon never took.
    private func performRestart() async {
        restartRefusal = await restarter.restartDaemonAwaitingCompletion()

        guard let restartRefusal else { return }

        log.error("the restart the assistant asked for did not finish: \(restartRefusal, privacy: .public)")
    }

    /// The Restart sheet finished, however it finished, so the gate runs again
    /// on what the daemon now reports.
    public func restartSheetFinished() async {
        restartSheetPresented = false
        await refreshReadiness()
        machine.apply(.applyingFinished)
    }

    /// Whether Applying has to offer the restart itself.
    ///
    /// It does once the gate has refused for a pending restart: the sheet may
    /// have been cancelled, and a screen with a warning and no action would be
    /// a dead end.
    public var offersRestart: Bool {
        machine.stage == .applying && machine.blocked == .restartPending
    }

    // MARK: - CLI row

    public func refreshCLIPlan() {
        cliPlan = planner.plan()
        cliInstalled = planner.verify()
    }

    /// The one admin moment: a command the user copies and runs. No privileged
    /// helper is involved, so the app's part ends at the clipboard and resumes
    /// at the verification.
    public func copyCLICommand() {
        guard case .available(let command, _) = cliPlan else { return }

        Clipboard.write(command)
    }

    // MARK: - Activation

    private func startActivation() {
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.activation.activate { [weak self] stage in
                self?.machine.apply(.activationProgressed(stage))
            }

            // A cancelled activation has no outcome to report: `cancelStarting`
            // has already left the ladder, and applying the refusal the
            // cancellation itself produced would draw the Boot failed card over
            // the screen the person asked for.
            guard !Task.isCancelled else { return }

            switch outcome {
            case .activated(_, let prepared):
                self.adopt(prepared)
                self.machine.apply(.activationSucceeded)
                if self.machine.stage == .applying { self.startApplying(saveAnswers: false) }
            case .failed(let cause, let evidence):
                self.machine.apply(.activationFailed(cause, evidence: evidence))
                await self.loadFailureLogLines()
            }
        }
    }

    /// Row four's reads, folded into the one settings model so the assistant and
    /// the Settings window share them.
    private func adopt(_ prepared: ActivationPreparation) {
        preparationRefusal = prepared.refusal
        settings.adopt(setupState: prepared.state, detections: prepared.detections)

        guard prepared.state == nil else {
            applyReadinessFromSettings()
            return
        }

        machine.apply(
            .readinessChanged(
                OnboardingReadiness(daemonLive: true, requiresNewerEngine: prepared.requiresNewerEngine)
            )
        )
    }

    /// The last lines the daemon can still show. A daemon that never started
    /// has none, and the card draws the cause without them rather than
    /// inventing filler.
    private func loadFailureLogLines() async {
        do {
            let page = try await gateway.queryLogs(
                ManagementLogsQuery(limit: ErrorPanelModel.logLineCount, direction: .backward)
            )
            failureLogLines = page.entries.map(\.message)
        } catch {
            // The card still draws the cause; what it cannot do is say why it
            // has no lines under it, and the log is the only place that can.
            let cause = ManagementMessage.diagnostic(for: error)
            log.error("no log lines for the failure card: \(cause, privacy: .public)")
            failureLogLines = []
        }
    }

    /// Lets a caller observe the work this model started and forgot.
    public func drainPendingWork() async {
        await activationTask?.value
        await applyTask?.value
        await restartTask?.value
    }
}
