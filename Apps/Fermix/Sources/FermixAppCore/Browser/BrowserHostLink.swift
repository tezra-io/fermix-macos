import Foundation

/// `host_stopping` and its answer, the quit's half of the host wire
/// (plan §4.0). The wire client implements it.
@MainActor
public protocol BrowserHostStopping: AnyObject {
    /// Sends `host_stopping`. `answered` runs when the daemon answers, on the
    /// main actor. It may never run, because the answer can be lost with the
    /// connection, and the quit's bound is what ends the wait then.
    func sendHostStopping(answered: @escaping @MainActor () -> Void)
}

/// The person's cancel of a task, from the tab it owns. The wire client
/// implements it.
@MainActor
public protocol BrowserTaskCancelling: AnyObject {
    func cancelTask(_ task: BrowserTaskID)
}

/// The daemon's end of one `browser_host` connection, as the host sees it:
/// what the host tells the daemon unasked. The wire client implements it and
/// hands itself to the browser coordinator as it attaches.
@MainActor
public protocol BrowserHostLink: BrowserHostStopping, BrowserTaskCancelling {
    func reportAvailability(_ availability: BrowserAvailability)
    /// A task's tab closed without the task's release: its page closed its
    /// own window.
    func tabClosed(_ tab: BrowserTab.ID, task: BrowserTaskID)
    /// A task's download, by its own id: it began writing `filename` into the
    /// task's directory, it moved, and it ended. The person's downloads never
    /// cross the wire.
    func downloadBegan(_ download: UUID, tab: BrowserTab.ID, filename: String)
    func downloadProgressed(_ download: UUID, receivedBytes: Int, totalBytes: Int?)
    func downloadFinished(_ download: UUID, tab: BrowserTab.ID, outcome: BrowserDownloadOutcome)
}

/// How a task's download ended, as `download.finished` carries it.
public enum BrowserDownloadOutcome: Equatable, Sendable {
    /// The whole file is at `path`, inside the task's download directory.
    /// `bytes` is its size, where it could be read.
    case completed(path: String, bytes: Int?)
    /// It stopped short, in the system's own sentence.
    case failed(reason: String)
    /// The host stopped it.
    case cancelled(reason: String)
}

/// The host's part of a quit, as the app coordinator asks for it.
@MainActor
public protocol BrowserHostQuitting: AnyObject {
    /// Starts the host's part of a quit. `done` runs once: at once where there
    /// is no daemon to tell, and otherwise when the daemon answers
    /// `host_stopping` or the bound elapses, whichever comes first.
    ///
    /// Called from the run loop, never from inside a main-actor task: AppKit
    /// spins a nested run loop while a termination is held, and main-actor work
    /// queued behind the block that entered it never runs (plan §4.8).
    func stopHost(done: @escaping @MainActor () -> Void)
}
