import Foundation
import Testing

@testable import FermixAppCore

/// A link to another app (plan §4.5, §8.1): the person's own tab asks first,
/// in the pane's one dialog, and a task's tab never opens another app.
@Suite("Browser links to other apps")
@MainActor
struct BrowserOtherAppTests {
    static let fermix = URL(string: "https://fermix.ai/contact")!
    static let mail = URL(string: "mailto:hello@fermix.ai")!

    /// The person's tab, in front, showing a page of `fermix.ai`.
    static func personsTab(_ harness: BrowserHarness) {
        harness.coordinator.open(Self.fermix)
        harness.page(0).events?.pageChanged(BrowserPageState(url: Self.fermix, title: "Contact"))
    }

    @Test("the person's tab asks first, naming the app, and the app opens only on the answer")
    func personsTabAsksFirst() throws {
        let harness = BrowserHarness()
        Self.personsTab(harness)

        harness.page(0).events?.pageMetExternalScheme(Self.mail)

        let question = try #require(harness.model.dialog?.dialog)
        #expect(question.kind == .openApp(name: "Mail"))
        #expect(question.origin == "fermix.ai")
        #expect(question.message == "fermix.ai wants to open this app.")
        #expect(harness.workspace.opened.isEmpty, "the app opened before the person answered")

        harness.coordinator.answer(.confirmed)
        #expect(harness.workspace.opened == [Self.mail])
        #expect(harness.model.dialog == nil)
        #expect(harness.model.notice == nil)
    }

    @Test("a cancelled question opens nothing")
    func cancelledQuestionOpensNothing() throws {
        let harness = BrowserHarness()
        Self.personsTab(harness)

        harness.page(0).events?.pageMetExternalScheme(Self.mail)
        harness.coordinator.answer(.dismissed)

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.model.dialog == nil)
    }

    @Test("with no app for the link the pane says so and asks nothing")
    func noAppSaysSo() throws {
        let harness = BrowserHarness()
        Self.personsTab(harness)
        harness.workspace.installedApp = nil

        harness.page(0).events?.pageMetExternalScheme(Self.mail)

        #expect(harness.model.dialog == nil)
        #expect(harness.model.notice == ProductStrings[.browserNoticeNoApp])
        #expect(harness.workspace.opened.isEmpty)
    }

    @Test("an app that refuses the link after the answer is said")
    func refusedAfterTheAnswerSaysSo() throws {
        let harness = BrowserHarness()
        Self.personsTab(harness)
        harness.workspace.succeeds = false

        harness.page(0).events?.pageMetExternalScheme(Self.mail)
        harness.coordinator.answer(.confirmed)

        #expect(harness.workspace.opened == [Self.mail])
        #expect(harness.model.notice == ProductStrings[.browserNoticeNoApp])
    }

    /// The agent's clicks arrive as trusted events, so the policy alone would
    /// let a task launch an app; ownership is what stops it.
    @Test("a task's tab never opens another app, and the pane says so while it is in front")
    func taskTabNeverOpensAnotherApp() throws {
        let harness = BrowserHarness()
        _ = try BrowserHostCoordinatorTests.attached(harness)
        let tab = try BrowserHostCoordinatorTests.openTaskTab(harness)
        BrowserHostCoordinatorTests.showPaneOnScreen(harness)
        #expect(harness.model.selectedTabID == tab.id)

        harness.page(0).events?.pageMetExternalScheme(Self.mail)

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.model.dialog == nil)
        #expect(harness.model.notice == ProductStrings[.browserNoticeTaskOpenAppRefused])
    }

    @Test("a task's tab behind the person's is refused without a word")
    func taskTabBehindIsRefusedQuietly() throws {
        let harness = BrowserHarness()
        _ = try BrowserHostCoordinatorTests.attached(harness)
        _ = try BrowserHostCoordinatorTests.openTaskTab(harness)
        harness.coordinator.open(Self.fermix)

        harness.page(0).events?.pageMetExternalScheme(Self.mail)

        #expect(harness.workspace.opened.isEmpty)
        #expect(harness.model.dialog == nil)
        #expect(harness.model.notice == nil)
    }

    /// One popup at a time: a link while a page's dialog is up opens nothing
    /// and leaves that dialog where it is.
    @Test("the question never stacks on a page's dialog")
    func questionNeverStacks() throws {
        let harness = BrowserHarness()
        Self.personsTab(harness)
        let alert = BrowserDialog(kind: .alert, message: "Hello", origin: "fermix.ai")
        harness.page(0).events?.pagePresented(alert) { _ in }

        harness.page(0).events?.pageMetExternalScheme(Self.mail)

        #expect(harness.model.dialog?.dialog == alert)
        harness.coordinator.answer(.confirmed)
        #expect(harness.workspace.opened.isEmpty)
    }

    @Test("the question is titled by the app and speaks for the website that asks")
    func questionWords() {
        let question = BrowserDialog(kind: .openApp(name: "FaceTime"), message: "", origin: "fermix.ai")

        #expect(BrowserText.dialogTitle(question) == "Open FaceTime?")
        #expect(BrowserText.openAppMessage(origin: "fermix.ai") == "fermix.ai wants to open this app.")
        #expect(BrowserText.openAppMessage(origin: "") == "This page wants to open this app.")
        #expect(BrowserText.dialogTitle(BrowserDialog(kind: .confirm, message: "Leave?", origin: "fermix.ai")) == "fermix.ai says")
        #expect(ProductStrings[.browserOpenAppOpen] == "Open")
    }
}
