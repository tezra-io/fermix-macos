import AppKit
import FermixAppCore
import WebKit

/// The engine's act kinds (plan §4.2, §4.8), carried out as input the page
/// receives the way a person's own would: a click or a key press is an
/// `NSEvent` delivered straight to the web view, never through
/// `window.sendEvent`, so the page sees it with `isTrusted` true without the
/// host window ever becoming key. What cannot be expressed as input — reading
/// a select's option, the last leg of a long value, a scroll — is set through
/// the page script instead, which the page sees with `isTrusted` false.
@MainActor
final class WebKitPageActions {
    /// How often a look glances at the page, and a `wait` act checks its
    /// condition.
    private static let pollInterval: Duration = .milliseconds(50)
    /// A value short enough to type as keys; anything longer, or holding a
    /// character the US layout has no key for, goes through the value setter.
    private static let maxTypedCharacters = 40

    private let webView: WKWebView
    private let script: WebKitPageScript
    /// Set immediately before the click that opens a file chooser, so the
    /// page's own `runOpenPanelWith` delegate call knows what to answer.
    private let expectUpload: (String) -> Void
    /// The page's own wait for a navigation in flight, for at most the budget
    /// it is given, answering whether the load finished: a look waits on it
    /// so a click or a submit that starts a load never reads the page mid-load
    /// while the budget lasts.
    private let waitForLoad: @MainActor (Duration) async throws -> Bool
    /// The page's own wait for the navigation its last load started to
    /// commit, for at most the timeout it is given, answering whether it is
    /// over: the look after `tab.open` or `tab.navigate` reads nothing before.
    private let waitForCommit: @MainActor (Duration) async throws -> Bool
    /// How many navigations WebKit has started in the page so far, which
    /// tells a navigation the look is about from a load already in flight.
    private let navigations: @MainActor () -> Int

    init(
        webView: WKWebView,
        script: WebKitPageScript,
        expectUpload: @escaping (String) -> Void,
        waitForLoad: @escaping @MainActor (Duration) async throws -> Bool,
        waitForCommit: @escaping @MainActor (Duration) async throws -> Bool,
        navigations: @escaping @MainActor () -> Int
    ) {
        self.webView = webView
        self.script = script
        self.expectUpload = expectUpload
        self.waitForLoad = waitForLoad
        self.waitForCommit = waitForCommit
        self.navigations = navigations
    }

    /// One act, carried out, then looked at as the engine asked: with no
    /// `look`, it answers as soon as its input is delivered.
    func perform(_ action: BrowserPageAction, observing look: BrowserSnapshotRequest?) async throws -> BrowserActOutcome {
        let (receipt, effect) = try await deliver(observing: look) { try await self.carryOut(action) }

        return BrowserActOutcome(
            effect: effect,
            input: receipt.input,
            url: address(),
            value: receipt.value,
            filled: receipt.filled,
            submitted: receipt.submitted,
            uploaded: receipt.uploaded,
            read: receipt.getValue
        )
    }

    // MARK: - Dispatch

    private struct ActReceipt {
        var input: BrowserInputPath
        var value: String?
        var filled: [BrowserFieldReceipt]?
        var submitted: String?
        var uploaded: String?
        var getValue: BrowserGetValue?

        init(
            input: BrowserInputPath,
            value: String? = nil,
            filled: [BrowserFieldReceipt]? = nil,
            submitted: String? = nil,
            uploaded: String? = nil,
            getValue: BrowserGetValue? = nil
        ) {
            self.input = input
            self.value = value
            self.filled = filled
            self.submitted = submitted
            self.uploaded = uploaded
            self.getValue = getValue
        }
    }

    private func carryOut(_ action: BrowserPageAction) async throws -> ActReceipt {
        switch action {
        case .click(let ref):
            try await trustedClick(ref: ref)
            return ActReceipt(input: .trusted)

        case .clickCoordinates(let x, let y):
            try await trustedClick(pageX: x, pageY: y)
            return ActReceipt(input: .trusted)

        case .fill(let ref, let text):
            let filled = try await fillField(ref: ref, text: text, append: false)
            return ActReceipt(input: filled.input, value: filled.value)

        case .fillForm(let fields):
            return try await fillForm(fields)

        case .type(let ref, let text):
            let filled = try await fillField(ref: ref, text: text, append: true)
            return ActReceipt(input: filled.input, value: filled.value)

        case .press(let key):
            try await pressKey(key)
            return ActReceipt(input: .trusted)

        case .hover(let ref):
            try await hover(ref: ref)
            return ActReceipt(input: .trusted)

        case .select(let ref, let value):
            let answer: SelectAnswer = try await script
                .call("selectOption", [ref, value], as: BrowserScriptAnswer<SelectAnswer>.self)
                .value(for: ref)
            return ActReceipt(input: .scripted, value: answer.value)

        case .submit(let ref):
            return try await submit(ref: ref)

        case .scroll(let ref, let x, let y):
            let refArgument: Any = ref.map { $0 as Any } ?? NSNull()
            _ = try await script
                .call("scrollBy", [refArgument, x, y], as: BrowserScriptAnswer<ScrollAnswer>.self)
                .value(for: ref ?? 0)
            return ActReceipt(input: .scripted)

        case .upload(let ref, let path):
            return try await upload(ref: ref, path: path)

        case .get(let field, let selector):
            let value = try await get(field: field, selector: selector)
            return ActReceipt(input: .scripted, getValue: value)

        case .wait(let until, let text, let selector, let ref, let timeoutMs):
            try await wait(until: until, text: text, selector: selector, ref: ref, timeoutMs: timeoutMs)
            return ActReceipt(input: .scripted)
        }
    }

    // MARK: - Click and hover

    private func trustedClick(ref: Int) async throws {
        let box: BrowserElementBox = try await script
            .call("locate", [ref], as: BrowserScriptAnswer<BrowserElementBox>.self)
            .value(for: ref)
        guard let point = geometry().center(of: box) else { throw BrowserPageDriveError.noRenderedBox(ref) }

        try deliverClick(at: point)
    }

    private func trustedClick(pageX: Double, pageY: Double) async throws {
        let viewport: BrowserVisualViewport = try await script.call("viewport", [])
        guard let point = geometry().viewPoint(x: pageX, y: pageY, viewport: viewport) else {
            throw BrowserPageDriveError.outsideView
        }

        try deliverClick(at: point)
    }

    private func hover(ref: Int) async throws {
        let box: BrowserElementBox = try await script
            .call("locate", [ref], as: BrowserScriptAnswer<BrowserElementBox>.self)
            .value(for: ref)
        guard let point = geometry().center(of: box) else { throw BrowserPageDriveError.noRenderedBox(ref) }
        let window = try window()
        let moved = try mouseEvent(.mouseMoved, at: point, clickCount: 0, in: window)

        webView.mouseMoved(with: moved)
    }

    private func deliverClick(at point: CGPoint) throws {
        let window = try window()
        let down = try mouseEvent(.leftMouseDown, at: point, clickCount: 1, in: window)
        let up = try mouseEvent(.leftMouseUp, at: point, clickCount: 1, in: window)

        webView.mouseDown(with: down)
        webView.mouseUp(with: up)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: webView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: clickCount > 0 ? 1 : 0
        ) else {
            throw BrowserPageDriveError.script("could not build a mouse event")
        }

        return event
    }

    private func geometry() -> BrowserViewGeometry {
        BrowserViewGeometry(size: webView.bounds.size, isFlipped: webView.isFlipped, pageZoom: webView.pageZoom)
    }

    // MARK: - Keys and typing

    private func pressKey(_ name: String) async throws {
        guard let key = BrowserKey.named(name) else { throw BrowserPageDriveError.unknownKey(name) }

        try deliverKey(key)
    }

    private func deliverKey(_ key: BrowserKey) throws {
        let window = try window()
        let flags: NSEvent.ModifierFlags = key.shift ? [.shift] : []
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
            )
        else {
            throw BrowserPageDriveError.script("could not build a key event")
        }

        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }

    /// A field filled by a trusted click and keys for a short, typeable value,
    /// or the native setter for everything else.
    private func fillField(ref: Int, text: String, append: Bool) async throws -> (value: String, input: BrowserInputPath) {
        try await trustedClick(ref: ref)
        _ = try await script
            .call("prepareTyping", [ref, append], as: BrowserScriptAnswer<PreparedField>.self)
            .value(for: ref)

        if text.count <= Self.maxTypedCharacters, let keys = BrowserKey.typing(text) {
            for key in keys { try deliverKey(key) }
            let value: FieldValue = try await script
                .call("valueOf", [ref], as: BrowserScriptAnswer<FieldValue>.self)
                .value(for: ref)
            return (value.value, .trusted)
        }

        let set: FieldValue = try await script
            .call("setValue", [ref, text, append], as: BrowserScriptAnswer<FieldValue>.self)
            .value(for: ref)
        return (set.value, .scripted)
    }

    /// One form's fields, from one snapshot, filled in order; the whole call
    /// stops at the first field that refuses, with what came before it kept.
    private func fillForm(_ fields: [BrowserFormField]) async throws -> ActReceipt {
        var filled: [BrowserFieldReceipt] = []
        var allTrusted = true
        for field in fields {
            do {
                let result = try await fillField(ref: field.ref, text: field.text, append: false)
                allTrusted = allTrusted && result.input == .trusted
                filled.append(BrowserFieldReceipt(ref: field.ref, value: result.value))
            } catch let cause as BrowserPageDriveError {
                throw BrowserPageDriveError.formStopped(at: field.ref, filled: filled, cause: cause)
            }
        }

        return ActReceipt(input: allTrusted ? .trusted : .scripted, filled: filled)
    }

    // MARK: - Submit and upload

    private func submit(ref: Int) async throws -> ActReceipt {
        let answer: SubmitControl = try await script
            .call("submitControl", [ref], as: BrowserScriptAnswer<SubmitControl>.self)
            .value(for: ref)
        guard let controlRef = answer.ref else { return ActReceipt(input: .scripted, submitted: answer.label) }

        try await trustedClick(ref: controlRef)
        return ActReceipt(input: .trusted, submitted: answer.label)
    }

    /// The page's own file input, opened by a scripted click: the input is
    /// commonly hidden behind a styled label with no box a person could click,
    /// and a scripted `click()` opens its chooser regardless (plan §4.8, check
    /// 4). `expectUpload` primes the delegate before the click can raise it.
    private func upload(ref: Int, path: String) async throws -> ActReceipt {
        expectUpload(path)
        _ = try await script
            .call("openChooser", [ref], as: BrowserScriptAnswer<OpenedChooser>.self)
            .value(for: ref)
        let held: HeldFiles = try await script
            .call("files", [ref], as: BrowserScriptAnswer<HeldFiles>.self)
            .value(for: ref)
        guard let name = held.names.first else { throw BrowserPageDriveError.uploadNotAccepted(ref) }

        return ActReceipt(input: .scripted, uploaded: name)
    }

    // MARK: - Get and wait

    /// `act` `kind=get`: a read of the page, decoded in the shape the field
    /// answers. `rect` needs a selector to measure; the page script's own
    /// `invalid_request` refusal is the fallback if one ever slips through.
    private func get(field: BrowserGetField, selector: String?) async throws -> BrowserGetValue {
        if field == .rect, selector == nil {
            throw BrowserPageDriveError.invalidRequest("get field=rect needs a selector")
        }

        let selectorArgument: Any = selector.map { $0 as Any } ?? NSNull()
        switch field {
        case .text, .title, .html, .readyState:
            return .text(try await readGetAnswer(field: field, selector: selectorArgument, as: TextGetAnswer.self).value)
        case .count:
            return .count(try await readGetAnswer(field: field, selector: selectorArgument, as: CountGetAnswer.self).value)
        case .rect:
            let rect = try await readGetAnswer(field: field, selector: selectorArgument, as: RectGetAnswer.self).value
            return .rect(BrowserRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        }
    }

    private func readGetAnswer<Answer: Decodable>(
        field: BrowserGetField, selector: Any, as: Answer.Type
    ) async throws -> Answer {
        let answer = try await script.call("get", [field.rawValue, selector], as: BrowserScriptAnswer<Answer>.self)
        switch answer {
        case .value(let value): return value
        case .refused(let word): throw BrowserPageDriveError.script(word)
        }
    }

    /// `act` `kind=wait`: polls the page script's own one-shot check on a
    /// fixed interval until it answers `done` or `timeoutMs` runs out, so the
    /// wait is bounded by the request's own timeout and never spins.
    private func wait(until: BrowserWaitUntil, text: String?, selector: String?, ref: Int?, timeoutMs: Int) async throws {
        if until == .element, selector == nil, ref == nil {
            throw BrowserPageDriveError.invalidRequest("wait until=element needs a ref or a selector")
        }

        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            let answer: WaitAnswer = try await script.call(
                "waitCondition",
                [
                    until.rawValue,
                    text.map { $0 as Any } ?? NSNull(),
                    selector.map { $0 as Any } ?? NSNull(),
                    ref.map { $0 as Any } ?? NSNull()
                ],
                as: WaitAnswer.self
            )
            if answer.done { return }
            guard ContinuousClock.now < deadline else { throw BrowserPageDriveError.waitTimedOut }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    // MARK: - Sign-in (M84 §8)

    /// The tab's top page as a sign-in checks it: `https`, on `site` by key,
    /// and the origin the checks were made on.
    private struct SecureTop {
        let url: URL
        let host: String
        let key: String
        let origin: String
    }

    /// `page.login_for`: the tab's top page is `https` and its host is
    /// `site`'s by key, and the saved login that host uses (its own site's,
    /// else the closest parent domain's), attributes only.
    /// Answers the top origin too, which the page holds for the
    /// `page.sign_in` that follows.
    func loginFor(site: String, store: any LoginStore) async throws -> (login: SavedLogin, origin: String) {
        try await waitUntilLoaded()
        let top = try secureTop(site: site)
        let found = try await Self.storeRead(missing: .noLogin(host: top.key)) { try await store.login(forHost: top.host) }
        guard let login = found else { throw BrowserLoginRefusal.noLogin(host: top.key) }

        return (login, top.origin)
    }

    /// `page.sign_in`: the `page.login_for` checks again, the same origin and
    /// the same login as then, the password read only for a `passwordRef` and
    /// handed to the ledger before the page has it, then one `fillLogin`,
    /// looked at after as an act is.
    func signIn(
        _ request: BrowserSignInRequest,
        expectedOrigin: String?,
        store: any LoginStore,
        ledger: LoginLedger,
        observing look: BrowserSnapshotRequest?
    ) async throws -> BrowserSignInOutcome {
        try await waitUntilLoaded()
        let top = try secureTop(site: request.site)
        guard top.origin == expectedOrigin else { throw BrowserLoginRefusal.pageMoved(.origin) }
        let found = try await Self.storeRead(missing: .pageMoved(.login)) { try await store.login(forHost: top.host) }
        guard let login = found, login.site == request.loginSite else { throw BrowserLoginRefusal.pageMoved(.login) }

        let fill = try await loginFill(request, login: login, topURL: top.url, store: store, ledger: ledger)
        let (_, effect) = try await deliver(observing: look) { try await self.fillLogin(fill) }

        return BrowserSignInOutcome(filled: fill.fields, effect: effect, url: address())
    }

    /// A sign-in checks the page's address, so it waits for a load in flight
    /// to finish first, within the script's own bound, and refuses a page
    /// still loading after it (`wait_timeout`) rather than check one whose
    /// navigation may not have committed.
    private func waitUntilLoaded() async throws {
        guard try await waitForLoad(WebKitPageScript.timeout) else { throw BrowserPageDriveError.waitTimedOut }
    }

    private func secureTop(site: String) throws -> SecureTop {
        guard
            let url = webView.url, url.scheme?.lowercased() == "https",
            let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else {
            throw BrowserLoginRefusal.insecurePage
        }
        guard
            case .success(let siteKey) = LoginSite.key(site),
            case .success(let hostKey) = LoginSite.key(host),
            siteKey == hostKey
        else {
            throw BrowserLoginRefusal.wrongSite(site: site)
        }

        let port = url.port.flatMap { $0 == 443 ? nil : $0 }
        return SecureTop(url: url, host: host, key: hostKey, origin: "https://\(host)" + (port.map { ":\($0)" } ?? ""))
    }

    /// The values the fill types. The keychain's secret is read only when a
    /// password field is named, and the ledger holds it from that moment.
    private func loginFill(
        _ request: BrowserSignInRequest,
        login: SavedLogin,
        topURL: URL,
        store: any LoginStore,
        ledger: LoginLedger
    ) async throws -> BrowserLoginFill {
        var password: LoginSecret?
        if request.passwordRef != nil {
            let secret = try await Self.storeRead(missing: .pageMoved(.login)) { try await store.password(for: login.id) }
            ledger.add(secret)
            password = secret
        }

        return BrowserLoginFill(
            topURL: topURL,
            usernameRef: request.usernameRef,
            username: request.usernameRef == nil ? nil : login.username,
            passwordRef: request.passwordRef,
            password: password
        )
    }

    private func fillLogin(_ fill: BrowserLoginFill) async throws {
        let answer: FillAnswer = try await script.call("fillLogin", [fill.scriptArgument()])
        try answer.check()
    }

    /// A store read in the host's vocabulary: a login that is not there is
    /// `missing`, and the keychain's own refusals are `store_unavailable`.
    private static func storeRead<Value>(
        missing: BrowserLoginRefusal,
        _ read: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await read()
        } catch let error as LoginStoreError {
            switch error {
            case .notFound, .site: throw missing
            default: throw BrowserLoginRefusal.storeUnavailable(error)
            }
        }
    }

    // MARK: - Looking

    /// The look after `tab.open` or `tab.navigate`: its own navigation's
    /// commit, within `timeout`, then its load and the page holding still,
    /// within the navigation budget from the commit, and the page as it
    /// stands once that is spent. It has moved by definition, so it always
    /// reads. Only its own navigation failing or never committing fails it; a
    /// navigation the page starts after that load and that fails leaves the
    /// document shown, which it reads. `timeout` is the engine's but in a
    /// test.
    func lookAfterNavigation(
        _ request: BrowserSnapshotRequest,
        within timeout: Duration = BrowserPageSettle.navigationTimeout
    ) async throws -> BrowserPageSnapshot {
        _ = try await settle(.afterNavigation(from: navigations(), timeout: timeout))
        return try await WebKitPageSnapshot(script: script, webView: webView).take(request)
    }

    /// Delivers an input, then takes the look the engine asked for. With no
    /// look the input answers as soon as it is delivered: no glance, no
    /// settle and no snapshot.
    private func deliver<Receipt>(
        observing look: BrowserSnapshotRequest?,
        _ input: @MainActor () async throws -> Receipt
    ) async throws -> (Receipt, BrowserPageEffect) {
        guard let look else { return (try await input(), .unobserved) }

        let before = try await glance(within: WebKitPageScript.timeout)
        let receipt = try await input()
        return (receipt, await lookAfterAct(from: before, observing: look))
    }

    /// The look after an act or a sign-in's fill. A page that stops answering,
    /// a dialog holding it say, or a load that fails ends it `unobserved`: the
    /// action itself stands.
    private func lookAfterAct(
        from before: BrowserPageSettle.Glance,
        observing look: BrowserSnapshotRequest
    ) async -> BrowserPageEffect {
        do {
            guard try await settle(.afterAct(from: before)) else { return .unchanged }
            return .changed(try await WebKitPageSnapshot(script: script, webView: webView).take(look))
        } catch {
            return .unobserved
        }
    }

    /// Does what `settling` decides until the look is over: true to read the
    /// page, false when it never moved. `settling` bounds every wait and
    /// glance by what is left of the look's budget, and past it answers only
    /// `read` or `unchanged`, so the loop ends. A page that does not answer a
    /// glance in time, a dialog holding it say, throws, and so does a
    /// navigation that never commits, as one that ended without a page.
    private func settle(_ settling: BrowserPageSettle) async throws -> Bool {
        var settling = settling
        let started = ContinuousClock.now
        var step = settling.opening
        while true {
            switch step {
            case .read:
                return true
            case .unchanged:
                return false
            case .glance(let bound):
                let seen = try await glance(within: bound)
                step = settling.next(seen, at: started.duration(to: .now))
            case .poll(let left):
                try await Task.sleep(for: min(Self.pollInterval, left))
                step = settling.afterWait(at: started.duration(to: .now))
            case .awaitLoad(let left):
                step = try await awaitLoad(within: left, settling, from: started)
            case .awaitCommit(let timeout):
                let committed = try await waitForCommit(timeout)
                step = settling.afterCommit(committed, at: started.duration(to: .now))
            case .neverCommitted(let timeout):
                throw BrowserPageDriveError.notStarted(webView.url?.absoluteString ?? "about:blank", within: timeout)
            }
        }
    }

    /// Waits for the navigation in flight, for at most `left`, and answers
    /// the step after it. A load still in flight at the end is read as it
    /// stands. A load that fails ends the look where `settling` says it does
    /// (`afterFailedLoad`), and otherwise fails it.
    private func awaitLoad(
        within left: Duration,
        _ settling: BrowserPageSettle,
        from started: ContinuousClock.Instant
    ) async throws -> BrowserPageSettle.Step {
        do {
            _ = try await waitForLoad(left)
        } catch let failure as BrowserPageDriveError {
            guard case .navigationFailed = failure, let step = settling.afterFailedLoad() else { throw failure }
            return step
        }

        return settling.afterWait(at: started.duration(to: .now))
    }

    /// The page's fingerprint, whether WebKit has a navigation in flight,
    /// which the fingerprint cannot see until the new document commits, and
    /// how many navigations it has started.
    private func glance(within bound: Duration) async throws -> BrowserPageSettle.Glance {
        let fingerprint: BrowserPageFingerprint = try await script.call("fingerprint", [], within: bound)
        return BrowserPageSettle.Glance(fingerprint: fingerprint, loading: webView.isLoading, navigations: navigations())
    }

    /// The address of the document the page shows, as WebKit reports it
    /// rather than the page, so an answer never waits on a script call, even
    /// on a page a dialog holds. It is the current history entry, which a new
    /// load replaces only once it commits: `webView.url` already names a load
    /// still in flight. With no entry yet, `webView.url` names the page, and a
    /// web view that has loaded nothing shows the empty document.
    private func address() -> String {
        (webView.backForwardList.currentItem?.url ?? webView.url)?.absoluteString ?? "about:blank"
    }

    private func window() throws -> NSWindow {
        guard let window = webView.window else { throw BrowserPageDriveError.detached }

        return window
    }
}

// MARK: - Page-script answers

private struct PreparedField: Decodable {
    let value: String
}

private struct FieldValue: Decodable {
    let value: String
}

private struct SelectAnswer: Decodable {
    let value: String
    let label: String
}

private struct SubmitControl: Decodable {
    let ref: Int?
    let label: String
}

private struct ScrollAnswer: Decodable {
    let x: Double
    let y: Double
}

private struct OpenedChooser: Decodable {}

private struct HeldFiles: Decodable {
    let names: [String]
}

private struct TextGetAnswer: Decodable {
    let value: String
}

private struct CountGetAnswer: Decodable {
    let value: Int
}

private struct RectGetAnswer: Decodable {
    struct Rect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let value: Rect
}

private struct WaitAnswer: Decodable {
    let done: Bool
}

/// `fillLogin`'s answer: `{ok: true}`, or the one word it refused with, the
/// ref it was about and what was wrong.
private struct FillAnswer: Decodable {
    let ok: Bool?
    let error: String?
    let ref: Int?
    let detail: String?

    func check() throws {
        switch error {
        case nil where ok == true:
            return
        case "stale":
            guard let ref else { break }
            throw BrowserPageDriveError.staleRef(ref)
        case "field":
            guard let problem = Self.problems[detail ?? ""] else { break }
            throw BrowserLoginRefusal.field(ref: ref, problem)
        case "moved":
            throw BrowserLoginRefusal.pageMoved(.documentOrigin)
        default:
            break
        }
        throw BrowserPageDriveError.script("fillLogin answered \(error ?? "no word")")
    }

    private static let problems: [String: BrowserLoginFieldProblem] = [
        "username": .notUsername,
        "password": .notPassword,
        "documents": .twoDocuments,
        "focus": .focus
    ]
}
