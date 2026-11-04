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

    @Test("over a message of Fermix's: its origin's label, a line where it follows another of Fermix's, and nothing over a reply or a picture that continues the message above")
    func seams() {
        let job = CompanionRowOrigin(kind: .job, name: "Morning briefing")
        let cue = CompanionRowOrigin(kind: .cue, name: "release-watch")
        let picture = CompanionMediaRef(ref: String(repeating: "a", count: 64), kind: "image", mime: "image/png", sizeBytes: 10, sha256: nil, filename: "chart.png", caption: nil)
        func row(_ seq: Int, _ role: String, _ text: String, msg: String? = nil, reply: String? = nil, origin: CompanionRowOrigin? = nil, media: [CompanionMediaRef] = []) -> ChatItem {
            .row(CompanionRow(FixtureCompanionScript.row(seq, role, text, clientMsgId: msg, inReplyTo: reply, mediaRefs: media, origin: origin)))
        }

        let asked = row(1, "user", "Anything today?", msg: "m1")
        let answer = row(2, "assistant", "Two meetings.", reply: "m1")
        let reminder = row(3, "assistant", "Reminder: take an umbrella.")
        let briefing = row(4, "assistant", "Good morning.", origin: job)
        let chart = row(5, "assistant", "", origin: job, media: [picture])
        let release = row(6, "assistant", "", origin: cue, media: [picture])
        let pending = ChatItem.pending(clientMsgId: "m7", text: "Thanks", files: [])

        #expect(ChatTimeline.seam(after: asked, before: answer) == .none, "a reply to the owner")
        #expect(ChatTimeline.seam(after: answer, before: reminder) == .line, "a message with no origin after one of Fermix's")
        #expect(ChatTimeline.seam(after: reminder, before: briefing) == .origin(job))
        #expect(ChatTimeline.seam(after: asked, before: briefing) == .origin(job), "an origin is named whatever stands above it")
        #expect(ChatTimeline.seam(after: briefing, before: chart) == .none, "a picture continues the message from the same place")
        #expect(ChatTimeline.seam(after: briefing, before: release) == .origin(cue), "a picture from another place is its own message")
        #expect(ChatTimeline.seam(after: reminder, before: row(8, "assistant", "", media: [picture])) == .none)
        #expect(ChatTimeline.seam(after: pending, before: reminder) == .none, "nothing of Fermix's above it")
        #expect(ChatTimeline.seam(after: nil, before: reminder) == .none, "the first message")
        #expect(ChatTimeline.seam(after: reminder, before: asked) == .none, "the owner's own message")
        #expect(ChatTimeline.seam(after: reminder, before: row(9, "assistant", "Two meetings.", reply: "m1")) == .none, "a reply, even after another of Fermix's")
    }

    @Test("a scheduled job's label is a clock, and a cue's the glyph Settings draws Cues with")
    func glyphs() {
        #expect(ChatOriginTitle.symbol(.job) == "clock")
        #expect(ChatOriginTitle.symbol(.cue) == SettingsPane.cues.systemImage)
    }

    @Test("the fixture's replies end on a scheduled job's message and a cue's, the cue named by a watcher the goldens list, then a reminder under a line")
    func fixture() throws {
        let rows = FixtureRepliesScript.rows.map(CompanionRow.init)
        let origins = rows.compactMap(\.origin)

        #expect(origins.map(\.kind) == [.job, .cue])
        let items = rows.map(ChatItem.row)
        let seams = items.indices.suffix(3).map { ChatTimeline.seam(after: items[$0 - 1], before: items[$0]) }
        #expect(seams == [.origin(origins[0]), .origin(origins[1]), .line])

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
