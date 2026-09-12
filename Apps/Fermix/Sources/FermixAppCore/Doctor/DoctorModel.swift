import AppKit
import Combine
import Foundation

/// Showing a folder to the user, behind a seam.
public protocol FolderRevealing: Sendable {
    func reveal(_ url: URL)
}

/// The production revealer: the Finder, showing the folder itself.
public struct WorkspaceFolderRevealer: FolderRevealing {
    public init() {}

    public func reveal(_ url: URL) {
        MainActor.assumeIsolated {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Opening a System Settings pane, behind a seam. The identifier is the
/// daemon's own remediation target; the app never composes one.
///
/// The answer is whether the pane actually opened, because the caller has a
/// place to say so and a button that silently does nothing is the failure the
/// remediation row exists to prevent.
public protocol SystemSettingsOpening: Sendable {
    func open(_ identifier: String) -> Bool
}

/// The production opener. macOS addresses its own panes by url, and an
/// identifier that does not form one is refused rather than opening the root
/// of System Settings and leaving the user to hunt.
public struct WorkspaceSystemSettingsOpener: SystemSettingsOpening {
    public init() {}

    public func open(_ identifier: String) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return false }

        return MainActor.assumeIsolated {
            NSWorkspace.shared.open(url)
        }
    }
}

/// How Doctor polls a session it started.
public enum DoctorPolicy {
    public static let pollInterval: TimeInterval = 0.5
    /// The network scope's own whole-run deadline is 30 seconds, so the poll
    /// cap covers it with room for the daemon's own budget to fire first. A run
    /// that outlives it is reported as stalled rather than polled forever.
    public static let maximumPolls = 80
}

/// Doctor's narrow model.
///
/// It starts a session, follows it to a terminal status, and can cancel it. The
/// checks themselves are the daemon's: nothing here re-implements a check, and
/// the network scope never starts on its own.
@MainActor
public final class DoctorModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case running(ManagementDoctorScope)
        case finished
        case failed(String)
    }

    @Published public private(set) var session: ManagementDoctorSession?
    @Published public private(set) var phase: Phase = .idle
    /// What the SUPPORT card has to say about its last action, if anything. A
    /// support action that could not run says so; the run's own phase is a
    /// different fact and is never overwritten by one.
    @Published public private(set) var supportMessage: String?
    @Published public private(set) var exporting = false
    /// The bundle waiting to be written, once the daemon has produced it. The
    /// model owns the request because the export is a toolbar command and a
    /// menu command, and a `@State` inside one view could not be reached by
    /// the other.
    @Published public var pendingBundle: Data?

    private let gateway: any DaemonQuerying
    private let logFolder: () throws -> URL
    private let settingsFile: () throws -> URL
    private let revealer: any FolderRevealing
    private let settingsOpener: any SystemSettingsOpening
    /// Opens a Fermix settings pane, which decision D1 made a presentation of
    /// this same window. A closure rather than the coordinator, because the
    /// coordinator builds this model.
    private let openSettingsPane: (SettingsPane) -> Void
    private let sleeper: any Sleeping
    /// The removal commands a `instructions` remediation names, read from this
    /// Mac. The same closure Home's Attention row uses, so the two doors show
    /// one answer (M34 §15.2).
    private let instructions: () -> CoexistenceInstructions?
    /// Shows the sheet, in the one window that hosts it (M34 §15.2).
    private let showInstructionsSheet: (CoexistenceInstructions) -> Void
    /// The one Restart sheet, owned by the coordinator, so a Doctor row, an
    /// Attention row and the Daemon menu ask through one door (M34 §5.10).
    private let askForRestart: () -> Void
    /// `settings.reload`, through the one settings model that owns it. Answers
    /// the daemon's sentence on a refusal and nil on success.
    private let reloadSettings: () async -> String?
    /// The Recovery screen, which is where an unreadable settings file is
    /// answered (M34 §7.5).
    private let openRecovery: () -> Void
    private let log = AppLog.logger(.app)
    /// Set by `cancel`, read by the poll loop. Cancellation is a fact the model
    /// owns rather than a task the surface has to hold, which is what keeps
    /// "the run stopped" and "the daemon was told" in one order.
    private var cancelRequested = false

    public init(
        gateway: any DaemonQuerying,
        logFolder: @escaping () throws -> URL,
        settingsFile: @escaping () throws -> URL,
        revealer: any FolderRevealing = WorkspaceFolderRevealer(),
        settingsOpener: any SystemSettingsOpening = WorkspaceSystemSettingsOpener(),
        openSettingsPane: @escaping (SettingsPane) -> Void = { _ in },
        sleeper: any Sleeping = TaskSleeper(),
        instructions: @escaping () -> CoexistenceInstructions? = { nil },
        showInstructions: @escaping (CoexistenceInstructions) -> Void = { _ in },
        askForRestart: @escaping () -> Void = {},
        reloadSettings: @escaping () async -> String? = { nil },
        openRecovery: @escaping () -> Void = {}
    ) {
        self.gateway = gateway
        self.logFolder = logFolder
        self.settingsFile = settingsFile
        self.revealer = revealer
        self.settingsOpener = settingsOpener
        self.openSettingsPane = openSettingsPane
        self.sleeper = sleeper
        self.instructions = instructions
        self.showInstructionsSheet = showInstructions
        self.askForRestart = askForRestart
        self.reloadSettings = reloadSettings
        self.openRecovery = openRecovery
    }

    public var rows: [DoctorRowModel] {
        session.map(DoctorProjection.rows) ?? []
    }

    public var banner: DoctorBanner? {
        session.map(DoctorProjection.banner)
    }

    public var isRunning: Bool {
        if case .running = phase { return true }

        return false
    }

    /// The button's own label states what it will do, because the run costs
    /// real requests against real endpoints.
    public var networkActionTitle: String { ProductStrings[.doctorNetworkRun] }

    /// The local scope: no permission prompts, and a 10-second whole-run
    /// deadline the daemon enforces.
    public func runLocal() async {
        await start(scope: .local)
        await awaitCompletion()
    }

    /// The network scope. It runs only from here, and only because the user
    /// pressed the button that says what it costs.
    public func runNetwork() async {
        await start(scope: .network)
        await awaitCompletion()
    }

    // MARK: - Support

    /// The daemon's own bounded, field-allowlisted, scrubbed diagnostics, as
    /// the bytes the export writes. Nothing here reads a file or adds a field.
    public func exportSupportBundle() async -> Data? {
        exporting = true
        supportMessage = nil
        defer { exporting = false }

        do {
            return try ManagementDiagnosticsDocument.json(try await gateway.buildDiagnostics())
        } catch {
            log.error("diagnostics refused: \(ManagementMessage.sentence(for: error), privacy: .public)")
            supportMessage = ManagementMessage.sentence(for: error)
            return nil
        }
    }

    /// Asks the daemon for the bundle and holds it until the exporter writes
    /// it. One entry point for the toolbar and the File menu alike.
    public func requestSupportBundle() {
        guard !exporting else { return }

        Task { pendingBundle = await exportSupportBundle() }
    }

    public func clearPendingBundle() {
        pendingBundle = nil
    }

    /// Carries out a check row's one action.
    ///
    /// One entry point for every destination the daemon's remediation table can
    /// name: a System Settings pane macOS owns, a Fermix pane this same window
    /// shows since decision D1, the sheet of commands, the one Restart sheet,
    /// the settings reload, and Recovery. Each is a surface that already exists;
    /// none of them is performed here.
    public func perform(_ action: DoctorRowAction) {
        switch action {
        case .openSystemSettings(let identifier):
            openSystemSettings(identifier)
        case .openSettings(let pane):
            openSettingsPane(pane)
        case .showInstructions(let target):
            showInstructions(target)
        case .restartDaemon:
            supportMessage = nil
            askForRestart()
        case .reloadSettings:
            Task { await reloadFromDisk() }
        case .openRecovery:
            supportMessage = nil
            openRecovery()
        }
    }

    /// Re-reads the settings file the daemon refused to write over, then re-runs
    /// the checks so the row that asked for it is redrawn from the daemon's own
    /// new answer. A refusal says so where every other failed support action
    /// does.
    private func reloadFromDisk() async {
        supportMessage = nil

        guard let sentence = await reloadSettings() else {
            await runLocal()
            return
        }

        log.error("settings reload refused: \(sentence, privacy: .public)")
        supportMessage = sentence
    }

    /// Opens the sheet of commands for a gap answered outside Fermix. A target
    /// this build has no entry for shows nothing rather than an empty sheet.
    private func showInstructions(_ target: String) {
        supportMessage = nil

        guard target == CoexistenceInstructions.legacyServiceUnitRemoval, let found = instructions() else {
            log.error("no instructions for \(target, privacy: .public)")
            supportMessage = ProductStrings[.coexistenceUnavailable]
            return
        }

        showInstructionsSheet(found)
    }

    /// Opens a System Settings pane a check named. The identifier is the
    /// daemon's; nothing here composes one.
    ///
    /// A pane macOS will not open says so in the same place every other failed
    /// support action does, rather than leaving a button that appears to work.
    public func openSystemSettings(_ identifier: String) {
        supportMessage = nil

        if !settingsOpener.open(identifier) {
            log.error("system settings refused the pane \(identifier, privacy: .public)")
            supportMessage = ProductStrings[.doctorSettingsPaneUnavailable]
        }
    }

    /// Shows the daemon's rotated log directory in the Finder. An account with
    /// no recorded home has no such folder, and the card says so rather than
    /// opening nothing.
    public func openLogFolder() {
        supportMessage = nil

        do {
            revealer.reveal(try logFolder())
        } catch {
            log.error("no log folder to open: \(String(describing: error), privacy: .public)")
            supportMessage = ProductStrings[.doctorSupportHomeUnavailable]
        }
    }

    /// Shows the settings file in the Finder.
    ///
    /// This is the whole of `fermix://uninstall` in the first release: no
    /// Uninstall sheet ships, so the route lands here with one named sentence
    /// and this one action rather than a placeholder pane (M34 §3.1, §3.4).
    public func revealSettingsFile() {
        supportMessage = nil

        do {
            revealer.reveal(try settingsFile())
        } catch {
            log.error("no settings file to reveal: \(String(describing: error), privacy: .public)")
            supportMessage = ProductStrings[.doctorSupportHomeUnavailable]
        }
    }

    /// Whether the uninstall notice is showing. Set by the route, cleared when
    /// the operator leaves Doctor, so the sentence answers the url that asked
    /// for it and never appears on an ordinary visit.
    @Published public var uninstallNoticeShown = false

    /// Starts a session and returns as soon as the daemon has issued one, so
    /// the surface can draw a running run and offer Cancel.
    ///
    /// The previous run's session is dropped as the new one is declared: Cancel
    /// inside the window before the daemon answers must address no session at
    /// all, never the finished one whose id is still in hand.
    public func start(scope: ManagementDoctorScope) async {
        guard !isRunning else { return }

        phase = .running(scope)
        session = nil
        cancelRequested = false

        do {
            let started = try await gateway.startDoctor(scope: scope)
            session = started
            if started.status != .running {
                phase = .finished
            }
        } catch {
            log.error("doctor refused: \(ManagementMessage.sentence(for: error), privacy: .public)")
            phase = .failed(ManagementMessage.sentence(for: error))
        }
    }

    /// Follows the running session to a terminal status, bounded. A run that
    /// never finishes stops being polled and says so: the daemon owns the
    /// deadline, and a client that polls forever hides one that stopped
    /// answering.
    public func awaitCompletion() async {
        guard isRunning, let identifier = session?.sessionId else { return }

        do {
            for _ in 0..<DoctorPolicy.maximumPolls {
                try await sleeper.sleep(seconds: DoctorPolicy.pollInterval)
                guard isRunning, !cancelRequested else { return }

                let current = try await gateway.doctorSession(id: identifier)
                session = current

                guard current.status == .running else {
                    phase = .finished
                    return
                }
            }

            phase = .failed(ProductStrings[.doctorRunStalled])
        } catch {
            phase = .failed(ManagementMessage.sentence(for: error))
        }
    }

    /// Cancels the running session. With nothing running there is nothing to
    /// cancel, and asking the daemon anyway would mint a request for a session
    /// id it never issued.
    public func cancel() async {
        guard let identifier = session?.sessionId, isRunning else { return }

        cancelRequested = true

        do {
            session = try await gateway.cancelDoctorSession(id: identifier)
            phase = .finished
        } catch {
            phase = .failed(ManagementMessage.sentence(for: error))
        }
    }
}
