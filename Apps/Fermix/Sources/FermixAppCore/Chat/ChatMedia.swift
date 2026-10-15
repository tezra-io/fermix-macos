import Foundation
import UniformTypeIdentifiers

/// The Fermix home as one visit to Chat read it from the bootstrap record:
/// where it is, for the disk's word on whether a file lies inside it
/// (`ChatFileFacts.read`), and how its paths are spelled, for the strip's
/// reading of a path's text (`ChatHome`). A home that cannot be read has
/// nothing inside it.
struct ChatVisit: Equatable, Sendable {
    let home: URL?
    let paths: ChatHome?
}

/// What a row's media needs that outlives the chat surface, built once by the
/// composition: each row's strip, worked out once for its content; the
/// previews made for its tiles; and the app each type of file opens in.
///
/// Nothing here reads the disk while a row is drawn. The home is read as the
/// surface appears (`surfaceEntered`), as the browser reads it at each open,
/// and the surface keeps what it read for the visit: every row and tile
/// reads it from there, so the next visit reads the home again. A file is
/// read off the main thread, when its tile is on screen, and a phone-side
/// file's is granted only while its preview is made (`ChatPreviews`).
@MainActor
final class ChatMedia {
    let previews: ChatPreviews
    /// What `~` reads as in a row's words.
    let userHome: String
    private let readHome: () throws -> URL
    private let documentApplication: @Sendable (UTType) -> WorkspaceApplication?
    private var strips: [Int: (source: StripSource, strip: ChatStrip)] = [:]
    private var hints: [String: ChatTileHint] = [:]

    /// What a row's strip is worked out from, so it is worked out again only
    /// when that changes: history may bring the same row with more in it, and
    /// a visit may find the home elsewhere.
    private struct StripSource: Equatable {
        let text: String
        let plain: Bool
        let mediaRefs: [CompanionMediaRef]
        let linkPreviews: [CompanionLinkPreview]
        let home: ChatHome?
    }

    /// `home` reads the Fermix home from the bootstrap record, as the
    /// browser's does; `reader` is what the Mac's own frameworks draw of a
    /// file, which the executable hands in, and `facts` whether a film plays
    /// and how long it is, the player's own; `grants` are the engine's grants
    /// of phone-side files, the session's; `documentApplication` is the app a
    /// document of a type goes to, never a browser, asked off the main
    /// thread (`WorkspaceLinkOpener.documentApplication`); `deadlines` times
    /// the previews out.
    init(
        home: @escaping () throws -> URL,
        userHome: String = NSHomeDirectory(),
        reader: any ChatMediaReading,
        facts: any MediaFacts,
        grants: any MediaGranting,
        documentApplication: @escaping @Sendable (UTType) -> WorkspaceApplication?,
        deadlines: any DeadlineScheduling
    ) {
        readHome = home
        self.userHome = userHome
        self.documentApplication = documentApplication
        previews = ChatPreviews(reader: reader, facts: facts, grants: grants, deadlines: deadlines)
    }

    /// The Fermix home for a visit to Chat, read from the bootstrap record
    /// as the surface appears.
    func surfaceEntered() -> ChatVisit {
        let home = try? readHome()
        return ChatVisit(home: home, paths: home.map(ChatHome.init))
    }

    /// A row's strip, as a visit reads it: worked out once for the row's
    /// content and kept, reading nothing. Before the surface has read the
    /// home, nothing is inside it. A person's words are read as they are
    /// drawn, as plain text.
    func strip(for row: CompanionRow, in visit: ChatVisit?) -> ChatStrip {
        let source = StripSource(
            text: row.text,
            plain: ChatSpeaker.isUser(row.role),
            mediaRefs: row.mediaRefs,
            linkPreviews: row.linkPreviews,
            home: visit?.paths
        )
        if let kept = strips[row.serverSeq], kept.source == source { return kept.strip }

        let strip = ChatStrip(
            text: source.text,
            plain: source.plain,
            mediaRefs: source.mediaRefs,
            linkPreviews: source.linkPreviews,
            userHome: userHome,
            home: source.home
        )
        strips[row.serverSeq] = (source, strip)
        return strip
    }

    /// What a tile's file is, read off the main thread, against the home the
    /// visit read.
    func lookUp(_ file: URL, in visit: ChatVisit?) async -> ChatFileLookup {
        let home = visit?.home
        let facts = await Task.detached(priority: .utility) { ChatFileFacts.read(file, home: home) }.value

        return facts.map(ChatFileLookup.found) ?? .missing
    }

    /// Where an Opens outside tile goes, by what its file is on the disk
    /// (`ChatFileFacts.disk`, or `ChatPreviewPolicy.facts(of:)` for a
    /// phone-side file): its app found off the main thread the first time a
    /// tile of its type asks, and kept by type.
    func hint(for disk: FileFacts) async -> ChatTileHint {
        guard ChatPreviewPolicy.handsToApp(disk) else { return .showInFinder }
        if let known = hints[disk.type.identifier] { return known }

        let lookUp = documentApplication
        let type = disk.type
        let hint = await Task.detached(priority: .utility) { lookUp(type).map { ChatTileHint.openIn($0.name) } ?? .showInFinder }.value
        hints[type.identifier] = hint
        return hint
    }
}
