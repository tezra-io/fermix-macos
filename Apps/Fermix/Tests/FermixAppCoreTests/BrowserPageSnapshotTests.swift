import Foundation
import Testing

@testable import FermixAppCore

/// Normalising the page script's answer into the engine's node shape, and
/// what an action is judged changed or unchanged by.
@Suite("Browser page snapshot")
struct BrowserPageSnapshotTests {
    static func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("a well-formed answer decodes with the evaluate time attached")
    func decodesAWellFormedAnswer() throws {
        let text = """
        {"title":"Example","url":"https://example.com","readyState":"interactive","elements":2,"crossOriginFrames":0,
         "closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"Example","childIds":[1]},
                  {"id":1,"role":"button","name":"Sign in","ref":7,"childIds":[]}]}
        """

        let snapshot = try BrowserPageSnapshot.decode(Self.json(text), tabLoading: true, evaluateMilliseconds: 12.5)

        #expect(snapshot.title == "Example")
        #expect(snapshot.url == "https://example.com")
        #expect(snapshot.readyState == .interactive)
        #expect(snapshot.tabLoading, "whether the tab was loading as the answer came")
        #expect(snapshot.nodes.count == 2)
        #expect(snapshot.nodes[1].ref == 7)
        #expect(snapshot.evaluateMilliseconds == 12.5)
    }

    @Test("an answer with no ready state is a script error")
    func missingReadyStateIsAScriptError() {
        let text = """
        {"title":"","url":"","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), tabLoading: false, evaluateMilliseconds: 0)
        }
    }

    @Test("a page read with no load in flight in its tab reports its document's own ready state")
    func settledTabReportsTheDocumentsState() {
        for state in [BrowserReadyState.loading, .interactive, .complete] {
            var snapshot = BrowserPageSnapshot.empty
            snapshot.readyState = state
            snapshot.tabLoading = false

            #expect(snapshot.reportedReadyState == state)
        }
    }

    @Test("a page read while its tab was loading reports a page not yet loaded as it was, and a complete document as loading")
    func loadingTabReportsThePageStillLoading() {
        var snapshot = BrowserPageSnapshot.empty
        snapshot.tabLoading = true
        snapshot.readyState = .loading
        #expect(snapshot.reportedReadyState == .loading)

        snapshot.readyState = .interactive
        #expect(snapshot.reportedReadyState == .interactive)

        snapshot.readyState = .complete
        #expect(snapshot.reportedReadyState == .loading, "the document a navigation in flight has not replaced yet")
    }

    @Test("unreadable JSON is a script error")
    func unreadableJSONIsAScriptError() {
        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json("not json"), tabLoading: false, evaluateMilliseconds: 0)
        }
    }

    @Test("a root that is not RootWebArea has no document root")
    func missingRootIsRejected() {
        let text = """
        {"title":"","url":"","readyState":"complete","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"button","name":"","childIds":[]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), tabLoading: false, evaluateMilliseconds: 0)
        }
    }

    @Test("a node whose id is not its own position is rejected")
    func misorderedIdIsRejected() {
        let text = """
        {"title":"","url":"","readyState":"complete","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[]},
                  {"id":5,"role":"button","name":"","childIds":[]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), tabLoading: false, evaluateMilliseconds: 0)
        }
    }

    @Test("a child id naming no node in the list is rejected")
    func danglingChildIdIsRejected() {
        let text = """
        {"title":"","url":"","readyState":"complete","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[3]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), tabLoading: false, evaluateMilliseconds: 0)
        }
    }

    @Test("a child id at or before its parent's is rejected")
    func backwardChildIdIsRejected() {
        let text = """
        {"title":"","url":"","readyState":"complete","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[0]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), tabLoading: false, evaluateMilliseconds: 0)
        }
    }
}

/// What an action's before-and-after fingerprints are judged the same page by.
@Suite("Browser page fingerprint")
struct BrowserPageFingerprintTests {
    static func fingerprint(
        url: String = "https://example.com",
        title: String = "Example",
        elements: Int = 40,
        text: Int = 1_200,
        focus: Int = 0,
        ready: String = "complete"
    ) -> BrowserPageFingerprint {
        BrowserPageFingerprint(url: url, title: title, elements: elements, text: text, focus: focus, ready: ready)
    }

    @Test("the page script's answer decodes with the body's text length")
    func decodesTheTextLength() throws {
        let json = #"{"url":"https://example.com","title":"Example","elements":40,"text":1200,"focus":0,"ready":"complete"}"#

        let decoded = try JSONDecoder().decode(BrowserPageFingerprint.self, from: Data(json.utf8))

        #expect(decoded == Self.fingerprint())
    }

    @Test("two identical looks are the same page")
    func identicalLooksAreTheSamePage() {
        #expect(Self.fingerprint().isSamePage(as: Self.fingerprint()))
    }

    @Test("a change of the body's text alone, with every element the same, is a different page")
    func aTextOnlyChangeIsSeen() {
        let before = Self.fingerprint(text: 1_200)
        let after = Self.fingerprint(text: 1_214)

        #expect(after.elements == before.elements)
        #expect(!after.isSamePage(as: before))
    }

    @Test("a different ready state alone is still the same page")
    func readyStateAloneDoesNotMove() {
        let loading = Self.fingerprint(ready: "loading")
        let complete = Self.fingerprint(ready: "complete")

        #expect(loading.isSamePage(as: complete))
    }

    @Test("a changed url, title, element count, text length or focus is a different page", arguments: [
        Self.fingerprint(url: "https://example.com/other"),
        Self.fingerprint(title: "Other title"),
        Self.fingerprint(elements: 41),
        Self.fingerprint(text: 1_201),
        Self.fingerprint(focus: 7)
    ])
    func aChangedFieldIsADifferentPage(_ changed: BrowserPageFingerprint) {
        #expect(!Self.fingerprint().isSamePage(as: changed))
    }
}
