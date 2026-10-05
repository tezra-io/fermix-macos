import Foundation
import UniformTypeIdentifiers

/// A file on this Mac a link names, read as the person opens it (plan §8.2):
/// where it really is, and what opening it comes to.
///
/// Everything is decided on the file the link lands on, every symbolic link
/// resolved, never on the link's own name: a `notes.txt` that points at an
/// app is an app. The rules are an allowlist, in order: what the pane shows
/// it shows; a document goes to the app that opens its type; and everything
/// else, from a folder to an app to a type nobody declared, is only ever shown
/// in Finder, which runs nothing.
struct BrowserLocalFile {
    /// What opening the file comes to.
    enum Opening: Equatable {
        /// A file tab, showing it as this kind.
        case show(BrowserFileKind)
        /// Handed to this app as a document, the app named now.
        case open(WorkspaceApplication)
        /// Selected in Finder, and nothing opened.
        case reveal
    }

    /// What runs when it is opened: an app, an executable and a script, and
    /// anything that conforms to one. Never handed to an app, though a script
    /// is shown as the text it is.
    static let runnableTypes: [UTType] = [
        .applicationBundle, .application, .executable, .unixExecutable, .script, .shellScript
    ]

    /// How much of a file of no known type is read to tell whether it is
    /// text.
    static let sniffLength = 65_536

    /// Where the link really lands.
    let url: URL
    /// What the file system says of it, read once; nil where it could not
    /// say, which leaves only Finder.
    private let facts: Facts?

    /// Nil where nothing is there. A leading `~` is the person's home folder,
    /// as a path in a reply writes it.
    init?(_ link: URL) {
        let path = (link.path as NSString).expandingTildeInPath
        guard let real = FilePlace.resolved(path), FileManager.default.fileExists(atPath: real) else { return nil }

        url = URL(fileURLWithPath: real)
        facts = Facts(of: url)
    }

    /// The three rules, in order.
    @MainActor
    func opening(_ workspace: any WorkspaceLinkOpening) -> Opening {
        if let kind = shownKind() { return .show(kind) }
        if let app = documentApplication(workspace) { return .open(app) }

        return .reveal
    }

    /// Rule one: a regular file the pane shows, by its type, or, for a type
    /// the Mac does not know as content, by its bytes reading as text. Text
    /// past the pane's size is not shown.
    func shownKind() -> BrowserFileKind? {
        guard let facts, facts.isRegularFile else { return nil }

        let kind = BrowserFileKind(facts.type) ?? (Self.isUntyped(facts.type) && Self.readsAsText(url) ? .text : nil)
        guard kind != .text || facts.size <= BrowserFileKind.textSizeCap else { return nil }

        return kind
    }

    /// Rule two: the app a document goes to, named now from its type. Only
    /// content goes to one, never anything that runs or a file with its
    /// executable bit set, which Launch Services would run rather than open.
    @MainActor
    func documentApplication(_ workspace: any WorkspaceLinkOpening) -> WorkspaceApplication? {
        guard let facts, facts.type.conforms(to: .content), !Self.runs(facts.type) else { return nil }
        guard !(facts.isRegularFile && facts.isExecutable) else { return nil }

        return workspace.application(toOpen: facts.type)
    }

    static func runs(_ type: UTType) -> Bool {
        runnableTypes.contains(where: type.conforms)
    }

    /// A type the Mac made up for an extension nobody declared (`dyn.*`), or
    /// one it knows only as data: an archive, an installer, a plug-in, a
    /// shortcut to somewhere else, or source code in a language it was never
    /// told of.
    private static func isUntyped(_ type: UTType) -> Bool {
        type.isDynamic || !type.conforms(to: .content)
    }

    /// Text where its first 64 KB is UTF-8 with no NUL byte. A read cut short
    /// may end inside a character, so up to three trailing bytes are let go
    /// there.
    private static func readsAsText(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: sniffLength) ?? Data() else { return false }
        guard !bytes.contains(0) else { return false }

        let cut = bytes.count == sniffLength ? 3 : 0
        return (0...cut).contains { String(validating: bytes.dropLast($0), as: UTF8.self) != nil }
    }

    /// What the rules read of a file.
    private struct Facts {
        let type: UTType
        let isRegularFile: Bool
        let isExecutable: Bool
        let size: Int

        init?(of file: URL) {
            let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .isExecutableKey, .fileSizeKey]
            guard let values = try? file.resourceValues(forKeys: keys), let type = values.contentType else { return nil }

            self.type = type
            isRegularFile = values.isRegularFile == true
            isExecutable = values.isExecutable == true
            size = values.fileSize ?? 0
        }
    }
}
