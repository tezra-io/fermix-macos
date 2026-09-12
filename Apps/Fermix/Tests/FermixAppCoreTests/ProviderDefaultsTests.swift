import Foundation
import Testing

@testable import FermixAppCore

@Suite("Provider defaults")
struct ProviderDefaultsTests {
    @Test("an unset model displays the daemon's inheritance label without storing an override")
    func inheritedModelPrompt() throws {
        let row = try ManagementValueFixture.settingRow(
            kind: "choice",
            value: "null",
            options: [(value: "", label: "Same as main model"), (value: "alternate", label: "Alternate")]
        )

        #expect(row.emptyValuePrompt == "Same as main model")
        #expect(row.value == .absent)
        #expect(DescriptorValue.text(row.value).isEmpty)
    }

    @Test("a field without a published empty option keeps the generic empty label")
    func ordinaryEmptyPrompt() throws {
        let row = try ManagementValueFixture.settingRow(kind: "choice", value: "null")

        #expect(row.emptyValuePrompt == ProductStrings[.settingsTextEmptyPrompt])
    }

    @Test("a primary without credentials is clearly marked as not connected")
    func unconfiguredPrimaryStatus() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "openai", "label": "OpenAI", "auth_modes": ["api_key"],
            "configured": false, "primary": true, "present_key": false,
            "default_model": "default-model"
        ])
        let unconfigured = try JSONDecoder().decode(ManagementSetupProvider.self, from: data)

        #expect(ProviderRowProjection.status(of: unconfigured, signingIn: nil).contains(
            ProductStrings[.providerStatusNotConnected]
        ))
    }

    @Test("settings has room for its pane names and a full detail column")
    func settingsWidth() {
        #expect(WindowMetrics.settingsSidebarWidth == 240)
        #expect(WindowMetrics.mainDefaultSize.width == 1040)
        #expect(WindowMetrics.mainDefaultSize.width >=
            WindowMetrics.settingsSidebarWidth + WindowMetrics.settingsContentMaxWidth)
    }
}
