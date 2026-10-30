import CryptoKit
import Foundation

/// What the capture guard compares a page's text fields with: the length of
/// a filled password in UTF-16 code units, which is what a page's
/// `value.length` counts, and the SHA-256 of its UTF-8 bytes. The password
/// itself never goes to the page for this; the digest goes only into the
/// page's own content world, never the wire. Prints and mirrors as withheld.
public struct BrowserSecretFingerprint: Equatable, Sendable, CustomStringConvertible,
                                        CustomDebugStringConvertible, CustomReflectable {
    public let utf16Length: Int
    /// Lowercase hex, the form the page script's own SHA-256 answers.
    public let sha256: String

    init(_ secret: LoginSecret) {
        utf16Length = secret.utf16Count
        sha256 = secret.withValue { value in
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    public var description: String { "BrowserSecretFingerprint(\(LoginSecret.withheld))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Every password a sign-in typed into a page since the app started (M84 §9),
/// at most `capacity`, the oldest leaving first, for the life of the process:
/// a filled page and its form can outlive the task that filled it.
///
/// While it holds an entry, every line the wire client sends is scrubbed of
/// each password in the three forms a page can hand it back in: as typed,
/// HTML-escaped (as the browser's serializer writes text and attribute
/// values) and form-encoded (as a GET form puts it in an address), each
/// replaced with `hidden`. Only string values are scrubbed: never a key, and
/// never a value the protocol closes to a fixed set
/// (`BrowserHostProtocol.closedPaths`), so a password that happens to be one
/// of the wire's own words leaves the frame's shape whole. Only the client's
/// own process holds it; it prints and mirrors as withheld.
@MainActor
public final class LoginLedger: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let capacity = 50
    public static let hidden = "[hidden]"

    private struct Entry {
        let secret: LoginSecret
        /// Every form of the password, longest first.
        let forms: [String]
        /// The same forms as `BrowserHostProtocol.lineEncoder()` writes them
        /// inside a JSON string: a line holding none of these holds no form,
        /// and is sent as it is.
        let fragments: [Data]
        let fingerprint: BrowserSecretFingerprint
    }

    /// Oldest first.
    private var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Takes `secret` in as the newest entry. A password already held moves
    /// to the newest place rather than taking a second one.
    public func add(_ secret: LoginSecret) {
        let forms = Self.forms(of: secret)
        entries.removeAll { $0.secret == secret }
        entries.append(Entry(
            secret: secret,
            forms: forms,
            fragments: forms.map(Self.jsonStringContent),
            fingerprint: BrowserSecretFingerprint(secret)
        ))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func holds(_ secret: LoginSecret) -> Bool {
        entries.contains { $0.secret == secret }
    }

    public var fingerprints: [BrowserSecretFingerprint] { entries.map(\.fingerprint) }

    /// `line` with every form of every password replaced by `hidden` in its
    /// string values. A line that holds no form anywhere is answered as it
    /// is; one that does is read as JSON, scrubbed value by value and written
    /// again with the same encoder, its keys and closed values untouched. The
    /// longest forms go first, so a password that contains another is hidden
    /// whole.
    public func scrub(_ line: Data) -> Data {
        guard entries.contains(where: { $0.fragments.contains { line.range(of: $0) != nil } }) else { return line }

        let forms = entries.flatMap(\.forms).sorted { $0.count > $1.count }
        let frame = WireJSON(parsing: line)
        let closed = BrowserHostProtocol.closedPaths[frame.frameName] ?? []
        return frame.hiding(forms, with: Self.hidden, closed: closed, at: []).encoded()
    }

    public nonisolated var description: String { "LoginLedger(\(LoginSecret.withheld))" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }

    // MARK: - The forms

    private static func forms(of secret: LoginSecret) -> [String] {
        let forms = secret.withValue { value in
            Set([value, formEncoded(value)] + htmlEscaped(value))
        }
        return forms.sorted { $0.count > $1.count }
    }

    /// The HTML serializer's three spellings of a value: as text, as an
    /// attribute value, and as an attribute value the way engines that also
    /// escape angle brackets in attributes write it.
    private static func htmlEscaped(_ value: String) -> [String] {
        let ampersands = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
        let text = ampersands
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let attribute = ampersands.replacingOccurrences(of: "\"", with: "&quot;")
        let bracketedAttribute = text.replacingOccurrences(of: "\"", with: "&quot;")
        return [text, attribute, bracketedAttribute]
    }

    /// `application/x-www-form-urlencoded`, as the URL standard serializes a
    /// form's value: `*-._` and alphanumerics kept, a space as `+`, every
    /// other byte of the UTF-8 as `%XX`.
    private static func formEncoded(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case 0x2A, 0x2D, 0x2E, 0x5F, 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                encoded.append(Character(Unicode.Scalar(byte)))
            case 0x20:
                encoded.append("+")
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    /// The bytes `lineEncoder()` writes for `text` between a JSON string's
    /// quotes. Encoding a string cannot fail; a failure is a defect, and its
    /// message carries no value.
    private static func jsonStringContent(_ text: String) -> Data {
        let quoted: Data
        do {
            quoted = try BrowserHostProtocol.lineEncoder().encode(text)
        } catch {
            preconditionFailure("the line encoder could not encode a ledger entry")
        }
        return Data(quoted.dropFirst().dropLast())
    }
}

/// One JSON value of a line this build wrote, as the scrub walks it. Read
/// with `JSONSerialization`, which tells a flag from a number and a whole
/// number from a fractional one, and written again with the line encoder.
private enum WireJSON: Encodable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([WireJSON])
    case object([String: WireJSON])

    /// A line this build's own encoder wrote always reads back; one that does
    /// not is a defect, and the message carries none of it.
    init(parsing line: Data) {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line)
        } catch {
            preconditionFailure("a browser host line this build wrote did not read back as JSON")
        }
        self.init(value)
    }

    private init(_ value: Any) {
        switch value {
        case let text as String: self = .string(text)
        case let number as NSNumber: self = Self.number(number)
        case let items as [Any]: self = .array(items.map(WireJSON.init))
        case let members as [String: Any]: self = .object(members.mapValues(WireJSON.init))
        case is NSNull: self = .null
        default: preconditionFailure("a browser host line held a value JSON has no kind for")
        }
    }

    private static func number(_ number: NSNumber) -> WireJSON {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
        return .integer(number.intValue)
    }

    /// The frame `BrowserHostProtocol.closedPaths` is keyed by: an event's
    /// own `type`, or `response` for an answer, which carries none.
    var frameName: String {
        guard case .object(let members) = self, case .string(let type)? = members["type"] else { return "response" }

        return type
    }

    /// The deepest a line this build writes nests (a node's property value is
    /// eight levels down); a deeper one is a defect, not a page's doing.
    private static let maximumDepth = 32

    /// Every string value with each of `forms` replaced, except at a closed
    /// path. Keys are never touched.
    func hiding(_ forms: [String], with replacement: String, closed: Set<[String]>, at path: [String]) -> WireJSON {
        precondition(path.count <= Self.maximumDepth, "a browser host line nests deeper than any frame")
        switch self {
        case .string(let text):
            guard !closed.contains(path) else { return self }
            return .string(forms.reduce(text) { $0.replacingOccurrences(of: $1, with: replacement) })
        case .array(let items):
            return .array(items.map { $0.hiding(forms, with: replacement, closed: closed, at: path + ["*"]) })
        case .object(let members):
            return .object(Dictionary(uniqueKeysWithValues: members.map { key, value in
                (key, value.hiding(forms, with: replacement, closed: closed, at: path + [key]))
            }))
        case .null, .bool, .integer, .double:
            return self
        }
    }

    func encoded() -> Data {
        do {
            return try BrowserHostProtocol.lineEncoder().encode(self)
        } catch {
            preconditionFailure("a scrubbed browser host line could not be written again")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
