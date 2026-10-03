import AppKit
import Foundation

/// What a page publishes about itself, in one value.
public struct BrowserPageState: Equatable, Sendable {
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var estimatedProgress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var hasOnlySecureContent: Bool

    public init(
        url: URL? = nil,
        title: String = "",
        isLoading: Bool = false,
        estimatedProgress: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        hasOnlySecureContent: Bool = false
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasOnlySecureContent = hasOnlySecureContent
    }
}

/// A page zoom step.
public enum BrowserZoom: Sendable {
    case larger
    case smaller
    case actualSize

    /// The zoom factors a page steps through, the ladder a Mac browser uses.
    public static let levels: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The factor one step away from `current`, held at the ends of the ladder.
    public func factor(from current: Double) -> Double {
        switch self {
        case .actualSize: return 1
        case .larger: return Self.levels.first { $0 > current } ?? Self.levels[Self.levels.count - 1]
        case .smaller: return Self.levels.last { $0 < current } ?? Self.levels[0]
        }
    }
}

/// A JavaScript dialog a page raised: `alert`, `confirm` or `prompt`.
public struct BrowserDialog: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    public let kind: Kind
    public let message: String
    /// The host of the frame that raised it, which is who the dialog speaks for.
    public let origin: String

    public init(kind: Kind, message: String, origin: String) {
        self.kind = kind
        self.message = message
        self.origin = origin
    }
}

/// How a person answered a page's dialog. A page is answered exactly once.
public enum BrowserDialogAnswer: Equatable, Sendable {
    case dismissed
    case confirmed
    case text(String)
}

/// A file chooser a page's upload field raised, as WebKit describes it.
public struct BrowserFileRequest: Equatable, Sendable {
    /// The field takes several files at once.
    public let allowsMultipleSelection: Bool
    /// The field takes a folder (`webkitdirectory`).
    public let allowsDirectories: Bool

    public init(allowsMultipleSelection: Bool, allowsDirectories: Bool) {
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsDirectories = allowsDirectories
    }
}

/// One page as the web engine drives it, behind the seam.
///
/// The engine's side of a tab: `BrowserTab` holds one and forwards the
/// person's actions to it, and the page reports what it did through `events`,
/// which it holds weakly because the tab owns it.
@MainActor
public protocol BrowserPage: AnyObject {
    var view: NSView { get }
    var events: (any BrowserPageEvents)? { get set }

    func load(_ url: URL)
    func back()
    func forward()
    func reload()
    func stop()
    func find(_ text: String)
    func zoom(_ zoom: BrowserZoom)
}

/// What a page tells the tab that holds it.
@MainActor
public protocol BrowserPageEvents: AnyObject {
    func pageChanged(_ state: BrowserPageState)
    /// The page opened a window of its own (a `target=_blank` link or
    /// `window.open`). The page is already built, with the opener's website data
    /// and its link back to the opener, which a sign-in window needs to report
    /// to the page that opened it. Answering false refuses it.
    func pageOpened(_ page: any BrowserPage) -> Bool
    /// The page asked for its own window to close, as a sign-in window does
    /// when it is done.
    func pageAskedToClose()
    /// The page's upload field asked for files. Answered exactly once: the
    /// files chosen, or nil for none.
    func pageRequestedFiles(_ request: BrowserFileRequest, answer: @escaping @MainActor ([URL]?) -> Void)
    func pageMetExternalScheme(_ url: URL)
    func pagePresented(_ dialog: BrowserDialog, answer: @escaping @MainActor (BrowserDialogAnswer) -> Void)
    func pageStartedDownload(_ url: URL)
    /// A load never reached a page, in the system's own sentence.
    func pageFailed(_ reason: String)
}

/// What a tab asks of the pane that shows it.
@MainActor
public protocol BrowserTabDelegate: AnyObject {
    /// A page opened a tab of its own. Answering false refuses it.
    func newTabRequested(_ tab: BrowserTab, from opener: BrowserTab) -> Bool
    func closeRequested(by tab: BrowserTab)
    /// A page's upload field asked for files, answered exactly once.
    func filesRequested(
        _ request: BrowserFileRequest,
        in tab: BrowserTab,
        answer: @escaping @MainActor ([URL]?) -> Void
    )
    /// A navigation to a scheme no web page serves, such as `mailto:`, which
    /// belongs to another app on the Mac.
    func externalSchemeMet(_ url: URL)
    func dialogPresented(
        _ dialog: BrowserDialog,
        in tab: BrowserTab,
        answer: @escaping @MainActor (BrowserDialogAnswer) -> Void
    )
    func downloadStarted(_ url: URL)
    func loadFailed(_ reason: String, in tab: BrowserTab)
}

/// One tab of the pane: what its page shows, and what a person can ask of it.
///
/// Its published state is written by its page's reports and by nothing else,
/// so a view reads it and never sets it. The shape mirrors Apple's `WebPage`,
/// so a later move to that API is mechanical.
@MainActor
public final class BrowserTab: ObservableObject, Identifiable {
    public let id = UUID()
    public let profile: BrowserProfile
    public weak var delegate: (any BrowserTabDelegate)?

    @Published public private(set) var url: URL?
    @Published public private(set) var title = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var estimatedProgress = 0.0
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var hasOnlySecureContent = false

    private let page: any BrowserPage

    public init(profile: BrowserProfile, page: any BrowserPage) {
        self.profile = profile
        self.page = page
        page.events = self
    }

    /// The page's own view, which the pane hosts as it is.
    public var view: NSView { page.view }

    /// The page as the engine reads and drives it, or nil for a page with no
    /// web engine behind it, as the fixture's pages have none.
    public var driver: (any BrowserPageDriving)? { page as? any BrowserPageDriving }
    /// The page as the engine captures it, or nil for a page with none.
    public var capturing: (any BrowserPageCapturing)? { page as? any BrowserPageCapturing }
    /// The page's own cookie store, or nil for a page with none.
    public var cookieStore: (any BrowserPageCookies)? { page as? any BrowserPageCookies }

    public func load(_ url: URL) { page.load(url) }
    public func back() { page.back() }
    public func forward() { page.forward() }
    public func reload() { page.reload() }
    public func stop() { page.stop() }
    public func find(_ text: String) { page.find(text) }
    public func zoom(_ zoom: BrowserZoom) { page.zoom(zoom) }

    /// Writes only what moved: every write publishes, and progress alone
    /// reports many times a second while a page loads.
    private func apply(_ state: BrowserPageState) {
        if url != state.url { url = state.url }
        if title != state.title { title = state.title }
        if isLoading != state.isLoading { isLoading = state.isLoading }
        if estimatedProgress != state.estimatedProgress { estimatedProgress = state.estimatedProgress }
        if canGoBack != state.canGoBack { canGoBack = state.canGoBack }
        if canGoForward != state.canGoForward { canGoForward = state.canGoForward }
        if hasOnlySecureContent != state.hasOnlySecureContent { hasOnlySecureContent = state.hasOnlySecureContent }
    }
}

extension BrowserTab: BrowserPageEvents {
    public func pageChanged(_ state: BrowserPageState) {
        apply(state)
    }

    /// A page's own window keeps the opener's website data, so it is a tab of
    /// the same profile.
    public func pageOpened(_ page: any BrowserPage) -> Bool {
        guard let delegate else { return false }

        return delegate.newTabRequested(BrowserTab(profile: profile, page: page), from: self)
    }

    public func pageAskedToClose() {
        delegate?.closeRequested(by: self)
    }

    /// A page with nobody to ask gets no file, as a cancelled chooser does,
    /// because WebKit holds the field until it is answered.
    public func pageRequestedFiles(_ request: BrowserFileRequest, answer: @escaping @MainActor ([URL]?) -> Void) {
        guard let delegate else {
            answer(nil)
            return
        }

        delegate.filesRequested(request, in: self, answer: answer)
    }

    public func pageMetExternalScheme(_ url: URL) {
        delegate?.externalSchemeMet(url)
    }

    /// A page with nobody to ask is answered at once, because WebKit holds the
    /// page until it is.
    public func pagePresented(_ dialog: BrowserDialog, answer: @escaping @MainActor (BrowserDialogAnswer) -> Void) {
        guard let delegate else {
            answer(.dismissed)
            return
        }

        delegate.dialogPresented(dialog, in: self, answer: answer)
    }

    public func pageStartedDownload(_ url: URL) {
        delegate?.downloadStarted(url)
    }

    public func pageFailed(_ reason: String) {
        delegate?.loadFailed(reason, in: self)
    }
}
