import Foundation
import Testing

@testable import FermixAppCore

/// The site a login is saved for, and which pages it belongs to (M84 D2).
///
/// A saved site is the key form of what the owner typed: lower-cased, the
/// trailing dot trimmed, one leading `www.` removed. A page belongs to a login
/// only when its host has the same key, so a subdomain, a look-alike and a
/// suffix trick never match. Addresses, `localhost`, internationalized names
/// and bare labels are refused at save, each with its own reason.
@Suite("Website login sites")
struct LoginSiteTests {
    @Test(
        "a typed host or a pasted address keeps the host's key",
        arguments: [
            ("github.com", "github.com"),
            ("GitHub.COM", "github.com"),
            ("github.com.", "github.com"),
            ("www.github.com", "github.com"),
            ("WWW.GitHub.com.", "github.com"),
            ("www.www.github.com", "www.github.com"),
            ("  accounts.google.com \n", "accounts.google.com"),
            ("accounts.google.com", "accounts.google.com"),
            ("my_host.example.com", "my_host.example.com"),
            ("https://github.com/login", "github.com"),
            ("HTTPS://www.GitHub.com/login?next=/", "github.com"),
            ("http://github.com:8080/x", "github.com"),
            ("https://alice@github.com/", "github.com"),
            ("https://github.com.", "github.com"),
            // A browser reads `\` as `/` in an http address, so this is
            // github.com there; the key must agree.
            ("https://github.com\\@evil.example/", "github.com"),
            ("https://evil.example:x@github.com/", "github.com")
        ]
    )
    func keyForm(input: String, key: String) {
        #expect(LoginSite.key(input) == .success(key))
    }

    @Test(
        "what is not a host is refused",
        arguments: [
            "", "   ", "github.com/login", "git hub.com", "github..com", ".github.com",
            "github.com:443", "ftp://github.com", "javascript:alert(1)", "https://",
            "file:///etc/hosts", "github.com#x", "%67ithub.com"
        ]
    )
    func notAHost(input: String) {
        #expect(LoginSite.key(input) == .failure(.notAHost))
    }

    @Test(
        "an address literal is refused",
        arguments: [
            "1.2.3.4", "https://127.0.0.1/login", "127.1", "0x7f.0.0.1", "2130706433",
            "::1", "[::1]", "https://[::1]:8443/", "fe80::1", "10.0.0.1."
        ]
    )
    func addressLiteral(input: String) {
        #expect(LoginSite.key(input) == .failure(.addressLiteral))
    }

    @Test(
        "localhost and its subdomains are refused, with no loopback exception",
        arguments: ["localhost", "LOCALHOST.", "app.localhost", "http://localhost:3000/", "www.localhost"]
    )
    func localhost(input: String) {
        #expect(LoginSite.key(input) == .failure(.localhost))
    }

    @Test(
        "an internationalized name is refused",
        arguments: [
            "xn--bcher-kva.de", "shop.xn--p1ai", "XN--bcher-kva.de", "bücher.de",
            "https://bücher.de/login", "github\u{FF0E}com", "gіthub.com"
        ]
    )
    func internationalized(input: String) {
        #expect(LoginSite.key(input) == .failure(.internationalized))
    }

    @Test("a bare label is refused, after the www. fold", arguments: ["com", "github", "www.com", "github."])
    func noDot(input: String) {
        #expect(LoginSite.key(input) == .failure(.noDot))
    }

    @Test(
        "a page matches only the exact saved site, www. folded",
        arguments: ["github.com", "www.github.com", "GITHUB.COM.", "WWW.github.com"]
    )
    func matches(host: String) {
        #expect(LoginSite.matches(savedSite: "github.com", host: host))
    }

    @Test(
        "a subdomain, a look-alike or a suffix trick never matches",
        arguments: [
            "gist.github.com", "evilgithub.com", "github.com.evil.example", "github.co",
            "githubcom", "127.0.0.1", "", "xn--github-.com", "www.www.github.com"
        ]
    )
    func doesNotMatch(host: String) {
        #expect(!LoginSite.matches(savedSite: "github.com", host: host))
    }

    @Test("a site saved with www. is stored folded, so both page forms match it")
    func wwwFoldBothWays() throws {
        let saved = try LoginSite.key("www.example.org").get()

        #expect(saved == "example.org")
        #expect(LoginSite.matches(savedSite: saved, host: "example.org"))
        #expect(LoginSite.matches(savedSite: saved, host: "www.example.org"))
    }
}
