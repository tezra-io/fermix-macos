import Foundation
import Testing

@testable import FermixAppCore

/// A link is checked before it opens for what could make it open somewhere
/// other than where it seems to: a name hidden before an `@`, words naming
/// one site over a link to another, and a host whose name passes for
/// another. Only web addresses are checked, and real names in any alphabet
/// pass.
@Suite("Link safety")
struct LinkSafetyTests {
    private static func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    private static func caution(_ words: String, _ link: String) throws -> LinkCaution? {
        LinkSafety.caution(words: words, url: try url(link))
    }

    private static func caution(_ link: String) throws -> LinkCaution? {
        LinkSafety.caution(url: try url(link))
    }

    /// The text RFC 3492 lists as code points.
    private static func text(_ points: [UInt32]) -> String {
        String(String.UnicodeScalarView(points.compactMap(Unicode.Scalar.init)))
    }

    // MARK: Hidden name

    @Test("a name or password before an @ hides the host it opens")
    func hiddenName() throws {
        #expect(try Self.caution("https://apple.com@evil.example") == .hiddenName(opens: "evil.example"))
        #expect(try Self.caution("https://user:pass@Evil.Example./x") == .hiddenName(opens: "evil.example"))
        #expect(try Self.caution("https://:pw@evil.example") == .hiddenName(opens: "evil.example"))
        #expect(try Self.caution("https://apple.com@\u{0430}pple.com") == .hiddenName(opens: "xn--pple-43d.com"))
        #expect(try Self.caution("Read more", "https://apple.com@evil.example") == .hiddenName(opens: "evil.example"))
    }

    @Test("a bare @ with no name before it hides nothing")
    func bareAt() throws {
        #expect(try Self.caution("https://@evil.example") == nil)
    }

    // MARK: Elsewhere

    @Test("words naming one site over a link to another are elsewhere")
    func elsewhere() throws {
        #expect(try Self.caution("apple.com", "https://evil.example") == .elsewhere(shown: "apple.com", opens: "evil.example"))
        #expect(try Self.caution("https://docs.python.org/3/", "https://www.evil.example/3/")
            == .elsewhere(shown: "docs.python.org", opens: "evil.example"))
        #expect(try Self.caution("fermix.ai", "https://evil.example") == .elsewhere(shown: "fermix.ai", opens: "evil.example"))
        #expect(try Self.caution("bbc.co.uk", "https://evil.co.uk") == .elsewhere(shown: "bbc.co.uk", opens: "evil.co.uk"))
        #expect(try Self.caution("apple.com", "http://17.253.144.10/") == .elsewhere(shown: "apple.com", opens: "17.253.144.10"))
    }

    @Test("the shown host is as written, lowercased and without its www")
    func shownAsWritten() throws {
        #expect(try Self.caution("WWW.Apple.com/iphone", "https://www.evil.example/x")
            == .elsewhere(shown: "apple.com", opens: "evil.example"))
        #expect(try Self.caution("яндекс.рф", "https://evil.example") == .elsewhere(shown: "яндекс.рф", opens: "evil.example"))
    }

    @Test("a name that only begins with the shown one is another site")
    func shownNameAsPrefix() throws {
        #expect(try Self.caution("apple.com", "https://apple.com.evil.example/login")
            == .elsewhere(shown: "apple.com", opens: "apple.com.evil.example"))
        #expect(try Self.caution("apple.com", "https://notapple.com") == .elsewhere(shown: "apple.com", opens: "notapple.com"))
    }

    @Test("a subdomain on either side is the same site")
    func subdomains() throws {
        #expect(try Self.caution("google.com", "https://accounts.google.com/signin") == nil)
        #expect(try Self.caution("accounts.google.com", "https://google.com") == nil)
        #expect(try Self.caution("Socket.IO", "https://socket.io/docs") == nil)
    }

    @Test("www, case, a closing dot and the scheme are ignored")
    func sameSiteWrittenDifferently() throws {
        #expect(try Self.caution("www.apple.com", "https://apple.com") == nil)
        #expect(try Self.caution("Apple.com", "https://WWW.APPLE.COM./iphone") == nil)
        #expect(try Self.caution("apple.com.", "https://apple.com") == nil)
        #expect(try Self.caution("HTTPS://docs.python.org/3/", "http://docs.python.org/3/library") == nil)
        #expect(try Self.caution(" apple.com ", "https://apple.com") == nil)
    }

    @Test("a name written in Unicode and its punycode are one site")
    func unicodeAndPunycode() throws {
        #expect(try Self.caution("яндекс.рф", "https://xn--d1acpjx3f.xn--p1ai") == nil)
        #expect(try Self.caution("xn--mnchen-3ya.de", "https://münchen.de") == nil)
        #expect(try Self.caution("münchen.de", "https://m%C3%BCnchen.de") == nil)
    }

    @Test("prose words never name a site", arguments: [
        "post", "the full notice", "Read more", "v1.2", "e.g.", "i.e.", "1.2.3", "Apple", "click here",
        "see apple.com", "apple.com is down", "a@b.com", "",
    ])
    func proseWords(_ words: String) throws {
        #expect(try Self.caution(words, "https://evil.example") == nil)
    }

    @Test("a file's name is not a site", arguments: [
        "notes.md", "file.txt", "main.swift", "package.json", "README.md", "config.yaml", "ci.yml", "run.sh",
        "server.go", "lib.rs", "app.ex", "app_test.exs", "data.csv", "index.html", "photo.JPG", "archive.zip",
        "Node.js", "setup.py", "report.pdf", "Cargo.toml",
    ])
    func fileNames(_ words: String) throws {
        #expect(try Self.caution(words, "https://evil.example") == nil)
    }

    @Test("short top-level names that are sites are read as sites", arguments: ["io", "ai", "app", "dev", "so", "me", "co"])
    func shortTopLevelNames(_ top: String) throws {
        #expect(try Self.caution("example.\(top)", "https://evil.example") == .elsewhere(shown: "example.\(top)", opens: "evil.example"))
        #expect(try Self.caution("example.\(top)", "https://example.\(top)/x") == nil)
    }

    // MARK: Lookalike

    @Test("a Cyrillic letter in a Latin name is a lookalike, named by its punycode")
    func mixedCyrillic() throws {
        #expect(try Self.caution("https://p\u{0430}ypal.com") == .lookalike(opens: "xn--pypal-4ve.com"))
        #expect(try Self.caution("https://\u{0430}pple.com/x") == .lookalike(opens: "xn--pple-43d.com"))
        #expect(try Self.caution("https://login.\u{0430}pple.com") == .lookalike(opens: "login.xn--pple-43d.com"))
        #expect(try Self.caution("https://\u{0435}\u{0445}\u{0430}m\u{0440}l\u{0435}.com") != nil)
        #expect(try Self.caution("https://XN--PPLE-43D.com") == .lookalike(opens: "xn--pple-43d.com"))
        #expect(try Self.caution("https://\u{0410}pple.com") == .lookalike(opens: "xn--pple-43d.com"))
    }

    @Test("a name wholly of Cyrillic letters that pass for Latin ones is a lookalike")
    func wholeCyrillic() throws {
        #expect(try Self.caution("https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.com") == .lookalike(opens: "xn--80ak6aa92e.com"))
        #expect(try Self.caution("https://xn--80ak6aa92e.com") == .lookalike(opens: "xn--80ak6aa92e.com"))
        #expect(try Self.caution("https://\u{0435}\u{0445}\u{0430}\u{043C}\u{0440}\u{04CF}\u{0435}.com") == .lookalike(opens: "xn--80ajb1au1a38g.com"))
        #expect(try Self.caution("https://\u{0441}\u{0441}\u{0441}-2.com") != nil)
    }

    @Test("Greek, Armenian and Cherokee letters that pass for Latin ones are lookalikes")
    func otherAlphabets() throws {
        let links = [
            "https://\u{03B1}pple.com",
            "https://\u{03B9}\u{03BF}.com",
            "https://g\u{0585}\u{0585}gle.com",
            "https://\u{0578}\u{0585}.com",
            "https://\u{13A2}\u{13AC}\u{13DA}\u{13A2}.com",
            "https://\u{AB72}\u{AB7C}\u{ABAA}\u{AB72}.com",
            "https://\u{13B3}eb.com",
        ]
        for link in links {
            let reached = try #require(Self.url(link).host)
            #expect(try Self.caution(link) == .lookalike(opens: reached), "\(link)")
        }
    }

    @Test("two alphabets that pass for one another in one name are a lookalike")
    func mixedNonLatin() throws {
        #expect(try Self.caution("https://\u{03B1}\u{0440}\u{0440}.com") != nil)
    }

    @Test("a character that draws nothing makes a lookalike")
    func drawsNothing() throws {
        #expect(try Self.caution("https://xn--apple-yt3b.com") == .lookalike(opens: "xn--apple-yt3b.com"))
        #expect(try Self.caution("https://ap%E2%80%8Dple.com") == .lookalike(opens: "xn--apple-yt3b.com"))
        #expect(try Self.caution("https://ap%07ple.com") != nil)
        for hidden: Unicode.Scalar in ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{0085}"] {
            let label = "xn--" + Punycode.encode("ap\(hidden)ple")
            #expect(try Self.caution("https://\(label).com") == .lookalike(opens: "\(label).com"), "\(hidden.value)")
        }
    }

    @Test("a Latin letter outside ASCII that passes for an ASCII one is a lookalike")
    func latinLookalikes() throws {
        #expect(try Self.caution("https://\u{0251}pple.com") == .lookalike(opens: "xn--pple-p5b.com"))
        #expect(try Self.caution("https://\u{0131}nstagram.com") == .lookalike(opens: "xn--nstagram-skb.com"))
        #expect(try Self.caution("https://\u{0261}oogle.com") != nil)
        #expect(try Self.caution("https://\u{1D0F}\u{1D0F}.com") != nil)
    }

    @Test("real names in other alphabets pass", arguments: [
        "https://münchen.de", "https://bücher.example", "https://яндекс.рф", "https://例え.jp", "https://ελληνικά.gr",
        "https://\u{13E3}\u{13B3}\u{13A9}.com", "https://xn--mnchen-3ya.de", "https://xn--d1acpjx3f.xn--p1ai",
        "https://apple.com", "https://co.uk",
    ])
    func realNames(_ link: String) throws {
        #expect(try Self.caution(link) == nil)
        #expect(try Self.caution("Read more", link) == nil)
    }

    @Test("an IP literal and an address with no host pass")
    func ipLiteralsAndNoHost() throws {
        #expect(try Self.caution("https://127.0.0.1/x") == nil)
        #expect(try Self.caution("https://[::1]:8443/x") == nil)
        #expect(try Self.caution("https://[fe80::1%25en0]/") == nil)
        #expect(try Self.caution("apple.com", "http:///x") == nil)
        #expect(try Self.caution("apple.com", "https://apple.com@") == nil)
    }

    @Test("a link that is not a web address is never checked", arguments: [
        "file:///tmp/apple.com", "mailto:apple.com@evil.example", "fermix://setup", "ftp://apple.com@evil.example",
    ])
    func otherSchemes(_ link: String) throws {
        #expect(try Self.caution(link) == nil)
        #expect(try Self.caution("apple.com", link) == nil)
    }

    // MARK: Precedence

    @Test("a hidden name comes before elsewhere, and elsewhere before lookalike")
    func precedence() throws {
        let all = "https://apple.com@\u{0430}pple.com"
        #expect(try Self.caution("apple.com", all) == .hiddenName(opens: "xn--pple-43d.com"))
        #expect(try Self.caution("google.com", "https://\u{0430}pple.com") == .elsewhere(shown: "google.com", opens: "xn--pple-43d.com"))
        #expect(try Self.caution("apple.com", "https://\u{0430}pple.com") == .elsewhere(shown: "apple.com", opens: "xn--pple-43d.com"))
        #expect(try Self.caution("https://\u{0430}pple.com", "https://\u{0430}pple.com") == .lookalike(opens: "xn--pple-43d.com"))
    }

    // MARK: The parsing path

    /// The markdown parser gives a host written in Unicode in its punycode
    /// form, and a reply's links are what it parsed.
    @Test("a markdown link to a Cyrillic host is caught as the parser reads it")
    func markdownLink() throws {
        let parsed = try AttributedString(markdown: "Sign in at [Apple](https://\u{0430}pple.com/account).")
        let link = try #require(parsed.runs.compactMap { $0.link }.first)
        #expect(LinkSafety.caution(words: "Apple", url: link) == .lookalike(opens: "xn--pple-43d.com"))
        #expect(LinkSafety.caution(words: "apple.com", url: link) == .elsewhere(shown: "apple.com", opens: "xn--pple-43d.com"))

        let reply = ReplyText(markdown: "Sign in at [Apple](https://\u{0430}pple.com/account) or https://\u{0430}pple.com/help.", home: "/Users/me")
        #expect(reply.links.count == 2)
        #expect(reply.links.map(LinkSafety.caution(url:)) == [.lookalike(opens: "xn--pple-43d.com"), .lookalike(opens: "xn--pple-43d.com")])
    }

    // MARK: Punycode

    /// RFC 3492 §7.1, each sample's code points and its punycode.
    static let samples: [(name: String, points: [UInt32], encoded: String)] = [
        ("A Arabic (Egyptian)", [
            0x644, 0x64A, 0x647, 0x645, 0x627, 0x628, 0x62A, 0x643, 0x644, 0x645, 0x648, 0x634, 0x639, 0x631, 0x628,
            0x64A, 0x61F,
        ], "egbpdaj6bu4bxfgehfvwxn"),
        ("B Chinese (simplified)", [0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, 0x6587], "ihqwcrb4cv8a8dqg056pqjye"),
        ("C Chinese (traditional)", [0x4ED6, 0x5011, 0x7232, 0x4EC0, 0x9EBD, 0x4E0D, 0x8AAA, 0x4E2D, 0x6587], "ihqwctvzc91f659drss3x8bo0yb"),
        ("D Czech", [
            0x50, 0x72, 0x6F, 0x10D, 0x70, 0x72, 0x6F, 0x73, 0x74, 0x11B, 0x6E, 0x65, 0x6D, 0x6C, 0x75, 0x76, 0xED,
            0x10D, 0x65, 0x73, 0x6B, 0x79,
        ], "Proprostnemluvesky-uyb24dma41a"),
        ("E Hebrew", [
            0x5DC, 0x5DE, 0x5D4, 0x5D4, 0x5DD, 0x5E4, 0x5E9, 0x5D5, 0x5D8, 0x5DC, 0x5D0, 0x5DE, 0x5D3, 0x5D1, 0x5E8,
            0x5D9, 0x5DD, 0x5E2, 0x5D1, 0x5E8, 0x5D9, 0x5EA,
        ], "4dbcagdahymbxekheh6e0a7fei0b"),
        ("G Japanese", [
            0x306A, 0x305C, 0x307F, 0x3093, 0x306A, 0x65E5, 0x672C, 0x8A9E, 0x3092, 0x8A71, 0x3057, 0x3066, 0x304F,
            0x308C, 0x306A, 0x3044, 0x306E, 0x304B,
        ], "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"),
        ("L 3年B組金八先生", [0x33, 0x5E74, 0x42, 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F], "3B-ww4c5e180e575a65lsy2b"),
        ("M 安室奈美恵-with-SUPER-MONKEYS", [
            0x5B89, 0x5BA4, 0x5948, 0x7F8E, 0x6075, 0x2D, 0x77, 0x69, 0x74, 0x68, 0x2D, 0x53, 0x55, 0x50, 0x45, 0x52,
            0x2D, 0x4D, 0x4F, 0x4E, 0x4B, 0x45, 0x59, 0x53,
        ], "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n"),
        ("N Hello-Another-Way-それぞれの場所", [
            0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2D, 0x41, 0x6E, 0x6F, 0x74, 0x68, 0x65, 0x72, 0x2D, 0x57, 0x61, 0x79,
            0x2D, 0x305D, 0x308C, 0x305E, 0x308C, 0x306E, 0x5834, 0x6240,
        ], "Hello-Another-Way--fc4qua05auwb3674vfr0b"),
        ("O ひとつ屋根の下2", [0x3072, 0x3068, 0x3064, 0x5C4B, 0x6839, 0x306E, 0x4E0B, 0x32], "2-u9tlzr9756bt3uc0v"),
        ("P MajiでKoiする5秒前", [
            0x4D, 0x61, 0x6A, 0x69, 0x3067, 0x4B, 0x6F, 0x69, 0x3059, 0x308B, 0x35, 0x79D2, 0x524D,
        ], "MajiKoi5-783gue6qz075azm5e"),
        ("Q パフィーdeルンバ", [0x30D1, 0x30D5, 0x30A3, 0x30FC, 0x64, 0x65, 0x30EB, 0x30F3, 0x30D0], "de-jg4avhby1noc0d"),
        ("R そのスピードで", [0x305D, 0x306E, 0x30B9, 0x30D4, 0x30FC, 0x30C9, 0x3067], "d9juau41awczczp"),
        ("S -> $1.00 <-", [0x2D, 0x3E, 0x20, 0x24, 0x31, 0x2E, 0x30, 0x30, 0x20, 0x3C, 0x2D], "-> $1.00 <--"),
    ]

    @Test("the RFC 3492 samples encode and decode", arguments: samples.indices)
    func rfcSamples(_ index: Int) {
        let sample = Self.samples[index]
        let label = Self.text(sample.points)
        #expect(label.unicodeScalars.count == sample.points.count, "\(sample.name)")
        #expect(Punycode.encode(label) == sample.encoded, "\(sample.name)")
        #expect(Punycode.decode(sample.encoded[...]) == label, "\(sample.name)")
    }

    @Test("well-known labels encode, decode and round trip", arguments: [
        ("münchen", "mnchen-3ya"), ("bücher", "bcher-kva"), ("\u{0430}pple", "pple-43d"), ("яндекс", "d1acpjx3f"),
        ("рф", "p1ai"), ("例え", "r8jz45g"), ("\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}", "80ak6aa92e"),
        ("\u{0251}pple", "pple-p5b"), ("ap\u{200D}ple", "apple-yt3b"),
    ])
    func wellKnownLabels(_ label: String, _ encoded: String) {
        #expect(Punycode.encode(label) == encoded)
        #expect(Punycode.decode(encoded[...]) == label)
        #expect(Punycode.decode(Punycode.encode(label)[...]) == label)
    }

    @Test("digits read in either case, and the letters written in ASCII keep theirs")
    func digitCase() {
        #expect(Punycode.decode("PPLE-43D") == "\u{0430}PPLE")
        #expect(Punycode.decode("MNCHEN-3YA") == "M\u{00FC}NCHEN")
    }

    @Test("text that is not punycode decodes to nothing", arguments: ["ü-abc", "-abc", "abc-!", "zzzzzzzzzzzzzzzzzzzzzzzz", "99999999999"])
    func notPunycode(_ encoded: String) {
        #expect(Punycode.decode(encoded[...]) == nil)
    }
}
