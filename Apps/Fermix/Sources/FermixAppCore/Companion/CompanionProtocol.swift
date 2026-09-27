import Foundation

/// The companion chat wire, as this build speaks it.
///
/// The version, the window and the client line cap are the vendored contract's
/// (`Resources/Contracts/companion/`). The reader's bounds are this client's:
/// the contract caps what a client sends and leaves the daemon's lines uncapped,
/// because a history page can be long, and an unbounded reader is a memory
/// fault waiting for a bad peer.
public enum CompanionProtocol {
    /// Wire protocol version this build speaks, declared in `client_hello` and
    /// validated against the window the daemon advertises in `server_hello`.
    public static let version = 1

    /// The daemon's window at the pinned contract, which `version` sits inside.
    public static let supportedWindow = CompanionVersionWindow(minimum: 1, maximum: 1)

    /// The longest client line the daemon reads. A longer one is refused with
    /// `line_too_large` and closes the connection, so `line()` refuses it first.
    public static let maximumClientLineBytes = 65_536

    /// The one profile the daemon serves; any other is `unsupported_profile`.
    public static let profileId = "main"

    /// What the reader holds: one daemon line of at most 16 MiB, and at most
    /// 32 MiB of unscanned inbound data at once.
    ///
    /// The contract bounds the parts of its longest line rather than the line.
    /// A history page carries at most 200 rows, the `history_pull` ceiling, and
    /// a user's row holds at most one client line of text: 200 of them are
    /// 12.5 MiB before their keys, so the fullest page of the longest messages
    /// a client can send fits one line. A reply is bounded by the model, not
    /// the contract, which is why the bound is this client's. The buffer holds
    /// two such lines, the realtime wire's ratio.
    public static let inboundLimits = LineInboundLimits(
        maximumLineBytes: 16_777_216,
        maximumBufferedBytes: 33_554_432
    )
}

/// The version window a daemon advertised.
public struct CompanionVersionWindow: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ version: Int) -> Bool {
        version >= minimum && version <= maximum
    }

    /// Which side is out of date, for a version this window excludes.
    public func direction(for version: Int) -> CompanionVersionDirection {
        version < minimum ? .clientTooOld : .clientTooNew
    }
}

/// Which side of the wire is out of date: update the app, or update Fermix.
/// The daemon publishes the same two words on its refusal.
public enum CompanionVersionDirection: String, Equatable, Sendable, Decodable {
    case clientTooOld = "client_too_old"
    case clientTooNew = "client_too_new"
}

/// Why a line could not become an event. A line too long to hold is the line
/// socket's refusal, not a decode failure: it never reaches the decoder.
public enum CompanionDecodeFailure: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingType
    /// A field the event's shape requires is absent, named by its path from the
    /// event, e.g. `messages.0.content`.
    case missingField(String)
    /// A field carries a value its shape does not admit, named the same way.
    case invalidField(String)
}

/// Why a client event could not become a line.
public enum CompanionEncodeFailure: Error, Equatable, Sendable {
    /// Longer than `CompanionProtocol.maximumClientLineBytes`.
    case lineTooLarge(bytes: Int)
}

// MARK: - Client events

/// Where a history pull reads from. The contract takes exactly one cursor, so
/// the two are cases of one value: a pull with both, or with neither, cannot be
/// built.
public enum CompanionHistoryCursor: Equatable, Sendable {
    /// The rows after this seq, oldest first: the catch-up read.
    case after(seq: Int)
    /// The newest rows before this seq, oldest first: scrolling back.
    case before(seq: Int)
}

/// Everything this client sends. The wire names are the contract's, and a value
/// is the only way to produce a line: nothing composes a dictionary by hand.
public enum CompanionClientEvent: Equatable, Sendable, Encodable {
    case clientHello(protocolVersion: Int)
    /// A message to the agent. This wire carries no attachments in version 1,
    /// so the line always sends an empty `attach_ids`.
    case msg(clientMsgId: String, profileId: String, text: String)
    /// A slash command, `/name args`. An approval's routes are sent this way.
    case command(clientMsgId: String, profileId: String, name: String, args: String?)
    /// Stops the turn of the named request and no other. Never answered itself.
    case cancel(profileId: String, clientMsgId: String)
    case historyPull(profileId: String, cursor: CompanionHistoryCursor, limit: Int)
    case historySearch(profileId: String, query: String, limit: Int, beforeSeq: Int?)
    /// Advances the monotonic read frontier.
    case readState(profileId: String, readUpToSeq: Int)

    public var wireType: String {
        switch self {
        case .clientHello: return "client_hello"
        case .msg: return "msg"
        case .command: return "command"
        case .cancel: return "cancel"
        case .historyPull: return "history_pull"
        case .historySearch: return "history_search"
        case .readState: return "read_state"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, name, args, query, limit
        case protocolVersion = "protocol_version"
        case clientMsgId = "client_msg_id"
        case profileId = "profile_id"
        case attachIds = "attach_ids"
        case afterSeq = "after_seq"
        case beforeSeq = "before_seq"
        case readUpToSeq = "read_up_to_seq"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)

        switch self {
        case .clientHello(let version):
            try container.encode(version, forKey: .protocolVersion)
        case .msg(let clientMsgId, let profileId, let text):
            try container.encode(clientMsgId, forKey: .clientMsgId)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(text, forKey: .text)
            try container.encode([String](), forKey: .attachIds)
        case .command(let clientMsgId, let profileId, let name, let args):
            try container.encode(clientMsgId, forKey: .clientMsgId)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(args, forKey: .args)
        case .cancel(let profileId, let clientMsgId):
            try container.encode(profileId, forKey: .profileId)
            try container.encode(clientMsgId, forKey: .clientMsgId)
        case .historyPull(let profileId, let cursor, let limit):
            try container.encode(profileId, forKey: .profileId)
            try Self.encode(cursor, into: &container)
            try container.encode(limit, forKey: .limit)
        case .historySearch(let profileId, let query, let limit, let beforeSeq):
            try container.encode(profileId, forKey: .profileId)
            try container.encode(query, forKey: .query)
            try container.encode(limit, forKey: .limit)
            try container.encodeIfPresent(beforeSeq, forKey: .beforeSeq)
        case .readState(let profileId, let readUpToSeq):
            try container.encode(profileId, forKey: .profileId)
            try container.encode(readUpToSeq, forKey: .readUpToSeq)
        }
    }

    private static func encode(
        _ cursor: CompanionHistoryCursor,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch cursor {
        case .after(let seq):
            try container.encode(seq, forKey: .afterSeq)
        case .before(let seq):
            try container.encode(seq, forKey: .beforeSeq)
        }
    }

    /// The event as one line, without the newline the line socket adds. A line
    /// the daemon would refuse for its length throws `lineTooLarge` instead.
    ///
    /// Slashes are written as themselves: a line is the bytes the daemon
    /// counts, and an escaped slash is two of them.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let line = try encoder.encode(self)
        guard line.count <= CompanionProtocol.maximumClientLineBytes else {
            throw CompanionEncodeFailure.lineTooLarge(bytes: line.count)
        }
        return line
    }
}

// MARK: - Server events

/// A tool call's phase. The contract publishes two words; a third keeps its own
/// rather than being folded into a neighbour.
public enum CompanionToolPhase: Equatable, Sendable, Decodable {
    case start
    case stop
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "start": self = .start
        case "stop": self = .stop
        default: self = .unrecognized(wireValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// How an approval ended, with the same open-vocabulary treatment.
public enum CompanionApprovalOutcome: Equatable, Sendable, Decodable {
    case approved
    case denied
    case expired
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "approved": self = .approved
        case "denied": self = .denied
        case "expired": self = .expired
        default: self = .unrecognized(wireValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The durable receipt for a `msg` or `command`: after it, the outbox stops
/// resending that request.
public struct CompanionAccepted: Equatable, Sendable, Decodable {
    public let clientMsgId: String
    public let duplicate: Bool
    /// On a duplicate whose request already has a reply row, that reply's seq.
    /// A first receipt never carries it: the request's own row arrives as a
    /// `row`.
    public let serverSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case duplicate
        case clientMsgId = "client_msg_id"
        case serverSeq = "server_seq"
    }
}

public struct CompanionToolEvent: Equatable, Sendable, Decodable {
    public let turnId: String
    public let tool: String
    public let phase: CompanionToolPhase
    public let detail: String?

    private enum CodingKeys: String, CodingKey {
        case tool, phase, detail
        case turnId = "turn_id"
    }
}

/// An owner-approval card. The token is submitted, never rendered: the routes
/// are sent back as commands.
public struct CompanionApproval: Equatable, Sendable, Decodable {
    public let approvalId: String
    /// The daemon's own word for what is asking, carried verbatim.
    public let kind: String
    public let text: String
    public let detail: String?
    public let token: String
    public let ttlSeconds: Int
    public let approveCommand: String
    public let denyCommand: String

    private enum CodingKeys: String, CodingKey {
        case kind, text, detail, token
        case approvalId = "approval_id"
        case ttlSeconds = "ttl_s"
        case approveCommand = "approve_command"
        case denyCommand = "deny_command"
    }
}

/// One page of the timeline, oldest first. A forward page carries
/// `nextAfterSeq`; a backward page carries `nextBeforeSeq` only when an older
/// row exists.
public struct CompanionHistoryPage: Equatable, Sendable, Decodable {
    public let profileId: String
    public let messages: [CompanionTimelineRow]
    public let historyHeadSeq: Int
    public let nextAfterSeq: Int?
    public let nextBeforeSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case messages
        case profileId = "profile_id"
        case historyHeadSeq = "history_head_seq"
        case nextAfterSeq = "next_after_seq"
        case nextBeforeSeq = "next_before_seq"
    }
}

/// Search hits, newest first; `nextBeforeSeq` only when an older hit exists.
public struct CompanionSearchResults: Equatable, Sendable, Decodable {
    public let profileId: String
    public let query: String
    public let hits: [CompanionSearchHit]
    public let nextBeforeSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case query, hits
        case profileId = "profile_id"
        case nextBeforeSeq = "next_before_seq"
    }
}

/// A refusal from the daemon. `reason` is the daemon's code, carried verbatim;
/// the rest is context, present where the code carries it.
public struct CompanionServerError: Equatable, Sendable, Decodable {
    public let reason: String
    public let message: String?
    /// The offending field, on `missing_field` and `invalid_field`.
    public let field: String?
    /// The type that was not an event, on `unknown_event`.
    public let event: String?
    /// The request refused, on the refusals that leave the connection open.
    public let clientMsgId: String?
    public let direction: CompanionVersionDirection?
    public let clientVersion: Int?
    public let minVersion: Int?
    public let maxVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case reason, message, field, event, direction
        case clientMsgId = "client_msg_id"
        case clientVersion = "client_version"
        case minVersion = "min_version"
        case maxVersion = "max_version"
    }

    /// The window the refusal named, when it named one.
    public var window: CompanionVersionWindow? {
        guard let minVersion, let maxVersion else { return nil }

        return CompanionVersionWindow(minimum: minVersion, maximum: maxVersion)
    }
}

/// Everything the daemon sends.
public enum CompanionServerEvent: Equatable, Sendable {
    case serverHello(minVersion: Int, maxVersion: Int)
    case accepted(CompanionAccepted)
    case turnStarted(profileId: String, turnId: String, inReplyTo: String)
    /// Text to append to the turn's draft exactly as sent, never trimmed.
    case textDelta(turnId: String, text: String)
    case toolEvent(CompanionToolEvent)
    /// A reply's canonical text at its timeline row; it replaces the draft.
    case textDone(turnId: String, serverSeq: Int, text: String)
    /// The turn's terminal failure: `cancelled` after a cancel, `interrupted`
    /// when the daemon lost the turn, or the failure's own code.
    case turnError(turnId: String, code: String, message: String)
    case row(CompanionAnnouncedRow)
    case approval(CompanionApproval)
    case approvalResolved(approvalId: String, outcome: CompanionApprovalOutcome)
    case readState(profileId: String, readUpToSeq: Int)
    case historyPage(CompanionHistoryPage)
    case searchResults(CompanionSearchResults)
    case error(CompanionServerError)
    /// An event type published after this build shipped: logged by the session,
    /// never silently dropped.
    case unrecognized(type: String)

    public var wireType: String {
        switch self {
        case .serverHello: return "server_hello"
        case .accepted: return "accepted"
        case .turnStarted: return "turn_started"
        case .textDelta: return "text_delta"
        case .toolEvent: return "tool_event"
        case .textDone: return "text_done"
        case .turnError: return "turn_error"
        case .row: return "row"
        case .approval: return "approval"
        case .approvalResolved: return "approval_resolved"
        case .readState: return "read_state"
        case .historyPage: return "history_page"
        case .searchResults: return "search_results"
        case .error: return "error"
        case .unrecognized(let type): return type
        }
    }

    public var isUnrecognized: Bool {
        if case .unrecognized = self { return true }

        return false
    }

    /// Decodes one wire line. A line that is not an object, carries no `type`,
    /// or misses or misshapes a field its type requires is refused; an unknown
    /// `type` is not.
    ///
    /// `JSONDecoder` declares an untyped error; anything it throws that is not
    /// a `DecodingError` is still bytes that are not a line.
    public static func decode(_ line: Data) throws(CompanionDecodeFailure) -> CompanionServerEvent {
        do {
            return try JSONDecoder().decode(CompanionServerEvent.self, from: line)
        } catch let error as DecodingError {
            throw Self.classify(error)
        } catch {
            throw .malformedJSON
        }
    }

    private static func classify(_ error: DecodingError) -> CompanionDecodeFailure {
        switch error {
        case .keyNotFound(let key, let context):
            let path = context.codingPath + [key]
            return path.count == 1 && key.stringValue == "type" ? .missingType : .missingField(fieldPath(path))
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return context.codingPath.isEmpty ? .notAnObject : .invalidField(fieldPath(context.codingPath))
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? .malformedJSON : .invalidField(fieldPath(context.codingPath))
        @unknown default:
            return .malformedJSON
        }
    }

    /// A coding path as the contract names fields: keys by name, array
    /// elements by index.
    private static func fieldPath(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}

extension CompanionServerEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, code, message, outcome
        case minVersion = "min_version"
        case maxVersion = "max_version"
        case profileId = "profile_id"
        case turnId = "turn_id"
        case inReplyTo = "in_reply_to"
        case serverSeq = "server_seq"
        case approvalId = "approval_id"
        case readUpToSeq = "read_up_to_seq"
    }

    /// Events with a payload type decode it from the same object; the rest are
    /// read field by field here.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let type = try fields.decode(String.self, forKey: .type)

        switch type {
        case "server_hello":
            self = .serverHello(
                minVersion: try fields.decode(Int.self, forKey: .minVersion),
                maxVersion: try fields.decode(Int.self, forKey: .maxVersion)
            )
        case "accepted":
            self = .accepted(try CompanionAccepted(from: decoder))
        case "turn_started":
            self = .turnStarted(
                profileId: try fields.decode(String.self, forKey: .profileId),
                turnId: try fields.decode(String.self, forKey: .turnId),
                inReplyTo: try fields.decode(String.self, forKey: .inReplyTo)
            )
        case "text_delta":
            self = .textDelta(
                turnId: try fields.decode(String.self, forKey: .turnId),
                text: try fields.decode(String.self, forKey: .text)
            )
        case "tool_event":
            self = .toolEvent(try CompanionToolEvent(from: decoder))
        case "text_done":
            self = .textDone(
                turnId: try fields.decode(String.self, forKey: .turnId),
                serverSeq: try fields.decode(Int.self, forKey: .serverSeq),
                text: try fields.decode(String.self, forKey: .text)
            )
        case "turn_error":
            self = .turnError(
                turnId: try fields.decode(String.self, forKey: .turnId),
                code: try fields.decode(String.self, forKey: .code),
                message: try fields.decode(String.self, forKey: .message)
            )
        case "row":
            self = .row(try CompanionAnnouncedRow(from: decoder))
        case "approval":
            self = .approval(try CompanionApproval(from: decoder))
        case "approval_resolved":
            self = .approvalResolved(
                approvalId: try fields.decode(String.self, forKey: .approvalId),
                outcome: try fields.decode(CompanionApprovalOutcome.self, forKey: .outcome)
            )
        case "read_state":
            self = .readState(
                profileId: try fields.decode(String.self, forKey: .profileId),
                readUpToSeq: try fields.decode(Int.self, forKey: .readUpToSeq)
            )
        case "history_page":
            self = .historyPage(try CompanionHistoryPage(from: decoder))
        case "search_results":
            self = .searchResults(try CompanionSearchResults(from: decoder))
        case "error":
            self = .error(try CompanionServerError(from: decoder))
        default:
            self = .unrecognized(type: type)
        }
    }
}
