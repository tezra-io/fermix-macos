import Foundation

/// What downloads need of the pane: the wire, the person, and the pane's one
/// sentence.
@MainActor
protocol BrowserDownloadsHosting: AnyObject {
    /// The daemon's end of the host wire, while one is attached.
    var downloadLink: (any BrowserHostLink)? { get }
    /// The save panel a person's download from `tab` asks through, or nil
    /// where that tab may not ask the person anything now.
    func savePanel(for tab: BrowserTab.ID) -> (any BrowserSavePanelPresenting)?
    func say(_ notice: String)
}

/// The files the pane's pages save (plan §4.4, §8.1), from the moment WebKit
/// turns a navigation into a download until it ends.
///
/// Whose tab began a download decides where its file goes and who hears of
/// it. A task's goes into the directory its `tab.open` named, under a name no
/// file there has, and the daemon hears it begin, move and end over the host
/// wire. The person's goes where they choose in the save panel, and the
/// pane's sentence says what became of it. A task's download whose tab goes
/// is cancelled with its terminal event; the person's goes on, as a
/// browser's does when its tab is closed. A download that does not finish
/// leaves nothing behind.
///
/// It is not a download manager: nothing is listed, and nothing is kept once
/// a download has ended. The finished file's quarantine attribute is
/// WebKit's own: its network process writes it on every file it downloads,
/// so nothing here sets it a second time.
@MainActor
final class BrowserDownloads {
    /// Where a download's file goes, by whose tab began it.
    enum Route: Equatable {
        /// A task's: into the directory its `tab.open` named.
        case task(directory: URL)
        /// The person's: wherever they choose.
        case person
    }

    /// One download in flight.
    private struct Flight {
        /// Its `download_id` on the wire.
        let id = UUID()
        let download: any BrowserDownload
        let tab: BrowserTab.ID
        let route: Route
        /// Where its file is written, once that is decided. A task's download
        /// is announced on the wire at that moment, so only one with a
        /// destination has an end to report.
        var destination: URL?
        var progress = BrowserDownloadProgressGate()
    }

    weak var host: (any BrowserDownloadsHosting)?
    private var flights: [ObjectIdentifier: Flight] = [:]
    /// Whether a save panel is up: the person is asked one thing at a time.
    private var asking = false

    /// A page began saving a file from `tab`. It is held until it ends.
    func save(_ download: any BrowserDownload, from tab: BrowserTab.ID, route: Route) {
        flights[ObjectIdentifier(download)] = Flight(download: download, tab: tab, route: route)
        download.events = self
    }

    /// The tab went: a task's download on it is cancelled.
    func tabGone(_ tab: BrowserTab.ID) {
        for (key, flight) in flights where flight.tab == tab && flight.route != .person {
            flights[key] = nil
            cancel(flight, reason: ProductStrings[.browserHostReasonDownloadTabClosed])
        }
    }

    /// The app is quitting: every download stops, the person's too, since
    /// the app is not here to finish it.
    func cancelAll() {
        let stopping = flights.values
        flights = [:]
        for flight in stopping {
            cancel(flight, reason: ProductStrings[.browserHostReasonAppTerminating])
        }
    }

    // MARK: - Mechanics

    /// Ends a flight short: its terminal event where the daemon heard it
    /// begin, the engine stopped, and what it wrote removed. Removed at once,
    /// because a quitting app is gone before the engine answers, and again
    /// once the engine has stopped, in case it was still making the file.
    private func cancel(_ flight: Flight, reason: String) {
        flight.download.events = nil
        if case .task = flight.route, flight.destination != nil {
            host?.downloadLink?.downloadFinished(flight.id, tab: flight.tab, outcome: .cancelled(reason: reason))
        }
        Self.discard(flight.destination)
        flight.download.cancel { [destination = flight.destination] in Self.discard(destination) }
    }

    /// A task's file, under a name nothing in its directory has and no other
    /// download is writing, announced on the wire as it is decided.
    private func taskDestination(for flight: Flight, in directory: URL, suggesting suggestedFilename: String) -> URL {
        let name = BrowserDownloadName.unique(suggestedFilename) { name in
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            return FileManager.default.fileExists(atPath: candidate.path) || isBeingWritten(candidate)
        }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        flights[ObjectIdentifier(flight.download)]?.destination = destination
        host?.downloadLink?.downloadBegan(flight.id, tab: flight.tab, filename: name)

        return destination
    }

    /// Without regard to case, as a Mac volume compares names.
    private func isBeingWritten(_ file: URL) -> Bool {
        flights.values.contains { $0.destination?.path.lowercased() == file.path.lowercased() }
    }

    /// The person's file, where they choose. Only the tab in front of an open
    /// pane may ask, one panel at a time, as a page's dialog may: any other
    /// download is cancelled at once.
    private func ask(about flight: Flight, suggesting suggestedFilename: String, answer: @escaping @MainActor (URL?) -> Void) {
        guard !asking, let panel = host?.savePanel(for: flight.tab) else {
            flights[ObjectIdentifier(flight.download)] = nil
            answer(nil)
            return
        }

        asking = true
        panel.chooseDestination(for: BrowserDownloadName.sanitized(suggestedFilename)) { [weak self] chosen in
            guard let self else {
                answer(nil)
                return
            }

            self.chosen(chosen, for: flight.download, answer: answer)
        }
    }

    /// The person answered the panel. A file already at the place they chose
    /// is one they agreed to replace, and it goes first: WebKit refuses to
    /// write over a file.
    private func chosen(_ destination: URL?, for download: any BrowserDownload, answer: @escaping @MainActor (URL?) -> Void) {
        asking = false
        let key = ObjectIdentifier(download)
        guard let destination, flights[key] != nil else {
            flights[key] = nil
            answer(nil)
            return
        }

        Self.discard(destination)
        flights[key]?.destination = destination
        host?.say(String(format: ProductStrings[.browserNoticeDownloadingFormat], destination.lastPathComponent))
        answer(destination)
    }

    /// Removes the file a download was writing. Its destination was a name
    /// nothing had, or one the person agreed to replace, so whatever is there
    /// is the download's own.
    private static func discard(_ file: URL?) {
        guard let file else { return }

        try? FileManager.default.removeItem(at: file)
    }

    private static func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
    }
}

extension BrowserDownloads: BrowserDownloadEvents {
    func download(
        _ download: any BrowserDownload,
        needsDestinationFor suggestedFilename: String,
        answer: @escaping @MainActor (URL?) -> Void
    ) {
        guard let flight = flights[ObjectIdentifier(download)] else {
            answer(nil)
            return
        }

        switch flight.route {
        case .task(let directory):
            answer(taskDestination(for: flight, in: directory, suggesting: suggestedFilename))
        case .person:
            ask(about: flight, suggesting: suggestedFilename, answer: answer)
        }
    }

    /// A task's progress goes on the wire, as often as the gate lets it.
    func download(_ download: any BrowserDownload, received bytes: Int, of total: Int?) {
        let key = ObjectIdentifier(download)
        guard var flight = flights[key], case .task = flight.route, flight.destination != nil,
              flight.progress.admits(received: bytes, total: total)
        else { return }

        flights[key] = flight
        host?.downloadLink?.downloadProgressed(flight.id, receivedBytes: bytes, totalBytes: total)
    }

    func downloadFinished(_ download: any BrowserDownload) {
        guard let flight = flights.removeValue(forKey: ObjectIdentifier(download)),
              let destination = flight.destination
        else { return }

        switch flight.route {
        case .task:
            host?.downloadLink?.downloadFinished(
                flight.id,
                tab: flight.tab,
                outcome: .completed(path: destination.path, bytes: Self.size(of: destination))
            )
        case .person:
            host?.say(String(format: ProductStrings[.browserNoticeDownloadSavedFormat], destination.lastPathComponent))
        }
    }

    func download(_ download: any BrowserDownload, failed reason: String) {
        guard let flight = flights.removeValue(forKey: ObjectIdentifier(download)),
              let destination = flight.destination
        else { return }

        Self.discard(destination)
        switch flight.route {
        case .task:
            host?.downloadLink?.downloadFinished(flight.id, tab: flight.tab, outcome: .failed(reason: reason))
        case .person:
            host?.say(String(format: ProductStrings[.browserNoticeDownloadFailedFormat], destination.lastPathComponent, reason))
        }
    }
}

/// Which of a task's progress reports go on the wire: one per hundredth of a
/// stated size, or per mebibyte of an unstated one, so a large file is a
/// hundred lines rather than one for every packet that arrives.
struct BrowserDownloadProgressGate: Equatable {
    static let unstatedSizeStep = 1_048_576

    private var reported: Int?

    /// The first report always goes.
    mutating func admits(received: Int, total: Int?) -> Bool {
        let step = total.map { max($0 / 100, 1) } ?? Self.unstatedSizeStep
        if let reported, received - reported < step { return false }

        reported = received
        return true
    }
}
