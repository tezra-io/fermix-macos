import Foundation

/// The site a website login is saved for, and the one rule for which pages it
/// belongs to (M84 D2): a page's own site, one leading `www.` folded, and, when
/// none is saved for it, the closest saved site it is a subdomain of. Pure, so
/// the save sheet, the store and the browser host all ask the same function.
public enum LoginSite {
    /// The key form of a typed host or a pasted http(s) address, or why it is
    /// refused.
    ///
    /// Key form: lower-cased, the trailing dot trimmed, one leading `www.`
    /// removed. Only `a-z 0-9 . - _`, at least one dot. An address literal,
    /// `localhost` and `*.localhost`, a label starting `xn--`, anything
    /// non-ASCII and a bare label are refused. There is no loopback exception:
    /// a login saved for a loopback host would go to whatever server a command
    /// starts there.
    public static func key(_ input: String) -> Result<String, LoginSiteRefusal> {
        guard let host = host(of: input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.notAHost)
        }
        guard host.allSatisfy(\.isASCII) else { return .failure(.internationalized) }

        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        return refusal(of: trimmed.lowercased()).map(Result.failure) ?? .success(folded(trimmed.lowercased()))
    }

    /// Which of the saved sites (keys) a page's host uses, or nil (D2): its own
    /// key when that is saved; otherwise the longest saved site the key ends
    /// with after a dot, so `identity.walmart.com` uses `walmart.com` and
    /// `a.b.example.com` uses `b.example.com` over `example.com`. Many sites
    /// sign in on a host of their own. A look-alike (`evilwalmart.com`) or a
    /// suffix trick (`walmart.com.evil.example`) never ends with `.` and a
    /// saved site, and a domain never uses its subdomain's login. The engine
    /// asks the owner at the password, naming both sites.
    public static func site(forHost host: String, among saved: [String]) -> String? {
        guard case .success(let hostKey) = key(host) else { return nil }
        if saved.contains(hostKey) { return hostKey }

        return saved.filter { hostKey.hasSuffix("." + $0) }.max { $0.count < $1.count }
    }

    private static let schemes: Set<String> = ["http", "https"]
    private static let alphabet = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")

    /// The host of an http(s) address, or the input itself when it names no
    /// scheme. Nil for any other scheme or an address with no host.
    ///
    /// Read by hand rather than through `URLComponents`, whose answer for a
    /// non-ASCII host differs across macOS releases: the authority ends at the
    /// first `/`, `\`, `?` or `#` (a browser reads `\` as `/` in an http
    /// address, so `github.com\@evil.example` is github.com there too), loses
    /// any user info up to its last `@`, and loses a port unless it is a
    /// bracketed literal, which is refused whole.
    private static func host(of input: String) -> String? {
        guard let separator = input.range(of: "://") else { return input.isEmpty ? nil : input }
        guard schemes.contains(input[..<separator.lowerBound].lowercased()) else { return nil }

        let rest = input[separator.upperBound...]
        let authority = rest.prefix { !"/\\?#".contains($0) }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if hostAndPort.hasPrefix("[") { return String(hostAndPort) }
        let host = hostAndPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return host.isEmpty ? nil : String(host)
    }

    /// Why a lower-cased, dot-trimmed ASCII host is refused, in the order the
    /// owner is told: what kind of name it is before what is wrong with it.
    private static func refusal(of host: String) -> LoginSiteRefusal? {
        if isAddressLiteral(host) { return .addressLiteral }
        guard host.allSatisfy(alphabet.contains) else { return .notAHost }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return .notAHost }

        let site = folded(host)
        if site == "localhost" || site.hasSuffix(".localhost") { return .localhost }
        if labels.contains(where: { $0.hasPrefix("xn--") }) { return .internationalized }
        return site.contains(".") ? nil : .noDot
    }

    /// An IPv6 literal (bracketed, or two colons or more), or a name a URL
    /// parser reads as IPv4: one whose last label is a decimal or `0x` number
    /// (`127.1`, `0x7f.0.0.1` and `2130706433` all reach 127.0.0.1).
    private static func isAddressLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.filter({ $0 == ":" }).count >= 2 { return true }
        guard let last = host.split(separator: ".").last, !last.isEmpty else { return false }
        if last.allSatisfy(\.isNumber) && last.allSatisfy(\.isASCII) { return true }
        return last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func folded(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
