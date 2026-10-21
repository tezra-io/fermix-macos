import Foundation

/// The `native_host` wire, as this build speaks it.
///
/// The version, the window and the frame bounds are the vendored contract's
/// (`Resources/Contracts/native_host/`). It is the browser host's grammar for
/// a different concept: the browser host wire is the app's browser pane, and
/// this one is the app's grants and the services they open, notifications
/// first. Direction is reversed as there: once this build has attached as the
/// host, the daemon is the one asking with an `id`, this build answers each
/// with `ok` or `error`, and it sends its own news as events that carry no
/// `id`.
public enum NativeHostProtocol {
    /// Wire protocol version this build declares in `client_hello`.
    public static let version = 1

    /// The daemon's window at the pinned contract, which `version` sits inside.
    public static let supportedWindow = NativeHostVersionWindow(minimum: 1, maximum: 1)

    /// The longest line the daemon reads from this build (`x-max-line-bytes`),
    /// the browser host's cap, so one transport rule holds on both of the
    /// app's host wires. `line()` refuses a longer one first.
    public static let maximumLineBytes = 4_194_304

    /// The longest `message` an error carries (`x-max-message-chars`).
    public static let maximumMessageChars = 500

    /// What one notification carries, as `notifications.post` publishes it: a
    /// title, a body, at most two buttons in their own words, and the reminder
    /// a press names. The engine's own protocol holds a request to these
    /// before it writes it, so this build checks none of them; they are stated
    /// here so the schema test holds this build's reading of the contract.
    public static let maximumTitleChars = 256
    public static let maximumBodyChars = 1_800
    public static let maximumActions = 2
    public static let maximumActionTitleChars = 64
    public static let maximumIdentifierChars = 64

    /// How long the daemon has to answer `client_hello` with `server_hello`.
    /// The contract sets no deadline; this is the client's own, the same as
    /// the browser host's.
    public static let handshakeTimeout: TimeInterval = 3

    /// What the reader holds. The contract leaves daemon-to-app lines
    /// uncapped, so this bound is this client's own, the browser host's
    /// choice repeated: one line of at most 16 MiB, twice that buffered.
    public static let inboundLimits = LineInboundLimits(
        maximumLineBytes: 16_777_216,
        maximumBufferedBytes: 33_554_432
    )
}

/// The version window a daemon advertised.
public struct NativeHostVersionWindow: Equatable, Sendable {
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
    public func direction(for version: Int) -> NativeHostVersionDirection {
        version < minimum ? .clientTooOld : .clientTooNew
    }
}

/// Which side of the wire is out of date: update the app, or update Fermix.
public enum NativeHostVersionDirection: String, Equatable, Sendable, Decodable {
    case clientTooOld = "client_too_old"
    case clientTooNew = "client_too_new"
}

/// Why a line from the daemon could not become a request, an error or
/// `server_hello`. A line too long to hold is the line socket's own refusal,
/// not a decode failure: it never reaches the decoder.
public enum NativeHostDecodeFailure: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingType
    /// A field the frame's shape requires is absent, named by its path from
    /// the frame, e.g. `actions.0.title`.
    case missingField(String)
    /// A field carries a value its shape does not admit, named the same way.
    case invalidField(String)
}

/// Why a line this build produced could not be sent.
public enum NativeHostEncodeFailure: Error, Equatable, Sendable {
    /// Longer than `NativeHostProtocol.maximumLineBytes`.
    case lineTooLarge(bytes: Int)
}

// MARK: - Requests (daemon → app)

/// One button `notifications.post` asks for.
///
/// The id is decoded as the wire's own word rather than as a
/// `NotificationActionID`: an id this build does not know is refused by the
/// request's own `id`, as `invalid_request`, instead of failing the line and
/// closing the connection.
public struct NativeHostAction: Equatable, Sendable, Decodable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// `notifications.post`'s fields. Decoded as their shapes only: whether they
/// fit what the app can show is the client's question, answered by `id`.
public struct NativeHostPostRequest: Equatable, Sendable, Decodable {
    public let title: String
    public let body: String
    public let sound: Bool
    public let actions: [NativeHostAction]
    /// The reminder a press on one of `actions` names. Absent on a post that
    /// offers no action.
    public let reminderId: String?

    private enum CodingKeys: String, CodingKey {
        case title, body, sound, actions
        case reminderId = "reminder_id"
    }

    public init(title: String, body: String, sound: Bool, actions: [NativeHostAction], reminderId: String?) {
        self.title = title
        self.body = body
        self.sound = sound
        self.actions = actions
        self.reminderId = reminderId
    }
}

/// Every request the daemon may send, each carrying the `id` it must be
/// answered by.
public enum NativeHostRequest: Equatable, Sendable {
    case notificationsAuthorize(id: Int)
    case notificationsPost(id: Int, NativeHostPostRequest)
    case hostStatus(id: Int)
    case hostStopAck(id: Int)

    public var id: Int {
        switch self {
        case .notificationsAuthorize(let id), .notificationsPost(let id, _), .hostStatus(let id), .hostStopAck(let id):
            return id
        }
    }

    public var wireType: String {
        switch self {
        case .notificationsAuthorize: return "notifications.authorize"
        case .notificationsPost: return "notifications.post"
        case .hostStatus: return "host.status"
        case .hostStopAck: return "host.stop_ack"
        }
    }
}

/// The daemon's own refusal. Every one closes the connection.
public struct NativeHostDaemonError: Equatable, Sendable, Decodable {
    public let reason: String
    public let message: String?
    /// The offending field, on `missing_field` and `invalid_field`.
    public let field: String?
    /// The type that was not an event, on `unknown_event`.
    public let event: String?
    public let direction: NativeHostVersionDirection?
    public let clientVersion: Int?
    public let minVersion: Int?
    public let maxVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case reason, message, field, event, direction
        case clientVersion = "client_version"
        case minVersion = "min_version"
        case maxVersion = "max_version"
    }

    /// The window the refusal named, when it named one.
    public var window: NativeHostVersionWindow? {
        guard let minVersion, let maxVersion else { return nil }

        return NativeHostVersionWindow(minimum: minVersion, maximum: maxVersion)
    }
}

/// Everything the daemon may send: the handshake reply, a request to answer,
/// or a fatal refusal.
public enum NativeHostInbound: Equatable, Sendable {
    case serverHello(minVersion: Int, maxVersion: Int)
    case error(NativeHostDaemonError)
    case request(NativeHostRequest)
}

extension NativeHostInbound: Decodable {
    private enum Discriminator: String, CodingKey {
        case type, id
    }

    private struct ServerHelloPayload: Decodable {
        let minVersion: Int
        let maxVersion: Int

        private enum CodingKeys: String, CodingKey {
            case minVersion = "min_version"
            case maxVersion = "max_version"
        }
    }

    public init(from decoder: Decoder) throws {
        let discriminator = try decoder.container(keyedBy: Discriminator.self)
        let type = try discriminator.decode(String.self, forKey: .type)

        switch type {
        case "server_hello":
            let hello = try ServerHelloPayload(from: decoder)
            self = .serverHello(minVersion: hello.minVersion, maxVersion: hello.maxVersion)
        case "error":
            self = .error(try NativeHostDaemonError(from: decoder))
        default:
            let id = try discriminator.decode(Int.self, forKey: .id)
            self = .request(try Self.request(type: type, id: id, decoder: decoder))
        }
    }

    private static func request(type: String, id: Int, decoder: Decoder) throws -> NativeHostRequest {
        switch type {
        case "notifications.authorize":
            return .notificationsAuthorize(id: id)
        case "notifications.post":
            return .notificationsPost(id: id, try NativeHostPostRequest(from: decoder))
        case "host.status":
            return .hostStatus(id: id)
        case "host.stop_ack":
            return .hostStopAck(id: id)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [Discriminator.type],
                    debugDescription: "unknown native host request type \(type)"
                )
            )
        }
    }
}

extension NativeHostInbound {
    /// Decodes one wire line from the daemon. A line that is not an object,
    /// carries no `type`, or misses or misshapes a field its type requires is
    /// refused, named by the field's path.
    public static func decode(_ line: Data) throws(NativeHostDecodeFailure) -> NativeHostInbound {
        do {
            return try JSONDecoder().decode(NativeHostInbound.self, from: line)
        } catch let error as DecodingError {
            throw Self.classify(error)
        } catch {
            throw .malformedJSON
        }
    }

    private static func classify(_ error: DecodingError) -> NativeHostDecodeFailure {
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

// MARK: - Events (app → daemon)

/// Everything this build sends unasked, with no `id`.
public enum NativeHostEvent: Equatable, Sendable {
    case clientHello(protocolVersion: Int)
    case attached(hostVersion: String)
    /// The app's grants, read from the framework itself: sent right after
    /// `attached` and again on every change.
    case capabilities(notifications: NotificationGrant)
    /// The person pressed `action` on the notification for `reminderId`.
    case notificationAction(reminderId: String, action: NotificationActionID)
    case hostStopping

    public var wireType: String {
        switch self {
        case .clientHello: return "client_hello"
        case .attached: return "attached"
        case .capabilities: return "capabilities"
        case .notificationAction: return "notification.action"
        case .hostStopping: return "host_stopping"
        }
    }
}

extension NativeHostEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, notifications, action
        case protocolVersion = "protocol_version"
        case hostVersion = "host_version"
        case reminderId = "reminder_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)

        switch self {
        case .clientHello(let protocolVersion):
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case .attached(let hostVersion):
            try container.encode(hostVersion, forKey: .hostVersion)
        case .capabilities(let notifications):
            try container.encode(notifications.rawValue, forKey: .notifications)
        case .notificationAction(let reminderId, let action):
            try container.encode(reminderId, forKey: .reminderId)
            try container.encode(action.rawValue, forKey: .action)
        case .hostStopping:
            break
        }
    }

    /// The event as one line, without the newline the line socket adds. A
    /// line the daemon would refuse for its length throws `lineTooLarge`
    /// instead.
    public func line() throws -> Data {
        try NativeHostLine.encode(self)
    }
}

// MARK: - Responses (app → daemon)

/// One of the host's enumerated error reasons.
public enum NativeHostErrorReason: String, CaseIterable, Equatable, Sendable, Encodable {
    /// `notifications.post` while the grant is not `granted`.
    case notAuthorized = "not_authorized"
    /// The framework refused the notification; the message is its own words.
    case postFailed = "post_failed"
    /// The request's fields do not fit what the app can show.
    case invalidRequest = "invalid_request"
    /// The app cannot take the request right now: it is quitting.
    case hostUnavailable = "host_unavailable"
}

/// A refusal of one request. Never closes the connection by itself.
public struct NativeHostError: Error, Equatable, Sendable, Encodable {
    public let reason: NativeHostErrorReason
    public let message: String

    /// `message` is bounded to the contract's own cap: a refusal is never the
    /// line that trips `line_too_large`.
    public init(reason: NativeHostErrorReason, message: String) {
        self.reason = reason
        self.message = String(message.prefix(NativeHostProtocol.maximumMessageChars))
    }
}

/// Which result shape a response carries, decided by the request its `id`
/// names.
public enum NativeHostResult: Equatable, Sendable {
    /// `notifications.authorize`: the grant once the prompt, if any, was
    /// answered.
    case authorize(state: NotificationGrant)
    /// `notifications.post`: this build's own identifier for what it posted.
    case post(notificationId: String)
    /// `host.status`: the host's own account of itself.
    case hostStatus(hostVersion: String, notifications: NotificationGrant)
    case hostStopAck
}

extension NativeHostResult: Encodable {
    private enum CodingKeys: String, CodingKey {
        case state, notifications
        case notificationId = "notification_id"
        case hostVersion = "host_version"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .authorize(let state):
            try container.encode(state.rawValue, forKey: .state)
        case .post(let notificationId):
            try container.encode(notificationId, forKey: .notificationId)
        case .hostStatus(let hostVersion, let notifications):
            try container.encode(hostVersion, forKey: .hostVersion)
            try container.encode(notifications.rawValue, forKey: .notifications)
        case .hostStopAck:
            break
        }
    }
}

/// This build's answer to one request: a result, or an error from the host's
/// vocabulary.
public struct NativeHostResponse: Equatable, Sendable {
    public let id: Int
    public let outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case success(NativeHostResult)
        case failure(NativeHostError)
    }

    public init(id: Int, result: NativeHostResult) {
        self.id = id
        self.outcome = .success(result)
    }

    public init(id: Int, error: NativeHostError) {
        self.id = id
        self.outcome = .failure(error)
    }
}

extension NativeHostResponse: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, ok, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)

        switch outcome {
        case .success(let result):
            try container.encode(true, forKey: .ok)
            try container.encode(result, forKey: .result)
        case .failure(let error):
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }

    /// The response as one line, without the newline the line socket adds. A
    /// line the daemon would refuse for its length throws `lineTooLarge`
    /// instead.
    public func line() throws -> Data {
        try NativeHostLine.encode(self)
    }
}

/// The one encoder for both kinds of line this build writes.
private enum NativeHostLine {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let line = try encoder.encode(value)
        guard line.count <= NativeHostProtocol.maximumLineBytes else {
            throw NativeHostEncodeFailure.lineTooLarge(bytes: line.count)
        }
        return line
    }
}
