import Foundation

/// The request envelope: a request id, the declared protocol version, the
/// method, and its bounded parameters.
struct ManagementRequestEnvelope<Params: Encodable>: Encodable {
    let requestId: String
    let protocolVersion: Int
    let method: String
    let params: Params

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case protocolVersion = "protocol_version"
        case method, params
    }
}

/// The parameter object of an input-free method. It encodes as `{}` — the
/// schema's default — rather than being omitted.
struct ManagementEmptyParams: Encodable {
    func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: ManagementDynamicKey.self)
    }
}

struct ManagementDoctorStartParams: Encodable {
    let scope: ManagementDoctorScope?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManagementDynamicKey.self)
        guard let scope, let key = ManagementDynamicKey(stringValue: "scope") else { return }
        try container.encode(scope.wireValue, forKey: key)
    }
}

struct ManagementSessionParams: Encodable {
    let sessionId: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManagementDynamicKey.self)
        guard let key = ManagementDynamicKey(stringValue: "session_id") else { return }
        try container.encode(sessionId, forKey: key)
    }
}

struct ManagementLeaseParams: Encodable {
    let leaseId: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManagementDynamicKey.self)
        guard let key = ManagementDynamicKey(stringValue: "lease_id") else { return }
        try container.encode(leaseId, forKey: key)
    }
}

/// A bounded log query. Every field is optional; an omitted field takes the
/// daemon's published default rather than one restated here.
public struct ManagementLogsQuery: Equatable, Sendable {
    /// The daemon's published page bounds, so an oversized page is refused
    /// before it is sent.
    public static let maximumLimit = 500
    public static let maximumSearchLength = 256
    public static let maximumSubsystemLength = 64

    public var limit: Int?
    public var level: ManagementLogLevel?
    public var subsystem: String?
    public var search: String?
    public var direction: ManagementLogDirection?
    public var cursor: String?

    public init(
        limit: Int? = nil,
        level: ManagementLogLevel? = nil,
        subsystem: String? = nil,
        search: String? = nil,
        direction: ManagementLogDirection? = nil,
        cursor: String? = nil
    ) {
        self.limit = limit
        self.level = level
        self.subsystem = subsystem
        self.search = search
        self.direction = direction
        self.cursor = cursor
    }

    func validated() throws -> ManagementLogsQuery {
        if let limit, limit < 1 || limit > Self.maximumLimit {
            throw ManagementError.invalidParameter(.outOfRange(field: "limit"))
        }
        try Self.checkText(subsystem, field: "subsystem", maximum: Self.maximumSubsystemLength)
        try Self.checkText(search, field: "search", maximum: Self.maximumSearchLength)
        if let cursor, cursor.isEmpty {
            throw ManagementError.invalidParameter(.empty(field: "cursor"))
        }
        return self
    }

    private static func checkText(_ value: String?, field: String, maximum: Int) throws {
        guard let value else { return }
        if value.isEmpty {
            throw ManagementError.invalidParameter(.empty(field: field))
        }
        if value.count > maximum {
            throw ManagementError.invalidParameter(.outOfRange(field: field))
        }
    }
}

struct ManagementLogsQueryParams: Encodable {
    let query: ManagementLogsQuery

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManagementDynamicKey.self)
        try encode(query.limit, as: "limit", into: &container)
        try encode(query.level?.wireValue, as: "level", into: &container)
        try encode(query.subsystem, as: "subsystem", into: &container)
        try encode(query.search, as: "search", into: &container)
        try encode(query.direction?.wireValue, as: "direction", into: &container)
        try encode(query.cursor, as: "cursor", into: &container)
    }

    private func encode<Value: Encodable>(
        _ value: Value?,
        as name: String,
        into container: inout KeyedEncodingContainer<ManagementDynamicKey>
    ) throws {
        guard let value, let key = ManagementDynamicKey(stringValue: name) else { return }
        try container.encode(value, forKey: key)
    }
}

/// Generates the request id carried on every request and echoed on every
/// response.
public protocol ManagementRequestIdentifierGenerator: Sendable {
    func nextIdentifier(for method: ManagementMethod) -> String
}

public struct UUIDRequestIdentifierGenerator: ManagementRequestIdentifierGenerator {
    public init() {}

    public func nextIdentifier(for method: ManagementMethod) -> String {
        "app-\(method.identifierSlug)-\(UUID().uuidString.lowercased())"
    }
}

/// The published request-id pattern, `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`.
///
/// An id that does not fit is refused whole. Trimming one to fit would make two
/// different requests share an id, which is exactly what correlation exists to
/// prevent.
public enum ManagementRequestIdentifier {
    public static let maximumLength = 128

    public static func isValid(_ identifier: String) -> Bool {
        guard (1...maximumLength).contains(identifier.count) else { return false }
        guard let first = identifier.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return identifier.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || "._:-".contains(character)
        }
    }
}
