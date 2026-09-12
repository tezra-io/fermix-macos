import Foundation

/// Every user-visible string in the product, by key.
///
/// The raw value is the key in `Localizable.strings`. Nothing user-visible may
/// be written as a Swift literal: this enum is the only way to reach copy, and
/// `CaseIterable` is what lets the copy gate derive its case set from the
/// product rather than from a hand-listed set of screens.
public enum ProductStringKey: String, CaseIterable, Sendable {
    // Welcome
    case welcomeTitle = "welcome.title"
    case welcomeValue = "welcome.value"
    case welcomeCTA = "welcome.cta"
    case welcomeUseExistingHome = "welcome.useExistingHome"
    case welcomeHomeRefusedFormat = "welcome.homeRefusedFormat"

    // Starting
    case startingTitle = "starting.title"
    case startingCaption = "starting.caption"
    case startingRowService = "starting.row.service"
    case startingRowDaemon = "starting.row.daemon"
    case startingRowAnswering = "starting.row.answering"
    case startingRowReading = "starting.row.reading"
    case ladderStateDone = "ladder.state.done"
    case ladderStateActive = "ladder.state.active"
    case ladderStatePending = "ladder.state.pending"

    // Applying
    case applyingTitle = "applying.title"
    case applyingRowSaving = "applying.row.saving"
    case applyingRowRestarting = "applying.row.restarting"
    case applyingRestartRefused = "applying.restartRefused"
    case applyingTakeRestart = "applying.takeRestart"

    // Connect AI
    case connectAITitle = "connectAI.title"
    case connectAISubcopy = "connectAI.subcopy"
    case connectAIKeyRowTitle = "connectAI.keyRow.title"
    case connectAIKeyRowHint = "connectAI.keyRow.hint"
    case connectAIConnectedTitle = "connectAI.connectedTitle"
    case connectAIConnectedBody = "connectAI.connectedBody"
    case connectAIChangeProvider = "connectAI.changeProvider"

    // About you
    case aboutYouTitle = "aboutYou.title"
    case aboutYouSubcopy = "aboutYou.subcopy"
    case aboutYouName = "aboutYou.name"
    case aboutYouTimezone = "aboutYou.timezone"
    case aboutYouTimezoneChange = "aboutYou.timezoneChange"
    case aboutYouTimezoneSearchPrompt = "aboutYou.timezoneSearchPrompt"
    case aboutYouStyle = "aboutYou.style"
    case aboutYouStyleConcise = "aboutYou.style.concise"
    case aboutYouStyleBalanced = "aboutYou.style.balanced"
    case aboutYouStyleDetailed = "aboutYou.style.detailed"
    case aboutYouStyleConciseSentence = "aboutYou.style.concise.sentence"
    case aboutYouStyleBalancedSentence = "aboutYou.style.balanced.sentence"
    case aboutYouStyleDetailedSentence = "aboutYou.style.detailed.sentence"
    case aboutYouAssistantName = "aboutYou.assistantName"

    // The assistant's bottom bar
    case assistantBack = "assistant.back"
    /// The way off the Starting ladder, which is the one mechanical screen a
    /// person can ask to stop.
    case assistantCancel = "assistant.cancel"
    case assistantContinue = "assistant.continue"

    // Onboarding gates
    case onboardingBlockedDaemon = "onboarding.blocked.daemon"
    case onboardingBlockedProvider = "onboarding.blocked.provider"
    case onboardingBlockedPersonalization = "onboarding.blocked.personalization"
    case onboardingBlockedSettings = "onboarding.blocked.settings"
    case onboardingBlockedRestart = "onboarding.blocked.restart"
    case recoveryTitle = "recovery.title"
    case recoveryBody = "recovery.body"
    case recoveryTryAgain = "recovery.tryAgain"
    case recoveryPreviousFormat = "recovery.previousFormat"

    // Ready
    case readyTitle = "ready.title"
    case readyStatus = "ready.status"
    case readyNextChannels = "ready.nextChannels"
    case readyNextVoice = "ready.nextVoice"
    case readyAttention = "ready.attention"
    case readyBlockedTitle = "ready.blockedTitle"
    case readyOpenPaneFormat = "ready.openPaneFormat"
    case readyCLITitle = "ready.cli.title"
    case readyCLIHint = "ready.cli.hint"
    case readyCLIHintLinked = "ready.cli.hint.linked"
    case readyCLIHintHomebrew = "ready.cli.hint.homebrew"
    case readyCLIHintForeign = "ready.cli.hint.foreign"
    case readyCLIHintNoLauncher = "ready.cli.hint.noLauncher"
    case readyCLICopy = "ready.cli.copy"
    case readyCLIVerify = "ready.cli.verify"
    case readyOpen = "ready.open"

    // Boot failed
    case bootFailedTitle = "bootFailed.title"
    case bootFailedLogHeader = "bootFailed.logHeader"
    case bootFailedRunDoctor = "bootFailed.runDoctor"
    case bootFailedViewLog = "bootFailed.viewLog"
    case bootFailedTryAgain = "bootFailed.tryAgain"
    case bootFailedCauseTimedOut = "bootFailed.cause.timedOut"
    case bootFailedCauseApprovalPending = "bootFailed.cause.approvalPending"
    case bootFailedCauseBackgroundItemDisabled = "bootFailed.cause.backgroundItemDisabled"
    case bootFailedCauseIncompatibleVersion = "bootFailed.cause.incompatibleVersion"
    case bootFailedCauseCrashLoop = "bootFailed.cause.crashLoop"
    case bootFailedCauseBindFailure = "bootFailed.cause.bindFailure"
    case bootFailedCauseWebUnavailable = "bootFailed.cause.webUnavailable"
    case bootFailedCauseInvalidPackage = "bootFailed.cause.invalidPackage"
    case bootFailedCauseBootstrapRecordUnusable = "bootFailed.cause.bootstrapRecordUnusable"
    case bootFailedCauseRegistrationFailed = "bootFailed.cause.registrationFailed"
    case bootFailedCauseDaemonUnresponsive = "bootFailed.cause.daemonUnresponsive"
    case bootFailedCauseNotInApplications = "bootFailed.cause.notInApplications"
    case bootFailedCauseLegacyInstallPresent = "bootFailed.cause.legacyInstallPresent"
    case bootFailedCauseLegacySystemInstallPresent = "bootFailed.cause.legacySystemInstallPresent"
    case bootFailedCauseForeignDaemonRunning = "bootFailed.cause.foreignDaemonRunning"
    case bootFailedCausePreManagementDaemonRunning = "bootFailed.cause.preManagementDaemonRunning"
    case bootFailedCauseDaemonRefusedIdentity = "bootFailed.cause.daemonRefusedIdentity"
    case bootFailedCauseDuplicateCopyPresent = "bootFailed.cause.duplicateCopyPresent"
    case bootFailedCauseMigrationHandoffInvalid = "bootFailed.cause.migrationHandoffInvalid"

    // Why a migration handoff journal was refused. One sentence per validator
    // failure: the card names the file, and this names what is wrong with it.
    case handoffUnreadable = "handoffDefect.unreadable"
    case handoffMalformed = "handoffDefect.malformed"
    case handoffUnsupportedSchemaVersion = "handoffDefect.unsupportedSchemaVersion"
    case handoffHomeEmpty = "handoffDefect.home.empty"
    case handoffHomeNotAbsolute = "handoffDefect.home.notAbsolute"
    case handoffHomeRelativeTraversal = "handoffDefect.home.relativeTraversal"
    case handoffHomeNotADirectory = "handoffDefect.home.notADirectory"
    case handoffHomeNotOwned = "handoffDefect.home.notOwnedByCurrentUser"
    case handoffHomeNotWritable = "handoffDefect.home.notWritable"
    case handoffHomeFilesystemRoot = "handoffDefect.home.filesystemRoot"
    case handoffHomeAccountHome = "handoffDefect.home.accountHome"
    case handoffHomeSystemDirectory = "handoffDefect.home.systemDirectory"
    case handoffHomeApplicationsDirectory = "handoffDefect.home.applicationsDirectory"
    case handoffHomeTemporaryDirectory = "handoffDefect.home.temporaryDirectory"
    case handoffHomeCloudSyncedDirectory = "handoffDefect.home.cloudSyncedDirectory"
    case handoffHomeBootstrapDirectory = "handoffDefect.home.bootstrapDirectory"

    // Home
    case homeStatusLabel = "home.status.label"
    case homeStatusRunning = "home.status.running"
    case homeStatusSetupRequired = "home.status.setupRequired"
    case homeRunInBackground = "home.runInBackground"
    case homeOpenAtLogin = "home.openAtLogin"
    case homeShowInMenuBar = "home.showInMenuBar"
    case homeRuntimeEmpty = "home.runtimeEmpty"
    case homeAttentionEmpty = "home.attentionEmpty"
    case homeAttentionNewerEngineTitle = "home.attention.newerEngine.title"
    case homeAttentionUnavailableTitle = "home.attention.unavailable.title"
    case homeAttentionUnread = "home.attention.unread"
    case homeRuntimeEngine = "home.runtime.engine"
    case homeRuntimeProtocol = "home.runtime.protocol"
    case homeRuntimeUptime = "home.runtime.uptime"
    case homeRuntimeProvider = "home.runtime.provider"
    case homeRuntimeChannels = "home.runtime.channels"
    case homeRuntimeSkills = "home.runtime.skills"
    case homeRuntimeTools = "home.runtime.tools"
    case homeRuntimeNone = "home.runtime.none"
    case homeUpdateCurrent = "home.updateCurrent"
    /// Home's tinted primary while readiness is not ready (M34 §3.2).
    case homeContinueSetup = "home.continueSetup"
    case homeUpdateUnknown = "home.updateUnknown"
    case homeUpdateUnconfigured = "home.updateUnconfigured"
    case homeUpdateChecking = "home.updateChecking"
    case homeUpdateCheckFailed = "home.updateCheckFailed"
    case homeUpdateAvailableFormat = "home.updateAvailableFormat"
    case homeUpdateCriticalFormat = "home.updateCriticalFormat"
    case homeUpdateStagedFormat = "home.updateStagedFormat"
    case homeUpdateCheckedFormat = "home.updateCheckedFormat"
    case homeUptimeFormat = "home.uptimeFormat"

    // Update and uninstall routes
    case updateTitle = "update.title"
    case updateBundled = "update.bundled"
    case updateCheck = "update.check"
    case updateHow = "update.how"
    case uninstallTitle = "uninstall.title"
    case uninstallBody = "uninstall.body"
    case uninstallReveal = "uninstall.reveal"

    // Recovery from an update that did not finish (M34 §6). One sentence per
    // reason, because each one sends the operator somewhere different.
    case updateRecoveryTitle = "updateRecovery.title"
    case updateRecoveryInterrupted = "updateRecovery.reason.interrupted"
    case updateRecoveryJournalUnusable = "updateRecovery.reason.journalUnusable"
    case updateRecoveryUnexpectedApp = "updateRecovery.reason.unexpectedApp"
    case updateRecoveryUnexpectedEngine = "updateRecovery.reason.unexpectedEngine"
    case updateRecoveryEngineNotStopped = "updateRecovery.reason.engineNotStopped"
    case updateRecoverySourceUnverified = "updateRecovery.reason.sourceEngineUnverified"
    case updateRecoveryTargetUnverified = "updateRecovery.reason.targetEngineUnverified"
    case updateRecoveryRegistrationNotRestored = "updateRecovery.reason.registrationNotRestored"
    case updateRecoveryConflictingRegistration = "updateRecovery.reason.conflictingRegistration"
    case updateRecoveryRegistrationNeedsApproval = "updateRecovery.reason.registrationNeedsApproval"
    case updateRecoveryNoSharedProtocol = "updateRecovery.reason.noSharedProtocol"
    case updateRecoveryVersionsFormat = "updateRecovery.versionsFormat"
    case updateRecoveryInstallerFormat = "updateRecovery.installerFormat"
    case updateRecoveryReinstall = "updateRecovery.reinstall"
    case updateRecoveryNeedsNetwork = "updateRecovery.needsNetwork"
    case updateRecoveryRollbackUnsafe = "updateRecovery.rollbackUnsafe"
    case updateRecoveryDisableRefused = "updateRecovery.disableRefused"

    // Daemon errors, in the app's own words where the daemon has none
    /// The one wording for "the daemon is not answering", shared by Home's
    /// header, the status item's state line, and the sentence a refused read
    /// puts in front of the operator. Three surfaces once said `Daemon not
    /// reachable`, `Not running` and `The Fermix daemon isn't running` about
    /// the same machine.
    case daemonStateNotRunning = "daemon.state.notRunning"
    case daemonErrorUnreachable = "daemon.error.unreachable"
    case daemonErrorIncompatible = "daemon.error.incompatible"
    case daemonErrorUnexpectedShape = "daemon.error.unexpectedShape"
    case daemonErrorRequiresNewerEngine = "daemon.error.requiresNewerEngine"
    /// Why a restart is refused outright: launchd does not own this daemon, so
    /// draining it would stop Fermix with nothing to bring it back.
    case lifecycleDaemonNotManaged = "lifecycle.daemonNotManaged"
    /// Another owner is already changing the background service, which in
    /// practice is an update stopping the engine before it replaces the app
    /// (M34 section 6).
    case lifecycleServiceBusy = "lifecycle.serviceBusy"

    // Background service

    // Attention rows (M34 §3.2), keyed on the daemon's own detail keys
    case attentionPersonalizationTitle = "attention.personalization.title"
    case attentionPersonalizationBody = "attention.personalization.body"
    case attentionProviderUnknownTitle = "attention.provider.unknown.title"
    case attentionProviderUnknownBody = "attention.provider.unknown.body"
    case attentionProviderPrimaryTitle = "attention.provider.primary.title"
    case attentionProviderPrimaryBody = "attention.provider.primary.body"
    case attentionProviderAuthModeTitle = "attention.provider.authMode.title"
    case attentionProviderAuthModeBody = "attention.provider.authMode.body"
    case attentionProviderCredentialsTitleFormat = "attention.provider.credentials.titleFormat"
    case attentionProviderCredentialsBody = "attention.provider.credentials.body"
    case attentionChannelTitleFormat = "attention.channel.titleFormat"
    case attentionChannelBody = "attention.channel.body"
    case attentionVoiceTitle = "attention.voice.title"
    case attentionVoiceBody = "attention.voice.body"
    case attentionRestartTitle = "attention.restart.title"
    case attentionRestartBody = "attention.restart.body"
    case attentionExternalChangeTitle = "attention.externalChange.title"
    case attentionConfigUnreadableTitle = "attention.configUnreadable.title"
    case attentionLegacyServiceTitle = "attention.legacyService.title"
    case attentionLegacyServiceBody = "attention.legacyService.body"
    case attentionActionShowInstructions = "attention.action.showInstructions"
    case coexistenceLegacyServiceTitle = "coexistence.legacyService.title"
    case coexistenceLegacyServiceBody = "coexistence.legacyService.body"
    case coexistenceCopyCommand = "coexistence.copyCommand"
    case coexistenceUnavailable = "coexistence.unavailable"
    case cliInstructionsBody = "cli.instructions.body"
    case attentionSecretACLTitle = "attention.secretACL.title"
    case attentionSecretACLBody = "attention.secretACL.body"
    case attentionUnrecognizedBody = "attention.unrecognized.body"
    case attentionActionRestart = "attention.action.restart"
    case attentionActionReload = "attention.action.reload"
    case attentionActionShowUpdate = "attention.action.showUpdate"
    // The update rows (M34 section 6). One title per state, because an update
    // that is offered and an update that is already staged ask for different
    // things.
    case attentionUpdateAvailableBody = "attention.update.available.body"
    case attentionUpdateCriticalBody = "attention.update.critical.body"
    case attentionUpdateStagedTitle = "attention.update.staged.title"
    case attentionUpdateStagedBody = "attention.update.staged.body"

    // Sidebar
    case sidebarHome = "sidebar.home"
    case sidebarDoctor = "sidebar.doctor"
    case sidebarPet = "sidebar.pet"
    case sidebarLogs = "sidebar.logs"
    /// The pinned footer row (decision D2).
    case sidebarSettings = "sidebar.settings"

    // Doctor
    case doctorTitle = "doctor.title"
    case doctorBannerHealthy = "doctor.banner.healthy"
    case doctorBannerHealthyWithWarning = "doctor.banner.healthyWithWarning"
    case doctorBannerWarningsFormat = "doctor.banner.warningsFormat"
    case doctorBannerFailingOne = "doctor.banner.failingOne"
    case doctorBannerFailingFormat = "doctor.banner.failingFormat"
    case doctorBannerExplainer = "doctor.banner.explainer"
    case doctorBannerCheckedJustNow = "doctor.banner.checkedJustNow"
    case doctorNetworkBody = "doctor.network.body"
    case doctorNetworkRun = "doctor.network.run"
    case doctorActionSystemSettings = "doctor.action.systemSettings"
    case doctorSupportExport = "doctor.support.export"
    case doctorSupportExportFilename = "doctor.support.exportFilename"
    case doctorSupportOpenLogFolder = "doctor.support.openLogFolder"
    case doctorSupportHomeUnavailable = "doctor.support.homeUnavailable"
    case doctorSettingsPaneUnavailable = "doctor.support.settingsPaneUnavailable"
    case doctorRunStalled = "doctor.runStalled"
    case doctorRunning = "doctor.running"
    case doctorNoChecks = "doctor.noChecks"
    case doctorCancel = "doctor.cancel"
    case doctorRetry = "doctor.retry"

    // Logs
    case logsTitle = "logs.title"
    case logsSearchPlaceholder = "logs.searchPlaceholder"
    case logsLevelLabel = "logs.levelLabel"
    case logsLevelAll = "logs.levelAll"
    case logsLevelEmergency = "logs.level.emergency"
    case logsLevelAlert = "logs.level.alert"
    case logsLevelCritical = "logs.level.critical"
    case logsLevelError = "logs.level.error"
    case logsLevelWarning = "logs.level.warning"
    case logsLevelNotice = "logs.level.notice"
    case logsLevelInfo = "logs.level.info"
    case logsLevelDebug = "logs.level.debug"
    case logsPause = "logs.pause"
    case logsResume = "logs.resume"
    case logsCopy = "logs.copy"
    case logsExport = "logs.export"
    case logsExportFilename = "logs.exportFilename"
    case logsLoadOlder = "logs.loadOlder"
    case logsEmpty = "logs.empty"
    case logsTruncated = "logs.truncated"
    case logsRotated = "logs.rotated"
    case logsSearchTooLong = "logs.searchTooLong"
    case doctorPillPass = "doctor.pill.pass"
    case doctorPillWarn = "doctor.pill.warn"
    case doctorPillFail = "doctor.pill.fail"
    case doctorPillUnavailable = "doctor.pill.unavailable"
    case doctorPillSkipped = "doctor.pill.skipped"
    case doctorPillCancelled = "doctor.pill.cancelled"
    case doctorPillTimedOut = "doctor.pill.timedOut"
    case doctorPillNotApplicable = "doctor.pill.notApplicable"

    // Voice
    case voiceStatusOffline = "voice.status.offline"
    case voiceStatusConnecting = "voice.status.connecting"
    case voiceStatusIdle = "voice.status.idle"
    case voiceStatusListening = "voice.status.listening"
    case voiceStatusMuted = "voice.status.muted"
    case voiceStatusThinking = "voice.status.thinking"
    case voiceStatusSpeaking = "voice.status.speaking"
    case voiceStatusToolUse = "voice.status.toolUse"
    case voiceStatusUpdateRequired = "voice.status.updateRequired"
    case voiceStatusHomeUnavailable = "voice.status.homeUnavailable"
    case voiceStatusRefusedFormat = "voice.status.refusedFormat"
    case voiceStatusToolFailed = "voice.status.toolFailed"
    case voiceErrorMicrophoneDenied = "voice.error.microphoneDenied"
    case voiceErrorMicrophoneRestricted = "voice.error.microphoneRestricted"
    case voiceErrorNoInputDevice = "voice.error.noInputDevice"
    case voiceErrorOutputFormatUnavailable = "voice.error.outputFormatUnavailable"
    case voiceErrorMicrophoneUnknown = "voice.error.microphoneUnknown"

    // Pet
    case petCallBegin = "pet.callBegin"
    case petCallEnd = "pet.callEnd"
    case petMute = "pet.mute"
    case petUnmute = "pet.unmute"
    case petInterrupt = "pet.interrupt"
    case petAccessibilityLabel = "pet.accessibilityLabel"
    case petShowWindow = "pet.showWindow"
    case petHideWindow = "pet.hideWindow"
    case petWindowHint = "pet.windowHint"
    case petMicrophoneNotice = "pet.microphoneNotice"

    // Windows
    case windowMainTitle = "window.main.title"
    case windowOnboardingTitle = "window.onboarding.title"
    case windowPetTitle = "window.pet.title"

    // Settings: the sidebar's four groups and its thirteen panes
    case settingsGroupAssistant = "settings.group.assistant"
    case settingsGroupConnections = "settings.group.connections"
    case settingsGroupCapabilities = "settings.group.capabilities"
    case settingsGroupSystem = "settings.group.system"
    case settingsPaneProviders = "settings.pane.providers"
    case settingsPanePersonality = "settings.pane.personality"
    case settingsPaneMemory = "settings.pane.memory"
    case settingsPaneChannels = "settings.pane.channels"
    case settingsPaneIntegrations = "settings.pane.integrations"
    case settingsPaneVoice = "settings.pane.voice"
    case settingsPaneMeetings = "settings.pane.meetings"
    case settingsPaneComputer = "settings.pane.computer"
    case settingsPaneCodingAgents = "settings.pane.codingAgents"
    case settingsPaneSearch = "settings.pane.search"
    case settingsPaneImages = "settings.pane.images"
    case settingsPaneSandbox = "settings.pane.sandbox"
    case settingsPanePermissions = "settings.pane.permissions"

    // Settings: what the sidebar search answers to, beyond the pane titles
    case settingsKeywordsProviders = "settings.keywords.providers"
    case settingsKeywordsPersonality = "settings.keywords.personality"
    case settingsKeywordsMemory = "settings.keywords.memory"
    case settingsKeywordsChannels = "settings.keywords.channels"
    case settingsKeywordsIntegrations = "settings.keywords.integrations"
    case settingsKeywordsVoice = "settings.keywords.voice"
    case settingsKeywordsMeetings = "settings.keywords.meetings"
    case settingsKeywordsComputer = "settings.keywords.computer"
    case settingsKeywordsCodingAgents = "settings.keywords.codingAgents"
    case settingsKeywordsSearch = "settings.keywords.search"
    case settingsKeywordsImages = "settings.keywords.images"
    case settingsKeywordsSandbox = "settings.keywords.sandbox"
    case settingsKeywordsPermissions = "settings.keywords.permissions"

    // Settings: the presentation's own chrome, banners and the restart sheet
    /// The back control's label, and what VoiceOver reads on it (decision D1).
    case settingsBackAccessibility = "settings.back.accessibility"
    /// One deep link's title, wherever a row opens a pane: Home's Attention
    /// rows and Doctor's remediations both read it, so the two cannot spell
    /// "Open Providers" differently.
    case settingsOpenPaneFormat = "settings.openPaneFormat"
    case settingsSearchPrompt = "settings.searchPrompt"
    case settingsRequiresNewerEngine = "settings.requiresNewerEngine"
    /// The other half of the newer-engine state: the daemon in memory already
    /// is the engine this copy ships, so no restart can serve these panes.
    case settingsEngineBehindApp = "settings.engineBehindApp"
    case settingsRowUnsupported = "settings.rowUnsupported"
    case settingsExternalChangeTitle = "settings.externalChange.title"
    case settingsExternalChangeBody = "settings.externalChange.body"
    case settingsExternalChangeAction = "settings.externalChange.action"
    case settingsConfigUnreadableTitle = "settings.configUnreadable.title"
    case settingsConfigUnreadableBody = "settings.configUnreadable.body"
    case settingsConfigUnreadableAction = "settings.configUnreadable.action"
    case settingsRestartTitle = "settings.restart.title"
    case settingsRestartAction = "settings.restart.action"
    case settingsRestartSheetTitle = "settings.restart.sheetTitle"
    case settingsEngineSheetTitle = "settings.engine.sheetTitle"
    case settingsRestartNow = "settings.restart.now"
    case settingsRestartWhenIdle = "settings.restart.whenIdle"
    case settingsRestartCancel = "settings.restart.cancel"
    case settingsRestartInFlightOne = "settings.restart.inFlight.one"
    case settingsRestartInFlightMany = "settings.restart.inFlight.many"
    case settingsRestartWaiting = "settings.restart.waiting"
    case settingsRestartStillBusy = "settings.restart.stillBusy"

    // Settings: shared row and sheet controls
    case settingsSheetCancel = "settings.sheet.cancel"
    case settingsSheetDone = "settings.sheet.done"
    case settingsSecretStored = "settings.secret.stored"
    case settingsSecretReplace = "settings.secret.replace"
    case settingsSecretRemove = "settings.secret.remove"
    case settingsSecretAdd = "settings.secret.add"
    case settingsSecretStore = "settings.secret.store"
    case settingsSecretPrompt = "settings.secret.prompt"
    case settingsNumberPercentFormat = "settings.number.percentFormat"
    case settingsListAdd = "settings.list.add"
    case settingsListAddPrompt = "settings.list.addPrompt"
    case settingsTextEmptyPrompt = "settings.text.emptyPrompt"
    case settingsChoiceNotSet = "settings.choice.notSet"
    case settingsChoiceSuggestions = "settings.choice.suggestions"
    case settingsListRemove = "settings.list.remove"
    case settingsJobCancel = "settings.job.cancel"
    case settingsJobTimedOut = "settings.job.timedOut"

    /// The ten job phases the contract publishes, in the app's own words. The
    /// wire value is an atom, so the sentence is the app's (M34 §7.3).
    case jobPhaseAwaitingBrowser = "job.phase.awaitingBrowser"
    case jobPhaseAwaitingSignIn = "job.phase.awaitingSignIn"
    case jobPhaseBinding = "job.phase.binding"
    case jobPhaseBindingWorkspace = "job.phase.bindingWorkspace"
    case jobPhaseCalling = "job.phase.calling"
    case jobPhaseDownloading = "job.phase.downloading"
    case jobPhaseListing = "job.phase.listing"
    case jobPhaseProbing = "job.phase.probing"
    case jobPhaseReadingKeychain = "job.phase.readingKeychain"
    case jobPhaseSidecarDownloading = "job.phase.sidecarDownloading"
    case jobPhaseVerifying = "job.phase.verifying"
    case jobPhaseVerifyingSignIn = "job.phase.verifyingSignIn"
    case settingsInstall = "settings.install"

    // Settings: the hand-built sections
    case settingsPrimarySection = "settings.primarySection"
    case settingsPrimaryFooterFormat = "settings.primaryFooterFormat"
    case settingsPrimaryUnconfiguredBody = "settings.primaryUnconfiguredBody"
    case settingsProvidersSection = "settings.providersSection"
    case settingsChannelsSection = "settings.channelsSection"
    case settingsVoiceLocalSection = "settings.voice.localSection"
    case settingsVoiceMicrophoneSection = "settings.voice.microphoneSection"
    case settingsVoiceLocalTitle = "settings.voice.localTitle"
    case settingsMeetingsSharedSection = "settings.meetings.sharedSection"
    case settingsMeetingsZoomSection = "settings.meetings.zoomSection"
    case settingsMeetingsEnableFooter = "settings.meetings.enableFooter"
    case settingsMeetingsGoogleSection = "settings.meetings.googleSection"
    case settingsMeetingsSignInTitle = "settings.meetings.signInTitle"
    case settingsMeetingsSignInAction = "settings.meetings.signInAction"
    case settingsMeetingsSignInAgainAction = "settings.meetings.signInAgainAction"
    case settingsMeetingsGoogleAccountLabel = "settings.meetings.googleAccountLabel"
    case settingsMeetingsSignInNotice = "settings.meetings.signInNotice"

    // Providers
    case providerVerbSignIn = "provider.verb.signIn"
    case providerVerbImportClaudeCode = "provider.verb.importClaudeCode"
    case providerVerbImportCodexCLI = "provider.verb.importCodexCLI"
    case providerVerbAddSetupToken = "provider.verb.addSetupToken"
    case providerVerbAddKey = "provider.verb.addKey"
    case providerStatusSigningIn = "provider.status.signingIn"
    case providerStatusReconnect = "provider.status.reconnect"
    case providerStatusPrimary = "provider.status.primary"
    case providerStatusConnected = "provider.status.connected"
    case providerStatusKeyUnverified = "provider.status.keyUnverified"
    case providerStatusNotConnected = "provider.status.notConnected"
    case providerUsePrimary = "provider.usePrimary"
    case providerPrimaryConfirmTitle = "provider.primaryConfirm.title"
    case providerPrimaryConfirmBody = "provider.primaryConfirm.body"
    case providerAddKeyTitle = "provider.addKey.title"
    case providerAddKeyProvider = "provider.addKey.provider"
    case providerAddKeySubcopyFormat = "provider.addKey.subcopyFormat"
    case providerVerifyAndSave = "provider.verifyAndSave"
    case providerSignInTitle = "provider.signIn.title"
    case providerSignInBody = "provider.signIn.body"
    case providerSignInReopen = "provider.signIn.reopen"
    case providerSignInBrowser = "provider.signIn.browser"
    case providerSignInRetry = "provider.signIn.retry"
    case providerSignInOpenFailed = "provider.signIn.openFailed"
    case providerSignInExpired = "provider.signIn.expired"
    case providerImportTitle = "provider.import.title"
    case providerImportBody = "provider.import.body"
    case providerSetupTokenBody = "provider.setupToken.body"
    case providerModelsTitle = "provider.models.title"
    case providerModelsSearchPrompt = "provider.models.searchPrompt"
    case providerModelsMore = "provider.models.more"
    case providerModelsChoose = "provider.models.choose"
    /// The provider sub-page (M34 §5.1): the way in, and the two verbs that
    /// live there rather than on the row.
    case providerDetails = "provider.details"
    case providerSignOut = "provider.signOut"

    // Channels
    case channelStatusOff = "channel.status.off"
    case channelStatusNeedsSetup = "channel.status.needsSetup"
    case channelStatusConnected = "channel.status.connected"
    case channelSetUp = "channel.setUp"
    case channelSheetFooter = "channel.sheetFooter"
    case channelManage = "channel.manage"
    case channelEnable = "channel.enable"

    // Computer
    case computerRightsSection = "computer.rightsSection"
    case computerGrantTitle = "computer.grant.title"
    case computerGrantAction = "computer.grant.action"
    case computerAppsTitle = "computer.apps.title"
    case computerAppsSearchPrompt = "computer.apps.searchPrompt"
    case computerAppsChoose = "computer.apps.choose"
    case computerAppsCountFormat = "computer.apps.countFormat"
    case computerAppsSelectedFormat = "computer.apps.selectedFormat"

    // Permissions
    case permissionMicrophoneTitle = "permission.microphone.title"
    case permissionScreenRecordingTitle = "permission.screenRecording.title"
    case permissionInputControlTitle = "permission.inputControl.title"
    case permissionBackgroundServiceTitle = "permission.backgroundService.title"
    case permissionPrincipalApp = "permission.principal.app"
    case permissionPrincipalComputerUse = "permission.principal.computerUse"
    case permissionPrincipalAgent = "permission.principal.agent"
    case permissionStateGranted = "permission.state.granted"
    case permissionStateNotGranted = "permission.state.notGranted"
    case permissionStateRequiresApproval = "permission.state.requiresApproval"
    case permissionStateUnknown = "permission.state.unknown"
    case permissionActionGrant = "permission.action.grant"
    case permissionActionOpenSettings = "permission.action.openSettings"
    case permissionActionOpenLoginItems = "permission.action.openLoginItems"
    case permissionsRightsSection = "permissions.rightsSection"
    case permissionsFactsSection = "permissions.factsSection"
    case permissionsBrowserFact = "permissions.browserFact"
    case permissionsKeychainProfile = "permissions.keychainProfile"
    case permissionsProfileUnknown = "permissions.profileUnknown"

    // Integrations
    case integrationsClientsSection = "integrations.clientsSection"
    /// The Codex-shaped page (decision D6): a subtitle, four counted pills, a
    /// search field and one no-results line.
    case integrationsSubtitle = "integrations.subtitle"
    case integrationsSearchPrompt = "integrations.searchPrompt"
    case integrationsFilterInstalled = "integrations.filter.installed"
    case integrationsFilterAvailable = "integrations.filter.available"
    case integrationsFilterMCPs = "integrations.filter.mcps"
    case integrationsFilterFeatures = "integrations.filter.features"
    case integrationsNoResults = "integrations.noResults"
    /// A sheet whose plugin the catalogue no longer carries. Distinct from a
    /// search that matched nothing: one is a filter, the other is a plugin that
    /// went away while its sheet was open.
    case integrationGone = "integration.gone"
    case integrationEnabled = "integration.enabled"
    case integrationOpen = "integration.open"
    case integrationDisconnect = "integration.disconnect"
    case integrationVerbsSection = "integration.verbsSection"
    case integrationNextStep = "integration.nextStep"
    case integrationSettingsSection = "integration.settingsSection"
    case integrationWorkspaceRow = "integration.workspace.row"
    case integrationWorkspaceChoose = "integration.workspace.choose"
    case integrationWorkspaceUnset = "integration.workspace.unset"
    case integrationWorkspaceTitle = "integration.workspace.title"
    case integrationWorkspaceAccessSection = "integration.workspace.accessSection"
    case integrationWorkspaceWriteWarning = "integration.workspace.writeWarning"
    case integrationWorkspaceFind = "integration.workspace.find"
    case integrationWorkspaceUse = "integration.workspace.use"
    case integrationWorkspaceEmpty = "integration.workspace.empty"
    case integrationClientRow = "integration.client.row"
    case integrationClientEdit = "integration.client.edit"
    case integrationClientConnect = "integration.client.connect"
    case integrationClientIdentifier = "integration.client.identifier"
    case integrationClientSecret = "integration.client.secret"
    case integrationClientPort = "integration.client.port"
    case integrationClientPortPrompt = "integration.client.portPrompt"
    case integrationClientPortInvalid = "integration.client.portInvalid"
    case codingNotInstalled = "coding.notInstalled"
    case codingInstalled = "coding.installed"
    case codingAuthenticated = "coding.authenticated"
    case codingAuthUnverified = "coding.authUnverified"
    case codingAuthAbsent = "coding.authAbsent"
    case codingDetectionUnavailable = "coding.detectionUnavailable"
    case codingCheckAgain = "coding.checkAgain"
    /// The three native driver features the Features pill counts. They are rows
    /// that open their own pane, never a second copy of that pane's toggle.
    case integrationFeatureComputerUse = "integration.feature.computerUse"
    case integrationFeatureComputerUseBody = "integration.feature.computerUse.body"
    case integrationFeatureComputerHistory = "integration.feature.computerHistory"
    case integrationFeatureComputerHistoryBody = "integration.feature.computerHistory.body"
    case integrationFeatureMeetings = "integration.feature.meetings"
    case integrationFeatureMeetingsBody = "integration.feature.meetings.body"
    case integrationFeatureOn = "integration.feature.on"
    case integrationFeatureOff = "integration.feature.off"
    case integrationFeatureUnread = "integration.feature.unread"
    case integrationInstall = "integration.install"
    case integrationEnable = "integration.enable"
    case integrationDisable = "integration.disable"
    case integrationSignIn = "integration.signIn"
    case integrationAddToken = "integration.addToken"
    case integrationReplaceToken = "integration.replaceToken"
    case integrationSetUpClient = "integration.setUpClient"
    case integrationCheck = "integration.check"
    case integrationClientSet = "integration.client.set"
    case integrationClientUnset = "integration.client.unset"
    case integrationDisclosureTitle = "integration.disclosure.title"
    case integrationTokenLabel = "integration.token.label"

    // Menu bar status item
    case menuStateStarting = "menu.state.starting"
    case menuGlyphRunning = "menu.glyph.running"
    case menuGlyphStarting = "menu.glyph.starting"
    case menuGlyphAttention = "menu.glyph.attention"
    case statusMenuRunningFormat = "statusMenu.runningFormat"
    case statusMenuRestartPending = "statusMenu.restartPending"
    case statusMenuHideHint = "statusMenu.hideHint"

    // Toolbars
    case toolbarMore = "toolbar.more"

    // The product name, wherever the product names itself.
    case productName = "product.name"

    // Grouped-form section headers. Title case is the second recorded exception
    // to the sentence-case rule (M34 §14 decision 4), and it lives in its own
    // catalogue section so the exception is a prefix rather than a list.
    case sectionHeaderBackground = "sectionHeader.background"
    case sectionHeaderAttention = "sectionHeader.attention"
    case sectionHeaderRuntime = "sectionHeader.runtime"
    case sectionHeaderChecks = "sectionHeader.checks"
    case sectionHeaderVersions = "sectionHeader.versions"

    // Menu titles. Title case is the first recorded exception to the
    // sentence-case rule (M34 §14 decision 4); the `menuTitle.` prefix is what
    // the copy gate exempts, so nothing outside this section can borrow it.
    case menuTitleFile = "menuTitle.file"
    case menuTitleEdit = "menuTitle.edit"
    case menuTitleView = "menuTitle.view"
    case menuTitleDaemon = "menuTitle.daemon"
    case menuTitleWindow = "menuTitle.window"
    case menuTitleHelpMenu = "menuTitle.helpMenu"
    case menuTitleAbout = "menuTitle.about"
    case menuTitleCheckForUpdates = "menuTitle.checkForUpdates"
    case menuTitleServices = "menuTitle.services"
    case menuTitleHide = "menuTitle.hide"
    case menuTitleHideOthers = "menuTitle.hideOthers"
    case menuTitleShowAll = "menuTitle.showAll"
    case menuTitleQuit = "menuTitle.quit"
    case menuTitleCloseWindow = "menuTitle.closeWindow"
    case menuTitleExportLogs = "menuTitle.exportLogs"
    case menuTitleCopyLogs = "menuTitle.copyLogs"
    case menuTitleExportSupportBundle = "menuTitle.exportSupportBundle"
    case menuTitleRevealLogFolder = "menuTitle.revealLogFolder"
    case menuTitleUndo = "menuTitle.undo"
    case menuTitleRedo = "menuTitle.redo"
    case menuTitleCut = "menuTitle.cut"
    case menuTitleCopy = "menuTitle.copy"
    case menuTitlePaste = "menuTitle.paste"
    case menuTitleDelete = "menuTitle.delete"
    case menuTitleSelectAll = "menuTitle.selectAll"
    case menuTitleFind = "menuTitle.find"
    case menuTitleShowSidebar = "menuTitle.showSidebar"
    case menuTitleHideSidebar = "menuTitle.hideSidebar"
    case menuTitleHome = "menuTitle.home"
    case menuTitleDoctor = "menuTitle.doctor"
    case menuTitleLogs = "menuTitle.logs"
    case menuTitlePet = "menuTitle.pet"
    case menuTitleRunLocalChecks = "menuTitle.runLocalChecks"
    case menuTitleRunNetworkChecks = "menuTitle.runNetworkChecks"
    case menuTitlePauseLogs = "menuTitle.pauseLogs"
    case menuTitleResumeLogs = "menuTitle.resumeLogs"
    case menuTitleRestartDaemon = "menuTitle.restartDaemon"
    case menuTitleOpenSetupAssistant = "menuTitle.openSetupAssistant"
    case menuTitleEnableService = "menuTitle.enableService"
    case menuTitleDisableService = "menuTitle.disableService"
    case menuTitleMinimize = "menuTitle.minimize"
    case menuTitleZoom = "menuTitle.zoom"
    case menuTitleBringAllToFront = "menuTitle.bringAllToFront"
    case menuTitleHelpItem = "menuTitle.helpItem"
    case menuTitleSettings = "menuTitle.settings"
    case menuTitleOpenFermix = "menuTitle.openFermix"
    case menuTitleRunDoctor = "menuTitle.runDoctor"
    case menuTitleShowPet = "menuTitle.showPet"
    case menuTitleHidePet = "menuTitle.hidePet"
    case menuTitleHideMenuBarItem = "menuTitle.hideMenuBarItem"
    case menuTitleLinkCommandLineTool = "menuTitle.linkCommandLineTool"

    // Shared formats and humane times
    case formatMiddot = "format.middot"
    case formatCommaPair = "format.commaPair"
    case progressStepFormat = "progress.stepFormat"
    case timeJustNow = "time.justNow"
    case timeDay = "time.day"
    case timeDays = "time.days"
    case timeHour = "time.hour"
    case timeHours = "time.hours"
    case timeMinute = "time.minute"
    case timeMinutes = "time.minutes"

    /// The one recorded exception to the sentence-case rule (M34 §14 decision
    /// 4): macOS menu titles.
    ///
    /// Membership is a prefix rather than a list, so a key can only claim the
    /// exception by living in the catalogue section that owns it.
    ///
    /// Decision 4's second exception, title-case section headers in a grouped
    /// `Form`, is withdrawn. It was keyed on this prefix, which reached only
    /// Home's three single-word headers; ten Settings headers live under other
    /// keys and were gated as sentence case, and every daemon-owned section
    /// title arrives in sentence case off the wire (`Model behaviour`,
    /// `Voice notes`). One window cannot hold both schemes, and the app cannot
    /// change the engine's half, so the app's half follows the engine's.
    public static let titleCasePrefixes = ["menuTitle."]

    public var usesTitleCase: Bool {
        Self.titleCasePrefixes.contains { rawValue.hasPrefix($0) }
    }
}

/// The states Starting can end in (M34 §4, §15.2).
///
/// Every refusal that precedes a mutation is here as its own case, because a
/// failure kind folded onto a neighbour sends the operator after the wrong
/// remedy: the two legacy-unit scopes need different commands, and a foreign
/// daemon is not an older one.
public enum BootFailureCause: String, CaseIterable, Sendable {
    case timedOut
    case approvalPending
    case backgroundItemDisabled
    case incompatibleVersion
    case crashLoop
    case bindFailure
    case webUnavailable
    /// The bundled engine failed its signature and manifest check, or the
    /// identity probe this bundle ships could not run at all. Reinstalling is
    /// the remedy, and it is the only cause whose sentence says so.
    case invalidPackage
    /// `launcher.json` cannot be read or written. Distinct from a bad bundle:
    /// the app is fine and the file under Application Support is not, so the
    /// sentence names the file rather than sending anyone to reinstall.
    case bootstrapRecordUnusable
    /// macOS refused to register the background item, or reports it as not
    /// found. Distinct again: nothing about the engine is wrong.
    case registrationFailed
    /// Something is on `daemon.sock` and did not answer. Distinct from a
    /// pre-management daemon, which *answered* and did not speak management v1:
    /// a management daemon mid-restart is not an older one, and must not be
    /// told to run the upgrade commands (M34 §15.2).
    case daemonUnresponsive
    case notInApplications
    case legacyInstallPresent
    /// A unit installed for every account on this Mac. Distinct from the
    /// user-scope one because removing it needs administrator rights the app
    /// does not take, so the sentence and the action differ (M34 §15.2).
    case legacySystemInstallPresent
    /// A management daemon from another distribution is already on this home.
    case foreignDaemonRunning
    /// Something answered on `daemon.sock` that does not speak management v1.
    case preManagementDaemonRunning
    /// A management daemon on this home answered `hello` with a refusal rather
    /// than an identity. Distinct from the pre-management cause because it
    /// speaks management: sending its owner to `brew upgrade fermix` would name
    /// a remedy for a daemon that is already past that (M34 §15.2).
    case daemonRefusedIdentity
    /// LaunchServices knows more than one copy of this bundle id.
    case duplicateCopyPresent
    /// `fermix migrate-to-app` left a handoff journal naming a home this app
    /// cannot adopt. The journal is left in place so the verb can be re-run.
    case migrationHandoffInvalid

    var stringKey: ProductStringKey {
        switch self {
        case .timedOut: return .bootFailedCauseTimedOut
        case .approvalPending: return .bootFailedCauseApprovalPending
        case .backgroundItemDisabled: return .bootFailedCauseBackgroundItemDisabled
        case .incompatibleVersion: return .bootFailedCauseIncompatibleVersion
        case .crashLoop: return .bootFailedCauseCrashLoop
        case .bindFailure: return .bootFailedCauseBindFailure
        case .webUnavailable: return .bootFailedCauseWebUnavailable
        case .invalidPackage: return .bootFailedCauseInvalidPackage
        case .bootstrapRecordUnusable: return .bootFailedCauseBootstrapRecordUnusable
        case .registrationFailed: return .bootFailedCauseRegistrationFailed
        case .daemonUnresponsive: return .bootFailedCauseDaemonUnresponsive
        case .notInApplications: return .bootFailedCauseNotInApplications
        case .legacyInstallPresent: return .bootFailedCauseLegacyInstallPresent
        case .legacySystemInstallPresent: return .bootFailedCauseLegacySystemInstallPresent
        case .foreignDaemonRunning: return .bootFailedCauseForeignDaemonRunning
        case .preManagementDaemonRunning: return .bootFailedCausePreManagementDaemonRunning
        case .daemonRefusedIdentity: return .bootFailedCauseDaemonRefusedIdentity
        case .duplicateCopyPresent: return .bootFailedCauseDuplicateCopyPresent
        case .migrationHandoffInvalid: return .bootFailedCauseMigrationHandoffInvalid
        }
    }
}

/// Why a migration handoff journal was refused, in one sentence.
///
/// The card names the journal file; this names what is wrong with it. Three
/// closed switches with no default, so a defect added to any of the three enums
/// has to be given copy rather than reaching the operator as a Swift value
/// description of an enum case (M34 §15.2).
extension MigrationHandoffDefect {
    var stringKey: ProductStringKey {
        switch self {
        case .unreadable: return .handoffUnreadable
        case .malformed: return .handoffMalformed
        case .unsupportedSchemaVersion: return .handoffUnsupportedSchemaVersion
        case .invalidHome(let defect): return defect.stringKey
        }
    }
}

extension BootstrapHomeDefect {
    var stringKey: ProductStringKey {
        switch self {
        case .empty: return .handoffHomeEmpty
        case .notAbsolute: return .handoffHomeNotAbsolute
        case .relativeTraversal: return .handoffHomeRelativeTraversal
        case .notADirectory: return .handoffHomeNotADirectory
        case .notOwnedByCurrentUser: return .handoffHomeNotOwned
        case .notWritable: return .handoffHomeNotWritable
        case .forbiddenLocation(_, let reason): return reason.stringKey
        }
    }
}

extension ForbiddenHomeReason {
    var stringKey: ProductStringKey {
        switch self {
        case .filesystemRoot: return .handoffHomeFilesystemRoot
        case .accountHome: return .handoffHomeAccountHome
        case .systemDirectory: return .handoffHomeSystemDirectory
        case .applicationsDirectory: return .handoffHomeApplicationsDirectory
        case .temporaryDirectory: return .handoffHomeTemporaryDirectory
        case .cloudSyncedDirectory: return .handoffHomeCloudSyncedDirectory
        case .bootstrapDirectory: return .handoffHomeBootstrapDirectory
        }
    }
}

/// Reads the shipped catalogue.
public enum ProductStrings {
    public static subscript(_ key: ProductStringKey) -> String {
        AppResources.bundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }

    public static func bootFailure(_ cause: BootFailureCause) -> String {
        self[cause.stringKey]
    }

    /// The sentence a refused migration handoff renders under the boot-failure
    /// copy, beside the path of the journal it refused.
    public static func handoffDefect(_ defect: MigrationHandoffDefect) -> String {
        self[defect.stringKey]
    }

    /// Two facts joined by the interpunct the design uses everywhere a status
    /// line carries a second fact.
    public static func middot(_ leading: String, _ trailing: String) -> String {
        String(format: self[.formatMiddot], leading, trailing)
    }

    public static func commaPair(_ leading: String, _ trailing: String) -> String {
        String(format: self[.formatCommaPair], leading, trailing)
    }

    /// The catalogue file itself, so the copy gate can read the shipped bytes
    /// rather than a copy of them.
    public static var catalogueURL: URL? {
        AppResources.bundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: "en"
        )
    }
}
