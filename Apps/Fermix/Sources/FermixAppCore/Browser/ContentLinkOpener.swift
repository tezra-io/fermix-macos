import Foundation

/// The one place a content link is opened (plan §4.5): a link in a reply, and
/// every surface that shows the owner's content after it.
///
/// A web page goes where the person's preference says, the pane or their own
/// browser; a file on this Mac goes to the pane's own rule for files
/// (`BrowserCoordinator.openFile`) whatever the preference, which is about web
/// pages; any other scheme belongs to an app on the Mac and goes there
/// whatever the preference, because the pane has nothing to show for it.
///
/// Provider sign-in and the prior installer never come here. They are not
/// content, and `ExternalOpening` stays their only way out of the app: a
/// sign-in's authorize address must reach the person's own browser, never the
/// pane, where the page could not be trusted with it.
@MainActor
public final class ContentLinkOpener {
    private let preference: any LinkPreferenceStoring
    private let browser: BrowserCoordinator
    private let workspace: any WorkspaceLinkOpening
    /// The Mac's own maps, which show a place Apple Maps found by its
    /// identifier, at Apple's own card for it here or in Maps.
    private let maps: any PlaceMaps

    public init(
        preference: any LinkPreferenceStoring,
        browser: BrowserCoordinator,
        workspace: any WorkspaceLinkOpening,
        maps: any PlaceMaps
    ) {
        self.preference = preference
        self.browser = browser
        self.workspace = workspace
        self.maps = maps
    }

    /// The schemes the pane opens from a link. A page itself may move to more
    /// (`BrowserNavigationPolicy.webSchemes`), but a link a person clicks in a
    /// reply, a file aside, is a web page or it is another app's.
    public static let paneSchemes: Set<String> = ["http", "https"]

    /// Where a link that is not a file goes, by its scheme and the
    /// preference.
    public static func destination(of url: URL, preferring preference: LinkDestination) -> LinkDestination {
        guard let scheme = url.scheme?.lowercased(), paneSchemes.contains(scheme) else { return .system }

        return preference
    }

    /// A file never goes straight to the Mac: handed to the workspace, a
    /// script opens in Terminal and runs, and an app launches.
    public func open(_ url: URL) {
        guard !url.isFileURL else {
            browser.openFile(url)
            return
        }

        switch Self.destination(of: url, preferring: preference.linkDestination) {
        case .fermix: browser.open(url)
        case .system: _ = workspace.open(url)
        }
    }

    /// A place a reply found goes to Apple Maps (M72 decision 3), as a
    /// card's Open in Maps sends it and a click on a place another source
    /// found does (`show`), whatever the preference, by what its own record
    /// carries: a place Apple Maps found opens at Apple's own card for it, by
    /// its identifier (§14.1), and any other at the address the app builds
    /// from it (`PlaceMapsAddress`).
    /// Never through the pane, and never by a link the reply wrote, so no
    /// reply chooses which app opens. An identifier Maps cannot open is said
    /// in the pane, as a reply's file that cannot open is, and the place is
    /// not looked up again by its name.
    public func openInMaps(_ place: CompanionPlace) {
        guard let identifier = place.applePlaceID else {
            _ = workspace.open(PlaceMapsAddress.url(for: place))
            return
        }

        maps.openPlace(identifier) { [browser] in
            browser.report(ProductStrings[.browserNoticePlaceNotOpened])
        }
    }

    /// A click on a place a reply found. A place Apple Maps found is shown
    /// here rather than in Maps, at Apple's own card for it (§14.1), so what
    /// comes back is the identifier its card is asked for by (`placeCard`)
    /// and the chat shows the card at what was clicked. Any other place opens
    /// in Maps at its address, as `openInMaps` opens it, and nothing comes
    /// back, since nothing is shown here.
    func show(_ place: CompanionPlace) -> String? {
        guard let identifier = place.applePlaceID else {
            openInMaps(place)
            return nil
        }

        return identifier
    }

    /// Apple's own card for the place Apple Maps knows by `identifier`, at
    /// `size`, for the popover a click on the place opens, which `finished`
    /// puts away when the card's own close button is pressed. Where Maps
    /// finds no place by it or cannot be asked, the popover says so in one
    /// sentence of its own: the pane is not involved, and the place is never
    /// looked up again by its name, so no other place can stand in.
    func placeCard(_ identifier: String, size: CGSize, finished: @escaping @MainActor () -> Void) async -> PlaceCardAnswer {
        do {
            return .card(try await maps.placeCard(identifier, size: size, finished: finished))
        } catch {
            return .said(ProductStrings[.chatPlaceCardUnavailable])
        }
    }

    /// A phone-side file, by its ref, goes where a file at the path the
    /// engine grants for it would (M66 §3.5): the pane's own rule for files.
    /// What the engine answered comes back, so the tile that asked can say
    /// the file is gone.
    public func open(ref: String, named name: String) async -> MediaGrantOutcome {
        await browser.openRef(ref, named: name)
    }
}
