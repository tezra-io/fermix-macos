import Foundation

/// How a navigation that ended without a page ended, read from the error
/// WebKit gave it: pure, so the rule is provable without a web view.
///
/// Two endings are not failures, and the person is told nothing of them. A
/// navigation another replaced, or one stopped, ends `NSURLErrorCancelled`.
/// One WebKit handed to a download ends with frame load interrupted by a
/// policy change, which WebKit reports in its older domain, not in
/// `WKError.errorDomain`. Neither leaves a page that failed to load: the page
/// stands as it was. Every other ending is a page that did not load, told in
/// the system's own sentence.
public enum BrowserNavigationEnding: Equatable, Sendable {
    /// The page did not load.
    case failed
    /// Nothing failed: the page stands as it was.
    case interrupted

    /// The domain WebKit reports frame load interrupted in.
    public static let webKitErrorDomain = "WebKitErrorDomain"
    public static let frameLoadInterruptedByPolicyChange = 102

    public init(_ error: any Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled), (Self.webKitErrorDomain, Self.frameLoadInterruptedByPolicyChange):
            self = .interrupted
        default:
            self = .failed
        }
    }
}
