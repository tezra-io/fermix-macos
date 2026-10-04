import AVFoundation
import Foundation

/// A right the product needs, and the identity that holds it (M34 §5.9).
///
/// The principal is on the row because one consent never implies another: the
/// microphone is the GUI's, screen capture and input control belong to the
/// separate signed helper, the background item is the agent's, and the three
/// iMessage rights belong to Fermix Messages (M54 §10.2).
public enum PermissionRight: String, CaseIterable, Sendable {
    case microphone
    case screenRecording
    case inputControl
    case backgroundService
    /// Full Disk Access, which is what lets the helper read the Messages
    /// database.
    case messagesData
    case messagesAutomation
    /// Who Fermix may message: the recipients the owner confirmed in the
    /// helper's own dialog.
    case messagesRecipients

    public var titleKey: ProductStringKey {
        switch self {
        case .microphone: return .permissionMicrophoneTitle
        case .screenRecording: return .permissionScreenRecordingTitle
        case .inputControl: return .permissionInputControlTitle
        case .backgroundService: return .permissionBackgroundServiceTitle
        case .messagesData: return .permissionMessagesDataTitle
        case .messagesAutomation: return .permissionMessagesAutomationTitle
        case .messagesRecipients: return .permissionMessagesRecipientsTitle
        }
    }

    public var principalKey: ProductStringKey {
        switch self {
        case .microphone: return .permissionPrincipalApp
        case .screenRecording, .inputControl: return .permissionPrincipalComputerUse
        case .backgroundService: return .permissionPrincipalAgent
        case .messagesData, .messagesAutomation, .messagesRecipients: return .permissionPrincipalMessages
        }
    }

    /// The word a state reads as on this row. A recipient record is confirmed
    /// or waiting for the owner rather than granted, so that row says so.
    public func stateTitleKey(_ state: PermissionState) -> ProductStringKey {
        guard self == .messagesRecipients else { return state.titleKey }

        switch state {
        case .granted: return .permissionStateConfirmed
        case .notGranted, .requiresApproval: return .permissionStateAwaitingConfirmation
        case .unknown: return state.titleKey
        }
    }

    /// Whether the daemon is what answers for this right. The computer-use
    /// helper's two come from `computer_use.permissions.get` and the iMessage
    /// helper's three from `imessage.permissions.get`, both protocol v2; the
    /// other two this process reads for itself.
    public var readByDaemon: Bool { self != .microphone && self != .backgroundService }

    /// Whether this is one of the iMessage helper's rights, which a Mac that
    /// has never used the channel does not see.
    public var isMessages: Bool {
        self == .messagesData || self == .messagesAutomation || self == .messagesRecipients
    }
}

/// What a right is, right now. `unknown` is a real answer: nothing prompts on
/// render, so a right the app has not been told about says so.
public enum PermissionState: Equatable, Sendable {
    case granted
    case notGranted
    /// Registered, and macOS is waiting for the operator in Login Items.
    case requiresApproval
    case unknown

    public var titleKey: ProductStringKey {
        switch self {
        case .granted: return .permissionStateGranted
        case .notGranted: return .permissionStateNotGranted
        case .requiresApproval: return .permissionStateRequiresApproval
        case .unknown: return .permissionStateUnknown
        }
    }

    public var tone: StatusTone {
        switch self {
        case .granted: return .pass
        case .notGranted: return .warn
        case .requiresApproval: return .warn
        case .unknown: return .neutral
        }
    }
}

/// The one thing a permission row offers.
public enum PermissionAction: Equatable, Sendable {
    /// Raises the system dialog for the GUI's own microphone right.
    case requestMicrophone
    /// Runs the daemon's grant job, which raises the helper's dialogs.
    case grantComputerUse
    /// Runs `imessage.grant.start` for one service: the Automation prompt, or
    /// the Full Disk Access pane with Fermix Messages revealed.
    case grantIMessage(ManagementIMessageGrantService)
    /// Runs `imessage.policy.confirm`, which shows the helper's own dialog
    /// naming every recipient.
    case confirmIMessageRecipients
    case openSystemSettings(String)
    case openLoginItems
}

/// One row of the ledger.
public struct PermissionRowModel: Identifiable, Equatable, Sendable {
    public let right: PermissionRight
    public let state: PermissionState
    public let action: PermissionAction?

    public var id: String { right.rawValue }
    public var title: String { ProductStrings[right.titleKey] }
    public var principal: String { ProductStrings[right.principalKey] }
    public var stateWord: String { ProductStrings[right.stateTitleKey(state)] }

    /// Status is never colour alone: the word carries it and VoiceOver reads
    /// the principal beside it.
    public var accessibilityValue: String { ProductStrings.commaPair(stateWord, principal) }
}

/// Which rights a pane can truthfully draw right now.
///
/// Against a daemon one release behind, `computer_use.permissions.get` refuses,
/// so the helper's two rights have no answer. They are dropped rather than drawn
/// as `Unknown` with no action beside a pane-level notice that already says why
/// (M34 §7.1: a v2 surface renders the named state, never an empty pane).
///
/// The iMessage rights are drawn only where `showsMessages` says the channel
/// is in use, so a Mac that never used iMessage sees nothing new (M54 §10.2).
public enum PermissionVisibility {
    public static func rights(
        _ rows: [PermissionRowModel],
        requiresNewerEngine: Bool,
        showsMessages: Bool
    ) -> [PermissionRowModel] {
        rows.filter { row in
            guard !(requiresNewerEngine && row.right.readByDaemon) else { return false }

            return showsMessages || !row.right.isMessages
        }
    }

    /// Whether the iMessage rights belong on screen: the channel is switched
    /// on, or its helper is on this Mac. Either is the owner having started.
    public static func showsMessages(
        channels: [ManagementSetupChannel],
        probe: ManagementIMessagePermissions?
    ) -> Bool {
        guard probe?.installed != true else { return true }

        return channels.contains { $0.name == IMessageChannelStatus.channel && $0.enabled }
    }
}

/// The three iMessage rights, from the helper's non-prompting probe
/// (M54 §10.2).
///
/// Each row offers the one act that clears it, by the rule the computer-use
/// rows follow: the daemon's job where the helper is installed to be asked,
/// and the System Settings pane where it is not. Automation that was denied is
/// the one exception: macOS raises its prompt once, so a denial is cleared in
/// the pane rather than by asking again. Nothing here prompts.
public enum IMessageRights {
    public static func rows(_ probe: ManagementIMessagePermissions?) -> [PermissionRowModel] {
        [
            PermissionRowModel(right: .messagesData, state: dataState(probe), action: dataAction(probe)),
            PermissionRowModel(
                right: .messagesAutomation,
                state: automationState(probe),
                action: automationAction(probe)
            ),
            PermissionRowModel(
                right: .messagesRecipients,
                state: recipientsState(probe),
                action: recipientsAction(probe)
            )
        ]
    }

    private static func dataState(_ probe: ManagementIMessagePermissions?) -> PermissionState {
        switch probe?.fullDiskAccess {
        case .granted?: return .granted
        case .denied?: return .notGranted
        case .unrecognized?, nil: return .unknown
        }
    }

    private static func dataAction(_ probe: ManagementIMessagePermissions?) -> PermissionAction? {
        guard let probe, probe.fullDiskAccess != .granted else { return nil }

        return probe.installed
            ? .grantIMessage(.fullDiskAccess)
            : .openSystemSettings(PermissionLedger.fullDiskAccessPane)
    }

    /// `not_determined` has not been asked, and `unknown` (Messages is not
    /// running) cannot be read, so both are the state nobody has an answer to.
    private static func automationState(_ probe: ManagementIMessagePermissions?) -> PermissionState {
        switch probe?.automation {
        case .granted?: return .granted
        case .denied?: return .notGranted
        case .notDetermined?, .unknown?, .unrecognized?, nil: return .unknown
        }
    }

    private static func automationAction(_ probe: ManagementIMessagePermissions?) -> PermissionAction? {
        guard let probe, probe.automation != .granted else { return nil }
        guard probe.installed, probe.automation != .denied else {
            return .openSystemSettings(PermissionLedger.automationPane)
        }

        return .grantIMessage(.automation)
    }

    /// Confirmed only when the helper's record is exactly the saved recipients;
    /// anything else is the daemon's "Awaiting confirmation".
    private static func recipientsState(_ probe: ManagementIMessagePermissions?) -> PermissionState {
        guard let probe else { return .unknown }

        return recipientsConfirmed(probe) ? .granted : .notGranted
    }

    /// A helper that is not installed holds no record to confirm.
    private static func recipientsAction(_ probe: ManagementIMessagePermissions?) -> PermissionAction? {
        guard let probe, probe.installed, !recipientsConfirmed(probe) else { return nil }

        return .confirmIMessageRecipients
    }

    static func recipientsConfirmed(_ probe: ManagementIMessagePermissions) -> Bool {
        probe.policy == .confirmed && probe.policyMatchesConfig == true
    }
}

/// The GUI's own microphone right: reading it, and asking for it.
///
/// Two members because they are two different acts. Reading never prompts and
/// happens on every render of the ledger; asking raises the system dialog and
/// happens only when the operator presses the button. A seam because
/// `AVCaptureDevice` answers for the running process, so a test that touched it
/// would report whatever the machine happens to have granted.
public protocol MicrophoneAuthorizationReading: Sendable {
    var microphoneState: PermissionState { get }
    /// Raises the system dialog and answers what the operator decided.
    func requestMicrophone() async -> PermissionState
}

/// The shipped reader. `authorizationStatus` never prompts; `requestAccess`
/// does, and is reached only from the ledger's explicit action.
public struct SystemMicrophoneAuthorization: MicrophoneAuthorizationReading {
    public init() {}

    public var microphoneState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .notGranted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    public func requestMicrophone() async -> PermissionState {
        await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .notGranted
    }
}

/// The one ledger behind Permissions, Voice, Computer and the iMessage row on
/// Channels (M34 §5.9, M54 §10).
///
/// One model so the surfaces cannot disagree about a right. Nothing here
/// prompts on render: the microphone status is read, each helper's rights are
/// read from the daemon's non-prompting probe, and every grant is an explicit
/// action.
@MainActor
public final class PermissionLedger: ObservableObject {
    @Published public private(set) var rows: [PermissionRowModel] = []
    /// The daemon's answer for the helper's two rights, where it has answered.
    @Published public private(set) var computerUse: SettingsReadState<ManagementComputerUsePermissions> = .unread
    /// The iMessage helper's probe, where the daemon has answered. The Channels
    /// row's status reads it too, so the two surfaces cannot disagree.
    @Published public private(set) var imessage: SettingsReadState<ManagementIMessagePermissions> = .unread
    /// The daemon's sentence for the last recipient confirmation it refused,
    /// such as an owner that is the address Messages on this Mac is signed in
    /// as. The probe carries no such field, so the refusal is held until the
    /// next confirmation runs.
    @Published public private(set) var imessageRefusal: String?

    private let gateway: any DaemonQuerying
    private let services: ServiceController
    private let microphone: any MicrophoneAuthorizationReading
    private let settingsOpener: any SystemSettingsOpening
    private let log = AppLog.logger(.app)
    /// The background item's registration as macOS last answered. Held rather
    /// than read through, because each read is a synchronous XPC round trip of
    /// about 70 ms (`LoginRegistrations`), and the projection asked twice: the
    /// Voice pane re-projects as it appears, so opening it froze the window for
    /// both. It is read again, off the main thread, on every `refresh()`, which
    /// is what the Permissions pane that draws the row runs as it opens.
    private var agentRegistration: ServiceRegistrationStatus

    public init(
        gateway: any DaemonQuerying,
        services: ServiceController,
        microphone: any MicrophoneAuthorizationReading,
        settingsOpener: any SystemSettingsOpening = WorkspaceSystemSettingsOpener()
    ) {
        self.gateway = gateway
        self.services = services
        self.microphone = microphone
        self.settingsOpener = settingsOpener
        // Once, before the first draw, so the row never opens on a guess.
        self.agentRegistration = services.status(.agent)
        self.rows = project()
    }

    /// Re-reads every right but the iMessage helper's, which `refreshIMessage()`
    /// reads only where the channel exists. Called on pane open and on Refresh,
    /// never on render: the helper's probe is a daemon round trip.
    public func refresh() async {
        // By the rule `SettingsModel.beginRead` states: an answer already drawn
        // stays on screen while it is re-read.
        if computerUse.value == nil { publish(.loading) }
        do {
            publish(.loaded(try await gateway.computerUsePermissions()))
        } catch {
            publish(.failure(error))
            log.error(
                "computer-use permissions unavailable: \(ManagementMessage.sentence(for: error), privacy: .public)"
            )
        }

        agentRegistration = await services.registrations().agent
        publishRows()
    }

    /// Re-reads the iMessage helper's probe. Never prompts; called where the
    /// channel is published, on pane open, on the app regaining focus, and by
    /// the owner of every iMessage job once it ends.
    public func refreshIMessage() async {
        if imessage.value == nil { publishIMessage(.loading) }
        do {
            publishIMessage(.loaded(try await gateway.imessagePermissions()))
        } catch {
            publishIMessage(.failure(error))
            log.error(
                "imessage permissions unavailable: \(ManagementMessage.sentence(for: error), privacy: .public)"
            )
        }

        publishRows()
    }

    /// Records how a recipient confirmation ended. A refusal keeps the daemon's
    /// own sentence; anything else, Cancel in the helper's dialog included,
    /// clears it, and the probe says where the record stands.
    public func noteIMessageConfirmation(_ job: ManagementJob?) {
        let refused = job?.failure.flatMap { $0.code == .refused ? $0.sentence : nil }
        guard refused != imessageRefusal else { return }

        imessageRefusal = refused
    }

    /// Re-reads only what this process can answer for itself, which is what a
    /// return from System Settings needs.
    public func refreshLocalRights() {
        publishRows()
    }

    /// Raises the microphone dialog. The one prompting call in this type, and
    /// it happens only where the operator pressed the button.
    public func requestMicrophone() async {
        _ = await microphone.requestMicrophone()
        publishRows()
    }

    /// Opens the pane a row deep-links to, and answers whether it opened. A
    /// button that silently does nothing is the failure the row exists to
    /// prevent, so the caller has the answer.
    @discardableResult
    public func openSystemSettings(_ identifier: String) -> Bool {
        precondition(!identifier.isEmpty, "a deep link names its pane")

        let opened = settingsOpener.open(identifier)
        // Coming back from System Settings is what changes a local right.
        refreshLocalRights()

        return opened
    }

    /// Opens Login Items, where the background item's switch is. It goes
    /// through the service owner's documented opener, the same one setup's
    /// approval step and the Boot failed card use, so the three buttons that
    /// name the pane cannot open it three ways.
    public func openLoginItems() {
        services.openLoginItemsSettings()
    }

    public func row(_ right: PermissionRight) -> PermissionRowModel? {
        rows.first { $0.right == right }
    }

    // MARK: - Publishing

    /// Publishes the helper's answer only where it changed: each visit to
    /// Permissions or Computer re-reads it, and the answer is nearly always
    /// the one already drawn.
    private func publish(_ answer: SettingsReadState<ManagementComputerUsePermissions>) {
        guard answer != computerUse else { return }

        computerUse = answer
    }

    /// The iMessage probe, by the same rule: re-read on focus, and nearly
    /// always the answer already drawn.
    private func publishIMessage(_ answer: SettingsReadState<ManagementIMessagePermissions>) {
        guard answer != imessage else { return }

        imessage = answer
    }

    /// Publishes the projection only where it changed. The Voice pane asks for
    /// it each time it appears, and an unchanged ledger redrawing every pane
    /// that observes it is the cost this avoids.
    private func publishRows() {
        let projected = project()
        guard projected != rows else { return }

        rows = projected
    }

    // MARK: - Projection

    private func project() -> [PermissionRowModel] {
        [
            PermissionRowModel(
                right: .microphone,
                state: microphone.microphoneState,
                action: microphoneAction
            ),
            PermissionRowModel(
                right: .screenRecording,
                state: helperState(\.screenCapture),
                action: helperAction(\.screenCapture, pane: Self.screenRecordingPane)
            ),
            PermissionRowModel(
                right: .inputControl,
                state: helperState(\.inputControl),
                action: helperAction(\.inputControl, pane: Self.accessibilityPane)
            ),
            PermissionRowModel(
                right: .backgroundService,
                state: backgroundState,
                action: agentRegistration == .requiresApproval ? .openLoginItems : nil
            )
        ] + IMessageRights.rows(imessage.value)
    }

    private var microphoneAction: PermissionAction? {
        switch microphone.microphoneState {
        case .granted: return nil
        case .unknown: return .requestMicrophone
        case .notGranted, .requiresApproval: return .openSystemSettings(Self.microphonePane)
        }
    }

    private func helperState(_ right: KeyPath<ManagementComputerUsePermissions, Bool>) -> PermissionState {
        guard let permissions = computerUse.value else { return .unknown }

        return permissions[keyPath: right] ? .granted : .notGranted
    }

    /// A grant is offered only where one is missing, and the deep link beside it
    /// is what a denied right needs instead.
    private func helperAction(
        _ right: KeyPath<ManagementComputerUsePermissions, Bool>,
        pane: String
    ) -> PermissionAction? {
        guard let permissions = computerUse.value else { return nil }
        guard !permissions[keyPath: right] else { return nil }

        return permissions.installed ? .grantComputerUse : .openSystemSettings(pane)
    }

    private var backgroundState: PermissionState {
        switch agentRegistration {
        case .enabled: return .granted
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notGranted
        }
    }

    /// The System Settings panes the rows deep-link to. They are macOS's own
    /// identifiers, not copy, and they carry no scheme: the opener adds it.
    public static let microphonePane = "com.apple.preference.security?Privacy_Microphone"
    public static let screenRecordingPane = "com.apple.preference.security?Privacy_ScreenCapture"
    public static let accessibilityPane = "com.apple.preference.security?Privacy_Accessibility"
    /// The iMessage rows' two, read from outside the ledger's actor by the
    /// projection that builds those rows.
    public nonisolated static let fullDiskAccessPane = "com.apple.preference.security?Privacy_AllFiles"
    public nonisolated static let automationPane = "com.apple.preference.security?Privacy_Automation"
}
