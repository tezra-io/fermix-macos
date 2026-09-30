import Foundation

@testable import FermixAppCore

/// Loading helpers for the vendored golden companion fixtures.
///
/// The companion fixture files are bare newline-delimited wire events (no name
/// wrapper), so they are read as objects and matched by their `type`.
enum CompanionFixtureDefect: Error, Equatable {
    case recordIsNotAnObject(file: String, line: Int)
    case recordHasNoType(file: String, line: Int)
    case fileIsEmpty(file: String)
    case schemaFieldMissing(String)
}

struct CompanionFixture {
    let type: String
    let line: Data
    let object: [String: Any]
}

enum CompanionFixtureFile: String, CaseIterable {
    case clientEvents = "fixtures/client_events.jsonl"
    case serverEvents = "fixtures/server_events.jsonl"
}

enum CompanionFixtures {
    static func load(_ file: CompanionFixtureFile) throws -> [CompanionFixture] {
        let data = try VendoredContracts.data(.companion, file.rawValue)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw CompanionFixtureDefect.fileIsEmpty(file: file.rawValue)
        }

        return try lines.enumerated().map { index, line in
            let raw = Data(line.utf8)
            let decoded = try JSONSerialization.jsonObject(with: raw)
            guard let object = decoded as? [String: Any] else {
                throw CompanionFixtureDefect.recordIsNotAnObject(file: file.rawValue, line: index + 1)
            }
            guard let type = object["type"] as? String else {
                throw CompanionFixtureDefect.recordHasNoType(file: file.rawValue, line: index + 1)
            }
            return CompanionFixture(type: type, line: raw, object: object)
        }
    }

    /// The vendored schema, as an object.
    static func schema() throws -> [String: Any] {
        let data = try VendoredContracts.data(.companion, "protocol.schema.json")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompanionFixtureDefect.schemaFieldMissing("$")
        }
        return object
    }

    /// One `$defs` entry of the schema.
    static func definition(_ name: String) throws -> [String: Any] {
        let definitions = try schema()["$defs"] as? [String: Any]
        guard let definition = definitions?[name] as? [String: Any] else {
            throw CompanionFixtureDefect.schemaFieldMissing("$defs.\(name)")
        }
        return definition
    }

    /// The event types a direction's schema definition publishes.
    static func publishedTypes(_ definition: String) throws -> Set<String> {
        let properties = try self.definition(definition)["properties"] as? [String: Any]
        let type = properties?["type"] as? [String: Any]
        guard let types = type?["enum"] as? [String] else {
            throw CompanionFixtureDefect.schemaFieldMissing("$defs.\(definition).properties.type.enum")
        }
        return Set(types)
    }

    /// Compares two wire lines as objects, so a key-order difference between an
    /// encoder and a golden file is not read as a contract difference.
    static func sameObject(_ produced: Data, _ golden: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: produced)
        let right = try JSONSerialization.jsonObject(with: golden)
        guard let left = left as? [String: Any], let right = right as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}

/// The daemon's side of the wire, written back for the round trip.
///
/// The app never sends a server event, so this writer lives with the tests. It
/// spells every wire name itself rather than borrowing the decoder's, so a
/// golden line that does not come back as itself names a field the decoder
/// dropped, renamed or invented. An absent optional is an absent key.
enum CompanionServerWire {
    static func object(_ event: CompanionServerEvent) -> [String: Any] {
        fields(event).merging(["type": event.wireType]) { _, type in type }
    }

    private static func fields(_ event: CompanionServerEvent) -> [String: Any] {
        switch event {
        case .serverHello(let minVersion, let maxVersion):
            return ["min_version": minVersion, "max_version": maxVersion]
        case .accepted(let accepted):
            return present([
                "client_msg_id": accepted.clientMsgId,
                "duplicate": accepted.duplicate,
                "server_seq": accepted.serverSeq
            ])
        case .turnStarted(let profileId, let turnId, let inReplyTo):
            return ["profile_id": profileId, "turn_id": turnId, "in_reply_to": inReplyTo]
        case .textDelta(let turnId, let text):
            return ["turn_id": turnId, "text": text]
        case .toolEvent(let tool):
            return present([
                "turn_id": tool.turnId,
                "tool": tool.tool,
                "phase": word(tool.phase),
                "detail": tool.detail
            ])
        case .textDone(let turnId, let serverSeq, let text):
            return ["turn_id": turnId, "server_seq": serverSeq, "text": text]
        case .turnError(let turnId, let code, let message):
            return ["turn_id": turnId, "code": code, "message": message]
        case .row(let row):
            return announced(row)
        case .approval(let approval):
            return approvalFields(approval)
        case .approvalResolved(let approvalId, let outcome):
            return ["approval_id": approvalId, "outcome": word(outcome)]
        case .readState(let profileId, let readUpToSeq):
            return ["profile_id": profileId, "read_up_to_seq": readUpToSeq]
        case .historyPage(let page):
            return pageFields(page)
        case .searchResults(let results):
            return present([
                "profile_id": results.profileId,
                "query": results.query,
                "hits": results.hits.map(hit),
                "next_before_seq": results.nextBeforeSeq
            ])
        case .error(let error):
            return errorFields(error)
        case .unrecognized:
            return [:]
        }
    }

    private static func present(_ fields: [String: Any?]) -> [String: Any] {
        fields.compactMapValues { $0 }
    }

    private static func word(_ phase: CompanionToolPhase) -> String {
        switch phase {
        case .start: return "start"
        case .stop: return "stop"
        case .unrecognized(let word): return word
        }
    }

    private static func word(_ outcome: CompanionApprovalOutcome) -> String {
        switch outcome {
        case .approved: return "approved"
        case .denied: return "denied"
        case .expired: return "expired"
        case .unrecognized(let word): return word
        }
    }

    private static func announced(_ row: CompanionAnnouncedRow) -> [String: Any] {
        present([
            "profile_id": row.profileId,
            "server_seq": row.serverSeq,
            "role": row.role,
            "text": row.text,
            "ts": row.timestamp,
            "client_msg_id": row.clientMsgId
        ])
    }

    private static func approvalFields(_ approval: CompanionApproval) -> [String: Any] {
        present([
            "approval_id": approval.approvalId,
            "kind": approval.kind,
            "text": approval.text,
            "detail": approval.detail,
            "token": approval.token,
            "ttl_s": approval.ttlSeconds,
            "approve_command": approval.approveCommand,
            "deny_command": approval.denyCommand
        ])
    }

    private static func pageFields(_ page: CompanionHistoryPage) -> [String: Any] {
        present([
            "profile_id": page.profileId,
            "messages": page.messages.map(timelineRow),
            "history_head_seq": page.historyHeadSeq,
            "next_after_seq": page.nextAfterSeq,
            "next_before_seq": page.nextBeforeSeq
        ])
    }

    private static func timelineRow(_ row: CompanionTimelineRow) -> [String: Any] {
        present([
            "server_seq": row.serverSeq,
            "role": row.role,
            "content": row.content,
            "kind": row.kind,
            "ts": row.timestamp,
            "media_refs": row.mediaRefs.map(mediaRef),
            "client_msg_id": row.clientMsgId,
            "in_reply_to": row.inReplyTo,
            "metadata": row.metadata.map { $0.mapValues(value) }
        ])
    }

    private static func mediaRef(_ ref: CompanionMediaRef) -> [String: Any] {
        present([
            "ref": ref.ref,
            "kind": ref.kind,
            "mime": ref.mime,
            "size_bytes": ref.sizeBytes,
            "sha256": ref.sha256,
            "filename": ref.filename,
            "caption": ref.caption
        ])
    }

    private static func hit(_ hit: CompanionSearchHit) -> [String: Any] {
        [
            "server_seq": hit.serverSeq,
            "role": hit.role,
            "ts": hit.timestamp,
            "excerpt": hit.excerpt,
            "ranges": hit.ranges.map { ["start": $0.start, "length": $0.length] }
        ]
    }

    private static func errorFields(_ error: CompanionServerError) -> [String: Any] {
        present([
            "reason": error.reason,
            "message": error.message,
            "field": error.field,
            "event": error.event,
            "client_msg_id": error.clientMsgId,
            "direction": error.direction?.rawValue,
            "client_version": error.clientVersion,
            "min_version": error.minVersion,
            "max_version": error.maxVersion
        ])
    }

    private static func value(_ value: CompanionJSONValue) -> Any {
        switch value {
        case .string(let string): return string
        case .integer(let integer): return integer
        case .double(let double): return double
        case .boolean(let boolean): return boolean
        case .array(let array): return array.map(Self.value)
        case .object(let object): return object.mapValues(Self.value)
        case .null: return NSNull()
        }
    }
}
