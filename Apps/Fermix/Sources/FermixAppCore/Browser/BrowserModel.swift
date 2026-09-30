import Foundation

/// A page's dialog waiting for the person, with the one answer WebKit is
/// holding the page for.
public struct BrowserDialogRequest: Identifiable {
    public let id = UUID()
    public let dialog: BrowserDialog
    let tabID: BrowserTab.ID
    let answer: @MainActor (BrowserDialogAnswer) -> Void
}

/// Everything the browser pane draws: whether it is open, its tabs and which
/// one shows, and the one sentence it has for the person.
///
/// The coordinator writes it and the pane reads it. The tabs publish their own
/// page state, so a page loading moves the tab it is in and nothing here.
@MainActor
public final class BrowserModel: ObservableObject {
    @Published public internal(set) var isOpen = false
    @Published public internal(set) var tabs: [BrowserTab] = []
    @Published public internal(set) var selectedTabID: BrowserTab.ID?
    /// Why something the person asked for did not happen: a file the pane does
    /// not download, an address that is not one, a page that never loaded.
    /// One at a time, and gone at the next thing the person does.
    @Published public internal(set) var notice: String?
    /// A page's dialog, over the pane. One at a time: a second page asking
    /// while one is up is answered at once, so dialogs never stack.
    @Published public internal(set) var dialog: BrowserDialogRequest?
    /// Counts the times the address field was asked for the caret, so the
    /// pane moves focus once per ask rather than holding it.
    @Published public internal(set) var addressFocusRequests = 0
    /// The host's own state: whose each tab is, and the tasks the person asked
    /// to cancel, which the tab strip draws. The coordinator runs its
    /// transitions and the pane reads it.
    @Published public internal(set) var host = BrowserHostReducer(availability: .available)

    public init() {}

    public var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }
}
