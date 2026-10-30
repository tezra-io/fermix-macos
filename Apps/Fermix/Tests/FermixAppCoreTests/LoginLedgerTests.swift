import CryptoKit
import Foundation
import Testing

@testable import FermixAppCore

/// The login ledger (M84 §9): every password a sign-in typed, at most fifty,
/// the oldest leaving first, and the scrub that keeps each one off the wire
/// in all three forms a page can hand it back in.
@MainActor
@Suite("Login ledger")
struct LoginLedgerTests {
    /// Every character the wire's JSON spelling or a page's own encoding
    /// treats specially: a quote, a backslash, a slash, an ampersand, an angle
    /// bracket, a space and a letter outside ASCII.
    static let awkward = LedgerForms.awkward

    // MARK: - Holding

    @Test("it holds at most fifty passwords, the oldest leaving first")
    func capacityDropsTheOldest() {
        let ledger = LoginLedger()
        for index in 0..<(LoginLedger.capacity + 2) {
            ledger.add(LoginSecret("password-\(index)"))
        }

        #expect(ledger.count == LoginLedger.capacity)
        #expect(!ledger.holds(LoginSecret("password-0")))
        #expect(!ledger.holds(LoginSecret("password-1")))
        #expect(ledger.holds(LoginSecret("password-2")))
        #expect(ledger.holds(LoginSecret("password-\(LoginLedger.capacity + 1)")))
    }

    @Test("a password filled again moves to the newest place instead of taking a second one")
    func refillMovesToNewest() {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("first-password"))
        for index in 0..<(LoginLedger.capacity - 1) {
            ledger.add(LoginSecret("other-\(index)"))
        }
        ledger.add(LoginSecret("first-password"))
        ledger.add(LoginSecret("one-more-password"))

        #expect(ledger.count == LoginLedger.capacity)
        #expect(ledger.holds(LoginSecret("first-password")))
        #expect(!ledger.holds(LoginSecret("other-0")))
    }

    @Test("an empty ledger, or a line that holds no form of a password, leaves the line byte for byte")
    func noFormScrubsNothing() throws {
        let line = try BrowserHostResponse(id: 1, result: .tabFocus(tabId: "t1", url: "https://example.com/", title: "Example")).line()
        let ledger = LoginLedger()
        let empty = ledger.scrub(line)
        ledger.add(LoginSecret("correct-horse-battery"))

        #expect(empty == line)
        #expect(ledger.scrub(line) == line)
    }

    // MARK: - The three forms

    @Test("an answer holding the password as typed, HTML-escaped or form-encoded comes out hidden")
    func answerScrubbedInEveryForm() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret(Self.awkward))

        for form in Self.forms(of: Self.awkward) {
            let response = BrowserHostResponse(
                id: 7,
                result: .pageAct(BrowserHostActResult(url: "https://example.com/", title: "Sign in", value: .string("before \(form) after")))
            )
            let scrubbed = ledger.scrub(try response.line())

            let object = try Self.object(scrubbed)
            let value = (object["result"] as? [String: Any])?["value"] as? String
            #expect(value == "before \(LoginLedger.hidden) after", "the form \(Self.formName(form)) survived")
            #expect(!Self.text(scrubbed).contains(Self.encoded(form)))
        }
    }

    @Test("an event holding the password comes out hidden in every form")
    func eventScrubbedInEveryForm() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret(Self.awkward))

        for form in Self.forms(of: Self.awkward) {
            let event = BrowserHostEvent.downloadBegan(downloadId: "d1", tabId: "t1", filename: "\(form).txt")
            let object = try Self.object(ledger.scrub(try event.line()))

            #expect(object["filename"] as? String == "\(LoginLedger.hidden).txt", "the form \(Self.formName(form)) survived")
        }
    }

    @Test("a dialog's message holding the password comes out hidden in every form")
    func dialogMessageScrubbedInEveryForm() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret(Self.awkward))

        for form in Self.forms(of: Self.awkward) {
            let event = BrowserHostEvent.dialogOpened(tabId: "t1", kind: .alert, message: "Your password is \(form)", defaultText: nil)
            let object = try Self.object(ledger.scrub(try event.line()))

            #expect(object["message"] as? String == "Your password is \(LoginLedger.hidden)", "the form \(Self.formName(form)) survived")
        }
    }

    @Test("an error message holding the password comes out hidden")
    func errorMessageScrubbed() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret(Self.awkward))
        let response = BrowserHostResponse(id: 3, error: BrowserHostError(reason: .actFailed, message: "page said \(Self.awkward)"))

        let object = try Self.object(ledger.scrub(try response.line()))

        #expect((object["error"] as? [String: Any])?["message"] as? String == "page said \(LoginLedger.hidden)")
    }

    @Test("a password holding another ledger password is hidden whole")
    func longestFormGoesFirst() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("short-secret"))
        ledger.add(LoginSecret("short-secret-and-longer"))
        let event = BrowserHostEvent.downloadBegan(downloadId: "d1", tabId: "t1", filename: "short-secret-and-longer")

        let object = try Self.object(ledger.scrub(try event.line()))

        #expect(object["filename"] as? String == LoginLedger.hidden)
    }

    // MARK: - The wire's own words

    /// A saved password can be a word the wire itself spells: a key, a
    /// closed value, or text inside one. The scrub hides it in what the page
    /// wrote and leaves the frame's own shape whole, so the daemon still
    /// reads the line.
    @Test("a password that is the word password leaves a sign-in result whole and hides it in the page's text")
    func passwordNamedPasswordKeepsTheSignInResult() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("password"))
        let page = BrowserHostPage(
            url: "https://example.com/login",
            title: "Your password",
            readyState: "complete",
            nodes: [
                BrowserHostNode(nodeId: .integer(1), role: BrowserHostAXValue("RootWebArea"), childIds: [.integer(2)]),
                BrowserHostNode(
                    nodeId: .integer(2),
                    role: BrowserHostAXValue("textbox"),
                    name: BrowserHostAXValue("Enter your password"),
                    value: BrowserHostAXValue("password"),
                    properties: [BrowserHostAXProperty(name: "editable", value: BrowserHostAXValue("plaintext"))],
                    backendDOMNodeId: 12
                )
            ]
        )
        let response = BrowserHostResponse(id: 29, result: .pageSignIn(BrowserHostSignInResult(
            url: "https://example.com/login", title: "Sign in", filled: ["username", "password"], page: page
        )))

        let object = try Self.object(ledger.scrub(try response.line()))

        let result = try #require(object["result"] as? [String: Any])
        #expect(Set(result.keys) == ["url", "title", "filled", "page"])
        #expect(result["filled"] as? [String] == ["username", "password"])
        let scrubbedPage = try #require(result["page"] as? [String: Any])
        #expect(Set(scrubbedPage.keys) == ["url", "title", "ready_state", "nodes"])
        #expect(scrubbedPage["title"] as? String == "Your \(LoginLedger.hidden)")
        let node = try #require((scrubbedPage["nodes"] as? [[String: Any]])?.last)
        #expect(Set(node.keys) == ["nodeId", "role", "name", "value", "properties", "backendDOMNodeId"])
        #expect((node["name"] as? [String: Any])?["value"] as? String == "Enter your \(LoginLedger.hidden)")
        #expect((node["value"] as? [String: Any])?["value"] as? String == LoginLedger.hidden)
    }

    @Test("a password that is the word password hides it in an error's message and keeps the reason")
    func passwordNamedPasswordKeepsTheErrorReason() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("password"))
        let response = BrowserHostResponse(id: 29, error: BrowserHostError(reason: .signInField, message: "ref 12 is not a password field"))

        let object = try Self.object(ledger.scrub(try response.line()))

        #expect(Set(object.keys) == ["id", "ok", "error"])
        let error = try #require(object["error"] as? [String: Any])
        #expect(Set(error.keys) == ["reason", "message"])
        #expect(error["reason"] as? String == "sign_in_field")
        #expect(error["message"] as? String == "ref 12 is not a \(LoginLedger.hidden) field")
    }

    @Test("a password that is a key or a closed value of the wire leaves both and hides the page's own text")
    func wireWordsStayWhole() throws {
        for word in ["ready_state", "complete", "interactive", "sign_in_field"] {
            let ledger = LoginLedger()
            ledger.add(LoginSecret(word))
            let page = BrowserHostPage(url: "https://example.com/", title: "about \(word)", readyState: "complete", nodes: [])
            let snapshot = BrowserHostResponse(id: 7, result: .pageSnapshot(page))
            let refusal = BrowserHostResponse(id: 9, error: BrowserHostError(reason: .signInField, message: "said \(word)"))

            let result = try #require(try Self.object(ledger.scrub(try snapshot.line()))["result"] as? [String: Any])
            let error = try #require(try Self.object(ledger.scrub(try refusal.line()))["error"] as? [String: Any])

            #expect(Set(result.keys) == ["url", "title", "ready_state", "nodes"], "\(word)")
            #expect(result["ready_state"] as? String == "complete", "\(word)")
            #expect(result["title"] as? String == "about \(LoginLedger.hidden)", "\(word)")
            #expect(error["reason"] as? String == "sign_in_field", "\(word)")
            #expect(error["message"] as? String == "said \(LoginLedger.hidden)", "\(word)")
        }
    }

    @Test("a password with a wire word as its prefix is hidden wherever the page put it")
    func wireWordPrefixHidden() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("snapshot1"))
        let response = BrowserHostResponse(id: 10, result: .pageAct(BrowserHostActResult(
            url: "https://example.com/?q=snapshot1", title: "snapshot1 snapshot", value: .string("snapshot1")
        )))

        let result = try #require(try Self.object(ledger.scrub(try response.line()))["result"] as? [String: Any])

        #expect(result["url"] as? String == "https://example.com/?q=\(LoginLedger.hidden)")
        #expect(result["title"] as? String == "\(LoginLedger.hidden) snapshot")
        #expect(result["value"] as? String == LoginLedger.hidden)
    }

    @Test("an event's type and closed values stay whole while its free-text reasons are hidden")
    func eventVocabularyStaysWhole() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("availability"))
        ledger.add(LoginSecret("completed"))
        ledger.add(LoginSecret("beforeunload"))
        let events: [BrowserHostEvent] = [
            .availability(available: false, reason: "availability is off"),
            .downloadFinished(downloadId: "d1", tabId: "t1", state: .completed, path: nil, bytes: nil, reason: "completed early"),
            .dialogOpened(tabId: "t1", kind: .beforeunload, message: "beforeunload now", defaultText: nil),
            .taskCancel(taskId: "task-1", reason: "availability")
        ]

        let objects = try events.map { try Self.object(ledger.scrub(try $0.line())) }

        #expect(objects.map { $0["type"] as? String } == ["availability", "download.finished", "dialog.opened", "task.cancel"])
        #expect(objects[0]["reason"] as? String == "\(LoginLedger.hidden) is off")
        #expect(objects[1]["state"] as? String == "completed")
        #expect(objects[1]["reason"] as? String == "\(LoginLedger.hidden) early")
        #expect(objects[2]["kind"] as? String == "beforeunload")
        #expect(objects[2]["message"] as? String == "\(LoginLedger.hidden) now")
        #expect(objects[3]["reason"] as? String == LoginLedger.hidden)
    }

    // MARK: - Fingerprints

    @Test("a fingerprint is the password's UTF-16 length and the SHA-256 of its UTF-8")
    func fingerprintIsLengthAndDigest() throws {
        let ledger = LoginLedger()
        ledger.add(LoginSecret("pässwörd😀"))

        let fingerprint = try #require(ledger.fingerprints.first)
        #expect(fingerprint.utf16Length == "pässwörd😀".utf16.count)
        let digest = SHA256.hash(data: Data("pässwörd😀".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint.sha256 == digest)
    }

    // MARK: - Printing nothing

    @Test("a login secret, the ledger, a fingerprint and the login fill that carries the secret print, debug-print and mirror nothing")
    func nothingPrints() throws {
        let secret = LoginSecret(Self.awkward)
        let ledger = LoginLedger()
        ledger.add(secret)
        let fingerprint = try #require(ledger.fingerprints.first)
        let fill = BrowserLoginFill(
            topURL: try #require(URL(string: "https://example.com/login")),
            usernameRef: 11,
            username: "person@example.com",
            passwordRef: 12,
            password: secret
        )

        for value in [secret as Any, ledger as Any, fingerprint as Any, fill as Any, [fill] as Any, Optional(fill) as Any] {
            let printed = [String(describing: value), String(reflecting: value), Self.dumped(value)]
            for text in printed {
                #expect(!text.contains("w<o>rd") && !text.contains("s&w"), "a password in \(text)")
                #expect(!text.contains("person@example.com"), "a username in \(text)")
                #expect(!text.contains(fingerprint.sha256), "a digest in \(text)")
            }
        }
        #expect(Mirror(reflecting: secret).children.isEmpty)
        #expect(Mirror(reflecting: fill).children.isEmpty)
        #expect(Mirror(reflecting: fingerprint).children.isEmpty)
        #expect(Mirror(reflecting: ledger).children.isEmpty)
    }

    // MARK: - Mechanics

    /// The three forms the scrub matches: as typed, the HTML serializer's
    /// attribute and text spellings, and `application/x-www-form-urlencoded`.
    static func forms(of password: String) -> [String] {
        let attribute = password.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let text = password
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._ ")
        let form = (password.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            .replacingOccurrences(of: " ", with: "+")
        return [password, attribute, text, form]
    }

    private static func formName(_ form: String) -> String {
        form.contains("%") ? "form-encoded" : form.contains("&amp;") ? "HTML-escaped" : "as typed"
    }

    private static func encoded(_ text: String) -> String {
        let quoted = (try? BrowserHostProtocol.lineEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return String(quoted.dropFirst().dropLast())
    }

    private static func object(_ line: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private static func text(_ line: Data) -> String {
        String(decoding: line, as: UTF8.self)
    }

    private static func dumped(_ value: Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }
}

/// The password every scrub case types: a quote, a backslash, a slash, an
/// ampersand, angle brackets, a space and a letter outside ASCII, each a
/// character the wire's JSON spelling or a page's own encoding treats
/// specially.
enum LedgerForms {
    static let awkward = "p\"a\\s/s&w<o>rd é1"
}
