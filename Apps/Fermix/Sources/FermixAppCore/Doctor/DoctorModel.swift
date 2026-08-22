import AppKit
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

    private let gateway: any DaemonQuerying
    private let logFolder: () throws -> URL
    private let revealer: any FolderRevealing
    private let sleeper: any Sleeping
    private let log = AppLog.logger(.app)
    /// Set by `cancel`, read by the poll loop. Cancellation is a fact the model
    /// owns rather than a task the surface has to hold, which is what keeps
    /// "the run stopped" and "the daemon was told" in one order.
    private var cancelRequested = false

    public init(
        gateway: any DaemonQuerying,
        logFolder: @escaping () throws -> URL,
        revealer: any FolderRevealing = WorkspaceFolderRevealer(),
        sleeper: any Sleeping = TaskSleeper()
    ) {
        self.gateway = gateway
        self.logFolder = logFolder
        self.revealer = revealer
        self.sleeper = sleeper
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
