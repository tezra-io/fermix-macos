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
        {"title":"Example","url":"https://example.com","elements":2,"crossOriginFrames":0,
         "closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"Example","childIds":[1]},
                  {"id":1,"role":"button","name":"Sign in","ref":7,"childIds":[]}]}
        """

        let snapshot = try BrowserPageSnapshot.decode(Self.json(text), evaluateMilliseconds: 12.5)

        #expect(snapshot.title == "Example")
        #expect(snapshot.url == "https://example.com")
        #expect(snapshot.nodes.count == 2)
        #expect(snapshot.nodes[1].ref == 7)
        #expect(snapshot.evaluateMilliseconds == 12.5)
    }

    @Test("unreadable JSON is a script error")
    func unreadableJSONIsAScriptError() {
        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json("not json"), evaluateMilliseconds: 0)
        }
    }

    @Test("a root that is not RootWebArea has no document root")
    func missingRootIsRejected() {
        let text = """
        {"title":"","url":"","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"button","name":"","childIds":[]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), evaluateMilliseconds: 0)
        }
    }

    @Test("a node whose id is not its own position is rejected")
    func misorderedIdIsRejected() {
        let text = """
        {"title":"","url":"","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[]},
                  {"id":5,"role":"button","name":"","childIds":[]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), evaluateMilliseconds: 0)
        }
    }

    @Test("a child id naming no node in the list is rejected")
    func danglingChildIdIsRejected() {
        let text = """
        {"title":"","url":"","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[3]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), evaluateMilliseconds: 0)
        }
    }

    @Test("a child id at or before its parent's is rejected")
    func backwardChildIdIsRejected() {
        let text = """
        {"title":"","url":"","elements":0,"crossOriginFrames":0,"closedShadowRoots":false,
         "nodes":[{"id":0,"role":"RootWebArea","name":"","childIds":[0]}]}
        """

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserPageSnapshot.decode(Self.json(text), evaluateMilliseconds: 0)
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
        focus: Int = 0,
        ready: String = "complete"
    ) -> BrowserPageFingerprint {
        BrowserPageFingerprint(url: url, title: title, elements: elements, focus: focus, ready: ready)
    }

    @Test("two identical looks are the same page")
    func identicalLooksAreTheSamePage() {
        #expect(Self.fingerprint().isSamePage(as: Self.fingerprint()))
    }

    @Test("a different ready state alone is still the same page")
    func readyStateAloneDoesNotMove() {
        let loading = Self.fingerprint(ready: "loading")
        let complete = Self.fingerprint(ready: "complete")

        #expect(loading.isSamePage(as: complete))
    }

    @Test("a changed url, title, element count or focus is a different page", arguments: [
        Self.fingerprint(url: "https://example.com/other"),
        Self.fingerprint(title: "Other title"),
        Self.fingerprint(elements: 41),
        Self.fingerprint(focus: 7)
    ])
    func aChangedFieldIsADifferentPage(_ changed: BrowserPageFingerprint) {
        #expect(!Self.fingerprint().isSamePage(as: changed))
    }
}
