import FermixAppCore
import Foundation
import WebKit

/// The page script (`BrowserPageScript`), evaluated in the app's own content
/// world, which the page can neither see nor change.
///
/// Every call carries the whole script ahead of it and the script installs
/// itself once per document, so a page the tab navigated to is served without
/// an install step or a user script in the tab's configuration.
@MainActor
final class WebKitPageScript {
    /// The one world every tab's script runs in. On macOS 27 it is configured
    /// to treat closed shadow roots as open, which is the only public way to
    /// reach them; built on an older SDK, or run on an older macOS, it is a
    /// plain named world and closed roots are skipped.
    static let world: WKContentWorld = makeWorld()
    static private(set) var readsClosedShadowRoots = false

    /// A call's bound: a page holding a dialog runs no script until the dialog
    /// is answered, and the engine's own action timeout is eight seconds.
    static let timeout: Duration = .seconds(8)

    private let webView: WKWebView
    private let source: String

    init(webView: WKWebView, source: String) {
        self.webView = webView
        self.source = source
    }

    /// One of the script's functions, answered as its JSON text.
    func text(_ function: String, _ arguments: [Any], within timeout: Duration? = nil) async throws -> String {
        let timeout = timeout ?? Self.timeout
        let body = source + "\nreturn JSON.stringify(globalThis.\(BrowserPageScript.global)[name](...args));"
        let call = PendingCall()

        return try await withCheckedThrowingContinuation { continuation in
            call.continuation = continuation
            webView.callAsyncJavaScript(body, arguments: ["name": function, "args": arguments], in: nil, in: Self.world) {
                call.finish(Self.answer($0))
            }
            call.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                call.finish(.failure(BrowserPageDriveError.unresponsive))
            }
        }
    }

    /// One of the script's functions, decoded. `BrowserScriptResult.decode` is
    /// the one place that turns the JSON text `text(_:_:)` answers into a
    /// value: nothing here interprets it a second way.
    func call<Answer: Decodable>(
        _ function: String,
        _ arguments: [Any],
        as: Answer.Type = Answer.self,
        within timeout: Duration? = nil
    ) async throws -> Answer {
        let json = try await text(function, arguments, within: timeout)
        return try BrowserScriptResult.decode(json, as: Answer.self)
    }

    private static func answer(_ result: Result<Any, any Error>) -> Result<String, any Error> {
        switch result {
        case .success(let value as String): return .success(value)
        case .success(let value): return .failure(BrowserPageDriveError.script("\(type(of: value)) is not an answer"))
        case .failure(let error): return .failure(BrowserPageDriveError.script("\(error)"))
        }
    }

    private static func makeWorld() -> WKContentWorld {
        #if canImport(WebKit, _underlyingVersion: 625)
        if #available(macOS 27, *) {
            let configuration = WKContentWorld.Configuration()
            configuration.allowAccessingClosedShadowRoots = true
            readsClosedShadowRoots = true
            return WKContentWorld(configuration: configuration)
        }
        #endif
        return .world(name: "fermix-page")
    }
}

/// A script call that finishes once: with the page's answer, or with the
/// timeout, whichever comes first.
@MainActor
private final class PendingCall {
    var continuation: CheckedContinuation<String, any Error>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }

        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }
}
