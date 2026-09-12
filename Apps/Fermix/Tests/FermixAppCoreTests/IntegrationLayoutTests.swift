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
