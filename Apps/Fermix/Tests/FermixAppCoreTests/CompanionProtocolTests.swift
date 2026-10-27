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
            .cancelTask(
                profileId: main,
                clientMsgId: "mac-4",
                task: CompanionTaskRef(callUuid: "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b", taskId: "dg_01HA", revision: 1)
            ),
            .historyPull(profileId: main, cursor: .after(seq: 0), limit: 50),
            .historyPull(profileId: main, cursor: .before(seq: 120), limit: 50),
            .historySearch(profileId: main, query: "dentist", limit: 20, beforeSeq: nil),
            .historySearch(profileId: main, query: "dentist friday", limit: 20, beforeSeq: 88),
            .readState(profileId: main, readUpToSeq: 13),
            .mediaFetch(profileId: main, ref: "9879f6d3c9efefe8c4f4aabe9d3269762264be52794e96f62ab8ffa53b7fadec"),
            .mediaRelease(profileId: main, ref: "9879f6d3c9efefe8c4f4aabe9d3269762264be52794e96f62ab8ffa53b7fadec"),
            .proposalAnswer(clientMsgId: "mac-10", profileId: main, proposalId: "cpr_4f1c2a9b7e3d5a60c8b1f2e3", decision: .confirm),
            .proposalAnswer(clientMsgId: "mac-11", profileId: main, proposalId: "cpr_9a0b1c2d3e4f5a6b7c8d9e0f", decision: .deny)
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

        #expect(try event("server_hello") == .serverHello(minVersion: 3, maxVersion: 4))

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
        #expect(try event("turn_done") == .turnDone(turnId: "turn-mac-5"))

        guard case .row(let call) = try event("row", where: { $0.object["metadata"] != nil }) else {
            Issue.record("no golden row carries a Live call's metadata")
            return
        }
        #expect(call.kind == "text")
        guard case .object(let facts)? = call.metadata?["call"] else {
            Issue.record("the call row's metadata has no call")
            return
        }
        #expect(facts["event"] == .string("shared"))
        #expect(facts["task_id"] == .string("dg_01H9"))
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
        #expect(refusal.clientVersion == 5)
        #expect(refusal.window == CompanionVersionWindow(minimum: 3, maximum: 4))
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
    /// The vendored goldens carry no preview, so the line is built in the
    /// schema's `linkPreviewCard` shape: with and without its optional fields.
    @Test("a history row keeps its media refs and its stored link previews")
    func historyRowKeepsItsMedia() throws {
        let line = Data(#"""
        {"type":"history_page","profile_id":"main","history_head_seq":7,"messages":[{"server_seq":7,"role":"user","content":"see https://x.test/a and https://y.test","kind":"media","ts":"2026-10-11T17:16:19Z","media_refs":[{"ref":"3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3","kind":"audio","mime":"audio/ogg","size_bytes":33419,"filename":"voice-note.ogg"}],"link_previews":[{"url":"https://x.test/a","site":"X","title":"A page","description":"What it says","image_ref":"9214332e155bb4042b5019c575d43397cba703a76fe3246218546f13d4055569"},{"url":"https://www.y.test/","site":"Y","title":"Y home"}]}]}
        """#.utf8)

        guard case .historyPage(let page) = try CompanionServerEvent.decode(line), let exported = page.messages.first else {
            Issue.record("the page did not decode")
            return
        }
        let row = CompanionRow(exported)

        #expect(row.mediaRefs.map(\.kind) == ["audio"])
        #expect(row.mediaRefs.first?.filename == "voice-note.ogg")
        #expect(row.linkPreviews == [
            CompanionLinkPreview(
                link: nil,
                url: "https://x.test/a",
                site: "X",
                title: "A page",
                description: "What it says",
                imageRef: "9214332e155bb4042b5019c575d43397cba703a76fe3246218546f13d4055569"
            ),
            CompanionLinkPreview(link: nil, url: "https://www.y.test/", site: "Y", title: "Y home", description: nil, imageRef: nil)
        ])
    }

    // MARK: - Version 3

    /// The vendored goldens are version 2 until the engine's version 3 is
    /// re-vendored, so these lines are built from the contract's shapes.
    @Test("a live row carries its media refs and link previews in the history message's shapes")
    func announcedRowKeepsItsMedia() throws {
        let line = Data(#"""
        {"type":"row","profile_id":"main","server_seq":21,"role":"user","text":"","ts":"2026-10-15T09:00:00Z","kind":"media","media_refs":[{"ref":"3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3","kind":"audio","mime":"audio/ogg","size_bytes":48213,"sha256":"3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3"}],"link_previews":[{"url":"https://x.test/a","site":"X","title":"A page","image_ref":"9214332e155bb4042b5019c575d43397cba703a76fe3246218546f13d4055569"}]}
        """#.utf8)

        guard case .row(let announced) = try CompanionServerEvent.decode(line) else {
            Issue.record("the row did not decode as a row")
            return
        }
        let row = CompanionRow(announced)

        #expect(row.mediaRefs.map(\.mime) == ["audio/ogg"])
        #expect(row.mediaRefs.first?.sizeBytes == 48213)
        #expect(row.linkPreviews.map(\.imageRef) == ["9214332e155bb4042b5019c575d43397cba703a76fe3246218546f13d4055569"])
        #expect(CompanionServerWire.object(.row(announced)) as NSDictionary == (try wireObject(line)))
    }

    @Test("a live row's media refs are required, possibly empty, and its link previews optional")
    func announcedRowMediaRefsAreRequired() throws {
        let bare = #"{"type":"row","profile_id":"main","server_seq":3,"role":"assistant","text":"Done.","ts":"2026-10-15T09:00:00Z""#
        guard case .row(let empty) = try CompanionServerEvent.decode(Data((bare + #","media_refs":[]}"#).utf8)) else {
            Issue.record("the row did not decode as a row")
            return
        }

        #expect(empty.mediaRefs.isEmpty)
        #expect(empty.linkPreviews == nil)
        #expect(throws: CompanionDecodeFailure.missingField("media_refs")) {
            _ = try CompanionServerEvent.decode(Data((bare + "}").utf8))
        }
    }

    @Test("a grant, a missing file and a changed row decode under the Swift names and write back as themselves")
    func versionThreeServerEvents() throws {
        let ref = "3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3"
        let lines: [(String, CompanionServerEvent)] = [
            (
                #"{"type":"media_path","ref":"\#(ref)","path":"/Users/me/.fermix/companion/media/\#(ref).ogg","kind":"audio","mime":"audio/ogg","size_bytes":48213,"sha256":"\#(ref)"}"#,
                .mediaPath(CompanionMediaPath(
                    ref: ref,
                    path: "/Users/me/.fermix/companion/media/\(ref).ogg",
                    kind: "audio",
                    mime: "audio/ogg",
                    sizeBytes: 48213,
                    sha256: ref
                ))
            ),
            (#"{"type":"media_missing","ref":"\#(ref)"}"#, .mediaMissing(ref: ref)),
            (#"{"type":"row_updated","profile_id":"main","server_seq":21}"#, .rowUpdated(profileId: "main", serverSeq: 21))
        ]

        for (line, expected) in lines {
            let event = try CompanionServerEvent.decode(Data(line.utf8))

            #expect(event == expected)
            #expect(!event.isUnrecognized)
            #expect(CompanionServerWire.object(event) as NSDictionary == (try wireObject(Data(line.utf8))))
        }
        #expect(throws: CompanionDecodeFailure.missingField("sha256")) {
            _ = try CompanionServerEvent.decode(Data(#"{"type":"media_path","ref":"\#(ref)","path":"/p","kind":"audio","mime":"audio/ogg","size_bytes":1}"#.utf8))
        }
        #expect(throws: CompanionDecodeFailure.missingField("server_seq")) {
            _ = try CompanionServerEvent.decode(Data(#"{"type":"row_updated","profile_id":"main"}"#.utf8))
        }
    }

    @Test("a failed grant's error names its ref, and every other error names none")
    func errorCarriesItsRef() throws {
        let ref = "3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3"
        let failed = try CompanionServerEvent.decode(
            Data(#"{"type":"error","reason":"request_failed","message":"the copy could not be made","ref":"\#(ref)"}"#.utf8)
        )
        let other = try CompanionServerEvent.decode(Data(#"{"type":"error","reason":"unsupported_profile"}"#.utf8))

        guard case .error(let grant) = failed, case .error(let refusal) = other else {
            Issue.record("the errors did not decode as errors")
            return
        }
        #expect(grant.ref == ref)
        #expect(grant.reason == "request_failed")
        #expect(refusal.ref == nil)
    }

    @Test("a media fetch and a media release carry the profile and the ref")
    func mediaClientEvents() throws {
        let ref = "3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3"
        let fetch = CompanionClientEvent.mediaFetch(profileId: CompanionProtocol.profileId, ref: ref)
        let release = CompanionClientEvent.mediaRelease(profileId: CompanionProtocol.profileId, ref: ref)

        #expect(try wireObject(fetch.line()) == ["type": "media_fetch", "profile_id": "main", "ref": ref] as NSDictionary)
        #expect(try wireObject(release.line()) == ["type": "media_release", "profile_id": "main", "ref": ref] as NSDictionary)
    }

    @Test("a media ref is 64 lowercase hex digits and nothing else")
    func mediaRefShape() {
        #expect(CompanionProtocol.isMediaRef(String(repeating: "0", count: 32) + String(repeating: "f", count: 32)))
        #expect(CompanionProtocol.isMediaRef("3f46f7693efbeb011de675f80f03d6e94717a4150e38a1bac1e6dad75a0d95c3"))
        #expect(!CompanionProtocol.isMediaRef(""))
        #expect(!CompanionProtocol.isMediaRef(String(repeating: "a", count: 63)))
        #expect(!CompanionProtocol.isMediaRef(String(repeating: "a", count: 65)))
        #expect(!CompanionProtocol.isMediaRef(String(repeating: "A", count: 64)))
        #expect(!CompanionProtocol.isMediaRef(String(repeating: "g", count: 64)))
        #expect(!CompanionProtocol.isMediaRef("../" + String(repeating: "a", count: 61)))
        #expect(!CompanionProtocol.isMediaRef(String(repeating: "é", count: 32)))
    }

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
        let window = CompanionVersionWindow(minimum: CompanionProtocol.version + 1, maximum: CompanionProtocol.version + 2)

        #expect(window.contains(CompanionProtocol.version + 1))
        #expect(!window.contains(CompanionProtocol.version))
        #expect(window.direction(for: CompanionProtocol.version) == .clientTooOld)
        #expect(window.direction(for: CompanionProtocol.version + 3) == .clientTooNew)
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
