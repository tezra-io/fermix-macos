import Foundation
import Testing
@testable import FermixAppCore

@Suite("OAuth client editing")
struct OAuthClientEditingTests {
    @Test("editing a client preserves its existing public identifier and port")
    func preservesExistingValues() throws {
        let client = try JSONDecoder().decode(ManagementPluginOAuthClient.self, from: Data("""
        {"provider":"google","configured":false,"client_id":"existing-client",
         "secret_present":true,"redirect_port":4567}
        """.utf8))
        var draft = OAuthClientDraft(client: client)

        #expect(draft.identifier == "existing-client")
        #expect(draft.port == "4567")
        draft.identifier = "replacement-client"
        #expect(try draft.validatedPort() == 4567)
        #expect(client.secretPresent == true)
    }

    @Test("a blank redirect port explicitly uses the daemon default")
    func blankPortUsesDefault() throws {
        var draft = OAuthClientDraft(client: nil)
        draft.port = "  "
        #expect(try draft.validatedPort() == nil)
    }

    @Test("invalid nonblank redirect ports are refused", arguments: ["abc", "1.5", "0", "-1", "65536"])
    func invalidPortIsRefused(port: String) {
        var draft = OAuthClientDraft(client: nil)
        draft.port = port
        #expect(throws: OAuthClientDraft.ValidationError.invalidPort) {
            try draft.validatedPort()
        }
    }

    @Test("valid redirect ports accept surrounding whitespace", arguments: [" 1 ", "65535"])
    func validPortIsPreserved(port: String) throws {
        var draft = OAuthClientDraft(client: nil)
        draft.port = port
        #expect(try draft.validatedPort() == Int(port.trimmingCharacters(in: .whitespaces)))
    }

    /// A provider that serves one region publishes none, and the daemon refuses
    /// a region for it, so the sheet sends nothing at all.
    @Test("a provider offering no regions sends no region")
    func noRegionsSendsNothing() throws {
        var draft = OAuthClientDraft(client: nil)
        draft.region = "eu"

        #expect(try draft.validatedRegion(offered: []) == nil)
    }

    /// Where the provider offers regions the daemon requires one of them, so
    /// the sheet refuses before the call rather than after it.
    @Test("an offered region is sent and anything else is refused")
    func offeredRegionsAreRequired() throws {
        let offered = try OAuthClientEditingTests.regions()
        var draft = OAuthClientDraft(client: nil)

        #expect(draft.region.isEmpty, "nothing is chosen until the picker is used")
        #expect(throws: OAuthClientDraft.ValidationError.missingRegion) {
            try draft.validatedRegion(offered: offered)
        }

        draft.region = "cn"
        #expect(throws: OAuthClientDraft.ValidationError.missingRegion) {
            try draft.validatedRegion(offered: offered)
        }

        draft.region = "eu"
        #expect(try draft.validatedRegion(offered: offered) == "eu")
    }

    /// The draft opens on the region the daemon last published, so reopening the
    /// sheet to change a port does not silently re-answer the region question.
    @Test("editing a client preserves the region it is bound to")
    func preservesExistingRegion() throws {
        let client = try JSONDecoder().decode(ManagementPluginOAuthClient.self, from: Data("""
        {"provider":"tesla","configured":true,"client_id":"existing-client",
         "redirect_port":null,"region":"eu",
         "regions":[{"id":"na","label":"North America"},{"id":"eu","label":"Europe"}]}
        """.utf8))
        let draft = OAuthClientDraft(client: client)

        #expect(draft.region == "eu")
        #expect(try draft.validatedRegion(offered: client.regions) == "eu")
    }

    /// The region rides on the wire only when there is one: an absent key is
    /// what a provider serving a single region is asked for, and a null would
    /// be a value the schema does not take.
    @Test("the client parameters omit the region key when none was chosen")
    func regionIsOmittedWhenAbsent() throws {
        let withRegion = try Self.encode(
            ManagementOAuthClientParams(
                provider: "tesla",
                clientId: "client-1",
                redirectPort: nil,
                region: "eu"
            )
        )
        let without = try Self.encode(
            ManagementOAuthClientParams(
                provider: "google",
                clientId: "client-2",
                redirectPort: 1455,
                region: nil
            )
        )

        #expect(withRegion["region"] as? String == "eu")
        #expect(withRegion["redirect_port"] == nil)
        #expect(without["region"] == nil)
        #expect(without["redirect_port"] as? Int == 1455)
    }

    static func regions() throws -> [ManagementPluginOAuthRegion] {
        try JSONDecoder().decode([ManagementPluginOAuthRegion].self, from: Data("""
        [{"id":"na","label":"North America"},{"id":"eu","label":"Europe"}]
        """.utf8))
    }

    private static func encode(_ params: ManagementOAuthClientParams) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(params))

        return try #require(object as? [String: Any])
    }
}

@Suite("Coding agent availability")
struct CodingAgentAvailabilityTests {
    @Test("only installed tools can be selected, regardless of their authentication state")
    func restrictsSelectionToInstalledTools() throws {
        let availability = CodingAgentAvailability(detection: try detection())

        #expect(availability.canSelect(""))
        #expect(availability.canSelect("codex"))
        #expect(!availability.canSelect("claude"))
        #expect(!availability.canSelect("another-cli"))
        #expect(availability.canEditConsent(currentlyEnabled: false))
    }

    @Test("no installed CLI prevents enabling while preserving the ability to disable")
    func missingToolsDoNotTrapConsent() throws {
        let availability = CodingAgentAvailability(detection: try detection(installed: false))

        #expect(!availability.canEditConsent(currentlyEnabled: false))
        #expect(availability.canEditConsent(currentlyEnabled: true))
        #expect(availability.guidance == "Install a coding CLI, then restart Fermix.")
    }

    @Test("missing structured detection is unknown and never treated as installed")
    func unavailableFactsRemainUnknown() {
        let availability = CodingAgentAvailability(detection: nil)

        #expect(availability.vendors.isEmpty)
        #expect(!availability.hasFacts)
        #expect(!availability.canSelect("codex"))
        #expect(availability.canSelect(""))
    }

    @Test("installed tools retain version and authentication distinctions")
    func statusUsesDaemonFacts() throws {
        let availability = CodingAgentAvailability(detection: try detection())
        let codex = try #require(availability.vendors.first { $0.vendor == "codex" })
        let claude = try #require(availability.vendors.first { $0.vendor == "claude" })

        #expect(availability.status(for: codex) == "0.100.0 · Sign-in not verified")
        #expect(availability.status(for: claude) == "Not installed")
    }

    private func detection(installed: Bool = true) throws -> ManagementDetection {
        try JSONDecoder().decode(ManagementDetection.self, from: Data("""
        {"target":"harness_vendors","present":\(installed),"detail":null,
         "guidance":"Install a coding CLI, then restart Fermix.","vendors":[
          {"vendor":"codex","installed":\(installed),"version":"0.100.0","auth":"unverified"},
          {"vendor":"claude","installed":false,"version":null,"auth":"absent"}]}
        """.utf8))
    }
}
