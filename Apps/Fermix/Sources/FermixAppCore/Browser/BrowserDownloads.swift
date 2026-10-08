import Foundation

/// What downloads need of the pane: the wire, the person, and the pane's one
/// sentence.
@MainActor
protocol BrowserDownloadsHosting: AnyObject {
    /// The daemon's end of the host wire, while one is attached.
    var downloadLink: (any BrowserHostLink)? { get }
    /// Where the person saves `filename`, a file from their tab `tab`, asked in
    /// the save panel on the pane's one rule for asking the person anything.
    /// Answered once: the place they chose, or nil where they cancelled, or at
    /// once where they may not be asked now.
    func askWhereToSave(_ filename: String, from tab: BrowserTab.ID, answer: @escaping @MainActor (URL?) -> Void)
    func say(_ notice: String)
}

/// The files the pane's pages save (plan §4.4, §8.1), from the moment WebKit
/// turns a navigation into a download until it ends.
///
/// Only the person's own tabs save files. Theirs goes where they choose in
/// the save panel, and the pane's sentence says what became of it. WebKit
/// writes it to a file of its own beside the system's temporary items, and
/// only a finished download is moved to the place the person chose, in one
/// step: a file already there is replaced then and never before, so a
/// download that does not finish leaves the person's files as they were and
/// nothing of its own behind. It goes on when its tab is closed, as a
/// browser's does, and stops with the app.
///
/// A task's tab saves nothing yet: over the host wire the daemon can vet a
/// download neither by where it comes from nor by its size, as it does every
/// download in its own browser. So the daemon hears a task's download begin
/// and fail at once, which answers the task rather than leaving it to time
/// out, and nothing is written.
///
/// It is not a download manager: nothing is listed, and nothing is kept once
/// a download has ended. A finished file's quarantine attribute is WebKit's
/// own: its network process writes it on every file it downloads, so nothing
/// here sets it a second time.
@MainActor
final class BrowserDownloads {
    /// Whose tab began a download.
    enum Route: Equatable {
        /// A task's: refused.
        case task
        /// The person's: saved where they choose.
        case person
    }

    /// One download in flight.
    private struct Flight {
        let download: any BrowserDownload
        let tab: BrowserTab.ID
        let route: Route
        /// Where it is written, once the person has chosen a place.
        var staging: Staging?
    }

    /// Where a person's download is written until it has finished: a file of
    /// its own, in the directory the system makes for replacing the chosen
    /// place, on that place's volume.
    private struct Staging {
        /// The place the person chose.
        let place: URL
        let directory: URL

        init(for place: URL) throws {
            directory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: place,
                create: true
            )
            self.place = place
        }

        /// The file WebKit writes.
        var file: URL {
            directory.appendingPathComponent(place.lastPathComponent, isDirectory: false)
        }

        /// The finished file into the chosen place, replacing whatever is
        /// there in one step, or creating it where nothing is. It keeps its
        /// own attributes, the quarantine WebKit wrote among them, and takes
        /// none of the old file's.
        func moveIntoPlace() throws {
            _ = try FileManager.default.replaceItemAt(place, withItemAt: file, backupItemName: nil, options: .usingNewMetadataOnly)
        }

        /// The directory and whatever the download left in it. Never the
        /// chosen place.
        func discard() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    weak var host: (any BrowserDownloadsHosting)?
    private var flights: [ObjectIdentifier: Flight] = [:]

    /// A page began saving a file from `tab`. It is held until it ends.
    func save(_ download: any BrowserDownload, from tab: BrowserTab.ID, route: Route) {
        flights[ObjectIdentifier(download)] = Flight(download: download, tab: tab, route: route)
        download.events = self
    }

    /// The app is quitting: every download stops, since the app is not here
    /// to finish it.
    func cancelAll() {
        let stopping = flights.values
        flights = [:]
        for flight in stopping {
            cancel(flight)
        }
    }

    // MARK: - Mechanics

    /// Ends a flight short: the engine stopped, and what it wrote removed. At
    /// once, because a quitting app is gone before the engine answers, and
    /// again once the engine has stopped, in case it was still making the
    /// file.
    private func cancel(_ flight: Flight) {
        flight.download.events = nil
        flight.staging?.discard()
        flight.download.cancel { [staging = flight.staging] in staging?.discard() }
    }

    /// A task's download, refused when WebKit asks where it goes, the first
    /// moment it has a name: the daemon hears it begin and fail.
    private func refuse(_ flight: Flight, suggesting suggestedFilename: String) {
        flights[ObjectIdentifier(flight.download)] = nil
        host?.downloadLink?.downloadRefused(
            UUID(),
            tab: flight.tab,
            filename: BrowserDownloadName.sanitized(suggestedFilename),
            reason: ProductStrings[.browserHostReasonTaskDownloadRefused]
        )
    }

    /// The person's file, where they choose, if the pane may ask them now.
    private func ask(about flight: Flight, suggesting suggestedFilename: String, answer: @escaping @MainActor (URL?) -> Void) {
        guard let host else {
            flights[ObjectIdentifier(flight.download)] = nil
            answer(nil)
            return
        }

        host.askWhereToSave(BrowserDownloadName.sanitized(suggestedFilename), from: flight.tab) { [weak self] chosen in
            guard let self else {
                answer(nil)
                return
            }

            self.chosen(chosen, for: flight.download, answer: answer)
        }
    }

    /// The person answered, or could not be asked. WebKit is given the
    /// staging file, never the place they chose, which a file they agreed to
    /// replace still holds.
    private func chosen(_ place: URL?, for download: any BrowserDownload, answer: @escaping @MainActor (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard let place, flights[key] != nil else {
            flights[key] = nil
            answer(nil)
            return
        }

        let staging: Staging
        do {
            staging = try Staging(for: place)
        } catch {
            flights[key] = nil
            sayFailed(place, error.localizedDescription)
            answer(nil)
            return
        }

        flights[key]?.staging = staging
        host?.say(String(format: ProductStrings[.browserNoticeDownloadingFormat], place.lastPathComponent))
        answer(staging.file)
    }

    private func sayFailed(_ place: URL, _ reason: String) {
        host?.say(String(format: ProductStrings[.browserNoticeDownloadFailedFormat], place.lastPathComponent, reason))
    }
}

/// Only a download the person chose a place for is written, so only one
/// finishes or fails here: a task's is refused, and a refused place cancels
/// a download, before anything is written.
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
        case .task:
            refuse(flight, suggesting: suggestedFilename)
            answer(nil)
        case .person:
            ask(about: flight, suggesting: suggestedFilename, answer: answer)
        }
    }

    /// The one moment the chosen place changes. A move that fails leaves it
    /// as it was, and says why.
    func downloadFinished(_ download: any BrowserDownload) {
        guard let flight = flights.removeValue(forKey: ObjectIdentifier(download)),
              let staging = flight.staging
        else { return }

        do {
            try staging.moveIntoPlace()
            host?.say(String(format: ProductStrings[.browserNoticeDownloadSavedFormat], staging.place.lastPathComponent))
        } catch {
            sayFailed(staging.place, error.localizedDescription)
        }
        staging.discard()
    }

    func download(_ download: any BrowserDownload, failed reason: String) {
        guard let flight = flights.removeValue(forKey: ObjectIdentifier(download)),
              let staging = flight.staging
        else { return }

        staging.discard()
        sayFailed(staging.place, reason)
    }
}
