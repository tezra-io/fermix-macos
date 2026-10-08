import Foundation
import Testing

@testable import FermixAppCore

/// The one place a content link is opened (plan §4.5).
@Suite("Content links")
@MainActor
struct ContentLinkTests {
    static let page = URL(string: "https://example.com/notes")!
    static let mail = URL(string: "mailto:hello@fermix.ai")!

    private func opener(_ destination: LinkDestination) -> (ContentLinkOpener, BrowserHarness, RecordingWorkspaceOpener) {
        let harness = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        let preference = InMemoryLinkPreferenceStore()
        preference.linkDestination = destination
        let opener = ContentLinkOpener(preference: preference, browser: harness.coordinator, workspace: workspace)

        return (opener, harness, workspace)
    }

    /// The pane is where a link opened before anybody chose.
    @Test("the preference starts at the pane")
    func defaultIsThePane() {
        #expect(UserDefaultsLinkPreferenceStore.defaultDestination == .fermix)
        #expect(InMemoryLinkPreferenceStore().linkDestination == .fermix)
        #expect(UserDefaultsLinkPreferenceStore.key == "browser.linkDestination")
    }

    @Test("a web link opens in the pane, in a new tab, when the preference says so")
    func webLinkOpensInThePane() {
        let (opener, harness, workspace) = opener(.fermix)

        opener.open(Self.page)

        #expect(harness.model.isOpen)
        #expect(harness.page(0).loaded == [Self.page])
        #expect(workspace.opened.isEmpty)
    }

    @Test("a web link opens in the person's own browser when the preference says so")
    func webLinkOpensInTheSystemBrowser() {
        let (opener, harness, workspace) = opener(.system)

        opener.open(Self.page)

        #expect(workspace.opened == [Self.page])
        #expect(!harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
    }

    /// The pane has nothing to show for another app's link, whatever the
    /// preference.
    @Test("another app's link goes to that app", arguments: LinkDestination.allCases)
    func otherSchemesGoToTheirApp(_ destination: LinkDestination) {
        let (opener, harness, workspace) = opener(destination)

        opener.open(Self.mail)

        #expect(workspace.opened == [Self.mail])
        #expect(harness.model.tabs.isEmpty)
    }

    @Test("only a web page is the pane's", arguments: [
        ("https://fermix.ai", LinkDestination.fermix),
        ("HTTP://fermix.ai", .fermix),
        ("mailto:a@fermix.ai", .system),
        ("javascript:alert(1)", .system),
        ("fermix://settings/voice", .system)
    ])
    func paneSchemes(_ link: String, _ expected: LinkDestination) throws {
        let url = try #require(URL(string: link))

        #expect(ContentLinkOpener.destination(of: url, preferring: .fermix) == expected)
        #expect(ContentLinkOpener.destination(of: url, preferring: .system) == .system)
    }

    /// The preference is about web pages. A file handed straight to the Mac
    /// would be launched or run by whatever is at its path, so it always
    /// takes the pane's own rules for files.
    @Test("a file link takes the pane's rule for files, whatever the preference", arguments: LinkDestination.allCases)
    func fileLinksTakeTheFileRule(_ destination: LinkDestination) throws {
        let place = try FilePlaceFixture()
        defer { place.remove() }
        let harness = place.harness()
        let workspace = RecordingWorkspaceOpener()
        let preference = InMemoryLinkPreferenceStore()
        preference.linkDestination = destination
        let opener = ContentLinkOpener(preference: preference, browser: harness.coordinator, workspace: workspace)
        let notes = try place.write("notes.md", in: place.home)
        let app = try place.folder("Thing.app", in: place.home)

        opener.open(notes)
        opener.open(app)

        #expect(harness.model.tabs.map(\.profile) == [.file])
        #expect(harness.page(0).files == [FileLoad(url: FilePlaceFixture.real(notes), kind: .text)])
        #expect(harness.workspace.revealed == [FilePlaceFixture.real(app)])
        #expect(harness.workspace.opened.isEmpty)
        #expect(workspace.opened.isEmpty, "a file went straight to the Mac")
    }
}

/// Provider sign-in stays external, always (plan §1): its authorize address
/// reaches the person's own browser through `ExternalOpening`, and the content
/// link opener, which could put it in the pane, never sees it.
@Suite("Sign-in never enters the pane")
@MainActor
struct SignInStaysExternalTests {
    @Test("a started sign-in goes to the external opener and never to the content link opener")
    func signInGoesExternal() async throws {
        let gateway = try SettingsFixture.gateway()
        let external = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: gateway, opener: external)
        let browser = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        _ = ContentLinkOpener(preference: InMemoryLinkPreferenceStore(), browser: browser.coordinator, workspace: workspace)
        let runner = model.makeJobRunner()

        #expect(await model.startSignIn(provider: "openai_codex", on: runner) == nil)
        // What the sign-in sheet does once it is on screen.
        model.openSignIn(on: runner)

        #expect(external.urls.map(\.host) == ["auth.openai.com"], "the authorize address did not reach the browser")
        #expect(workspace.opened.isEmpty)
        #expect(browser.model.tabs.isEmpty)
        #expect(!browser.model.isOpen)
        runner.dismiss()
    }

    /// The structure the behaviour stands on: the opener is built once, in the
    /// composition, and reaches the chat and nothing else, while everything
    /// that starts a sign-in or opens an installer holds `ExternalOpening`.
    @Test("the content link opener reaches the chat and nothing that signs in")
    func openerReachesOnlyContent() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let holders = files.filter { $0.text.contains("ContentLinkOpener") }.map { file in
            String(file.path.split(separator: "/").suffix(2).joined(separator: "/"))
        }

        #expect(Set(holders) == [
            "Browser/ContentLinkOpener.swift",
            "App/AppComposition.swift",
            "App/AppKitWindowHost.swift",
            "App/MainWindowView.swift",
            "Chat/ChatSurfaceView.swift"
        ])

        // Every surface that starts a sign-in or opens the installer, which the
        // composition root builds and is not one of.
        let signIn = files
            .filter { $0.text.contains("startAuth(") || $0.text.contains(".opener.open(") }
            .filter { !$0.path.hasSuffix("App/AppComposition.swift") }
        #expect(!signIn.isEmpty, "the scan found no sign-in path")
        for file in signIn {
            #expect(!file.text.contains("ContentLinkOpener"), "\(file.path) can reach the pane")
        }

        // The composition builds the opener over the workspace, never over the
        // external opener that carries sign-in.
        let composition = try #require(files.first { $0.path.hasSuffix("App/AppComposition.swift") }?.text)
        let built = try #require(composition.range(of: "links = ContentLinkOpener("))
        let arguments = composition[built.upperBound...].prefix { $0 != ")" }
        #expect(arguments.contains("workspace: environment.workspace"))
        #expect(!arguments.contains("environment.opener"))
    }
}
