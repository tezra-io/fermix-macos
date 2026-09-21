import Foundation
import Testing

@testable import FermixAppCore

/// The sandbox section's environment variable rows, against the goldens that
/// publish them.
///
/// After the allowed names list the daemon publishes one row per name, keyed
/// `env:<NAME>`: a `secret` row where Fermix can store the value, and a
/// read-only `text` row where it cannot, or where the value comes from a helper
/// command or another variable. Nothing in Swift knows the family. The
/// descriptor form draws the rows it is handed, and a secret row's key is its
/// `secret.set` id, so these rows need no pane and no binding of their own.
/// That is the claim, and these are the cases that fail the day it stops being
/// true.
@Suite("Sandbox environment rows")
@MainActor
struct SandboxEnvironmentRowTests {
    static let section = "sandbox"
    /// The contract's own prefix for the fifth secret id family.
    static let family = "env:"

    /// The name rows the sandbox golden publishes, in the daemon's order.
    static func environmentRows() throws -> [ManagementSettingRow] {
        try DescriptorCoverageTests.rows(inSection: section).filter { $0.key.hasPrefix(family) }
    }

    /// Both shapes the contract describes are in the golden, the secret one in
    /// both of its states, so no branch below passes because the fixture never
    /// reached it.
    @Test("the golden publishes a stored name, an empty one and one whose value comes from elsewhere")
    func theGoldenCoversEveryShape() throws {
        let rows = try Self.environmentRows()
        let secrets = rows.filter { $0.kind == .secret }

        #expect(secrets.contains { $0.present == true })
        #expect(secrets.contains { $0.present == false })
        #expect(rows.contains { $0.readOnly })
    }

    /// A name Fermix can store is the one secret row, reading stored or not from
    /// the daemon's own `present`. A name whose value comes from somewhere else
    /// is a labelled fact, never a field whose save the daemon would refuse.
    @Test("every environment row resolves to a control this build draws")
    func environmentRowsResolve() throws {
        for row in try Self.environmentRows() {
            let projected = DescriptorRowModel(row: row, value: row.value)

            switch projected.control {
            case .secret(let present):
                #expect(row.kind == .secret, "\(row.key)")
                #expect(!row.readOnly, "\(row.key)")
                #expect(present == row.present, "\(row.key) does not read the daemon's own presence")
            case .readOnly:
                #expect(row.readOnly, "\(row.key) draws as a fact and the daemon takes a write for it")
            default:
                Issue.record("\(row.key) resolves to \(projected.control), which is neither")
            }

            #expect(projected.key == row.key)
            #expect(projected.footer == row.footer, "\(row.key) loses the sentence that says where it stands")
        }
    }

    /// The sandbox environment policy is read on every command, so the allowed
    /// names row and every name row carry `restart: false` while the mode and
    /// profile rows above them still carry `true`. The flag is the row's, which
    /// is the reading this section would break first if it were the section's.
    @Test("an environment row asks for no restart while the rows above it still do")
    func environmentRowsAskForNoRestart() throws {
        let rows = try DescriptorCoverageTests.rows(inSection: Self.section)
        let environment = try Self.environmentRows()

        #expect(environment.allSatisfy { !DescriptorRowModel(row: $0, value: $0.value).restart })
        #expect(rows.contains { DescriptorRowModel(row: $0, value: $0.value).restart })
    }

    /// A secret row's key is its `secret.set` id. For this family that is the
    /// contract's own statement, so it is read off the contract: every id the
    /// request goldens store or forget an environment variable under is the key
    /// of a secret row the section publishes.
    @Test("the ids the contract stores a variable under are keys of rows it publishes")
    func requestIdsArePublishedRowKeys() throws {
        let methods = [ManagementMethod.secretSet.rawValue, ManagementMethod.secretClear.rawValue]
        let secretKeys = Set(try Self.environmentRows().filter { $0.kind == .secret }.map(\.key))
        var exercised: Set<String> = []

        for fixture in try ManagementFixtures.load(.requests, from: .management) {
            let method = try fixture.string("method")
            guard methods.contains(method) else { continue }

            let params = try #require(try fixture.object("frame")["params"] as? [String: Any])
            let identifier = try #require(params["id"] as? String)
            guard identifier.hasPrefix(Self.family) else { continue }

            #expect(secretKeys.contains(identifier), "\(fixture.name) names no published row")
            exercised.insert(method)
        }

        #expect(exercised == Set(methods), "the contract publishes a store and a forget for this family")
    }

    /// The half no value can show: the descriptor row hands the secret row its
    /// own key as the id to store under. That lives in a view body, so it is
    /// read as source, the way the other wiring gates in this suite's neighbours
    /// are. Without it every case here could pass over a form that wrote a
    /// variable under some other name.
    @Test("the descriptor row stores a secret under the row's own key")
    func theSecretRowIsHandedTheRowKey() throws {
        let text = try #require(
            try SourceTree.swiftFiles(matching: "Settings/Rows/DescriptorRow.swift").first?.text
        )

        #expect(text.contains("SecretRow("))
        #expect(text.contains("identifier: row.key"))
    }

    /// Storing a value goes out under the row's own key and re-reads the section
    /// that publishes it, which is what moves the row from `Add…` to `Stored`.
    /// The plugin catalogue is asked for nothing: this family lives on a
    /// descriptor row, not on `plugins.list`.
    @Test("storing a variable writes under its row key and re-reads the sandbox section")
    func storingRereadsTheSection() async throws {
        let rows = try Self.environmentRows().filter { $0.kind == .secret }
        #expect(!rows.isEmpty, "the golden publishes no environment variable to store")

        for row in rows {
            let harness = try SettingsHarness()
            await harness.model.loadSection(Self.section)

            #expect(await harness.model.setSecret(id: row.key, value: "not-a-real-value") == nil)
            #expect(harness.gateway.storedSecrets == [SecretWrite(id: row.key, value: "not-a-real-value")])
            #expect(harness.gateway.readSections == [Self.section, Self.section], "\(row.key)")
            #expect(!harness.gateway.calls.contains(.v2(.pluginsList)), "\(row.key)")
        }
    }

    /// Forgetting one follows the same road back, so `Stored` does not outlive
    /// the value it described.
    @Test("forgetting a variable re-reads the sandbox section")
    func forgettingRereadsTheSection() async throws {
        let stored = try #require(try Self.environmentRows().first { $0.present == true })
        let harness = try SettingsHarness()
        await harness.model.loadSection(Self.section)

        #expect(await harness.model.clearSecret(id: stored.key) == nil)
        #expect(harness.gateway.calls.contains(.v2(.secretClear)))
        #expect(harness.gateway.readSections == [Self.section, Self.section])
        #expect(!harness.gateway.calls.contains(.v2(.pluginsList)))
    }
}
