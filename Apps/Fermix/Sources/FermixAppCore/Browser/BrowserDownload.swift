import Foundation

/// One file a page is saving, as the web engine runs it (plan §4.4), behind
/// the seam.
///
/// The page hands it to its tab as WebKit turns a navigation into a download,
/// and whoever takes it sets `events` at once: the download asks them where
/// the file goes and tells them how it ends.
@MainActor
public protocol BrowserDownload: AnyObject {
    var events: (any BrowserDownloadEvents)? { get set }
    /// Stops it, and nothing is reported after. `stopped` runs once the
    /// engine has stopped writing, which is when what it wrote can go.
    func cancel(_ stopped: @escaping @MainActor () -> Void)
}

/// What a download asks of whoever took it, and what it tells them.
@MainActor
public protocol BrowserDownloadEvents: AnyObject {
    /// Where the file goes, asked once, before anything is written. Answering
    /// nil cancels the download, and nothing is reported after.
    func download(
        _ download: any BrowserDownload,
        needsDestinationFor suggestedFilename: String,
        answer: @escaping @MainActor (URL?) -> Void
    )
    /// Bytes written so far, and the size the response stated, where it
    /// stated one.
    func download(_ download: any BrowserDownload, received bytes: Int, of total: Int?)
    func downloadFinished(_ download: any BrowserDownload)
    /// It stopped short, in the system's own sentence. What it wrote is still
    /// at its destination.
    func download(_ download: any BrowserDownload, failed reason: String)
}

/// Asking the person where a file goes, behind a seam, so no test raises a
/// panel.
@MainActor
public protocol BrowserSavePanelPresenting: AnyObject {
    /// The system save panel, as a sheet on the pane's window, open on the
    /// person's Downloads folder with `filename` filled in. `answer` runs
    /// once: the place they chose, or nil where they cancelled.
    func chooseDestination(for filename: String, answer: @escaping @MainActor (URL?) -> Void)
}

/// The pane's page area, which is also where the pane asks the person where
/// a file goes: the save panel is a sheet on the window the area is in.
public typealias BrowserPaneArea = BrowserPageStage & BrowserSavePanelPresenting

/// A downloaded file's name: the page's suggestion, made safe to write, and
/// made unique in its directory, so no file is ever written over.
enum BrowserDownloadName {
    /// The longest name a Mac volume takes, in UTF-8 bytes.
    static let maximumBytes = 255

    /// `suggested` as one name in a directory: no path separator, not hidden,
    /// not empty, and short enough to write, its extension kept.
    static func sanitized(_ suggested: String) -> String {
        let flattened = suggested
            .map { "/:\0".contains($0) || $0.isNewline ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let visible = String(flattened.drop { $0 == "." })
        let name = visible.isEmpty ? ProductStrings[.browserDownloadUntitled] : visible

        return fitted(stem(of: name), suffix: "", extension: pathExtension(of: name))
    }

    /// The first of `name`, `name 2`, `name 3` and on that `taken` does not
    /// hold, numbered before the extension as the Finder numbers a copy.
    static func unique(_ suggested: String, taken: (String) -> Bool) -> String {
        let name = sanitized(suggested)
        var candidate = name
        var copy = 1
        while taken(candidate) {
            copy += 1
            candidate = fitted(stem(of: name), suffix: " \(copy)", extension: pathExtension(of: name))
        }

        return candidate
    }

    /// The stem cut until the whole name fits a volume's limit.
    private static func fitted(_ stem: String, suffix: String, extension pathExtension: String) -> String {
        let tail = suffix + (pathExtension.isEmpty ? "" : "." + pathExtension)
        var stem = stem
        while !stem.isEmpty, (stem + tail).utf8.count > maximumBytes {
            stem.removeLast()
        }

        return stem + tail
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension
    }
}
