import Foundation
import Testing

@testable import FermixAppCore

/// A reply's blocks on the wire (M72 §8.3): carried by `text_done`, a live
/// `row` and a history message, decoded with the contract's rules, and kept
/// with the row so a change to them reshapes it. The vendored goldens carry
/// no block until the engine's are re-vendored, so the lines are built from
/// the plan's shape.
@Suite("Companion blocks")
struct CompanionBlocksTests {
    /// The plan's place, with every field it carries.
    static let fullPlace = #"""
    {"name":"Example Coffee","canonical_url":"https://example.coffee/","source_url":"https://provider.example/place/1","location":{"latitude":40.7233,"longitude":-74.0030},"address":"12 Example St, New York","rating":{"value":4.6,"best":5,"count":321},"price_range":"$$","categories":["coffee_shop"],"opening_hours":{"current_day":"Thursday 07:00-19:00"},"distance":{"value":0.4,"units":"km"}}
    """#

    /// A place with only what the contract requires, and one address.
    static let barePlace = #"""
    {"name":"Bare Cafe","source_url":"https://provider.example/place/2","location":{"latitude":40.72,"longitude":-74.0}}
    """#

    static let example = CompanionPlace(
        name: "Example Coffee",
        canonicalURL: "https://example.coffee/",
        sourceURL: "https://provider.example/place/1",
        location: CompanionPlaceLocation(latitude: 40.7233, longitude: -74.0030),
        address: "12 Example St, New York",
        rating: CompanionPlaceRating(value: 4.6, best: 5, count: 321),
        priceRange: "$$",
        categories: ["coffee_shop"],
        openingHours: CompanionPlaceHours(currentDay: "Thursday 07:00-19:00"),
        distance: CompanionPlaceDistance(value: 0.4, units: "km")
    )

    private static func textDone(blocks: String) -> Data {
        Data(#"{"type":"text_done","turn_id":"turn-1","server_seq":11,"text":"Two places.","blocks":\#(blocks)}"#.utf8)
    }

    private static func page(blocks: String) -> Data {
        Data(#"""
        {"type":"history_page","profile_id":"main","history_head_seq":11,"messages":[{"server_seq":11,"role":"assistant","content":"Two places.","ts":"2026-10-16T09:00:00Z","media_refs":[],"blocks":\#(blocks)}]}
        """#.utf8)
    }

    @Test("text_done carries its blocks, every field of a place as the plan names it")
    func textDoneCarriesItsBlocks() throws {
        let line = Self.textDone(blocks: #"[{"type":"places","places":[\#(Self.fullPlace),\#(Self.barePlace)]}]"#)

        guard case .textDone(_, _, _, let blocks) = try CompanionServerEvent.decode(line) else {
            Issue.record("the line did not decode as text_done")
            return
        }
        guard case .places(let places)? = blocks.first else {
            Issue.record("no places block")
            return
        }

        #expect(blocks.count == 1)
        #expect(places.first == Self.example)
        #expect(places.last?.name == "Bare Cafe")
        #expect(places.last?.canonicalURL == nil)
        #expect(places.last?.rating == nil)
        #expect(places.last?.openingHours == nil)
        #expect(CompanionServerWire.object(try CompanionServerEvent.decode(line)) as NSDictionary == (try wireObject(line)))
    }

    @Test("text_done without blocks has none, and writes back without the key")
    func textDoneWithoutBlocks() throws {
        let line = Data(#"{"type":"text_done","turn_id":"turn-1","server_seq":11,"text":"Done."}"#.utf8)
        let event = try CompanionServerEvent.decode(line)

        #expect(event == .textDone(turnId: "turn-1", serverSeq: 11, text: "Done."))
        #expect(CompanionServerWire.object(event) as NSDictionary == (try wireObject(line)))
    }

    @Test("a history message and a live row keep their blocks with the row")
    func rowsKeepTheirBlocks() throws {
        let blocks = #"[{"type":"places","places":[\#(Self.fullPlace)]}]"#
        guard case .historyPage(let page) = try CompanionServerEvent.decode(Self.page(blocks: blocks)),
              let exported = page.messages.first
        else {
            Issue.record("the page did not decode")
            return
        }
        let live = Data(#"""
        {"type":"row","profile_id":"main","server_seq":12,"role":"assistant","text":"One place.","ts":"2026-10-16T09:00:00Z","media_refs":[],"blocks":\#(blocks)}
        """#.utf8)
        guard case .row(let announced) = try CompanionServerEvent.decode(live) else {
            Issue.record("the row did not decode")
            return
        }

        #expect(CompanionRow(exported).blocks == [.places([Self.example])])
        #expect(CompanionRow(announced).blocks == [.places([Self.example])])
        #expect(CompanionServerWire.object(.row(announced)) as NSDictionary == (try wireObject(live)))
    }

    /// Rule 1 of the plan: the text stands alone, so a block a newer engine
    /// sends and this build cannot draw is skipped, whatever it holds, and
    /// the ones it can draw keep their order.
    @Test("a block of a type this build does not know is skipped")
    func unknownBlockIsSkipped() throws {
        let blocks = #"[{"type":"events","events":[{"title":7}]},{"type":"places","places":[\#(Self.barePlace)]},{"type":"choices"}]"#

        guard case .historyPage(let page) = try CompanionServerEvent.decode(Self.page(blocks: blocks)),
              let exported = page.messages.first
        else {
            Issue.record("the page did not decode")
            return
        }

        #expect(CompanionRow(exported).blocks.count == 1)
        guard case .places(let places)? = CompanionRow(exported).blocks.first else {
            Issue.record("the places block was not kept")
            return
        }
        #expect(places.map(\.name) == ["Bare Cafe"])
    }

    /// A misshapen block of a known type is refused with its line, as a
    /// misshapen link preview is, and the refusal names the field.
    @Test("a places block missing a required field, or with one misshapen, refuses the line by the field's name")
    func misshapenBlockIsRefused() {
        let noLocation = #"{"type":"places","places":[{"name":"Lost","source_url":"https://provider.example/place/3"}]}"#
        let wordLatitude = #"{"type":"places","places":[{"name":"Lost","location":{"latitude":"north","longitude":-74.0}}]}"#

        #expect(throws: CompanionDecodeFailure.missingField("blocks.0.places.0.location")) {
            _ = try CompanionServerEvent.decode(Self.textDone(blocks: "[\(noLocation)]"))
        }
        #expect(throws: CompanionDecodeFailure.missingField("messages.0.blocks.0.places.0.location")) {
            _ = try CompanionServerEvent.decode(Self.page(blocks: "[\(noLocation)]"))
        }
        #expect(throws: CompanionDecodeFailure.invalidField("blocks.0.places.0.location.latitude")) {
            _ = try CompanionServerEvent.decode(Self.textDone(blocks: "[\(wordLatitude)]"))
        }
        #expect(throws: CompanionDecodeFailure.missingField("blocks.0.type")) {
            _ = try CompanionServerEvent.decode(Self.textDone(blocks: #"[{"places":[]}]"#))
        }
    }

    // MARK: - The held row

    private static func held(_ seq: Int, blocks: [CompanionBlock]) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: "assistant",
            content: "Two places.",
            kind: "text",
            timestamp: "2026-10-16T09:00:00Z",
            mediaRefs: [],
            clientMsgId: nil,
            inReplyTo: nil,
            metadata: nil,
            linkPreviews: nil,
            blocks: blocks.isEmpty ? nil : CompanionBlocks(blocks)
        )
    }

    private static func chat(after events: [CompanionServerEvent]) -> CompanionChat {
        var chat = CompanionChat()
        _ = CompanionReducer.negotiated(&chat, onScreen: [])
        _ = CompanionReducer.receive(CompanionEvents.backward([8, 9, 10], head: 10), into: &chat)
        for event in events {
            _ = CompanionReducer.receive(event, into: &chat)
        }
        return chat
    }

    /// The blocks come with the turn's `text_done`, so history bringing the
    /// reply again with the same blocks changes nothing it draws.
    @Test("a reply held from text_done keeps its blocks, and history bringing them again is no change")
    func textDoneBlocksAreKept() {
        let blocks: [CompanionBlock] = [.places([Self.example])]
        let held = Self.chat(after: [.textDone(turnId: "turn-1", serverSeq: 11, text: "Two places.", blocks: blocks)])
        let replaced = Self.chat(after: [
            .textDone(turnId: "turn-1", serverSeq: 11, text: "Two places.", blocks: blocks),
            .historyPage(
                CompanionHistoryPage(
                    profileId: CompanionEvents.profile,
                    messages: [Self.held(11, blocks: blocks)],
                    historyHeadSeq: 11,
                    nextAfterSeq: 11,
                    nextBeforeSeq: nil
                )
            )
        ])

        #expect(held.rows.last?.blocks == blocks)
        #expect(replaced.rows.last?.role == "assistant")
        #expect(replaced.rows.last?.blocks == blocks)
        #expect(replaced.reshape == nil)
    }

    /// A row read again with different blocks has a different height, so the
    /// transcript holds the reader's place against it, as for its media.
    @Test("a row brought again with other blocks is a change of height")
    func changedBlocksReshape() {
        let chat = Self.chat(after: [
            .textDone(turnId: "turn-1", serverSeq: 11, text: "Two places.", blocks: []),
            CompanionMediaRows.updated(11),
            CompanionMediaRows.page([Self.held(11, blocks: [.places([Self.example])])], head: 11)
        ])

        #expect(chat.rows.last?.blocks == [.places([Self.example])])
        #expect(chat.reshape?.seqs == [11])
    }
}
