import Foundation
import Testing

@testable import FermixAppCore

/// A page's upload field (plan §8.1): the person's own tab gets the system's
/// file chooser, a task's tab never does. The chooser is the fake engine's, so
/// no test raises a panel.
@Suite("Browser file chooser")
@MainActor
struct BrowserFileChooserTests {
    static let fermix = URL(string: "https://fermix.ai")!
    static let several = BrowserFileRequest(allowsMultipleSelection: true, allowsDirectories: false)
    static let folder = BrowserFileRequest(allowsMultipleSelection: false, allowsDirectories: true)
    static let chosen = [URL(fileURLWithPath: "/Users/someone/Documents/report.pdf")]

    @Test("the person's tab in front gets the chooser the page asked for, over its own page")
    func personsTabGetsTheChooser() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        var answers: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.several) { answers.append($0) }

        #expect(harness.engine.fileRequests == [Self.several])
        #expect(harness.engine.filePages.first === harness.page(0).view)
        #expect(answers.isEmpty, "the page was answered before the person chose")

        harness.engine.answerFiles(Self.chosen)
        #expect(answers == [Self.chosen])
    }

    @Test("a folder field asks for a folder, and a cancelled chooser gives the page no file")
    func cancelledChooserGivesNoFile() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        var answers: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.folder) { answers.append($0) }
        harness.engine.answerFiles(nil)

        #expect(harness.engine.fileRequests == [Self.folder])
        #expect(answers == [nil])
    }

    /// Ownership, not placement: the task's tab is in front of a pane on
    /// screen, exactly where the person's would get the chooser.
    @Test("a task's tab gets no chooser, even in front of the pane")
    func taskTabGetsNoChooser() throws {
        let harness = BrowserHarness()
        _ = try BrowserHostCoordinatorTests.attached(harness)
        let tab = try BrowserHostCoordinatorTests.openTaskTab(harness)
        BrowserHostCoordinatorTests.showPaneOnScreen(harness)
        #expect(harness.model.selectedTabID == tab.id)
        var answers: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.several) { answers.append($0) }

        #expect(answers == [nil])
        #expect(harness.engine.fileRequests.isEmpty)
    }

    @Test("a tab behind another, or in a hidden pane, gets no chooser")
    func unshownTabsGetNoChooser() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        harness.coordinator.open(Self.fermix)
        var behind: [[URL]?] = []
        var hidden: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.several) { behind.append($0) }
        harness.coordinator.closePane()
        harness.page(1).events?.pageRequestedFiles(Self.several) { hidden.append($0) }

        #expect(behind == [nil])
        #expect(hidden == [nil])
        #expect(harness.engine.fileRequests.isEmpty)
    }

    /// One popup at a time, whichever came first.
    @Test("the chooser and a page's dialog never stack")
    func chooserAndDialogNeverStack() throws {
        let harness = BrowserHarness()
        harness.coordinator.open(Self.fermix)
        let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "fermix.ai")
        var dialogs: [BrowserDialogAnswer] = []
        var files: [[URL]?] = []

        harness.page(0).events?.pageRequestedFiles(Self.several) { files.append($0) }
        harness.page(0).events?.pagePresented(alert) { dialogs.append($0) }
        harness.page(0).events?.pageRequestedFiles(Self.several) { files.append($0) }
        #expect(dialogs == [.dismissed])
        #expect(files == [nil], "a second chooser stacked on the first")
        #expect(harness.model.dialog == nil)

        harness.engine.answerFiles(Self.chosen)
        harness.page(0).events?.pagePresented(alert) { dialogs.append($0) }
        harness.page(0).events?.pageRequestedFiles(Self.several) { files.append($0) }
        #expect(harness.model.dialog?.dialog == alert)
        #expect(files == [nil, Self.chosen, nil], "a chooser stacked on a dialog")
        #expect(harness.engine.fileRequests.count == 1)
    }

    @Test("a tab passes the page's request to the pane, and with no pane answers no file")
    func tabRoutesTheRequest() throws {
        let delegate = RecordingTabDelegate()
        delegate.files = Self.chosen
        let page = FakeBrowserPage()
        let tab = BrowserTab(profile: .shared, page: page)
        var answers: [[URL]?] = []

        page.events?.pageRequestedFiles(Self.several) { answers.append($0) }
        tab.delegate = delegate
        page.events?.pageRequestedFiles(Self.folder) { answers.append($0) }

        #expect(answers == [nil, Self.chosen])
        #expect(delegate.fileRequests == [Self.folder])
    }
}
