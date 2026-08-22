import Foundation

/// Every user-visible string in the product, by key.
///
/// The raw value is the key in `Localizable.strings`. Nothing user-visible may
/// be written as a Swift literal: this enum is the only way to reach copy, and
/// `CaseIterable` is what lets the copy gate derive its case set from the
/// product rather than from a hand-listed set of screens.
public enum ProductStringKey: String, CaseIterable, Sendable {
    // Welcome
    case welcomeValue = "welcome.value"
    case welcomeCTA = "welcome.cta"
    case welcomeCaption = "welcome.caption"

    // Activate
    case activateHeadlineRegistering = "activate.headline.registering"
    case activateHeadlineStarting = "activate.headline.starting"
    case activateHeadlineAlmostReady = "activate.headline.almostReady"
    case activateCaption = "activate.caption"
    case activateMirrorChip = "activate.mirrorChip"
    case activateRowService = "activate.row.service"
    case activateRowDaemon = "activate.row.daemon"
    case activateRowSetup = "activate.row.setup"
    case activateStateDone = "activate.state.done"
    case activateStateActive = "activate.state.active"
    case activateStatePending = "activate.state.pending"

    // Connect AI
    case connectAITitle = "connectAI.title"
    case connectAISubcopy = "connectAI.subcopy"
    case connectAIChatGPTName = "connectAI.chatgpt.name"
    case connectAIChatGPTHint = "connectAI.chatgpt.hint"
    case connectAIClaudeName = "connectAI.claude.name"
    case connectAIClaudeHint = "connectAI.claude.hint"
    case connectAISignIn = "connectAI.signIn"
    case connectAIKeyRowTitle = "connectAI.keyRow.title"
    case connectAIKeyRowHint = "connectAI.keyRow.hint"
    case connectAISkip = "connectAI.skip"

    // Connect channel
    case connectChannelTitle = "connectChannel.title"
    case connectChannelSubcopy = "connectChannel.subcopy"
    case connectChannelTelegramName = "connectChannel.telegram.name"
    case connectChannelTelegramHint = "connectChannel.telegram.hint"
    case connectChannelTelegramCTA = "connectChannel.telegram.cta"
    case connectChannelSlackName = "connectChannel.slack.name"
    case connectChannelSlackHint = "connectChannel.slack.hint"
    case connectChannelDiscordName = "connectChannel.discord.name"
    case connectChannelDiscordHint = "connectChannel.discord.hint"
    case connectChannelPairing = "connectChannel.pairing"
    case connectChannelPairingHint = "connectChannel.pairingHint"
    case connectChannelPairingReady = "connectChannel.pairingReady"
    case connectChannelPairingScan = "connectChannel.pairingScan"
    case connectChannelSkip = "connectChannel.skip"

    // Onboarding gates
    case onboardingBlockedDaemon = "onboarding.blocked.daemon"
    case onboardingBlockedProvider = "onboarding.blocked.provider"
    case recoveryTitle = "recovery.title"
    case recoveryBody = "recovery.body"
    case recoveryTryAgain = "recovery.tryAgain"

    // Ready
    case readyTitle = "ready.title"
    case readyPill = "ready.pill"
    case readyCLITitle = "ready.cli.title"
    case readyCLIHint = "ready.cli.hint"
    case readyCLIHintLinked = "ready.cli.hint.linked"
    case readyCLIHintHomebrew = "ready.cli.hint.homebrew"
    case readyCLIHintForeign = "ready.cli.hint.foreign"
    case readyCLIHintNoLauncher = "ready.cli.hint.noLauncher"
    case readyCLICopy = "ready.cli.copy"
    case readyCLIVerify = "ready.cli.verify"
    case readyOpen = "ready.open"
    case readyAdvanced = "ready.advanced"

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
    case bootFailedCauseNotInApplications = "bootFailed.cause.notInApplications"
    case bootFailedCauseLegacyInstallPresent = "bootFailed.cause.legacyInstallPresent"

    // Home
    case homeStatusRunning = "home.status.running"
    case homeStatusSetupRequired = "home.status.setupRequired"
    case homeStatusUnreachable = "home.status.unreachable"
    case homeOpenSetup = "home.openSetup"
    case homeRunDoctor = "home.runDoctor"
    case homeRestartDaemon = "home.restartDaemon"
    case homeOpenAtLogin = "home.openAtLogin"
    case homeSectionRuntime = "home.section.runtime"
    case homeSectionAttention = "home.section.attention"
    case homeRuntimeEmpty = "home.runtimeEmpty"
    case homeAttentionEmpty = "home.attentionEmpty"
    case homeRuntimeEngine = "home.runtime.engine"
    case homeRuntimeProtocol = "home.runtime.protocol"
    case homeRuntimeUptime = "home.runtime.uptime"
    case homeRuntimeProvider = "home.runtime.provider"
    case homeRuntimeChannels = "home.runtime.channels"
    case homeRuntimeNone = "home.runtime.none"
    case homeAttentionSetupRequired = "home.attention.setupRequired"
    case homeAttentionServiceDisabledTitle = "home.attention.serviceDisabled.title"
    case homeAttentionServiceDisabled = "home.attention.serviceDisabled"
    case homeAttentionRestartRequiredTitle = "home.attention.restartRequired.title"
    case homeAttentionRestartRequired = "home.attention.restartRequired"
    case homeAttentionChannel = "home.attention.channel"
    case homeAttentionJobsTitle = "home.attention.jobs.title"
    case homeAttentionJobs = "home.attention.jobs"
    case homeUpdateCurrent = "home.updateCurrent"
    case homeUpdateUnknown = "home.updateUnknown"
    case homeUpdateAvailableFormat = "home.updateAvailableFormat"
    case homeUptimeFormat = "home.uptimeFormat"

    // Update and uninstall routes
    case updateTitle = "update.title"
    case updateUnwired = "update.unwired"
    case uninstallTitle = "uninstall.title"
    case uninstallBody = "uninstall.body"

    // Daemon errors, in the app's own words where the daemon has none
    case daemonErrorNotRunning = "daemon.error.notRunning"
    case daemonErrorUnreachable = "daemon.error.unreachable"
    case daemonErrorIncompatible = "daemon.error.incompatible"

    // Background service
    case serviceEnable = "service.enable"
    case serviceDisable = "service.disable"

    // Sidebar
    case sidebarHome = "sidebar.home"
    case sidebarSetup = "sidebar.setup"
    case sidebarDoctor = "sidebar.doctor"
    case sidebarPet = "sidebar.pet"
    case sidebarLogs = "sidebar.logs"

    // Setup
    case setupTitle = "setup.title"
    case setupFooterServedLocally = "setup.footer.servedLocally"
    case setupFooterOpenInBrowser = "setup.footer.openInBrowser"
    case setupOpening = "setup.opening"
    case setupRetry = "setup.retry"

    // Doctor
    case doctorTitle = "doctor.title"
    case doctorBannerHealthy = "doctor.banner.healthy"
    case doctorBannerHealthyWithWarning = "doctor.banner.healthyWithWarning"
    case doctorBannerWarningsFormat = "doctor.banner.warningsFormat"
    case doctorBannerFailingFormat = "doctor.banner.failingFormat"
    case doctorBannerExplainer = "doctor.banner.explainer"
    case doctorBannerCheckedJustNow = "doctor.banner.checkedJustNow"
    case doctorNetworkLabel = "doctor.network.label"
    case doctorNetworkBody = "doctor.network.body"
    case doctorNetworkRun = "doctor.network.run"
    case doctorSupportLabel = "doctor.support.label"
    case doctorSupportExportHint = "doctor.support.exportHint"
    case doctorSupportExport = "doctor.support.export"
    case doctorSupportExportFilename = "doctor.support.exportFilename"
    case doctorSupportOpenLogFolder = "doctor.support.openLogFolder"
    case doctorSupportHomeUnavailable = "doctor.support.homeUnavailable"
    case doctorFixHintFormat = "doctor.fixHintFormat"
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

    // Menu bar
    case menuTitle = "menu.title"
    case menuStateStarting = "menu.state.starting"
    case menuStateAttention = "menu.state.attention"
    case menuVersionFormat = "menu.versionFormat"
    case menuOpenFermix = "menu.openFermix"
    case menuSetup = "menu.setup"
    case menuRunDoctor = "menu.runDoctor"
    case menuRestartDaemon = "menu.restartDaemon"
    case menuShowPet = "menu.showPet"
    case menuShowPetHint = "menu.showPetHint"
    case menuPauseNotifications = "menu.pauseNotifications"
    case menuCheckForUpdates = "menu.checkForUpdates"
    case menuUpdatesHint = "menu.updatesHint"
    case menuQuit = "menu.quit"
    case menuQuitHint = "menu.quitHint"
    case menuGlyphRunning = "menu.glyph.running"
    case menuGlyphStarting = "menu.glyph.starting"
    case menuGlyphAttention = "menu.glyph.attention"

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
}

/// The states Activate can end in: the seven M34 §5 causes, the 90-second
/// timeout, and the two preflight refusals that stop activation before it
/// mutates anything (added after a live incident: a masked window's default
/// button ran activation from a non-Applications bundle beside a running
/// Homebrew daemon).
public enum BootFailureCause: String, CaseIterable, Sendable {
    case timedOut
    case approvalPending
    case backgroundItemDisabled
    case incompatibleVersion
    case crashLoop
    case bindFailure
    case webUnavailable
    case invalidPackage
    case notInApplications
    case legacyInstallPresent

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
        case .notInApplications: return .bootFailedCauseNotInApplications
        case .legacyInstallPresent: return .bootFailedCauseLegacyInstallPresent
        }
    }
}

/// Reads the shipped catalogue.
public enum ProductStrings {
    public static subscript(_ key: ProductStringKey) -> String {
        Bundle.module.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }

    public static func bootFailure(_ cause: BootFailureCause) -> String {
        self[cause.stringKey]
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
        Bundle.module.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: "en"
        )
    }
}
