import Foundation

/// What could make a link open somewhere other than where it seems to.
enum LinkCaution: Equatable, Hashable, Sendable {
    /// The link's words name one site and it opens another: `[apple.com](https://evil.example)`.
    case elsewhere(shown: String, opens: String)
    /// The host's name passes for another: letters from an alphabet that look like Latin ones,
    /// alphabets mixed in one name, or characters that draw nothing. `opens` is the host as it
    /// is really reached, in its ASCII (punycode, `xn--`) form, which shows the trick.
    case lookalike(opens: String)
    /// A name before an `@` hides the host: `https://apple.com@evil.example` opens evil.example.
    case hiddenName(opens: String)
}

/// The check a link passes before it opens: whether it might open somewhere
/// other than where it seems to. Only a web address (`http`, `https`) with a
/// host is checked; any other link opens what it names.
///
/// A host is read as it is reached. Foundation gives a host written in
/// Unicode in its ASCII form (`аpple.com` is `xn--pple-43d.com`, the
/// characters that draw nothing already dropped) and a percent-encoded one
/// in Unicode (`%D0%B0pple.com` is `аpple.com`), so every host is brought to
/// one ASCII form to compare and to name, and each of its labels to Unicode
/// to read its letters.
enum LinkSafety {
    /// The caution for a link whose words are `words` and whose destination is `url`, nil when none.
    static func caution(words: String, url: URL) -> LinkCaution? {
        guard let host = reachedHost(url) else { return nil }

        return hiddenName(url, reaching: host) ?? elsewhere(words, reaching: host) ?? lookalike(reaching: host)
    }

    /// The checks that need no words: lookalike host and hidden name. (Used where only the URL is known.)
    static func caution(url: URL) -> LinkCaution? {
        guard let host = reachedHost(url) else { return nil }

        return hiddenName(url, reaching: host) ?? lookalike(reaching: host)
    }

    /// The host a web address reaches, lowercased and without a closing dot,
    /// percent-encoding read; nil for any other link and for an address with
    /// no host.
    private static func reachedHost(_ url: URL) -> String? {
        guard ReplyLinks.isAddress(url), let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }

        return withoutClosingDot(host.lowercased())
    }

    // MARK: Hidden name

    /// A name or password before the `@`. A bare `@` hides nothing, so an
    /// empty name is none.
    private static func hiddenName(_ url: URL, reaching host: String) -> LinkCaution? {
        let names = [url.user(percentEncoded: true), url.password(percentEncoded: true)]
        guard names.contains(where: { $0?.isEmpty == false }) else { return nil }

        return .hiddenName(opens: ascii(host))
    }

    // MARK: Elsewhere

    /// The site the words name, when they read as an address, and the one the
    /// link opens, when it is neither that site nor a part of it.
    private static func elsewhere(_ words: String, reaching host: String) -> LinkCaution? {
        guard let shown = shownHost(words) else { return nil }
        let opens = withoutWWW(ascii(host))
        guard !sameSite(ascii(shown), opens) else { return nil }

        return .elsewhere(shown: shown, opens: opens)
    }

    /// The host words name when they read as a web address or a bare domain,
    /// lowercased and without its `www.`: an optional scheme, then labels
    /// joined by dots, the last a top-level name, then an optional path,
    /// query or fragment. Prose and a file's name name no host.
    private static func shownHost(_ words: String) -> String? {
        let written = afterScheme(words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let host = withoutClosingDot(String(written.prefix { !"/?#".contains($0) }))
        guard isDomain(host) else { return nil }

        return withoutWWW(host)
    }

    private static func afterScheme(_ written: String) -> Substring {
        guard let scheme = ["https://", "http://"].first(where: { written.hasPrefix($0) }) else { return written[...] }

        return written.dropFirst(scheme.count)
    }

    /// A name of two labels or more, each letters, digits and hyphens, the
    /// last a top-level name.
    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last else { return false }

        return labels.allSatisfy(isLabel) && isTopLevel(last)
    }

    private static func isLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// A top-level name is 2 to 24 letters and no file's extension
    /// (`notes.md`, `main.swift`).
    private static func isTopLevel(_ label: Substring) -> Bool {
        (2...24).contains(label.count) && label.allSatisfy(\.isLetter) && !fileExtensions.contains(String(label))
    }

    /// The extensions of the files a reply names most, which read as a
    /// top-level name and are not one here. `.io`, `.ai`, `.app`, `.dev`,
    /// `.so`, `.me` and `.co` are sites.
    private static let fileExtensions: Set<String> = [
        "md", "txt", "py", "js", "ts", "swift", "json", "yml", "yaml", "toml", "pdf", "png", "jpg", "jpeg",
        "gif", "csv", "html", "htm", "sh", "rb", "go", "rs", "ex", "exs", "log", "zip",
    ]

    /// Two hosts are one site when they are the same or one is a part of the
    /// other, ending in a dot and the whole of it (`accounts.google.com` and
    /// `google.com`). No list of public suffixes is read.
    private static func sameSite(_ shown: String, _ opens: String) -> Bool {
        shown == opens || shown.hasSuffix("." + opens) || opens.hasSuffix("." + shown)
    }

    // MARK: Lookalike

    /// The host when one of its labels passes for another name.
    private static func lookalike(reaching host: String) -> LinkCaution? {
        guard host.split(separator: ".").map(unicodeLabel).contains(where: passesForAnother) else { return nil }

        return .lookalike(opens: ascii(host))
    }

    /// A label passes for another when it holds a character that draws
    /// nothing, mixes alphabets that pass for one another, is written wholly
    /// in letters that pass for Latin ones, or holds a Latin letter that
    /// passes for an ASCII one. An IP literal is digits, dots, colons and hex
    /// letters, so it never does.
    private static func passesForAnother(_ label: String) -> Bool {
        let scalars = label.unicodeScalars
        return scalars.contains(where: drawsNothing)
            || Set(scalars.compactMap(LookalikeScript.init)).count > 1
            || isWhollyLookalike(scalars)
            || scalars.contains { latinLookalikes.contains($0) }
    }

    /// A character that draws nothing (zero width, joiners, a soft hyphen, a
    /// filler) or a format or control character.
    private static func drawsNothing(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isDefaultIgnorableCodePoint
            || properties.generalCategory == .format
            || properties.generalCategory == .control
    }

    /// A label whose letters, digits and hyphens aside, are all from one
    /// alphabet other than Latin and each pass for a Latin letter: Cyrillic
    /// `аррӏе` reads as `apple`.
    private static func isWhollyLookalike(_ scalars: String.UnicodeScalarView) -> Bool {
        let letters = scalars.filter { !isDigitOrHyphen($0) }
        guard let first = letters.first, let script = LookalikeScript(first), let table = passesForLatin[script] else {
            return false
        }

        return letters.allSatisfy { table.contains($0) }
    }

    private static func isDigitOrHyphen(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "-": true
        default: false
        }
    }

    /// The letters of each alphabet other than Latin that pass for a Latin
    /// letter in a host, lowercased as a host's letters are read. Most are
    /// the same shape; some are a small capital the same height as a
    /// lowercase letter.
    private static let passesForLatin: [LookalikeScript: Set<Unicode.Scalar>] = [
        // а в е к м н о р с т у х ѕ і ј ԁ һ ӏ ԛ ԝ ү ꙇ
        // a b e k m h o p c t y x s i j d h l q w y i
        .cyrillic: lowercased("авекмнорстухѕіјԁһӏԛԝүꙇ"),
        // α ο ν ρ τ υ ι κ χ
        // a o v p t u i k x
        // ε is left out: it reads as ɛ, not e.
        .greek: lowercased("αονρτυικχ"),
        // օ հ ս ց ո
        // o h u g n
        .armenian: lowercased("օհսցո"),
        // Ꭺ Ᏼ Ꮯ Ꭰ Ꭼ Ꮐ Ꮋ Ꭵ Ꭻ Ꮶ Ꮮ Ꮇ Ꮻ Ꮲ Ꭱ Ꮪ Ꭲ Ꮩ Ꮃ Ꮓ
        // A B C D E G H i J K L M O P R S T V W Z
        // Lowercased to their small letters (Ꮃ to ꮃ); a host carries the capitals.
        .cherokee: lowercased("ᎪᏴᏟᎠᎬᏀᎻᎥᎫᏦᏞᎷᏫᏢᎡᏚᎢᏙᎳᏃ"),
    ]

    /// Latin letters outside ASCII that pass for an ASCII letter, kept to
    /// the ones used to pass a host for another: ɑ ɡ ı ȷ ɩ ǀ ɪ ʟ ꞁ ɴ ᴏ ᴄ ᴠ ᴡ ᴢ ꜱ,
    /// read as a g i j i l i l l n o c v w z s. A letter with a mark
    /// (`ü` in `münchen`) is its own letter, not one of these.
    private static let latinLookalikes: Set<Unicode.Scalar> = lowercased("ɑɡıȷɩǀɪʟꞁɴᴏᴄᴠᴡᴢꜱ")

    private static func lowercased(_ letters: String) -> Set<Unicode.Scalar> {
        Set(letters.lowercased().unicodeScalars)
    }

    // MARK: Host forms

    /// A host in its ASCII form, each label written in Unicode in Punycode
    /// with its `xn--`, as it is looked up.
    private static func ascii(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map(asciiLabel).joined(separator: ".")
    }

    private static func asciiLabel(_ label: Substring) -> String {
        guard !label.unicodeScalars.allSatisfy(\.isASCII) else { return String(label) }

        return "xn--" + Punycode.encode(String(label))
    }

    /// A label as it is drawn, lowercased: an `xn--` label decoded, and one
    /// that is not Punycode the ASCII it is written in.
    private static func unicodeLabel(_ label: Substring) -> String {
        guard label.hasPrefix("xn--"), let decoded = Punycode.decode(label.dropFirst(4)) else { return String(label) }

        return decoded.lowercased()
    }

    private static func withoutClosingDot(_ host: String) -> String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The alphabets whose letters pass for one another in a host, each read by
/// its Unicode blocks: Latin, and the four with letters shaped like Latin
/// ones. A letter of any other alphabet, and anything that is not a letter,
/// is none of them.
private enum LookalikeScript: Hashable {
    case latin, cyrillic, greek, armenian, cherokee

    init?(_ scalar: Unicode.Scalar) {
        guard Self.isLetter(scalar), let block = Self.blocks.first(where: { $0.ranges.contains { range in range.contains(scalar.value) } }) else {
            return nil
        }

        self = block.script
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static let blocks: [(script: LookalikeScript, ranges: [ClosedRange<UInt32>])] = [
        // Basic Latin, Latin-1 Supplement, Extended-A and B, IPA, Phonetic
        // Extensions, Extended Additional, C, D and E, and fullwidth letters.
        (.latin, [
            0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x250...0x2AF, 0x1D00...0x1D7F, 0x1E00...0x1EFF,
            0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
        ]),
        // Cyrillic, its Supplement, and Extended-A, B and C.
        (.cyrillic, [0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F]),
        // Greek and Coptic, and Greek Extended.
        (.greek, [0x370...0x3FF, 0x1F00...0x1FFF]),
        // Armenian, and its ligatures.
        (.armenian, [0x531...0x58F, 0xFB13...0xFB17]),
        // Cherokee, and its small letters.
        (.cherokee, [0x13A0...0x13FF, 0xAB70...0xABBF]),
    ]
}

/// Punycode (RFC 3492): a label in any letters written in the letters,
/// digits and hyphens a host is looked up in, as each `xn--` label of a host
/// is. Neither direction maps or checks the label as IDNA does; each is the
/// RFC's algorithm alone.
enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 0x80

    /// `label` in Punycode, without the `xn--` that marks it in a host. The
    /// sums stay far inside an `Int` for any label a string can hold: each
    /// step adds at most the highest code point times the label's length.
    static func encode(_ label: String) -> String {
        let points = label.unicodeScalars.map { Int($0.value) }
        let basic = label.unicodeScalars.filter(\.isASCII)
        var output = String(String.UnicodeScalarView(basic))
        if !basic.isEmpty {
            output.append("-")
        }

        var n = initialN
        var delta = 0
        var bias = initialBias
        var handled = basic.count
        for next in Set(points.filter { $0 >= initialN }).sorted() {
            delta += (next - n) * (handled + 1)
            n = next
            for point in points {
                if point < n {
                    delta += 1
                }
                if point == n {
                    output += digits(of: delta, bias: bias)
                    bias = adapt(delta, points: handled + 1, first: handled == basic.count)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }

        return output
    }

    /// The label `encoded` writes in Punycode, given without its `xn--`; nil
    /// when it is not Punycode.
    static func decode(_ encoded: Substring) -> String? {
        let scalars = Array(encoded.unicodeScalars)
        let delimiter = scalars.lastIndex(of: "-") ?? 0
        let basic = scalars[..<delimiter]
        guard basic.allSatisfy(\.isASCII) else { return nil }

        var output = Array(basic)
        var extended = scalars[(basic.isEmpty ? 0 : delimiter + 1)...]
        var n = initialN
        var i = 0
        var bias = initialBias
        while !extended.isEmpty {
            let start = i
            guard let next = number(from: &extended, adding: i, bias: bias) else { return nil }

            i = next
            bias = adapt(i - start, points: output.count + 1, first: start == 0)
            guard let moved = sum(n, i / (output.count + 1)), moved >= initialN,
                  let scalar = Unicode.Scalar(UInt32(clamping: moved)) else {
                return nil
            }

            n = moved
            i %= output.count + 1
            output.insert(scalar, at: i)
            i += 1
        }

        return String(String.UnicodeScalarView(output))
    }

    /// One variable-length number read from the front of `extended` and added
    /// to `i`; nil when the digits end early, a character is no digit, or the
    /// number overflows.
    private static func number(from extended: inout ArraySlice<Unicode.Scalar>, adding i: Int, bias: Int) -> Int? {
        var i = i
        var weight = 1
        var k = base
        while let scalar = extended.popFirst() {
            guard let digit = value(of: scalar), let step = product(digit, weight), let next = sum(i, step) else {
                return nil
            }

            i = next
            let t = threshold(k, bias: bias)
            if digit < t {
                return i
            }
            guard let grown = product(weight, base - t) else { return nil }

            weight = grown
            k += base
        }

        return nil
    }

    /// `delta` as a variable-length number of digits.
    private static func digits(of delta: Int, bias: Int) -> String {
        var output = ""
        var q = delta
        var k = base
        var t = threshold(k, bias: bias)
        while q >= t {
            output.append(digit(t + (q - t) % (base - t)))
            q = (q - t) / (base - t)
            k += base
            t = threshold(k, bias: bias)
        }
        output.append(digit(q))

        return output
    }

    private static func threshold(_ k: Int, bias: Int) -> Int {
        min(max(k - bias, tMin), tMax)
    }

    private static func adapt(_ delta: Int, points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }

        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }

    /// The digit for a value below 36: `a` to `z` for 0 to 25, `0` to `9`
    /// for 26 to 35.
    private static func digit(_ value: Int) -> Character {
        let ascii = value < 26 ? 0x61 + value : 0x30 + value - 26
        return Character(Unicode.Scalar(UInt8(ascii)))
    }

    /// The value of a digit in either case, nil for anything else.
    private static func value(of scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "a"..."z": Int(scalar.value) - 0x61
        case "A"..."Z": Int(scalar.value) - 0x41
        case "0"..."9": Int(scalar.value) - 0x30 + 26
        default: nil
        }
    }

    private static func sum(_ a: Int, _ b: Int) -> Int? {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : result
    }

    private static func product(_ a: Int, _ b: Int) -> Int? {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : result
    }
}
