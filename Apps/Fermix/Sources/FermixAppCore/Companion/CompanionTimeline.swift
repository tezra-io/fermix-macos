import Foundation

/// A row of the profile's timeline as the contract exports it: one
/// `history_page` message, and nothing else of the daemon's storage.
///
/// The timeline, its `serverSeq` numbering and its read frontier are the ones
/// the phone shares, so a row may have been written by either.
public struct CompanionTimelineRow: Equatable, Sendable, Decodable {
    public let serverSeq: Int
    /// The daemon's own word for who wrote the row, carried verbatim.
    public let role: String
    public let content: String
    public let kind: String?
    /// RFC 3339, UTC, exactly as the daemon wrote it.
    public let timestamp: String
    public let mediaRefs: [CompanionMediaRef]
    /// On a user's row, the request it recorded, to match the outbox.
    public let clientMsgId: String?
    /// On a reply, the request it answers.
    public let inReplyTo: String?
    /// An object the contract leaves open, kept as the daemon sent it.
    public let metadata: [String: CompanionJSONValue]?

    private enum CodingKeys: String, CodingKey {
        case role, content, kind, metadata
        case serverSeq = "server_seq"
        case timestamp = "ts"
        case mediaRefs = "media_refs"
        case clientMsgId = "client_msg_id"
        case inReplyTo = "in_reply_to"
    }
}

/// A timeline row announced live as it is written outside a turn's
/// completion: the sender's own message, a slash command's answer, a scheduled
/// delivery, a row written from the phone. It carries fewer fields than the
/// exported row, and its text is `text` rather than `content`.
public struct CompanionAnnouncedRow: Equatable, Sendable, Decodable {
    public let profileId: String
    public let serverSeq: Int
    public let role: String
    public let text: String
    /// RFC 3339, UTC, exactly as the daemon wrote it.
    public let timestamp: String
    /// On a user's row, for the sender to match its outbox.
    public let clientMsgId: String?

    private enum CodingKeys: String, CodingKey {
        case role, text
        case profileId = "profile_id"
        case serverSeq = "server_seq"
        case timestamp = "ts"
        case clientMsgId = "client_msg_id"
    }
}

/// A file a timeline row refers to. The row carries the reference, never the
/// bytes.
public struct CompanionMediaRef: Equatable, Sendable, Decodable {
    public let ref: String
    public let kind: String
    public let mime: String
    public let sizeBytes: Int
    public let sha256: String?
    public let filename: String?
    public let caption: String?

    private enum CodingKeys: String, CodingKey {
        case ref, kind, mime, sha256, filename, caption
        case sizeBytes = "size_bytes"
    }
}

/// One search hit: plain text around the matches, with `…` where the daemon
/// cut it, and one range per matched word.
public struct CompanionSearchHit: Equatable, Sendable, Decodable {
    public let serverSeq: Int
    public let role: String
    /// RFC 3339, UTC, exactly as the daemon wrote it.
    public let timestamp: String
    public let excerpt: String
    public let ranges: [CompanionMatchRange]

    private enum CodingKeys: String, CodingKey {
        case role, excerpt, ranges
        case serverSeq = "server_seq"
        case timestamp = "ts"
    }
}

/// A matched span of an excerpt, counted in Unicode scalar values, not in
/// characters or UTF-16 units.
public struct CompanionMatchRange: Equatable, Sendable, Decodable {
    public let start: Int
    public let length: Int
}

/// One value inside an object the contract leaves open. The probes run in
/// JSON's own order of specificity; they are type tests, not swallowed
/// failures, and every JSON value matches one of them.
public enum CompanionJSONValue: Equatable, Sendable, Decodable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([CompanionJSONValue])
    case object([String: CompanionJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CompanionJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CompanionJSONValue].self))
        }
    }
}
