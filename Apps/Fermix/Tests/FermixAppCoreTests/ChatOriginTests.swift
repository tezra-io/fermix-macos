import Foundation
import Testing

@testable import FermixAppCore

/// Where a message Fermix sent on its own came from (`metadata.origin`), the
/// label Chat draws over it, and the watcher's page a cue's label opens.
@Suite("Chat origin")
@MainActor
struct ChatOriginTests {
    @Test("a row's metadata names a scheduled job or a cue by name, and anything else names none")
    func reads() {
        func origin(_ value: CompanionJSONValue?) -> CompanionRowOrigin? {
            CompanionRowOrigin(metadata: value.map { ["origin": $0] })
        }

        #expect(
            origin(.object(["kind": .string("job"), "name": .string("Morning briefing")]))
                == CompanionRowOrigin(kind: .job, name: "Morning briefing")
        )
        #expect(
            origin(.object(["kind": .string("cue"), "name": .string("release-watch")]))
                == CompanionRowOrigin(kind: .cue, name: "release-watch")
        )
        #expect(origin(nil) == nil)
        #expect(CompanionRowOrigin(metadata: nil) == nil)
        #expect(CompanionRowOrigin(metadata: ["call": .object(["event": .string("ended")])]) == nil, "a call's row names none")
        #expect(origin(.object(["kind": .string("reminder"), "name": .string("Umbrella")])) == nil, "a kind this build does not know")
        #expect(origin(.object(["kind": .string("cue"), "name": .string("")])) == nil)
        #expect(origin(.object(["kind": .string("cue")])) == nil)
        #expect(origin(.string("cue")) == nil)
    }

    @Test("a history row and a live row carry their origin, and a row that gains one draws anew")
    func rowsCarryIt() throws {
        let job = CompanionRowOrigin(kind: .job, name: "Morning briefing")
        let labelled = CompanionRow(FixtureCompanionScript.row(15, "assistant", "Good morning.", origin: job))
        let plain = CompanionRow(FixtureCompanionScript.row(15, "assistant", "Good morning."))

        #expect(labelled.origin == job)
        #expect(plain.origin == nil)
        #expect(!labelled.drawsAlike(plain), "the label changes the row's height")

        let line = #"{"type":"row","profile_id":"main","server_seq":30,"role":"assistant","text":"The release is out.","ts":"2026-11-02T09:30:00Z","kind":"text","metadata":{"origin":{"kind":"cue","name":"release-watch"}},"media_refs":[]}"#
        guard case .row(let announced) = try CompanionServerEvent.decode(Data(line.utf8)) else {
            Issue.record("a live row did not decode as a row")
            return
        }
        #expect(CompanionRow(announced).origin == CompanionRowOrigin(kind: .cue, name: "release-watch"))
    }

    @Test("the engine's golden rows name a cue by its watcher and a job by its name, on a live row and a history page alike")
    func goldens() throws {
        let fixtures = try CompanionFixtures.load(.serverEvents)
        let events = try fixtures.filter { $0.type == "row" || $0.type == "history_page" }.map { try CompanionServerEvent.decode($0.line) }

        let live = events.compactMap { event -> CompanionRow? in
            guard case .row(let row) = event else { return nil }
            return CompanionRow(row)
        }
        let paged = events.flatMap { event -> [CompanionRow] in
            guard case .historyPage(let page) = event else { return [] }
            return page.messages.map(CompanionRow.init)
        }

        #expect(live.compactMap(\.origin).contains(CompanionRowOrigin(kind: .cue, name: "codex-limits")))
        #expect(live.compactMap(\.origin).contains(CompanionRowOrigin(kind: .job, name: "Morning briefing")))
        #expect(paged.compactMap(\.origin).contains(CompanionRowOrigin(kind: .job, name: "Morning briefing")))
        #expect(live.filter { ChatSpeaker.isUser($0.role) }.allSatisfy { $0.origin == nil }, "the owner's own rows name none")
    }

    @Test("a scheduled job's label is a clock, and a cue's the glyph Settings draws Cues with")
    func glyphs() {
        #expect(ChatOriginTitle.symbol(.job) == "clock")
        #expect(ChatOriginTitle.symbol(.cue) == SettingsPane.cues.systemImage)
    }

    @Test("the fixture's replies end on a scheduled job's message and a cue's, the cue named by a watcher the goldens list")
    func fixture() throws {
        let rows = FixtureRepliesScript.rows.map(CompanionRow.init)
        let origins = rows.compactMap(\.origin)

        #expect(origins.map(\.kind) == [.job, .cue])
        #expect(rows.suffix(2).allSatisfy { $0.origin != nil && !ChatSpeaker.isUser($0.role) })

        let watchers: ManagementCueWatcherList = try FakeDaemonGateway.fixtureResult(named: "cues_watchers_list", as: ManagementCueWatcherList.self)
        let cue = try #require(origins.first { $0.kind == .cue })
        #expect(watchers.watchers.map(\.name).contains(cue.name), "its label opens a page the fixture can draw")
    }

    @Test("a cue's label selects Cues with its watcher's page asked for, which opens once")
    func opensTheWatcher() throws {
        let harness = try SettingsHarness()

        harness.model.showCueWatcher("release-watch")

        #expect(harness.model.selectedPane == .cues)
        #expect(harness.model.takeAskedCuesPage() == .watcher("release-watch"))
        #expect(harness.model.takeAskedCuesPage() == nil, "it opens once")
        #expect(harness.model.askedCuesPage == nil)
    }
}
