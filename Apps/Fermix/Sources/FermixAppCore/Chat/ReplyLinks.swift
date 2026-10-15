import Foundation

/// The web addresses in a reply: links where the text writes them, and a list
/// in reading order for the strip under the row (M66 §3.1).
///
/// An address is one written with its scheme, `http://` or `https://`, in
/// text that is not code. A host alone (`example.com`) or a file's name
/// (`notes.md`) is a word, and an address in code is what was typed, as a path
/// in code is a link only when it is the whole span.
///
/// The system's detector finds them, not the markdown parser: the parser
/// makes some bare addresses links on its own, and which, and where one ends,
/// differs from one macOS to the next (`{https://a.b/c}` keeps its brace, and
/// `www.example.com` is a link). So every link the parser made of an address
/// it read in the text is undone first, and the detector's are the only ones,
/// on every Mac alike. A markdown link the reply wrote with words of its own
/// is the reply's and stays as it is.
enum ReplyLinks {
    /// The schemes an address is written with.
    static let schemes: Set<String> = ["http", "https"]

    /// Every address written out in a parsed reply, as a link marked as
    /// written (`ReplyWrittenLink`): an address is the text it is, as a path
    /// is.
    static func linked(_ reply: AttributedString) -> AttributedString {
        var linked = withoutAddressLinks(reply)
        let text = String(linked.characters)
        for address in addresses(inText: text) {
            guard let range = Range(address.range, in: linked), linked[range].runs.allSatisfy(isPlain) else { continue }

            linked.linkWritten(range, to: address.url)
        }

        return linked
    }

    /// The address text is when it is one from end to end, written with its
    /// scheme, as a code span's whole text or a link's destination is read.
    static func address(wholly text: Substring) -> URL? {
        guard hasScheme(text), !text.contains(where: \.isWhitespace), let url = URL(string: String(text)) else { return nil }

        return url
    }

    /// The addresses written in plain text, each as the range it covers and
    /// the address it opens.
    static func addresses(inText text: String) -> [(range: Range<String.Index>, url: URL)] {
        let whole = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: whole).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let written = trimmed(text[found])
            guard hasScheme(written), let url = URL(string: String(written)) else { return nil }

            return (found.lowerBound..<written.endIndex, url)
        }
    }

    /// An address less the marks after it that close the sentence rather than
    /// the address: closing punctuation, a quote, a stray backtick or angle
    /// bracket, and a closing bracket the address did not open, so a page
    /// named `Foo_(bar)` keeps its own.
    static func trimmed(_ address: Substring) -> Substring {
        var trimmed = address
        while let last = trimmed.last, closesSentence(last) || closesUnopened(last, in: trimmed) {
            trimmed = trimmed.dropLast()
        }

        return trimmed
    }

    private static func closesSentence(_ mark: Character) -> Bool {
        ReplyMarks.punctuation.contains(mark) || ReplyMarks.closingQuotes.contains(mark)
    }

    private static func closesUnopened(_ mark: Character, in address: Substring) -> Bool {
        guard let opening = ReplyMarks.brackets[mark] else { return false }

        return address.count(where: { $0 == mark }) > address.count(where: { $0 == opening })
    }

    /// The reply with every link the parser made of an address it read in the
    /// text undone: a link whose words are its own address, or that address
    /// less its scheme (`www.example.com`), which is a word here. A markdown
    /// link with words of its own keeps its link.
    private static func withoutAddressLinks(_ reply: AttributedString) -> AttributedString {
        var plain = reply
        for (link, range) in reply.runs[\.link] {
            guard let link, isAddress(link), readsAsItself(link, String(reply[range].characters)) else { continue }

            plain[range].link = nil
        }

        return plain
    }

    private static func readsAsItself(_ link: URL, _ words: String) -> Bool {
        URL(string: words) == link || URL(string: "http://" + words) == link
    }

    private static func hasScheme(_ address: Substring) -> Bool {
        schemes.contains { address.lowercased().hasPrefix($0 + "://") }
    }

    static func isAddress(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    /// Text that is neither a link nor code, the only place an address is
    /// read.
    private static func isPlain(_ run: AttributedString.Runs.Run) -> Bool {
        run.link == nil && run.inlinePresentationIntent?.contains(.code) != true
    }

    /// The system's link detector, made once.
    private static let detector: NSDataDetector = {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            preconditionFailure("the link detector is made from a fixed type")
        }

        return detector
    }()
}
