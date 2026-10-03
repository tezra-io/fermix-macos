import Foundation
import Testing

@testable import FermixAppCore

/// The browser pane's one owner: tabs, the pane, and what pages ask for.
@Suite("Browser coordinator")
@MainActor
struct BrowserCoordinatorTests {
    static let fermix = URL(string: "https://fermix.ai")!
    static let example = URL(string: "https://example.com")!

    @Test("a link opens in a new tab of the shared profile, in front, and opens the pane")
    func linkOpensATab() throws {
        let harness = BrowserHarness()

        harness.coordinator.open(Self.fermix)

        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.map(\.profile) == [.shared])
        #expect(harness.model.selectedTab?.id == harness.model.tabs.first?.id)
        #expect(harness.page(0).loaded == [Self.fermix])
        #expect(harness.record.paneShown == [true])
    }

    /// The engine is built once, over the profile the record keeps: a second
    /// profile would be the person signed out of every website.
    @Test("the engine is built once, over the recorded website profile")
    func engineIsBuiltOnce() throws {
        let harness = BrowserHarness()

        harness.coordinator.open(Self.fermix)
        harness.coordinator.newTab(profile: .private)

        let recorded = try WebsiteProfileRecord(location: harness.location).identifier()
        #expect(harness.record.enginesBuilt == [recorded])
        #expect(harness.record.paneShown == [true], "the pane opens once")
    }

    @Test("a new tab is blank, in front, with the caret in the address field")
    func newTabFocusesTheAddress() throws {
        let harness = BrowserHarness()

        harness.coordinator.newTab(profile: .private)

        #expect(harness.model.tabs.map(\.profile) == [.private])
        #expect(harness.page(0).loaded.isEmpty)
        #expect(harness.model.addressFocusRequests == 1)
    }

    @Test("closing a tab brings its neighbour to the front")
    func closingSelectsTheNeighbour() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.example)
        let first = try #require(harness.model.tabs.first)
        let second = try #require(harness.model.tabs.last)

        harness.coordinator.close(second)

        #expect(harness.model.tabs.map(\.id) == [first.id])
        #expect(harness.model.selectedTabID == first.id)
        #expect(harness.page(1).actions == ["stop"])
        #expect(harness.model.isOpen)
    }

    @Test("closing the last tab closes the pane")
    func lastTabClosesThePane() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)

        harness.coordinator.close(try #require(harness.model.tabs.first))

        #expect(!harness.model.isOpen)
        #expect(harness.model.selectedTabID == nil)
        #expect(harness.record.paneShown == [true, false])
    }

    /// The pane hides and its tabs stay, so a link opened later lands beside
    /// them.
    @Test("closing the pane keeps its tabs")
    func closingThePaneKeepsTabs() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)

        harness.coordinator.closePane()
        #expect(!harness.model.isOpen)
        #expect(harness.model.tabs.count == 1)

        harness.coordinator.open(Self.example)
        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.count == 2)
        #expect(harness.record.paneShown == [true, false, true])
    }

    @Test("hiding the pane answers the dialog waiting over it")
    func hidingAnswersTheDialog() {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        var answers: [BrowserDialogAnswer] = []
        harness.page(0).events?.pagePresented(BrowserDialog(kind: .alert, message: "Hi", origin: "fermix.ai")) {
            answers.append($0)
        }

        harness.coordinator.closePane()

        #expect(answers == [.dismissed])
        #expect(harness.model.dialog == nil)
    }

    @Test("an address loads in the tab in front")
    func addressLoadsInFront() throws {
        let harness = BrowserHarness()
        harness.coordinator.newTab(profile: .shared)

        harness.coordinator.load(address: "fermix.ai")

        #expect(harness.page(0).loaded == [URL(string: "https://fermix.ai")!])
        #expect(harness.model.tabs.count == 1)
    }

    @Test("an address with no tab to load it in opens one")
    func addressWithoutATabOpensOne() throws {
        let harness = BrowserHarness()

        harness.coordinator.load(address: "https://example.com")

        #expect(harness.model.tabs.count == 1)
        #expect(harness.page(0).loaded == [Self.example])
    }

    @Test("something that is not an address says so and loads nothing")
    func nonAddressSaysSo() throws {
        let harness = BrowserHarness()
        harness.coordinator.newTab(profile: .shared)

        harness.coordinator.load(address: "what is fermix")

        #expect(harness.model.notice == ProductStrings[.browserNoticeNotAnAddress])
        #expect(harness.page(0).loaded.isEmpty)

        harness.coordinator.load(address: "fermix.ai")
        #expect(harness.model.notice == nil, "the sentence goes at the next thing the person does")
    }

    /// A sign-in window has to be in front to be answered, and beside the page
    /// that opened it.
    @Test("a page's own window lands beside its opener, in front")
    func openedWindowLandsBesideItsOpener() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.example)
        let opener = try #require(harness.model.tabs.first)

        #expect(harness.page(0).events?.pageOpened(FakeBrowserPage()) == true)

        #expect(harness.model.tabs.count == 3)
        #expect(harness.model.tabs[0].id == opener.id)
        #expect(harness.model.selectedTabID == harness.model.tabs[1].id)
    }

    @Test("a page that closes its own window closes its tab")
    func pageClosesItsTab() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.example)

        harness.page(1).events?.pageAskedToClose()

        #expect(harness.model.tabs.count == 1)
    }

    @Test("the page in front may ask the person, and the answer reaches the page")
    func dialogsReachThePerson() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        var answers: [BrowserDialogAnswer] = []
        let dialog = BrowserDialog(kind: .confirm, message: "Leave this page?", origin: "fermix.ai")

        harness.page(0).events?.pagePresented(dialog) { answers.append($0) }
        #expect(harness.model.dialog?.dialog == dialog)

        harness.coordinator.answer(.confirmed)
        #expect(answers == [.confirmed])
        #expect(harness.model.dialog == nil)
    }

    /// One popup at a time, and only for the page the person is looking at.
    @Test("a second dialog, or one from a tab behind, is dismissed at once")
    func dialogsNeverStack() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.example)
        var behind: [BrowserDialogAnswer] = []
        var second: [BrowserDialogAnswer] = []
        let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "example.com")

        harness.page(0).events?.pagePresented(alert) { behind.append($0) }
        harness.page(1).events?.pagePresented(alert) { _ in }
        harness.page(1).events?.pagePresented(alert) { second.append($0) }

        #expect(behind == [.dismissed])
        #expect(second == [.dismissed])
        #expect(harness.model.dialog != nil)
    }

    @Test("closing a tab answers the dialog its page is waiting on")
    func closingAnswersThePendingDialog() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        var answers: [BrowserDialogAnswer] = []
        let prompt = BrowserDialog(kind: .prompt(defaultText: ""), message: "Name?", origin: "fermix.ai")
        harness.page(0).events?.pagePresented(prompt) { answers.append($0) }

        harness.coordinator.close(try #require(harness.model.tabs.first))

        #expect(answers == [.dismissed])
        #expect(harness.model.dialog == nil)
    }

    @Test("the page in front opens in the person's own browser")
    func openInSystemBrowser() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.page(0).events?.pageChanged(BrowserPageState(url: Self.fermix, title: "Fermix"))

        harness.coordinator.openInSystemBrowser()

        #expect(harness.workspace.opened == [Self.fermix])
    }

    @Test("a failed load is said for the tab in front only")
    func failuresAreForTheTabInFront() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.example)

        harness.page(0).events?.pageFailed("The Internet connection appears to be offline.")
        #expect(harness.model.notice == nil)

        harness.page(1).events?.pageFailed("The Internet connection appears to be offline.")
        #expect(harness.model.notice == "The Internet connection appears to be offline.")
    }

    /// A profile that cannot be read is never replaced, so the pane opens on
    /// the sentence rather than a link going nowhere.
    @Test("an unreadable website profile opens the pane on its sentence")
    func unreadableProfileSaysSo() throws {
        let harness = BrowserHarness()
        let record = WebsiteProfileRecord(location: harness.location)
        try FileManager.default.createDirectory(at: harness.location.directoryURL, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: record.url)

        harness.coordinator.open(Self.fermix)

        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
        #expect(harness.model.notice == ProductStrings[.browserNoticeProfileUnavailable])
        #expect(harness.record.enginesBuilt.isEmpty)
    }
}

/// What the address field loads.
@Suite("Browser address")
struct BrowserAddressTests {
    @Test("a web address loads as written", arguments: [
        "https://fermix.ai", "http://example.com/path?q=1", "HTTPS://Example.com"
    ])
    func webAddressesLoad(_ typed: String) {
        #expect(BrowserAddress.url(from: typed) == URL(string: typed))
    }

    @Test("a bare host loads over https", arguments: [
        ("fermix.ai", "https://fermix.ai"),
        ("  example.com/docs  ", "https://example.com/docs"),
        ("localhost:4000", "https://localhost:4000")
    ])
    func bareHostsLoadOverHTTPS(_ typed: String, _ expected: String) {
        #expect(BrowserAddress.url(from: typed) == URL(string: expected))
    }

    /// Not the pane's to open, or not an address at all. `mailto:` in
    /// particular must not read as a sign-in to a host.
    @Test("anything else is not an address", arguments: [
        "", "   ", "what is fermix", "fermix", "mailto:hello@fermix.ai", "file:///etc/hosts",
        "ftp://example.com", "javascript:alert(1)", "about:blank", "https://"
    ])
    func otherTextIsNotAnAddress(_ typed: String) {
        #expect(BrowserAddress.url(from: typed) == nil)
    }
}

/// The words the pane draws for a tab and a dialog.
@Suite("Browser pane words")
struct BrowserTextTests {
    @Test("a tab is named by its title, then its host, then as a new tab")
    func tabTitles() {
        #expect(BrowserText.tabTitle(title: "Fermix", url: URL(string: "https://fermix.ai")) == "Fermix")
        #expect(BrowserText.tabTitle(title: "", url: URL(string: "https://fermix.ai/docs")) == "fermix.ai")
        #expect(BrowserText.tabTitle(title: "", url: nil) == ProductStrings[.browserUntitledTab])
        #expect(BrowserText.tabTitle(title: "", url: URL(string: "about:blank")) == ProductStrings[.browserUntitledTab])
    }

    @Test("a dialog speaks for the website that raised it")
    func dialogTitles() {
        #expect(BrowserText.dialogTitle(origin: "fermix.ai") == "fermix.ai says")
        #expect(BrowserText.dialogTitle(origin: "") == "This page says")
    }
}
