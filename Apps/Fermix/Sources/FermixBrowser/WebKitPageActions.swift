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
    /// The engine's own settle budget: how long an action waits for the page
    /// to change before it is reported `unchanged`.
    static let settleBudget: Duration = .milliseconds(1500)
    private static let pollInterval: Duration = .milliseconds(50)
    /// A value short enough to type as keys; anything longer, or holding a
    /// character the US layout has no key for, goes through the value setter.
    private static let maxTypedCharacters = 40

    private let webView: WKWebView
    private let script: WebKitPageScript
    /// Set immediately before the click that opens a file chooser, so the
    /// page's own `runOpenPanelWith` delegate call knows what to answer.
    private let expectUpload: (String) -> Void

    init(webView: WKWebView, script: WebKitPageScript, expectUpload: @escaping (String) -> Void) {
        self.webView = webView
        self.script = script
        self.expectUpload = expectUpload
    }

    func perform(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome {
        let before = try await fingerprint()
        let receipt = try await carryOut(action)
        let (effect, url) = await settle(from: before, observing: request)

        return BrowserActOutcome(
            effect: effect,
            input: receipt.input,
            url: url,
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

    // MARK: - Settling

    private func fingerprint() async throws -> BrowserPageFingerprint {
        try await script.call("fingerprint", [])
    }

    /// Polls the fingerprint until it moves off `before` or the settle budget
    /// runs out. A page that stops answering once the action landed — one
    /// holding a dialog, say — is `unobserved`: the action itself stands.
    private func settle(
        from before: BrowserPageFingerprint,
        observing request: BrowserSnapshotRequest
    ) async -> (BrowserPageEffect, url: String) {
        let deadline = ContinuousClock.now + Self.settleBudget
        var last = before

        while ContinuousClock.now < deadline {
            guard let fingerprint = try? await fingerprint() else { return (.unobserved, before.url) }
            last = fingerprint
            if !last.isSamePage(as: before) {
                guard let snapshot = try? await WebKitPageSnapshot(script: script).take(request) else {
                    return (.unobserved, last.url)
                }
                return (.changed(snapshot), last.url)
            }
            try? await Task.sleep(for: Self.pollInterval)
        }

        return (.unchanged, last.url)
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
