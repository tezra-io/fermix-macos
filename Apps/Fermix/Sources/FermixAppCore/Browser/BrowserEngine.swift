import AppKit
import Foundation

/// Which website data a tab keeps.
///
/// `shared` is the one persistent Fermix profile, which remembers website
/// sign-ins across tabs and launches and is separate from every other browser
/// on the Mac. `private` keeps nothing once the tab is gone.
public enum BrowserProfile: String, CaseIterable, Sendable {
    case shared
    case `private`
}

/// The browser behind the pane (plan §4.2).
///
/// The core declares it and imports no WebKit: both executables link this
/// library, and `FermixAgent` must never load a web engine. The GUI-only
/// `FermixBrowser` target implements it on WebKit's web view, the fixture build
/// implements it with fake pages, and `AppComposition` is handed one or the
/// other.
@MainActor
public protocol BrowserEngine: AnyObject {
    func makeTab(profile: BrowserProfile) -> BrowserTab
    /// The system's file chooser for a page's upload field, as a sheet on the
    /// window `page` is in, answered once with the files the person chose or
    /// nil. The coordinator offers it to the person's own tab alone.
    func chooseFiles(_ request: BrowserFileRequest, for page: NSView, answer: @escaping @MainActor ([URL]?) -> Void)
    /// The system's save panel for a file a page is downloading, as a sheet on
    /// the window `page` is in, open on the person's Downloads folder with
    /// `filename` filled in, answered once with the place they chose or nil.
    /// The coordinator offers it to the person's own tab alone.
    func chooseSaveDestination(_ filename: String, for page: NSView, answer: @escaping @MainActor (URL?) -> Void)
    /// The invisible corner window a task's page runs in while the pane cannot
    /// show it (plan §4.10). WebKit suspends a page whose window is not on
    /// screen, so a task's page is always in one.
    var hostWindow: any BrowserPageStage { get }
    /// Lets go of what the engine holds for tabs, once the host has none.
    func releaseIdle()
}

/// Somewhere a tab's page is on screen: the pane's page area, or the host
/// window. A page moves between the two by reparenting its view, never by
/// loading it again.
@MainActor
public protocol BrowserPageStage: AnyObject {
    /// Puts the page here. A page already here stays as it is.
    func hold(_ page: NSView)
    /// Takes the page out, where it is here.
    func release(_ page: NSView)
}

/// Builds the engine over the one persistent website profile, named by the
/// identifier `WebsiteProfileRecord` keeps in the app's support folder.
///
/// A factory rather than an engine, because the identifier is read on the first
/// tab and not at launch: a person who never opens the pane never has a website
/// profile written for them.
public typealias BrowserEngineMaking = @MainActor (_ websiteProfile: UUID) -> any BrowserEngine
