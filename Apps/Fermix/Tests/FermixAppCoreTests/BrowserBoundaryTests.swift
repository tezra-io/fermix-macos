import Foundation
import Testing

@testable import FermixAppCore

/// Where a navigation goes (plan §4.2), rule by rule.
@Suite("Browser navigation policy")
struct BrowserNavigationPolicyTests {
    @Test("a web page moves the tab", arguments: ["http", "https", "HTTPS", "about", "blob", "data"])
    func webPagesMoveTheTab(_ scheme: String) {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme)) == .allow)
    }

    @Test("a web page that asks for a window of its own gets a tab")
    func newWindowsBecomeTabs() {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", targetsNewWindow: true)) == .newTab)
    }

    /// The web's own schemes, and a file a page built itself, in any case the
    /// page wrote it.
    @Test("the tab's own download of a web file is saved", arguments: ["http", "https", "HTTPS", "blob", "data"])
    func webDownloadsAreSaved(_ scheme: String) {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isDownload: true)) == .download)
    }

    /// A link's `download` attribute keeps the file out of a new window, and
    /// a script's download is still the tab's own.
    @Test("a download is saved whether it asked for a window or a script began it")
    func downloadsIgnoreWindowAndGesture() {
        #expect(
            BrowserNavigationPolicy.decide(
                BrowserNavigation(scheme: "https", targetsNewWindow: true, isDownload: true)
            ) == .download
        )
        #expect(
            BrowserNavigationPolicy.decide(
                BrowserNavigation(scheme: "https", isDownload: true, isUserInitiated: false)
            ) == .download
        )
    }

    /// Nothing a website offers: the download answer comes before the scheme
    /// rules, so it holds the scheme to the web's own itself.
    @Test(
        "a download of any other scheme is refused",
        arguments: ["mailto", "tel", "zoommtg", "file", "about", "javascript", "ftp"]
    )
    func otherSchemeDownloadsAreRefused(_ scheme: String) {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isDownload: true)) == .cancel)
    }

    /// A hidden frame is how a page saves a file nobody asked for.
    @Test("a frame's download is refused without a word", arguments: ["https", "blob", "data"])
    func frameDownloadsAreRefused(_ scheme: String) {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isDownload: true, isMainFrame: false)) == .cancel)
    }

    @Test("a click on another app's scheme opens that app", arguments: ["mailto", "tel", "facetime", "zoommtg"])
    func clickedSchemesGoToTheirApp(_ scheme: String) {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme)) == .external)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, targetsNewWindow: true)) == .external)
    }

    /// A page that reaches for another app on its own is how an app gets
    /// launched that nobody asked for.
    @Test("a script or a frame reaching for another app is refused")
    func unaskedSchemesAreRefused() {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "mailto", isUserInitiated: false)) == .cancel)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "zoommtg", isMainFrame: false)) == .cancel)
        #expect(
            BrowserNavigationPolicy.decide(
                BrowserNavigation(scheme: "zoommtg", targetsNewWindow: true, isUserInitiated: false)
            ) == .cancel
        )
    }

    /// Frames and scripts move web content freely; only another app is held
    /// back.
    @Test("a frame or a script may load a web page")
    func framesLoadWebPages() {
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", isMainFrame: false)) == .allow)
        #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: "https", isUserInitiated: false)) == .allow)
    }

    /// HTTPS-first never applies to these: a local server answers in the
    /// clear, and WebKit's https attempt on one is a silent blank page.
    @Test("this Mac's own loopback addresses are loopback, in the spellings that mean only this Mac", arguments: [
        "localhost", "LocalHost", "localhost.", "LOCALHOST.",
        "127.0.0.1", "127.1.2.3", "127.255.255.254",
        "::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]", "::0:1"
    ])
    func loopbackHosts(_ host: String) {
        #expect(BrowserNavigationPolicy.isLoopback(host: host))
    }

    /// Everything else keeps HTTPS-first: a name that merely contains
    /// `localhost`, a name under `.localhost`, whose address is the system
    /// resolver's to choose, every IPv4 spelling a URL parser reads otherwise
    /// than `inet_pton` does (`0127.0.0.1` is octal there, so another machine),
    /// a zone id, which `inet_pton` drops and a URL never carries, and the
    /// other private and unspecified addresses.
    @Test("every other host is not loopback", arguments: [
        "", "example.com", "localhost.example.com", "mylocalhost", "notlocalhost.", "localhost.com", "localhost..",
        "dev.localhost", "localhost.localhost", "app.localhost.", "[localhost]",
        "0127.0.0.1", "127.0.0.01", "127.000.000.001", "0x7f.0.0.1", "2130706433", "127.1", "127.0.0.1.", "[127.0.0.1]",
        "126.0.0.1", "128.0.0.1", "10.0.0.1", "192.168.1.151", "0.0.0.0", "127.0.0", "127.0.0.1.example.com",
        "::", "::2", "fe80::1", "::ffff:127.0.0.1", "::1%lo0", "[::1%25lo0]", "::1%", "[::1", "::1]", "localhost:8765"
    ])
    func otherHosts(_ host: String) {
        #expect(!BrowserNavigationPolicy.isLoopback(host: host))
    }

    /// The page reads the host off the navigation's own URL, which spells an
    /// IPv6 literal its own way.
    @Test("a navigation's host is read as the page reads it", arguments: [
        ("http://localhost:8765/links.html", true),
        ("http://127.0.0.1:8765/links.html", true),
        ("http://[::1]:8765/links.html", true),
        ("http://dev.localhost/", false),
        ("http://0127.0.0.1/", false),
        ("http://example.com/", false),
        ("http://192.168.1.151:8766/", false)
    ])
    func navigationHosts(_ address: String, _ loopback: Bool) throws {
        let host = try #require(URL(string: address)?.host)

        #expect(BrowserNavigationPolicy.isLoopback(host: host) == loopback)
    }
}

@Suite("Browser tab")
@MainActor
struct BrowserTabTests {
    /// The tab's state is the page's report and nothing else.
    @Test("a page's report is what the tab publishes")
    func tabPublishesThePageReport() throws {
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        let url = try #require(URL(string: "https://fermix.ai"))
        let state = BrowserPageState(
            url: url,
            title: "Fermix",
            isLoading: true,
            estimatedProgress: 0.4,
            canGoBack: true,
            canGoForward: false,
            hasOnlySecureContent: true
        )

        page.events?.pageChanged(state)

        #expect(tab.url == url)
        #expect(tab.title == "Fermix")
        #expect(tab.isLoading)
        #expect(tab.estimatedProgress == 0.4)
        #expect(tab.canGoBack)
        #expect(!tab.canGoForward)
        #expect(tab.hasOnlySecureContent)
    }

    @Test("the person's actions reach the page")
    func actionsReachThePage() throws {
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        let url = try #require(URL(string: "https://fermix.ai"))

        tab.load(url)
        tab.back()
        tab.forward()
        tab.reload()
        tab.stop()
        tab.find("mascot")
        tab.zoom(.larger)

        #expect(page.loaded == [url])
        #expect(page.actions == ["back", "forward", "reload", "stop", "find mascot", "zoom larger"])
    }

    /// A page's own window keeps the opener's website data: a sign-in window
    /// opened from a private tab stays private.
    @Test("a page's own window is a tab of the opener's profile")
    func openedWindowsKeepTheProfile() {
        let delegate = RecordingTabDelegate()
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .private, page: page)
        tab.delegate = delegate

        #expect(page.events?.pageOpened(FakeBrowserPage()) == true)
        #expect(delegate.openedTabs.map(\.profile) == [.private])

        delegate.acceptsTabs = false
        #expect(page.events?.pageOpened(FakeBrowserPage()) == false)
    }

    @Test("the page's requests reach the delegate")
    func requestsReachTheDelegate() throws {
        let delegate = RecordingTabDelegate()
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        tab.delegate = delegate
        let mail = try #require(URL(string: "mailto:hello@fermix.ai"))
        let file = FakeDownload()

        page.events?.pageMetExternalScheme(mail)
        page.events?.pageStartedDownload(file)
        page.events?.pageAskedToClose()
        page.events?.pageFailed("A server with the specified hostname could not be found.")

        #expect(delegate.externals == [mail])
        #expect(delegate.downloads.map(ObjectIdentifier.init) == [ObjectIdentifier(file)])
        #expect(file.cancels == 0)
        #expect(delegate.failures == ["A server with the specified hostname could not be found."])
        #expect(delegate.closeRequests.map(\.id) == [tab.id])
    }

    @Test("a download from a tab nobody holds is cancelled")
    func unheldTabCancelsADownload() {
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        let file = FakeDownload()

        page.events?.pageStartedDownload(file)

        #expect(file.cancels == 1)
        #expect(tab.delegate == nil)
    }

    /// WebKit holds a page until its dialog is answered, so a tab nobody is
    /// showing answers at once.
    @Test("a dialog with nobody to ask is dismissed at once")
    func unshownDialogsAreDismissed() {
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        var answers: [BrowserDialogAnswer] = []

        page.events?.pagePresented(BrowserDialog(kind: .alert, message: "Hi", origin: "fermix.ai")) { answers.append($0) }

        #expect(answers == [.dismissed])
        #expect(tab.delegate == nil)
        #expect(page.events?.pageOpened(FakeBrowserPage()) == false, "a tab with no pane refuses a new one")
    }
}

@Suite("Browser zoom")
struct BrowserZoomTests {
    @Test("zoom steps along the ladder and stops at its ends")
    func zoomSteps() {
        #expect(BrowserZoom.larger.factor(from: 1) == 1.15)
        #expect(BrowserZoom.smaller.factor(from: 1) == 0.85)
        #expect(BrowserZoom.larger.factor(from: 3) == 3)
        #expect(BrowserZoom.smaller.factor(from: 0.5) == 0.5)
        #expect(BrowserZoom.actualSize.factor(from: 2.5) == 1)
        // A factor between two rungs steps to the next rung, not past it.
        #expect(BrowserZoom.larger.factor(from: 1.1) == 1.15)
        #expect(BrowserZoom.smaller.factor(from: 1.1) == 1)
    }
}

/// The one persistent website profile's identity (plan §4.6).
@Suite("Website profile record")
struct WebsiteProfileRecordTests {
    @Test("the record lives in the app's support folder beside the bootstrap record")
    func recordLocation() throws {
        let location = BrowserProfileLocation().location
        let record = WebsiteProfileRecord(location: location)

        #expect(record.url.deletingLastPathComponent().path == location.directoryURL.path)
        #expect(record.url.lastPathComponent == "website-profile.json")
        #expect(record.url.lastPathComponent != LifecycleJournal.fileName)
        #expect(record.url.lastPathComponent != BootstrapLocation.recordName)
    }

    /// The identifier is the profile: a second one would be the person signed
    /// out of every website.
    @Test("the identifier is created once and read back ever after")
    func identifierIsKept() throws {
        let location = BrowserProfileLocation().location

        let first = try WebsiteProfileRecord(location: location).identifier()
        let second = try WebsiteProfileRecord(location: location).identifier()

        #expect(first == second)
    }

    @Test("two support folders keep two profiles")
    func foldersKeepTheirOwnProfiles() throws {
        let installed = try WebsiteProfileRecord(location: BrowserProfileLocation().location).identifier()
        let development = try WebsiteProfileRecord(location: BrowserProfileLocation().location).identifier()

        #expect(installed != development)
    }

    /// Replacing an unreadable record would sign the person out without a
    /// word, so it is refused instead.
    @Test("an unreadable record is refused, never replaced")
    func unreadableRecordIsRefused() throws {
        let location = BrowserProfileLocation().location
        let record = WebsiteProfileRecord(location: location)
        try FileManager.default.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
        try Data("{\"identifier\": 7}".utf8).write(to: record.url)

        #expect(throws: WebsiteProfileRecordError.malformed(path: record.url.path)) { try record.identifier() }
        #expect(try Data(contentsOf: record.url) == Data("{\"identifier\": 7}".utf8))

        try Data("{\"schema_version\": 2, \"identifier\": \"\(UUID().uuidString)\"}".utf8).write(to: record.url)
        #expect(throws: WebsiteProfileRecordError.unsupportedSchemaVersion(2)) { try record.identifier() }
    }

    @Test("the record's names are the ones a later build reads")
    func recordShape() throws {
        let location = BrowserProfileLocation().location
        let record = WebsiteProfileRecord(location: location)
        let identifier = try record.identifier()

        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: record.url)) as? [String: Any]

        #expect(document?["schema_version"] as? Int == 1)
        #expect(document?["identifier"] as? String == identifier.uuidString)
    }
}
