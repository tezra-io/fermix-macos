import Foundation
import Testing

@testable import FermixAppCore

@Suite("Settings editing parity")
@MainActor
struct SettingsEditingParityTests {
    @Test("clearing a model override sends the same empty text as browser setup")
    func clearsTextOverride() throws {
        let gateway = try SettingsFixture.gateway()
        var writes: [ManagementSettingValue] = []
        let field = DescriptorTextRow(
            label: "Sub-agent model", prompt: "Same as main model", value: "override",
            model: SettingsFixture.model(gateway: gateway),
            key: SettingsDraftKey(section: "routing", key: "subagent_model"),
            commit: { writes.append($0) }
        )

        field.submit("")
        #expect(writes == [.text("")])
        field.submit("override")
        #expect(writes.count == 1, "unchanged text is never written")
    }

    @Test("removing the final allowed environment name writes an empty array")
    func clearsLastListEntry() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let descriptor = try #require(DescriptorCoverageTests.rows(inSection: "sandbox")
            .first { $0.key == "sandbox_env_allow" })
        let row = DescriptorRow(model: model, section: "sandbox", row: descriptor)

        row.commitList([])
        await waitForWrite(gateway)

        let write = try #require(gateway.appliedSettings.first)
        #expect(write.values[descriptor.key] == .list([]))
    }

    @Test("a provider with no discovered models still accepts a custom model ID")
    func customModelDoesNotRequireDiscovery() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let descriptor = try #require(DescriptorCoverageTests.rows(inSection: "providers.openrouter")
            .first { $0.key == "default_model" })
        let row = ModelChoiceRow(row: descriptor, section: "providers.openrouter", model: model) {
            Issue.record("manual model entry must not require opening discovery")
        }
        let field = try #require(row.modelField)

        field.submit("vendor/custom-model")
        await waitForWrite(gateway)

        #expect(gateway.appliedSettings.first?.values[descriptor.key] == .text("vendor/custom-model"))
        #expect(!gateway.calls.contains(.v2(.providersModelsList)))
    }

    private func waitForWrite(_ gateway: FakeDaemonGateway) async {
        for _ in 0..<1_000 {
            if !gateway.appliedSettings.isEmpty { return }
            await Task.yield()
        }
        Issue.record("the settings write did not start within the scheduling bound")
    }
}
