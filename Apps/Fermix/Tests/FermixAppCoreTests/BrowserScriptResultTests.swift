import Foundation
import Testing

@testable import FermixAppCore

/// `BrowserScriptResult.decode`: the one place a page script's JSON-text
/// answer becomes a value. `WebKitPageScript.call` in `FermixBrowser` is
/// untestable directly (it needs a real `WKWebView`), so this is the proof
/// that the decode step itself is right, and the regression test for the
/// bug it replaced: a page script function that stringified its own answer,
/// stringified again by the one wrapper every call already goes through,
/// which handed this a JSON string where it expected an object.
@Suite("Browser script result")
struct BrowserScriptResultTests {
    private struct Answer: Decodable, Equatable {
        let value: String
    }

    @Test("a well-formed stringified object decodes")
    func decodesAStringifiedObject() throws {
        let decoded = try BrowserScriptResult.decode(#"{"value":"hello"}"#, as: Answer.self)

        #expect(decoded == Answer(value: "hello"))
    }

    @Test("malformed text is a script error, not a crash")
    func malformedTextIsAScriptError() {
        #expect(throws: BrowserPageDriveError.self) {
            try BrowserScriptResult.decode("not json", as: Answer.self)
        }
    }

    /// The exact shape of the bug this replaced: a function that already
    /// called `JSON.stringify` on its own answer, stringified a second time
    /// by the call wrapper, hands the decoder a JSON string instead of the
    /// object it names.
    @Test("a double-encoded string is a script error, not a silent wrong read")
    func doubleEncodedStringIsAScriptError() {
        let doubleEncoded = #""{\"value\":\"hello\"}""#

        #expect(throws: BrowserPageDriveError.self) {
            try BrowserScriptResult.decode(doubleEncoded, as: Answer.self)
        }
    }
}
