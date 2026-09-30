import Foundation
import Testing

@testable import FermixAppCore

/// The typed companion events, driven by the vendored golden fixtures.
///
/// Every fixture in both files is exercised and each direction asserts that
/// its fixtures cover every event type the schema publishes, so an event added
/// upstream fails here instead of being silently skipped.
@Suite("Companion protocol")
struct CompanionProtocolTests {
    @Test("this build declares the version, window and line cap the vendored contract publishes")
    func declaredConstantsMatchTheContract() throws {
        let schema = try CompanionFixtures.schema()
        let range = schema["x-supported-version-range"] as? [String: Any]

        #expect(schema["x-protocol-version"] as? Int == CompanionProtocol.version)
        #expect(range?["min"] as? Int == CompanionProtocol.supportedWindow.minimum)
        #expect(range?["max"] as? Int == CompanionProtocol.supportedWindow.maximum)
        #expect(CompanionProtocol.supportedWindow.contains(CompanionProtocol.version))
        #expect(schema["x-max-line-bytes"] as? Int == CompanionProtocol.maximumClientLineBytes)
    }

    /// A pull, a search or a query past the contract's bounds is `invalid_field`,
    /// which closes the connection, so the bounds the session asks for are the
    /// schema's own.
    @Test("the page, search and query bounds are the ones the vendored schema publishes")
    func requestBoundsMatchTheContract() throws {
        let pull = try CompanionFixtures.definition("history_pull")["properties"] as? [String: Any]
        let search = try CompanionFixtures.definition("history_search")["properties"] as? [String: Any]

        #expect((pull?["limit"] as? [String: Any])?["maximum"] as? Int == CompanionProtocol.historyPageLimit)
        #expect((search?["limit"] as? [String: Any])?["maximum"] as? Int == CompanionProtocol.searchLimit)
        #expect(
            (search?["query"] as? [String: Any])?["maxLength"] as? Int == CompanionProtocol.maximumSearchQueryLength
        )
    }

    @Test("every golden client event is produced by a typed value")
    func encodesEveryClientFixture() throws {
        let fixtures = try CompanionFixtures.load(.clientEvents)
        let main = CompanionProtocol.profileId
        let produced: [CompanionClientEvent] = [
            .clientHello(protocolVersion: CompanionProtocol.version),
            .msg(clientMsgId: "mac-1", profileId: main, text: "What is on my calendar today?"),
            .command(clientMsgId: "mac-2", profileId: main, name: "confirm", args: "opaque-token"),
            .cancel(profileId: main, clientMsgId: "mac-3"),
            .historyPull(profileId: main, cursor: .after(seq: 0), limit: 50),
            .historyPull(profileId: main, cursor: .before(seq: 120), limit: 50),
            .historySearch(profileId: main, query: "dentist", limit: 20, beforeSeq: nil),
            .historySearch(profileId: main, query: "dentist friday", limit: 20, beforeSeq: 88),
            .readState(profileId: main, readUpToSeq: 13)
        ]

        #expect(produced.count == fixtures.count)
        #expect(Set(fixtures.map(\.type)) == (try CompanionFixtures.publishedTypes("clientEvent")))

        for (event, fixture) in zip(produced, fixtures) {
            let line = try event.line()

            // The line socket adds the terminator, so the event must never
            // carry one of its own.
            #expect(!line.contains(0x0A), "\(fixture.type) must be exactly one line")
            #expect(event.wireType == fixture.type)
            #expect(
                try CompanionFixtures.sameObject(line, fixture.line),
                "\(fixture.type): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    @Test("every golden server event decodes and writes back as itself")
    func roundTripsEveryServerFixture() throws {
        let fixtures = try CompanionFixtures.load(.serverEvents)

        #expect(Set(fixtures.map(\.type)) == (try CompanionFixtures.publishedTypes("serverEvent")))

        for fixture in fixtures {
            let event = try CompanionServerEvent.decode(fixture.line)
            let written = CompanionServerWire.object(event)

            #expect(event.wireType == fixture.type)
            #expect(!event.isUnrecognized, "\(fixture.type) decoded as an unknown event")
            #expect(
                NSDictionary(dictionary: written).isEqual(to: fixture.object),
                "\(fixture.type) came back as \(written)"
            )
        }
    }

    @Test("the golden server events carry their fields under the Swift names")
    func serverFixtureFields() throws {
        let fixtures = try CompanionFixtures.load(.serverEvents)

        func event(_ type: String, where predicate: (CompanionFixture) -> Bool = { _ in true }) throws
            -> CompanionServerEvent {
            guard let fixture = fixtures.first(where: { $0.type == type && predicate($0) }) else {
                throw CompanionFixtureDefect.fileIsEmpty(file: type)
            }
            return try CompanionServerEvent.decode(fixture.line)
        }

        #expect(try event("server_hello") == .serverHello(minVersion: 1, maxVersion: 1))

        let duplicate = try event("accepted") { $0.object["duplicate"] as? Bool == true }
        #expect(duplicate == .accepted(CompanionAccepted(clientMsgId: "mac-1", duplicate: true, serverSeq: 13)))

        let stopped = try event("tool_event") { $0.object["detail"] != nil }
        #expect(
            stopped == .toolEvent(
                CompanionToolEvent(turnId: "turn-mac-1", tool: "web_search", phase: .stop, detail: "%{status: :ok}")
            )
        )
        #expect(try event("text_done") == .textDone(turnId: "turn-mac-1", serverSeq: 13, text: "You have one meeting, at 10."))
        #expect(try event("turn_error") == .turnError(turnId: "turn-mac-3", code: "cancelled", message: "cancelled"))
        #expect(
            try event("approval_resolved") == .approvalResolved(
                approvalId: "sandbox-bhw-xTAySHRgYU9X7p4sNoI3EvHmKLZlouMRAn73iic",
                outcome: .approved
            )
        )

        guard case .historyPage(let backward) = try event("history_page", where: { $0.object["next_before_seq"] != nil })
        else {
            Issue.record("the backward history page did not decode as a page")
            return
        }
        #expect(backward.nextBeforeSeq == 70)
        #expect(backward.nextAfterSeq == nil)
        #expect(backward.messages.map(\.serverSeq) == [70])

        guard case .searchResults(let results) = try event("search_results") else {
            Issue.record("the search results did not decode as results")
            return
        }
        #expect(results.hits.first?.ranges == [CompanionMatchRange(start: 9, length: 7)])

        guard case .error(let refusal) = try event("error", where: { $0.object["direction"] != nil }) else {
            Issue.record("the version refusal did not decode as an error")
            return
        }
        #expect(refusal.reason == "unsupported_protocol_version")
        #expect(refusal.direction == .clientTooNew)
        #expect(refusal.clientVersion == 2)
        #expect(refusal.window == CompanionVersionWindow(minimum: 1, maximum: 1))
    }

    /// The contract takes exactly one cursor, and the Swift value is the only
    /// way to write a pull, so both and neither are unrepresentable rather
    /// than refused at run time. What is provable is that the schema's rule is
    /// still that one, and that each case writes its own cursor and not the
    /// other.
    @Test("a history pull carries exactly one cursor, the schema's either-or")
    func historyPullCarriesExactlyOneCursor() throws {
        let oneOf = try CompanionFixtures.definition("history_pull")["oneOf"] as? [[String: Any]]
        let alternatives = oneOf?.compactMap { $0["required"] as? [String] }

        #expect(alternatives == [["after_seq"], ["before_seq"]])

        let cases: [(CompanionHistoryCursor, carried: String, absent: String)] = [
            (.after(seq: 0), "after_seq", "before_seq"),
            (.before(seq: 1), "before_seq", "after_seq")
        ]
        for (cursor, carried, absent) in cases {
            let event = CompanionClientEvent.historyPull(profileId: CompanionProtocol.profileId, cursor: cursor, limit: 1)
            let object = try JSONSerialization.jsonObject(with: try event.line()) as? [String: Any]

            #expect(object?[carried] != nil, "\(cursor) did not write \(carried)")
            #expect(object?[absent] == nil, "\(cursor) wrote \(absent) as well")
        }
    }

    /// Absent is absent: an optional this client has no value for is a missing
    /// key, never an explicit null.
    @Test("an absent optional is an absent key")
    func absentOptionalsAreAbsentKeys() throws {
        let command = CompanionClientEvent.command(
            clientMsgId: "mac-5",
            profileId: CompanionProtocol.profileId,
            name: "status",
            args: nil
        )
        let line = String(decoding: try command.line(), as: UTF8.self)

        #expect(!line.contains("args"))
        #expect(!line.contains("null"))
    }

    /// The daemon refuses a longer client line and closes the connection, so
    /// the line is refused here, at the cap and not a byte later.
    @Test("a client line over the contract's cap is refused")
    func clientLineOverTheCapIsRefused() throws {
        func message(_ text: String) -> CompanionClientEvent {
            .msg(clientMsgId: "mac-6", profileId: CompanionProtocol.profileId, text: text)
        }
        let overhead = try message("").line().count
        let cap = CompanionProtocol.maximumClientLineBytes
        let longest = String(repeating: "a", count: cap - overhead)

        #expect(try message(longest).line().count == cap)
        #expect(throws: CompanionEncodeFailure.lineTooLarge(bytes: cap + 1)) {
            _ = try message(longest + "a").line()
        }
    }

    @Test("a missing required field is refused by its name")
    func missingFieldIsNamed() {
        #expect(throws: CompanionDecodeFailure.missingField("client_msg_id")) {
            _ = try CompanionServerEvent.decode(Data(#"{"type":"accepted","duplicate":false}"#.utf8))
        }
        #expect(throws: CompanionDecodeFailure.missingField("min_version")) {
            _ = try CompanionServerEvent.decode(Data(#"{"type":"server_hello","max_version":1}"#.utf8))
        }

        let page = #"{"type":"history_page","profile_id":"main","history_head_seq":1,"#
            + #""messages":[{"server_seq":1,"role":"user","ts":"2026-09-25T09:00:00Z","media_refs":[]}]}"#
        #expect(throws: CompanionDecodeFailure.missingField("messages.0.content")) {
            _ = try CompanionServerEvent.decode(Data(page.utf8))
        }
    }

    @Test("a field of the wrong shape is refused by its name")
    func invalidFieldIsNamed() {
        #expect(throws: CompanionDecodeFailure.invalidField("server_seq")) {
            _ = try CompanionServerEvent.decode(
                Data(#"{"type":"text_done","turn_id":"t","server_seq":"13","text":"x"}"#.utf8)
            )
        }
        #expect(throws: CompanionDecodeFailure.invalidField("direction")) {
            _ = try CompanionServerEvent.decode(
                Data(#"{"type":"error","reason":"unsupported_protocol_version","direction":"sideways"}"#.utf8)
            )
        }
    }

    @Test("a line that is not an object, or has no type, is refused")
    func structurallyInvalidLinesAreRefused() {
        #expect(throws: CompanionDecodeFailure.notAnObject) {
            _ = try CompanionServerEvent.decode(Data("[1,2,3]".utf8))
        }
        #expect(throws: CompanionDecodeFailure.missingType) {
            _ = try CompanionServerEvent.decode(Data(#"{"turn_id":"t"}"#.utf8))
        }
        #expect(throws: CompanionDecodeFailure.malformedJSON) {
            _ = try CompanionServerEvent.decode(Data("{not json".utf8))
        }
    }

    /// Rule 5 of the contract: an unrecognized server event is logged, never
    /// silently dropped, so it decodes to a value that carries its type.
    @Test("an unknown event type is preserved and never fatal")
    func unknownEventIsPreserved() throws {
        let event = try CompanionServerEvent.decode(Data(#"{"type":"weather","sunny":true}"#.utf8))

        #expect(event == .unrecognized(type: "weather"))
        #expect(event.isUnrecognized)
    }

    @Test("an unseen tool phase or approval outcome keeps its own word")
    func unseenVocabularyIsPreserved() throws {
        let tool = try CompanionServerEvent.decode(
            Data(#"{"type":"tool_event","turn_id":"t","tool":"shell","phase":"progress"}"#.utf8)
        )
        let resolved = try CompanionServerEvent.decode(
            Data(#"{"type":"approval_resolved","approval_id":"a","outcome":"withdrawn"}"#.utf8)
        )

        #expect(tool == .toolEvent(CompanionToolEvent(turnId: "t", tool: "shell", phase: .unrecognized("progress"), detail: nil)))
        #expect(resolved == .approvalResolved(approvalId: "a", outcome: .unrecognized("withdrawn")))
    }

    @Test("a version window names the side that must update")
    func windowNamesTheOutdatedSide() {
        let window = CompanionVersionWindow(minimum: 2, maximum: 3)

        #expect(window.contains(2))
        #expect(!window.contains(CompanionProtocol.version))
        #expect(window.direction(for: 1) == .clientTooOld)
        #expect(window.direction(for: 4) == .clientTooNew)
    }
}

/// The inbound framing bounds, driven directly rather than through a socket:
/// the line socket's reader, with the companion wire's bounds and decoder, must
/// refuse an over-length daemon line before it is turned into an event.
@Suite("Companion inbound framing")
struct CompanionInboundFramingTests {
    private func companionBuffer() -> LineInboundBuffer<CompanionServerEvent, CompanionDecodeFailure> {
        LineInboundBuffer(limits: CompanionProtocol.inboundLimits) { line throws(CompanionDecodeFailure) in
            try CompanionServerEvent.decode(line)
        }
    }

    @Test("the published bounds are one line of 16 MiB and 32 MiB of inbound buffer")
    func publishedBounds() {
        #expect(
            CompanionProtocol.inboundLimits
                == LineInboundLimits(maximumLineBytes: 16_777_216, maximumBufferedBytes: 33_554_432)
        )
    }

    @Test("complete lines are delivered in order")
    func deliversCompleteLines() throws {
        var buffer = companionBuffer()
        var events: [CompanionServerEvent] = []
        let stream = #"{"type":"server_hello","min_version":1,"max_version":1}"# + "\n"
            + #"{"type":"text_delta","turn_id":"t","text":" and "}"# + "\n"

        try buffer.append(Data(stream.utf8)) { events.append($0) }

        #expect(events == [.serverHello(minVersion: 1, maxVersion: 1), .textDelta(turnId: "t", text: " and ")])
    }

    @Test("a daemon line longer than this client's bound is refused")
    func refusesAnOversizedLine() {
        var buffer = companionBuffer()
        let limit = CompanionProtocol.inboundLimits.maximumLineBytes
        let oversized = Data(repeating: 0x41, count: limit + 1) + Data("\n".utf8)

        #expect(throws: LineSocketFailure<CompanionDecodeFailure>.framingViolation(.lineTooLong(bytes: limit + 1))) {
            try buffer.append(oversized) { _ in }
        }
    }

    @Test("a line that is not an event is refused with the decoder's reason")
    func refusesAnUndecodableLine() {
        var buffer = companionBuffer()
        let stream = #"{"type":"accepted","duplicate":false}"# + "\n"

        #expect(throws: LineSocketFailure<CompanionDecodeFailure>.undecodable(.missingField("client_msg_id"))) {
            try buffer.append(Data(stream.utf8)) { _ in }
        }
    }
}
