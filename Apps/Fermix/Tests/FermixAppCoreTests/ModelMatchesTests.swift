import Testing

@testable import FermixAppCore

/// The dropdown of a typed model row (owner, 2026-09-28): the daemon's
/// suggestions until something is typed, then what its listing matches.
@MainActor
@Suite("Model matches")
struct ModelMatchesTests {
    /// A listing that answers each query with models named after it, and
    /// remembers what it was asked.
    final class RecordingListing {
        private(set) var queries: [String] = []
        var refuse = false

        func answer(_ query: String, from page: ManagementProviderModels) -> ModelListingOutcome {
            queries.append(query)
            if refuse { return .refused("the provider did not answer") }
            let models = ["\(query)-1", "\(query)-2"].map { ManagementProviderModel(id: $0, label: $0) }
            return .page(ManagementProviderModels(models: models, cursor: nil, source: page.source, truncated: false))
        }
    }

    static func fixturePage() async throws -> ManagementProviderModels {
        try await SettingsFixture.gateway().providerModels(provider: "openrouter", live: true, query: nil, cursor: nil, limit: nil)
    }

    static func matches(_ listing: RecordingListing, suggestions: [String] = ["a", "b"]) async throws -> ModelMatches {
        let page = try await fixturePage()
        return ModelMatches(suggestions: suggestions, debounce: .zero) { query in listing.answer(query, from: page) }
    }

    @Test("nothing typed lists the daemon's suggestions and asks nothing")
    func nothingTyped() async throws {
        let listing = RecordingListing()
        let matches = try await Self.matches(listing)

        #expect(matches.items == ["a", "b"])
        matches.search("   ")
        await matches.settle()
        #expect(matches.items == ["a", "b"])
        #expect(listing.queries.isEmpty)
    }

    @Test("typing asks the listing for what was typed and lists its models")
    func typingLists() async throws {
        let listing = RecordingListing()
        let matches = try await Self.matches(listing)

        matches.search(" gpt ")
        await matches.settle()

        #expect(listing.queries == ["gpt"])
        #expect(matches.items == ["gpt-1", "gpt-2"])
    }

    @Test("a newer query supersedes an older one, and clearing goes back to the suggestions")
    func newerQueryWins() async throws {
        let listing = RecordingListing()
        let matches = try await Self.matches(listing)

        matches.search("g")
        matches.search("gp")
        await matches.settle()
        #expect(matches.items == ["gp-1", "gp-2"])

        matches.search("")
        #expect(matches.items == ["a", "b"])
    }

    @Test("a refusal leaves the last list standing")
    func refusalKeepsTheList() async throws {
        let listing = RecordingListing()
        let matches = try await Self.matches(listing)
        matches.search("gpt")
        await matches.settle()

        listing.refuse = true
        matches.search("claude")
        await matches.settle()

        #expect(listing.queries == ["gpt", "claude"])
        #expect(matches.items == ["gpt-1", "gpt-2"])
    }

    /// The row's listing is the daemon's own, live, for the row's provider:
    /// the same call the paginated picker makes.
    @Test("through the settings model the dropdown lists the daemon's live listing")
    func throughTheSettingsModel() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let matches = ModelMatches(suggestions: [], debounce: .zero) { query in
            await model.models(provider: "openrouter", live: true, query: query, cursor: nil)
        }

        matches.search("claude")
        await matches.settle()

        #expect(gateway.calls.contains(.v2(.providersModelsList)))
        let page = try await Self.fixturePage()
        #expect(matches.items == page.models.map(\.id))
        #expect(!matches.items.isEmpty)
    }
}
