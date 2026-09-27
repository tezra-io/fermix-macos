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

    /// Whatever it points at: a download link to a web page is still a file.
    @Test("a download is refused, wherever it points")
    func downloadsAreRefused() {
        for scheme in ["https", "blob", "mailto"] {
            #expect(BrowserNavigationPolicy.decide(BrowserNavigation(scheme: scheme, isDownload: true)) == .refuseDownload)
        }
        #expect(
            BrowserNavigationPolicy.decide(
                BrowserNavigation(scheme: "https", targetsNewWindow: true, isDownload: true)
            ) == .refuseDownload
        )
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
        let file = try #require(URL(string: "https://fermix.ai/fermix.dmg"))

        page.events?.pageMetExternalScheme(mail)
        page.events?.pageStartedDownload(file)
        page.events?.pageAskedToClose()

        #expect(delegate.externals == [mail])
        #expect(delegate.downloads == [file])
        #expect(delegate.closeRequests.map(\.id) == [tab.id])
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
        let location = try BrowserProfileLocation().location
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
        let location = try BrowserProfileLocation().location

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
        let location = try BrowserProfileLocation().location
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
        let location = try BrowserProfileLocation().location
        let record = WebsiteProfileRecord(location: location)
        let identifier = try record.identifier()

        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: record.url)) as? [String: Any]

        #expect(document?["schema_version"] as? Int == 1)
        #expect(document?["identifier"] as? String == identifier.uuidString)
    }
}
