import Foundation
import UniformTypeIdentifiers

/// A file on this Mac a link names, read as the person opens it (plan §8.2):
/// where it really is, and what opening it comes to.
///
/// Everything is decided on the file the link lands on, every symbolic link
/// resolved, never on the link's own name: a `notes.txt` that points at a
/// script is a script, and handing the link to another app would run it.
struct BrowserLocalFile {
    /// What opening the file comes to, decided in this order.
    enum Opening: Equatable {
        /// A folder, which Finder opens.
        case folder
        /// Something that runs: an app, an executable or a script
        /// (`BrowserFileKind.runnableTypes`), or any other file with its
        /// executable bit set that the pane does not show. Opening one is
        /// running it, so it is only ever shown in Finder.
        case reveal
        /// A file the pane does not show, or text past the pane's size, for
        /// the app on the Mac that opens it.
        case defaultApp
        /// A file the pane shows, as this kind.
        case show(BrowserFileKind)
    }

    /// Where the link really lands.
    let url: URL
    let opening: Opening

    /// Nil where nothing is there. A leading `~` is the person's home folder,
    /// as a path in a reply writes it.
    init?(_ link: URL) {
        let path = (link.path as NSString).expandingTildeInPath
        guard let real = FilePlace.resolved(path), FileManager.default.fileExists(atPath: real) else { return nil }

        url = URL(fileURLWithPath: real)
        opening = Self.opening(of: url)
    }

    private static let facts: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isRegularFileKey, .isExecutableKey, .contentTypeKey, .fileSizeKey
    ]

    /// A package is a directory to the file system and one file to the
    /// person, so an app is something that runs rather than a folder. A
    /// directory's executable bit only lets it be searched, so only a regular
    /// file's says it runs. A file whose facts cannot be read is never
    /// opened, since nothing says it does not run.
    private static func opening(of file: URL) -> Opening {
        guard let values = try? file.resourceValues(forKeys: facts), let type = values.contentType else { return .reveal }

        let kind = BrowserFileKind(type)
        if values.isDirectory == true, values.isPackage != true { return .folder }
        if BrowserFileKind.runs(type) { return .reveal }
        if values.isRegularFile == true, values.isExecutable == true, kind == nil { return .reveal }
        guard let kind else { return .defaultApp }
        guard kind != .text || (values.fileSize ?? 0) <= BrowserFileKind.textSizeCap else { return .defaultApp }

        return .show(kind)
    }
}
