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
