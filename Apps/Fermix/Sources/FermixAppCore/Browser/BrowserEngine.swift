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
}

/// Builds the engine over the one persistent website profile, named by the
/// identifier `WebsiteProfileRecord` keeps in the app's support folder.
///
/// A factory rather than an engine, because the identifier is read on the first
/// tab and not at launch: a person who never opens the pane never has a website
/// profile written for them.
public typealias BrowserEngineMaking = @MainActor (_ websiteProfile: UUID) -> any BrowserEngine
