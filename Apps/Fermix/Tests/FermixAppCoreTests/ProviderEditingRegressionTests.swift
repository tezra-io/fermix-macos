import Foundation
import Testing

@testable import FermixAppCore

@Suite("Provider editing regressions")
@MainActor
struct ProviderEditingRegressionTests {
    @Test("a focused model suggestion survives validated write and readback without an old blur write")
    func selectedModelSurvivesReadback() async throws {
        let gateway = try SettingsFixture.gateway()
        let store = try StatefulProviderSettings(section: "providers.anthropic")
        gateway.providerSettings = store
        let model = SettingsFixture.model(gateway: gateway)
        await model.loadSection(store.section)
        let row = try #require(model.section(store.section).value?.rows.first { $0.key == "default_model" })
        let choice = try #require(row.options.first { $0.value != DescriptorValue.text(row.value) })
        var input = DescriptorTextDraft(text: "unfinished custom model")

        let change = input.choose(choice.value)
        #expect(await model.apply(section: store.section, key: row.key, value: change))
        let readback = try #require(model.section(store.section).value?.rows.first { $0.key == row.key })
        input.receive(DescriptorValue.text(readback.value), focused: true)

        #expect(readback.value == .text(choice.value))
        #expect(input.text == choice.value)
        #expect(input.submission(comparedTo: DescriptorValue.text(readback.value)) == nil)
        #expect(gateway.appliedSettings.count == 1, "focus loss must not send the old model back")
        #expect(try store.read().rows.first { $0.key == row.key }?.value == .text(choice.value))
    }

    @Test("auth-mode selection controls credentials while retaining slots for other entry points")
    func selectedAuthModeControlsCredentials() async throws {
        let gateway = try SettingsFixture.gateway()
        gateway.providerSettings = try StatefulProviderSettings(section: "providers.anthropic")
        let model = SettingsFixture.model(gateway: gateway)
        await model.loadSection("providers.anthropic")

        #expect(await model.apply(section: "providers.anthropic", key: "auth_mode", value: .text("oauth")))
        #expect(model.providerAuthMode("anthropic") == "oauth")
        #expect(model.providerCredentialExclusions("anthropic") == ["anthropic_api_key"])
        #expect(model.section("providers.anthropic").value?.rows.contains { $0.key == "anthropic_api_key" } == true)
        #expect(ProviderRowProjection.detailAuthVerbs(for: "anthropic", detections: nil, authMode: model.providerAuthMode("anthropic")) == [.addSetupToken])

        #expect(await model.apply(section: "providers.anthropic", key: "auth_mode", value: .text("api_key")))
        #expect(model.providerAuthMode("anthropic") == "api_key")
        #expect(model.providerCredentialExclusions("anthropic").isEmpty)
        #expect(ProviderRowProjection.detailAuthVerbs(for: "anthropic", detections: nil, authMode: model.providerAuthMode("anthropic")).isEmpty)
    }

    @Test("a provider write is validated against its actual published keys")
    func invalidKeyIsRefusedWithoutChangingStoredModel() async throws {
        let gateway = try SettingsFixture.gateway()
        let store = try StatefulProviderSettings(section: "providers.anthropic")
        gateway.providerSettings = store
        let before = try store.read()
        let model = SettingsFixture.model(gateway: gateway)

        #expect(await !model.apply(section: store.section, key: "model", value: .text("mistyped-key")))
        #expect(try store.read() == before)
    }
}

/// A stateful fixture for real published choice rows. Invalid keys and closed
/// choice values refuse; accepted values are returned by the next settings.get.
final class StatefulProviderSettings {
    let section: String
    private var object: [String: Any]

    init(section: String) throws {
        self.section = section
        let fixture = try #require(try ManagementFixtures.load(.success).first {
            (try? $0.object("response")["result"] as? [String: Any])?["id"] as? String == section
        })
        object = try #require(try fixture.object("response")["result"] as? [String: Any])
    }

    func read() throws -> ManagementSettingsSectionRows {
        try JSONDecoder().decode(ManagementSettingsSectionRows.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func apply(_ values: [String: ManagementSettingValue]) throws {
        let published = try read().rows
        var rows = try #require(object["rows"] as? [[String: Any]])
        for (key, value) in values {
            guard let row = published.first(where: { $0.key == key }), row.kind == .choice,
                  !row.readOnly, case .text(let text) = value,
                  row.suggestions || row.options.contains(where: { $0.value == text }),
                  let index = rows.firstIndex(where: { $0["key"] as? String == key }) else {
                throw ManagementRefusal.daemon(.invalidParams, "This is not a published setting or allowed value.")
            }
            rows[index]["value"] = text
        }
        object["rows"] = rows
    }
}
