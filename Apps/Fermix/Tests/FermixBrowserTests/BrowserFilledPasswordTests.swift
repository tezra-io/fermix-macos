import CryptoKit
import FermixAppCore
import Foundation
import Testing

@testable import FermixBrowser

/// After a sign-in (M84 §9): every read the pane serves masks the password
/// field, the document guard undoes each way a page reveals it, and the
/// capture guard refuses a screenshot while it shows as text.
@MainActor
@Suite("Browser filled password", .serialized)
struct BrowserFilledPasswordTests {
    private static let observation = BrowserSnapshotRequest(mode: .interactive, maxChars: 1, depth: 1)
    private static let bullets = String(repeating: "•", count: SignInFixture.password.count)

    // MARK: - Reads

    @Test("typing into the filled password field, by keys or by the setter, answers bullets")
    func typingAnswersBullets() async throws {
        let (harness, refs, _) = try await Self.signedIn(SignInFixture.plainForm)
        let password = try #require(refs["Password"])

        let prepared: FieldValue = try await harness.call("prepareTyping", [password, true])
        // A typed key lands in the page as a person's would; the read after
        // it is the one the key path answers.
        try await harness.pageWorld("const p = document.getElementById('password'); p.value = p.value + 'x';")
        let keyed: FieldValue = try await harness.call("valueOf", [password])
        let set: FieldValue = try await harness.call("setValue", [password, "é", true])

        #expect(prepared.value == Self.bullets)
        #expect(keyed.value == Self.bullets + "•")
        #expect(set.value == Self.bullets + "••")
        for answer in [prepared.value, keyed.value, set.value] {
            #expect(answer.allSatisfy { $0 == "•" })
        }
    }

    @Test("a password field the model typed into itself answers bullets too, with no sign-in")
    func unfilledPasswordFieldMasked() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(SignInFixture.plainForm, at: SignInFixture.loginPage)
        let password = try #require(try await harness.fieldRefs()["Password"])

        let set: FieldValue = try await harness.call("setValue", [password, "hunter22", false])

        #expect(set.value == "••••••••")
    }

    @Test("a label wrapping both fields and an aria-labelledby on the password's box name nothing but bullets")
    func embeddedNamesMasked() async throws {
        let page = """
            <!doctype html><html><body>
            <label>Sign in <input id="username" type="email"> <input id="password" type="password"></label>
            <div id="box"><input id="second" type="password"></div>
            <button aria-labelledby="box">Show</button>
            </body></html>
            """
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        try await harness.load(page, at: SignInFixture.loginPage)
        let fields = try await harness.orderedFieldRefs()
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        _ = try await harness.page.signIn(
            BrowserSignInTestRequest.both(username: fields[0], password: fields[1]),
            store: store, ledger: LoginLedger(), observing: Self.observation
        )
        try await harness.pageWorld("document.getElementById('second').value = document.getElementById('password').value;")

        let snapshot = try await harness.snapshotText()

        #expect(!snapshot.contains("s3cret"))
        #expect(snapshot.contains("Sign in \(Self.bullets)"))
        #expect(snapshot.contains(#""name":"\#(Self.bullets)""#))
    }

    @Test("get html has no value attribute on a password field a React-style page syncs")
    func htmlHasNoPasswordValue() async throws {
        let (harness, _, _) = try await Self.signedIn(SignInFixture.plainForm, syncValueAttribute: true)

        let html: TextAnswer = try await harness.call("get", ["html", NSNull()])
        let field: TextAnswer = try await harness.call("get", ["html", "#password"])

        #expect(try await harness.pageBool("document.getElementById('username').hasAttribute('value')") == true)
        #expect(!html.value.contains("s3cret"))
        #expect(!field.value.contains("value="))
        #expect(!html.value.contains(#"type="password" value"#))
    }

    @Test("get html leaves the value attribute out even before any guard runs")
    func htmlStripsWithoutTheGuard() async throws {
        let harness = BrowserPageHarness()
        try await harness.load("""
            <!doctype html><html><body><input id="password" type="password" value="hunter2222"></body></html>
            """, at: SignInFixture.loginPage)

        let field: TextAnswer = try await harness.call("get", ["html", "#password"])

        #expect(field.value == #"<input id="password" type="password">"#)
    }

    @Test("a value-prefix selector matches nothing on the filled password")
    func selectorOracleClosed() async throws {
        let (harness, _, _) = try await Self.signedIn(SignInFixture.plainForm, syncValueAttribute: true)
        let first = String(SignInFixture.password.prefix(1))

        let count: CountAnswer = try await harness.call("get", ["count", "input[value^=\"\(first)\"]"])
        let control: CountAnswer = try await harness.call("get", ["count", "input[value^=\"o\"]"])

        #expect(count.value == 0)
        #expect(control.value == 1, "the username field keeps its synced attribute, so the selector itself works")
    }

    // MARK: - The document guard

    @Test("the show-password button leaves an empty text field")
    func revealClearsTheField() async throws {
        let (harness, refs, _) = try await Self.signedIn(SignInFixture.plainForm)
        let password = try #require(refs["Password"])

        try await harness.pageWorld("document.getElementById('password').type = 'text';")
        let read: FieldValue = try await harness.call("valueOf", [password])

        #expect(read.value == "")
        #expect(try await harness.pageString("document.getElementById('password').value") == "")
        #expect(try await harness.pageString("document.getElementById('password').type") == "text")
    }

    /// WebKit's own style for a password field already outranks any author
    /// rule, `!important` included, so a class cannot turn the dots off
    /// here; the inline pin is the guard's own hold on them, restored by the
    /// observer whenever the page edits or drops the field's `style`, and
    /// only on a field a sign-in filled.
    @Test("a class or an inline style that turns the dots off leaves dots, and the guard restores its pin")
    func restyleLeavesDots() async throws {
        let page = """
            <!doctype html><html><head><style>.reveal { -webkit-text-security: none !important; }</style></head><body>
            <form><input id="username" type="email" aria-label="Email">
            <input id="password" type="password" aria-label="Password">
            <input id="control" type="password"></form>
            </body></html>
            """
        let (harness, _, _) = try await Self.signedIn(page)
        let computed = "getComputedStyle(document.getElementById('%@')).getPropertyValue('-webkit-text-security')"
        let inline = "document.getElementById('%@').style.getPropertyValue('-webkit-text-security')"
            + " + '/' + document.getElementById('%@').style.getPropertyPriority('-webkit-text-security')"

        try await harness.pageWorld("document.getElementById('password').classList.add('reveal');")
        let afterClass = try await harness.pageString(String(format: computed, "password"))
        try await harness.pageWorld("""
            for (const id of ["password", "control"]) {
              document.getElementById(id).style.setProperty("-webkit-text-security", "none", "important");
            }
            """)
        let pinAfterStyle = try await harness.pageString(String(format: inline, "password", "password"))
        let controlAfterStyle = try await harness.pageString(String(format: inline, "control", "control"))
        try await harness.pageWorld("document.getElementById('password').removeAttribute('style');")
        let pinAfterRemoval = try await harness.pageString(String(format: inline, "password", "password"))

        #expect(afterClass == "disc")
        #expect(try await harness.pageString(String(format: computed, "password")) == "disc")
        #expect(pinAfterStyle == "disc/important")
        #expect(pinAfterRemoval == "disc/important")
        #expect(controlAfterStyle == "none/important", "a field no sign-in filled is left as the page set it")
    }

    @Test("a form with no method and no handler of its own is not sent, so the address never holds the password")
    func getFormNotSent() async throws {
        let (harness, _, _) = try await Self.signedIn(SignInFixture.plainForm)

        try await harness.pageWorld("""
            window.addEventListener("submit", (event) => { window.prevented = event.defaultPrevented; });
            document.getElementById("form").requestSubmit();
            """)
        try await harness.pageWorld("location.href = 'https://github.com/after';")
        try await Self.waitUntil { harness.refusedNavigations.contains { $0.path == "/after" } }

        #expect(try await harness.pageBool("window.prevented") == true)
        #expect(!harness.refusedNavigations.contains { $0.absoluteString.contains("password=") })
        #expect(harness.webView.url?.absoluteString == SignInFixture.loginPage)
    }

    @Test("a fetch login in a form with no method still gets the password")
    func fetchLoginStillWorks() async throws {
        let (harness, _, _) = try await Self.signedIn(SignInFixture.plainForm)

        try await harness.pageWorld("""
            const form = document.getElementById("form");
            form.addEventListener("submit", (event) => {
              event.preventDefault();
              window.sent = new FormData(form).get("password");
            });
            form.requestSubmit();
            """)

        #expect(try await harness.pageString("window.sent") == SignInFixture.password)
    }

    @Test("a POST form is left to send: the guard is for GET alone")
    func postFormSent() async throws {
        let page = SignInFixture.plainForm.replacingOccurrences(of: #"<form id="form">"#, with: #"<form id="form" method="post">"#)
        let (harness, _, _) = try await Self.signedIn(page)

        try await harness.pageWorld("""
            window.addEventListener("submit", (event) => { window.prevented = event.defaultPrevented; });
            document.getElementById("form").requestSubmit();
            """)
        try await Self.waitUntil { !harness.refusedNavigations.isEmpty }

        #expect(try await harness.pageBool("window.prevented") == false)
        #expect(harness.refusedNavigations.first?.absoluteString == SignInFixture.loginPage)
    }

    @Test("a password field inside a shadow root gets the same guard")
    func shadowRootGuarded() async throws {
        let (harness, refs, _) = try await Self.signedIn(SignInFixture.shadowForm)
        let password = try #require(refs["Password"])
        let field = "document.getElementById('host').shadowRoot.getElementById('password')"

        try await harness.pageWorld("\(field).setAttribute('value', \(field).value);")
        let attribute = try await harness.pageBool("\(field).hasAttribute('value')")
        try await harness.pageWorld("""
            \(field).style.setProperty('-webkit-text-security', 'none', 'important');
            """)
        let dots = try await harness.pageString("getComputedStyle(\(field)).getPropertyValue('-webkit-text-security')")
        try await harness.pageWorld("\(field).type = 'text';")
        let read: FieldValue = try await harness.call("valueOf", [password])

        #expect(attribute == false)
        #expect(dots == "disc")
        #expect(read.value == "")
    }

    // MARK: - The capture guard

    @Test("a page that copies the password into a text field makes a capture answer secret_on_screen")
    func copiedPasswordRefusesCapture() async throws {
        let (harness, _, ledger) = try await Self.signedIn(SignInFixture.plainForm)

        try await harness.pageWorld("""
            const copy = document.createElement("input");
            copy.value = document.getElementById("password").value;
            document.body.append(copy);
            """)

        await #expect(throws: BrowserLoginRefusal.secretOnScreen) {
            try await harness.page.refuseShownSecrets(ledger.fingerprints)
        }
    }

    @Test("a same-length different value passes the capture guard")
    func sameLengthOtherValuePasses() async throws {
        let (harness, _, ledger) = try await Self.signedIn(SignInFixture.plainForm)
        let other = String(repeating: "z", count: SignInFixture.password.utf16.count)

        try await harness.pageWorld("const copy = document.createElement('textarea'); copy.value = '\(other)'; document.body.append(copy);")

        try await harness.page.refuseShownSecrets(ledger.fingerprints)
    }

    @Test("the page script's SHA-256 agrees with CryptoKit on every length and alphabet")
    func scriptDigestAgrees() async throws {
        // Each side of the one-block padding edge (55 and 56 bytes), a full
        // block, more than one, and text whose UTF-8 and UTF-16 lengths differ.
        let samples = [8, 55, 56, 63, 64, 65, 200].map { String(repeating: "a", count: $0) } + ["pässwörd😀1 \"&<>"]
        for sample in samples {
            let harness = BrowserPageHarness()
            try await harness.load("<!doctype html><html><body><textarea id='t'></textarea></body></html>", at: SignInFixture.loginPage)
            let ledger = LoginLedger()
            ledger.add(LoginSecret(sample))
            _ = try await harness.webView.callAsyncJavaScript(
                "document.getElementById('t').value = text;", arguments: ["text": sample], in: nil, contentWorld: .page
            )

            await #expect(throws: BrowserLoginRefusal.secretOnScreen, "\(sample.utf8.count) bytes") {
                try await harness.page.refuseShownSecrets(ledger.fingerprints)
            }
        }
    }

    // MARK: - Mechanics

    /// A page loaded, its login typed in by a sign-in, and the refs and the
    /// ledger it left. `syncValueAttribute` makes the page copy each field's
    /// value into its `value` attribute on every input, as React does.
    static func signedIn(
        _ html: String,
        syncValueAttribute: Bool = false
    ) async throws -> (BrowserPageHarness, [String: Int], LoginLedger) {
        let harness = BrowserPageHarness()
        let store = try await SignInFixture.store()
        let ledger = LoginLedger()
        try await harness.load(html, at: SignInFixture.loginPage)
        if syncValueAttribute {
            try await harness.pageWorld("""
                for (const input of document.querySelectorAll("input")) {
                  input.addEventListener("input", () => input.setAttribute("value", input.value));
                }
                """)
        }
        let refs = try await harness.fieldRefs()
        _ = try await harness.page.loginFor(site: SignInFixture.site, store: store)
        _ = try await harness.page.signIn(
            BrowserSignInTestRequest.both(username: refs["Email"], password: refs["Password"]),
            store: store, ledger: ledger, observing: observation
        )
        return (harness, refs, ledger)
    }

    /// Waits for something the page does on its own, bounded: a navigation
    /// it tried is reported to the delegate a moment after the call that
    /// caused it returned.
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "the page never did what the case waited for")
    }
}

enum BrowserSignInTestRequest {
    static func both(username: Int?, password: Int?) -> BrowserSignInRequest {
        BrowserSignInRequest(site: SignInFixture.site, loginSite: SignInFixture.site, usernameRef: username, passwordRef: password)
    }
}

struct FieldValue: Decodable {
    let value: String
}

struct TextAnswer: Decodable {
    let value: String
}

struct CountAnswer: Decodable {
    let value: Int
}
