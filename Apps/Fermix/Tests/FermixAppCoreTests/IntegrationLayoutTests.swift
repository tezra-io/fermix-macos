import AppKit
import SwiftUI
import Testing
@testable import FermixAppCore

@MainActor
struct IntegrationLayoutTests {
    @Test("a plugin and its sign-in client have separate list identities")
    func pluginAndClientIdentitiesDoNotCollide() {
        let plugin = row(enabled: false, summary: "Read your notes.")
        let client = ManagementPluginOAuthClient(
            provider: plugin.name, configured: false, redirectPort: nil
        )

        #expect(plugin.id != client.integrationListID)
    }

    @Test("integration rows keep their two-line height across catalogue states")
    func rowsKeepTheirHeight() throws {
        let standard = height(of: row(enabled: true, summary: "Read and update your notes."))
        let disabled = height(of: row(enabled: false, summary: ""))
        let missing = height(of: row(enabled: false, summary: nil))
        let longTitle = height(of: row(
            enabled: false,
            title: String(repeating: "A long integration name ", count: 8),
            summary: "Read and update your notes."
        ))

        #expect(standard > 0)
        #expect(abs(disabled - standard) < 1)
        #expect(abs(missing - standard) < 1)
        #expect(abs(longTitle - standard) < 1)
    }

    @Test("the integration list bounces only when its content needs scrolling")
    func shortListsDoNotBounce() throws {
        let files = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationsPane.swift")
        let text = try #require(files.first?.text)

        #expect(text.contains(".scrollBounceBehavior(.basedOnSize)"))
    }

    @Test("a changed integration result list starts at the top")
    func changedResultsResetTheirScrollPosition() throws {
        let files = try SourceTree.swiftFiles(matching: "Settings/Panes/IntegrationsPane.swift")
        let text = try #require(files.first?.text)
        let start = try #require(text.range(of: "private var list: some View {"))
        let end = try #require(text.range(of: "private var clients: some View {"))
        let list = String(text[start.upperBound..<end.lowerBound])

        for identity in [".id(filter)", ".id(query)", ".id(model.plugins.value != nil)"] {
            #expect(list.contains(identity), "the list retains an old scroll anchor without \(identity)")
        }
    }

    private func height(of row: IntegrationRowModel) -> CGFloat {
        let view = IntegrationRow(row: row, open: {}, setEnabled: { _, _ in })
            .frame(width: 400)
        let host = NSHostingView(rootView: view)
        return host.fittingSize.height
    }

    private func row(
        enabled: Bool,
        title: String = "Integration",
        summary: String?
    ) -> IntegrationRowModel {
        IntegrationRowModel(
            name: "notes", title: title, summary: summary, status: "Not connected.",
            primaryAction: nil, verb: nil, verbs: [], actions: [], installed: true,
            enabled: enabled, runtimeKind: nil, authKind: nil, credentialPresent: false,
            authProvider: nil, consent: "", disclosure: nil, accessProfiles: [],
            workspaces: [], workspaceLabel: nil
        )
    }
}

/// A plugin's detail is one sheet that turns pages (owner report of 2026-09-20:
/// "some of the prompts like entering the api keys has 3 levels of pop up
/// windows").
///
/// Everything the sheet decides is decided here, away from the view: which page
/// answers which published id, where a token stands beside a sign-in, what the
/// sign-in wait shows, and what Escape leaves.
@Suite("Integration detail")
struct IntegrationDetailTests {

    // MARK: - Pages

    /// A page is reached by the id the daemon published and by nothing else.
    /// Derived from the published set, so an id added to the vocabulary is
    /// asked the same question without being listed here.
    @Test("only the two ids a page answers turn the detail to one")
    func pagesAnswerPublishedActionIds() {
        let row = Self.row(authProvider: "google")
        let paged: [ManagementPluginAction: IntegrationDetailPage] = [
            .chooseWorkspace: .workspace,
            .setUpClient: .client(provider: "google")
        ]

        #expect(!ManagementPluginAction.publishedValues.isEmpty)
        for action in ManagementPluginAction.publishedValues.values {
            #expect(IntegrationDetailPage.answering(action, on: row) == paged[action], "\(action.wireValue)")
        }
        #expect(IntegrationDetailPage.answering(.unrecognized("teleport"), on: row) == nil)
    }

    /// The client page is addressed by the daemon's own `auth_provider`. A row
    /// that names none has no client to open, and deriving one from the
    /// plugin's name would be the app deciding which family it signs in with.
    @Test("a client verb on a row that names no sign-in family opens no page")
    func clientPageNeedsTheDaemonsProvider() {
        #expect(IntegrationDetailPage.answering(.setUpClient, on: Self.row(authProvider: nil)) == nil)
    }

    /// An id a page answers is never also a call: the model refuses to perform
    /// it, so a page and the write path cannot both claim one id.
    @Test("every id a page answers is one the model refuses to perform")
    func pagesAndTheWritePathDoNotOverlap() {
        let row = Self.row(authProvider: "google")

        for action in ManagementPluginAction.publishedValues.values
        where IntegrationDetailPage.answering(action, on: row) != nil {
            #expect(action.isAnsweredInPlace, "\(action.wireValue) is paged and performed")
        }
        // The token's two ids are the secret row's, which is in place too.
        #expect(ManagementPluginAction.addToken.isAnsweredInPlace)
        #expect(ManagementPluginAction.replaceToken.isAnsweredInPlace)
        #expect(!ManagementPluginAction.signIn.isAnsweredInPlace, "a sign-in is a call, waited for on the page")
    }

    // MARK: - The token beside a sign-in

    /// A token is drawn on the detail only where it is the plugin's way in. Where
    /// a sign-in is published too, the daemon's `primary_action` says which of
    /// the two leads.
    @Test("a token leads where it is the only door or the daemon leads with it")
    func tokenStanding() {
        #expect(Self.row(authKind: .oauth, primary: .signIn, actions: [.signIn]).tokenSlot == .none)
        #expect(Self.row(authKind: nil, actions: [.check]).tokenSlot == .none)

        // The only door.
        #expect(Self.row(authKind: .apiKey, primary: .addToken, actions: [.addToken, .check]).tokenSlot == .leading)
        #expect(Self.row(authKind: .apiKey, primary: .check, actions: [.check]).tokenSlot == .leading)

        // Two doors, and the daemon says which one leads.
        #expect(Self.row(authKind: .apiKey, primary: .signIn, actions: [.signIn, .addToken]).tokenSlot == .secondary)
        #expect(Self.row(authKind: .apiKey, primary: .addToken, actions: [.addToken, .signIn]).tokenSlot == .leading)
        #expect(
            Self.row(authKind: .apiKey, primary: .replaceToken, actions: [.replaceToken, .signIn]).tokenSlot
                == .leading
        )

        // Two doors and the daemon leads with neither: the sign-in is still
        // how the plugin is meant to be connected, so the token stays second.
        #expect(Self.row(authKind: .apiKey, primary: .check, actions: [.check, .signIn]).tokenSlot == .secondary)
        #expect(Self.row(authKind: .apiKey, primary: nil, actions: [.signIn]).tokenSlot == .secondary)
    }

    /// A word is not a routing key (redlines §7). The daemon's English for the
    /// next step can say anything; the token's standing reads the id.
    @Test("the daemon's verb words never decide where a token stands")
    func tokenStandingIgnoresVerbWords() {
        let misleading = Self.row(
            authKind: .apiKey,
            primary: .signIn,
            verb: "Add token…",
            verbs: ["Add token…", "Replace the token"],
            actions: [.signIn, .check]
        )

        #expect(misleading.tokenSlot == .secondary)
    }

    /// The way to a second-door token is titled from the deck by the id it
    /// stands for, and both ids have a word.
    @Test("the token's door is titled by the id it stands for")
    func tokenDoorIsTitledById() {
        #expect(Self.row(credentialPresent: true).tokenAction == .replaceToken)
        #expect(Self.row(credentialPresent: false).tokenAction == .addToken)
        #expect(ManagementPluginAction.replaceToken.title == ProductStrings[.integrationReplaceToken])
        #expect(ManagementPluginAction.addToken.title == ProductStrings[.integrationAddToken])
    }

    /// What the contract publishes today: a row has one credential kind, so no
    /// golden plugin has two doors and every token the goldens carry leads.
    @Test("no golden plugin has a second-door token")
    func goldenTokensLead() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)

        #expect(rows.contains { $0.tokenSlot == .leading }, "the goldens carry no token plugin at all")
        for row in rows {
            #expect(row.tokenSlot != .secondary, "\(row.name) publishes a sign-in beside its token")
            #expect((row.tokenSlot == .none) == (row.authKind != .apiKey), "\(row.name)")
        }
    }

    // MARK: - The sign-in wait

    /// The block keeps the rules of the sheet it replaces: up from the moment
    /// the sign-in is asked for, gone by itself once the run completes or is
    /// cancelled, and left standing with the sentence where it ended badly.
    @Test("the sign-in block follows the run the way its sheet did")
    func signInBlockFollowsTheRun() throws {
        func block(_ status: String, kind: String = "auth") throws -> IntegrationSignInBlock {
            IntegrationSignInBlock.resolve(
                asked: true,
                starting: false,
                job: try ManagementValueFixture.job(kind: kind, status: status, phase: nil)
            )
        }

        // Asked for and not yet minted: the spinner, before there is a job.
        #expect(IntegrationSignInBlock.resolve(asked: true, starting: true, job: nil) == .waiting)
        #expect(try block("running") == .waiting)
        #expect(try block("completed") == .hidden)
        #expect(try block("cancelled") == .hidden)
        #expect(try block("failed") == .ended)
        #expect(try block("timed_out") == .ended)
        // Refused before a job was minted: the runner holds a sentence and no
        // job, which is where `Try again` belongs.
        #expect(IntegrationSignInBlock.resolve(asked: true, starting: false, job: nil) == .ended)
    }

    /// The runner is shared by every verb on the detail. A check that was
    /// refused leaves it holding a sentence and no job exactly as a refused
    /// sign-in does, and a check that is running is a running job.
    @Test("nothing but a sign-in is drawn as one")
    func onlyASignInIsDrawnAsOne() throws {
        let check = try ManagementValueFixture.job(kind: "plugin_check", status: "running", phase: "probing")
        let signIn = try ManagementValueFixture.job(kind: "auth", status: "running", phase: "awaiting_browser")

        // Nothing was asked of the sign-in, whatever the runner holds.
        #expect(IntegrationSignInBlock.resolve(asked: false, starting: false, job: nil) == .hidden)
        #expect(IntegrationSignInBlock.resolve(asked: false, starting: false, job: signIn) == .hidden)
        #expect(IntegrationSignInBlock.resolve(asked: false, starting: true, job: nil) == .hidden)
        // A sign-in was asked for earlier and the runner has moved on.
        #expect(IntegrationSignInBlock.resolve(asked: true, starting: false, job: check) == .hidden)
    }

    // MARK: - Escape

    /// Escape leaves the innermost thing (M34 §3.1): a page goes back to the
    /// detail, and the detail closes.
    @Test("Escape goes back from a page and closes the detail")
    func escapeLeavesTheInnermostThing() {
        let pages: [IntegrationDetailPage] = [.workspace, .client(provider: "google"), .token]

        for page in pages {
            for signIn in [IntegrationSignInBlock.hidden, .waiting, .ended] {
                #expect(
                    IntegrationDetailEscape.resolve(page: page, signIn: signIn, busy: false) == .back,
                    "\(page) with the sign-in \(signIn)"
                )
            }
        }

        #expect(IntegrationDetailEscape.resolve(page: .detail, signIn: .hidden, busy: false) == .close)
        // A sign-in that ended badly had `Done` on its sheet, so it holds nothing.
        #expect(IntegrationDetailEscape.resolve(page: .detail, signIn: .ended, busy: false) == .close)
    }

    /// On the sign-in sheet Escape was its `Cancel`, and the detail under it
    /// could not be closed until the wait was over. While the sign-in was still
    /// starting, or a cancel was already on its way, every button there was
    /// disabled and the key did nothing.
    @Test("Escape cancels a sign-in being waited for, and never closes over one")
    func escapeCancelsTheWait() {
        #expect(IntegrationDetailEscape.resolve(page: .detail, signIn: .waiting, busy: false) == .cancelSignIn)
        #expect(IntegrationDetailEscape.resolve(page: .detail, signIn: .waiting, busy: true) == .nothing)
    }

    // MARK: - The verb row

    /// The widest row the daemon publishes is a sign-in whose client was
    /// refused: five verbs, wider than the sheet. On one line they were squeezed
    /// until the verb the row leads with read `Set up th…`. The widths here are
    /// the ones those five buttons measure in the sheet, and the measure is the
    /// room the sheet leaves them.
    @Test("the detail's verbs wrap onto a second line rather than squeeze")
    func verbsWrapRatherThanSqueeze() {
        let refusedClient: [Double] = [169, 65, 99, 93, 72]

        #expect(
            IntegrationVerbFlow.lines(widths: refusedClient, spacing: 8, fitting: 362) == [[0, 1, 2], [3, 4]],
            "the daemon's order is kept, and the verb it leads with is first"
        )
        // The golden rows fit on one line and are left on it.
        #expect(IntegrationVerbFlow.lines(widths: [81, 93, 92, 72], spacing: 8, fitting: 362) == [[0, 1, 2, 3]])
    }

    /// The edges of the rule: a run that fits to the point stays, one point
    /// over wraps, and a button wider than a whole line still gets a line
    /// rather than being dropped.
    @Test("a verb wraps exactly when it would run past its line")
    func verbWrappingEdges() {
        #expect(IntegrationVerbFlow.lines(widths: [100, 100], spacing: 8, fitting: 208) == [[0, 1]])
        #expect(IntegrationVerbFlow.lines(widths: [100, 100], spacing: 8, fitting: 207) == [[0], [1]])
        #expect(IntegrationVerbFlow.lines(widths: [500, 50], spacing: 8, fitting: 300) == [[0], [1]])
        #expect(IntegrationVerbFlow.lines(widths: [50, 500, 50], spacing: 8, fitting: 300) == [[0], [1], [2]])
        #expect(IntegrationVerbFlow.lines(widths: [], spacing: 8, fitting: 300).isEmpty)
    }

    // MARK: - Rows

    private static func row(
        authKind: ManagementPluginAuthKind? = nil,
        primary: ManagementPluginAction? = nil,
        verb: String? = nil,
        verbs: [String] = [],
        actions: [ManagementPluginAction] = [],
        credentialPresent: Bool = false,
        authProvider: String? = nil
    ) -> IntegrationRowModel {
        IntegrationRowModel(
            name: "notes", title: "Notes", summary: nil, status: "Not connected.",
            primaryAction: primary, verb: verb, verbs: verbs, actions: actions, installed: true,
            enabled: true, runtimeKind: nil, authKind: authKind, credentialPresent: credentialPresent,
            authProvider: authProvider, consent: "", disclosure: nil, accessProfiles: [],
            workspaces: [], workspaceLabel: nil
        )
    }
}
