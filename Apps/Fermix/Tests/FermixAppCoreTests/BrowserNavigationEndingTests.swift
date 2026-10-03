import Foundation
import Testing

@testable import FermixAppCore

/// Which endings of a navigation the person is told of: the errors WebKit
/// was measured giving, by domain and code, never by their text.
@Suite("Browser navigation ending")
struct BrowserNavigationEndingTests {
    /// What WebKit gives a navigation it handed to a download, whether the
    /// download was given a place or refused one, measured against WebKit on
    /// this Mac: its older domain, code 102, "Frame load interrupted".
    @Test("a navigation that became a download is not a failure")
    func downloadIsNotAFailure() {
        let handedToADownload = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSLocalizedDescriptionKey: "Frame load interrupted"]
        )

        #expect(BrowserNavigationEnding(handedToADownload) == .interrupted)
    }

    @Test("a navigation another replaced, or one stopped, is not a failure")
    func cancelledIsNotAFailure() {
        #expect(BrowserNavigationEnding(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) == .interrupted)
    }

    /// The rule reads the domain and the code: the same code in another
    /// domain, or the same sentence on another error, is still a failure.
    @Test("only the domain and code decide, never the sentence")
    func domainAndCodeDecide() {
        let sameCodeOtherDomain = NSError(domain: "WKErrorDomain", code: 102)
        let sameSentence = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Frame load interrupted"]
        )

        #expect(BrowserNavigationEnding(sameCodeOtherDomain) == .failed)
        #expect(BrowserNavigationEnding(sameSentence) == .failed)
        #expect(BrowserNavigationEnding(NSError(domain: "WebKitErrorDomain", code: 101)) == .failed)
    }

    @Test(
        "a page that could not load is a failure",
        arguments: [
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut, NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted
        ]
    )
    func loadErrorsAreFailures(_ code: Int) {
        #expect(BrowserNavigationEnding(NSError(domain: NSURLErrorDomain, code: code)) == .failed)
    }
}
