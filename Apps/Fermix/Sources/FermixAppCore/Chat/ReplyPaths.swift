import Foundation

/// The local paths in a reply, made links to the files they name. The agent
/// says where it put what it made (a screenshot, a report, a download), and a
/// path the reader can click is the way to it.
///
/// Three forms are read, each on the reply as SwiftUI's markdown parser left
/// it: a markdown link whose destination is a path, a code span whose whole
/// text is one, and a bare path standing on its own in plain text. Nothing
/// here looks at the disk: a reply is drawn again as each piece of a turn
/// arrives, and whether the file is there is for the click to find out.
enum ReplyPaths {
    /// Every path in a parsed reply, as a `file://` link. A bare path is read
    /// in plain text only: inside a link it is part of that link, and inside
    /// code it counts only as the whole span. A markdown link to a path keeps
    /// its own words; a path written out is marked as written
    /// (`ReplyWrittenLink`).
    static func linked(_ reply: AttributedString, home: String) -> AttributedString {
        var linked = reply
        for run in reply.runs {
            if let link = run.link {
                guard let file = fileLink(link, home: home) else { continue }
                linked[run.range].link = file
            } else if let file = codePath(run, in: reply, home: home) {
                linked.linkWritten(run.range, to: file)
            }
        }
        let text = String(reply.characters)
        for path in barePaths(in: text) {
            guard let range = Range(path, in: reply), reply[range].runs.allSatisfy(isPlain) else { continue }
            linked.linkWritten(range, to: fileURL(String(withoutLineReference(text[path])), home: home))
        }

        return linked
    }

    /// The file a code span names when it is a path from end to end, a line
    /// reference after it aside.
    private static func codePath(_ run: AttributedString.Runs.Run, in reply: AttributedString, home: String) -> URL? {
        guard isCode(run) else { return nil }

        return file(wholly: Substring(reply[run.range].characters), home: home)
    }

    /// The file text names when it is a path from end to end, a line
    /// reference after it aside, as a code span's whole text is read.
    static func file(wholly text: Substring, home: String) -> URL? {
        let path = withoutLineReference(text)
        return isPath(path) ? fileURL(String(path), home: home) : nil
    }

    /// The file a markdown link names when its destination is a local path.
    /// SwiftUI's parser keeps such a destination as a URL with no scheme and
    /// nothing to resolve it against, which no opener can follow. A
    /// destination with a scheme, or with a host (`//example.com/a`), is an
    /// address and stays as it is.
    private static func fileLink(_ link: URL, home: String) -> URL? {
        guard link.scheme == nil, link.host == nil else { return nil }
        let path = link.path(percentEncoded: false)
        guard afterRoot(Substring(path)) != nil else { return nil }

        return fileURL(path, home: home)
    }

    /// The bare paths in plain text, as ranges of it, a line reference after
    /// one included. A path starts a word, after any opening marks, and runs
    /// to the word's end, less its closing marks (`ReplyMarks`), so the path
    /// inside an address (`https://example.com/a/b`) or a fraction (`1/2`)
    /// never starts one. A path with a space in it, unquoted, links only up
    /// to the space: an agent writes such a path in code.
    static func barePaths(in text: String) -> [Range<String.Index>] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word in
            var path = word.drop(while: ReplyMarks.opening.contains)
            while let last = path.last, ReplyMarks.closing.contains(last) {
                path = path.dropLast()
            }
            return isPath(withoutLineReference(path)) ? path.startIndex..<path.endIndex : nil
        }
    }

    /// A path less a line reference after it, `:42` or `:42:7`, which says
    /// where in the file to look rather than which file to open.
    static func withoutLineReference(_ text: Substring) -> Substring {
        var path = text
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":") else { break }
            let number = path[path.index(after: colon)...]
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
            path = path[..<colon]
        }

        return path
    }

    /// Whether text is a path worth a link: rooted at `~/` with at least one
    /// component after it, or at `/` with at least two. One under `/` is a
    /// slash command (`/approve`), and `~/` alone is the whole home folder.
    private static func isPath(_ text: some StringProtocol) -> Bool {
        guard let components = afterRoot(Substring(text)) else { return false }
        let fewest = text.hasPrefix("~/") ? 1 : 2
        return components.split(separator: "/").count >= fewest
    }

    /// What follows a local path's root, `/` or `~/`, or nil for text with
    /// none. A second slash after the root starts an address with no scheme
    /// (`//example.com/a`), not a path.
    private static func afterRoot(_ text: Substring) -> Substring? {
        let rest: Substring
        if text.hasPrefix("~/") {
            rest = text.dropFirst(2)
        } else if text.hasPrefix("/") {
            rest = text.dropFirst()
        } else {
            return nil
        }

        return rest.hasPrefix("/") ? nil : rest
    }

    /// The `file://` URL of a local path, `~` read as the home folder. The
    /// path's own trailing slash says whether it is a folder: left to decide,
    /// `URL(fileURLWithPath:)` would ask the disk.
    static func fileURL(_ path: String, home: String) -> URL {
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst() : path
        return URL(fileURLWithPath: expanded, isDirectory: expanded.hasSuffix("/"))
    }

    /// Plain text, the only place a bare path is read: not already a link,
    /// and not code, whose paths count only as the whole span.
    private static func isPlain(_ run: AttributedString.Runs.Run) -> Bool {
        run.link == nil && !isCode(run)
    }

    private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
        run.inlinePresentationIntent?.contains(.code) == true
    }
}
