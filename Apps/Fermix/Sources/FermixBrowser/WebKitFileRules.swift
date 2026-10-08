import Foundation
import WebKit

/// The content rule list every file page carries (plan §8.2): every load over
/// the network refused, whatever it is for, so a file the agent wrote cannot
/// reach anywhere through an image, a stylesheet, a frame or a redirect.
///
/// Compiling a list is asynchronous, so the engine compiles this one once, on
/// its first file tab, and a file page waits on it before it loads anything:
/// a file never loads without it in place. A list that failed to compile
/// leaves every file page empty, with the system's sentence for why.
@MainActor
final class WebKitFileRules {
    /// One rule per scheme, because a rule's filter cannot say "or". With no
    /// resource type named, each rule covers every kind of load.
    static let source = """
    [
      {"trigger": {"url-filter": "^https?:"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?:"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp:"}, "action": {"type": "block"}}
    ]
    """
    static let identifier = "file-page-network"

    private var compiled: Result<WKContentRuleList, any Error>?
    private var waiting: [@MainActor (Result<WKContentRuleList, any Error>) -> Void] = []

    init() {
        Task { await compile() }
    }

    /// The compiled list, or why there is none: once it is ready, or at once
    /// where it already is.
    func whenCompiled(_ answer: @escaping @MainActor (Result<WKContentRuleList, any Error>) -> Void) {
        guard let compiled else {
            waiting.append(answer)
            return
        }

        answer(compiled)
    }

    private func compile() async {
        let result: Result<WKContentRuleList, any Error>
        do {
            result = .success(try await Self.compiledList())
        } catch {
            result = .failure(error)
        }

        compiled = result
        let answers = waiting
        waiting = []
        for answer in answers { answer(result) }
    }

    /// The store answers with a list or an error; an answer with neither is a
    /// failed compile, said in WebKit's own words.
    private static func compiledList() async throws -> WKContentRuleList {
        let compiled = try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source)
        guard let compiled else { throw WKError(.contentRuleListStoreCompileFailed) }

        return compiled
    }
}
