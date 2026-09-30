import Foundation

/// What the address field loads.
///
/// A web address, with or without its scheme, and nothing else: a typed
/// `mailto:` or `file:` is not the pane's to open, and a phrase is not an
/// address. There is no search from the field, because a search engine is a
/// choice about who sees what the person types, and nobody has made it.
public enum BrowserAddress {
    public static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        guard text.contains("://") else { return hostAddress(text) }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }

        return url
    }

    /// A bare host such as `fermix.ai/docs` or `localhost:4000`, over https.
    /// Anything carrying user information is refused: `mailto:a@b.c` would
    /// otherwise read as a sign-in to the host `b.c`.
    private static func hostAddress(_ text: String) -> URL? {
        guard let url = URL(string: "https://" + text),
              let host = url.host, host.contains(".") || host == "localhost",
              url.user == nil
        else { return nil }

        return url
    }
}
