import Foundation

/// The `browser_host` wire, as this build speaks it.
///
/// The version, the window and the frame bounds are the vendored contract's
/// (`Resources/Contracts/browser_host/`). Direction is reversed from the other
/// three wires: once this build has attached as the host, the daemon is the
/// one sending requests with an `id`, this build answers each with `ok` or
/// `error`, and it sends its own news as events that carry no `id`.
public enum BrowserHostProtocol {
    /// Wire protocol version this build declares in `client_hello`.
    public static let version = 1

    /// The daemon's window at the pinned contract, which `version` sits inside.
    public static let supportedWindow = BrowserHostVersionWindow(minimum: 1, maximum: 1)

    /// The longest line the daemon reads from this build (`x-max-line-bytes`).
    /// A response or event longer than this is refused by the daemon with
    /// `line_too_large` and closes the connection, so `line()` refuses it
    /// first.
    public static let maximumLineBytes = 4_194_304

    /// The longest `message` an error carries (`x-max-message-chars`).
    public static let maximumMessageChars = 500

    /// The longest `availability` reason (`x-max-reason-chars`).
    public static let maximumReasonChars = 200

    /// The most nodes one `page` carries (`x-max-nodes`).
    public static let maximumNodes = 50_000

    /// How long the daemon has to answer `client_hello` with `server_hello`.
    /// The contract sets no deadline; this is the client's own, the same as
    /// the companion and realtime wires.
    public static let handshakeTimeout: TimeInterval = 3

    /// What the reader holds. The contract leaves daemon-to-app lines
    /// uncapped ("daemon-to-app lines are not capped"), so this bound is this
    /// client's own rather than the contract's, the companion wire's own
    /// choice repeated here: one line of at most 16 MiB, twice that buffered.
    public static let inboundLimits = LineInboundLimits(
        maximumLineBytes: 16_777_216,
        maximumBufferedBytes: 33_554_432
    )
}

/// The version window a daemon advertised.
public struct BrowserHostVersionWindow: Equatable, Sendable {
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
    public func direction(for version: Int) -> BrowserHostVersionDirection {
        version < minimum ? .clientTooOld : .clientTooNew
    }
}

/// Which side of the wire is out of date: update the app, or update Fermix.
public enum BrowserHostVersionDirection: String, Equatable, Sendable, Decodable {
    case clientTooOld = "client_too_old"
    case clientTooNew = "client_too_new"
}

/// Why a line from the daemon could not become a request, an error or
/// `server_hello`. A line too long to hold is the line socket's own refusal,
/// not a decode failure: it never reaches the decoder.
public enum BrowserHostDecodeFailure: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingType
    /// A field the frame's shape requires is absent, named by its path from
    /// the frame, e.g. `fields.0.text`.
    case missingField(String)
    /// A field carries a value its shape does not admit, named the same way.
    case invalidField(String)
}

/// Why a line this build produced could not be sent.
public enum BrowserHostEncodeFailure: Error, Equatable, Sendable {
    /// Longer than `BrowserHostProtocol.maximumLineBytes`.
    case lineTooLarge(bytes: Int)
}

// MARK: - Requests (daemon → app)

/// One `page.snapshot`, `tab.open` or `page.act` naming the look this build
/// takes at a page: how much of it, in how many characters, how deep.
public struct BrowserHostSnapshotOptions: Equatable, Sendable, Decodable {
    public let mode: BrowserSnapshotMode
    public let maxChars: Int
    public let depth: Int

    private enum CodingKeys: String, CodingKey {
        case mode, depth
        case maxChars = "max_chars"
    }

    public init(mode: BrowserSnapshotMode, maxChars: Int, depth: Int) {
        self.mode = mode
        self.maxChars = maxChars
        self.depth = depth
    }
}

/// One field of a `page.act` `fill_form`, by the ref a snapshot gave it.
public struct BrowserHostFormField: Equatable, Sendable, Decodable {
    public let ref: Int
    public let text: String

    public init(ref: Int, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// `page.act`'s ten kinds.
public enum BrowserHostActKind: String, Equatable, Sendable, Decodable {
    case click
    case fill
    case fillForm = "fill_form"
    case type
    case submit
    case press
    case hover
    case get
    case wait
    case clickCoords = "click_coords"
}

/// A `get` act's optional target field.
public enum BrowserHostGetField: String, Equatable, Sendable, Decodable {
    case text
    case title
    case html
    case count
    case readyState = "ready_state"
    case rect
}

/// A `wait` act's condition.
public enum BrowserHostWaitUntil: String, Equatable, Sendable, Decodable {
    case text
    case url
    case element
    case load
}

public struct BrowserHostTabOpenRequest: Equatable, Sendable, Decodable {
    public let taskId: String
    public let url: String
    public let observe: Bool
    public let downloadDir: String
    public let taskTabCap: Int
    public let tabCap: Int
    public let snapshot: BrowserHostSnapshotOptions?

    private enum CodingKeys: String, CodingKey {
        case url, observe, snapshot
        case taskId = "task_id"
        case downloadDir = "download_dir"
        case taskTabCap = "task_tab_cap"
        case tabCap = "tab_cap"
    }
}

public struct BrowserHostTabNavigateRequest: Equatable, Sendable, Decodable {
    public let tabId: String
    public let url: String
    public let observe: Bool
    public let snapshot: BrowserHostSnapshotOptions?

    private enum CodingKeys: String, CodingKey {
        case url, observe, snapshot
        case tabId = "tab_id"
    }
}

public struct BrowserHostPageSnapshotRequest: Equatable, Sendable, Decodable {
    public let tabId: String
    public let mode: BrowserSnapshotMode
    public let maxChars: Int
    public let depth: Int

    private enum CodingKeys: String, CodingKey {
        case mode, depth
        case tabId = "tab_id"
        case maxChars = "max_chars"
    }
}

public struct BrowserHostPageScreenshotRequest: Equatable, Sendable, Decodable {
    public let tabId: String
    public let fullPage: Bool
    public let path: String

    private enum CodingKeys: String, CodingKey {
        case path
        case tabId = "tab_id"
        case fullPage = "full_page"
    }
}

public struct BrowserHostPageActRequest: Equatable, Sendable, Decodable {
    public let tabId: String
    public let kind: BrowserHostActKind
    public let observe: Bool
    public let snapshot: BrowserHostSnapshotOptions?
    public let ref: Int?
    public let x: Double?
    public let y: Double?
    public let text: String?
    public let key: String?
    public let fields: [BrowserHostFormField]?
    public let field: BrowserHostGetField?
    public let selector: String?
    public let waitUntil: BrowserHostWaitUntil?
    public let timeoutMs: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, observe, snapshot, ref, x, y, text, key, fields, field, selector
        case tabId = "tab_id"
        case waitUntil = "wait_until"
        case timeoutMs = "timeout_ms"
    }
}

/// Every request the daemon may send, each carrying the `id` it must be
/// answered by.
public enum BrowserHostRequest: Equatable, Sendable {
    case tabOpen(id: Int, BrowserHostTabOpenRequest)
    case tabNavigate(id: Int, BrowserHostTabNavigateRequest)
    case tabList(id: Int, taskId: String)
    case tabFocus(id: Int, tabId: String)
    case tabClose(id: Int, tabId: String)
    case taskRelease(id: Int, taskId: String)
    case pageSnapshot(id: Int, BrowserHostPageSnapshotRequest)
    case pageScreenshot(id: Int, BrowserHostPageScreenshotRequest)
    case pagePdf(id: Int, tabId: String, path: String)
    case pageAct(id: Int, BrowserHostPageActRequest)
    case pageUpload(id: Int, tabId: String, ref: Int, path: String)
    case dialogResolve(id: Int, tabId: String, accept: Bool, text: String?)
    case cookiesGet(id: Int, tabId: String)
    case cookiesClear(id: Int, tabId: String)
    case hostStatus(id: Int)
    case hostStopAck(id: Int)

    public var id: Int {
        switch self {
        case .tabOpen(let id, _), .tabNavigate(let id, _), .tabList(let id, _), .tabFocus(let id, _),
             .tabClose(let id, _), .taskRelease(let id, _), .pageSnapshot(let id, _), .pageScreenshot(let id, _),
             .pagePdf(let id, _, _), .pageAct(let id, _), .pageUpload(let id, _, _, _),
             .dialogResolve(let id, _, _, _), .cookiesGet(let id, _), .cookiesClear(let id, _),
             .hostStatus(let id), .hostStopAck(let id):
            return id
        }
    }

    public var wireType: String {
        switch self {
        case .tabOpen: return "tab.open"
        case .tabNavigate: return "tab.navigate"
        case .tabList: return "tab.list"
        case .tabFocus: return "tab.focus"
        case .tabClose: return "tab.close"
        case .taskRelease: return "task.release"
        case .pageSnapshot: return "page.snapshot"
        case .pageScreenshot: return "page.screenshot"
        case .pagePdf: return "page.pdf"
        case .pageAct: return "page.act"
        case .pageUpload: return "page.upload"
        case .dialogResolve: return "dialog.resolve"
        case .cookiesGet: return "cookies.get"
        case .cookiesClear: return "cookies.clear"
        case .hostStatus: return "host.status"
        case .hostStopAck: return "host.stop_ack"
        }
    }
}

/// The daemon's own refusal. Every one closes the connection.
public struct BrowserHostDaemonError: Equatable, Sendable, Decodable {
    public let reason: String
    public let message: String?
    /// The offending field, on `missing_field` and `invalid_field`.
    public let field: String?
    /// The type that was not an event, on `unknown_event`.
    public let event: String?
    public let direction: BrowserHostVersionDirection?
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
    public var window: BrowserHostVersionWindow? {
        guard let minVersion, let maxVersion else { return nil }

        return BrowserHostVersionWindow(minimum: minVersion, maximum: maxVersion)
    }
}

/// Everything the daemon may send before this build has attached, or at any
/// time: the handshake reply, a request to answer, or a fatal refusal.
public enum BrowserHostInbound: Equatable, Sendable {
    case serverHello(minVersion: Int, maxVersion: Int)
    case error(BrowserHostDaemonError)
    case request(BrowserHostRequest)
}

extension BrowserHostInbound: Decodable {
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

    private struct TaskIdPayload: Decodable {
        let taskId: String

        private enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
        }
    }

    private struct TabIdPayload: Decodable {
        let tabId: String

        private enum CodingKeys: String, CodingKey {
            case tabId = "tab_id"
        }
    }

    private struct PagePdfPayload: Decodable {
        let tabId: String
        let path: String

        private enum CodingKeys: String, CodingKey {
            case path
            case tabId = "tab_id"
        }
    }

    private struct PageUploadPayload: Decodable {
        let tabId: String
        let ref: Int
        let path: String

        private enum CodingKeys: String, CodingKey {
            case ref, path
            case tabId = "tab_id"
        }
    }

    private struct DialogResolvePayload: Decodable {
        let tabId: String
        let accept: Bool
        let text: String?

        private enum CodingKeys: String, CodingKey {
            case accept, text
            case tabId = "tab_id"
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
            self = .error(try BrowserHostDaemonError(from: decoder))
        default:
            let id = try discriminator.decode(Int.self, forKey: .id)
            self = .request(try Self.request(type: type, id: id, decoder: decoder))
        }
    }

    private static func request(type: String, id: Int, decoder: Decoder) throws -> BrowserHostRequest {
        switch type {
        case "tab.open":
            return .tabOpen(id: id, try BrowserHostTabOpenRequest(from: decoder))
        case "tab.navigate":
            return .tabNavigate(id: id, try BrowserHostTabNavigateRequest(from: decoder))
        case "tab.list":
            return .tabList(id: id, taskId: try TaskIdPayload(from: decoder).taskId)
        case "tab.focus":
            return .tabFocus(id: id, tabId: try TabIdPayload(from: decoder).tabId)
        case "tab.close":
            return .tabClose(id: id, tabId: try TabIdPayload(from: decoder).tabId)
        case "task.release":
            return .taskRelease(id: id, taskId: try TaskIdPayload(from: decoder).taskId)
        case "page.snapshot":
            return .pageSnapshot(id: id, try BrowserHostPageSnapshotRequest(from: decoder))
        case "page.screenshot":
            return .pageScreenshot(id: id, try BrowserHostPageScreenshotRequest(from: decoder))
        case "page.pdf":
            let payload = try PagePdfPayload(from: decoder)
            return .pagePdf(id: id, tabId: payload.tabId, path: payload.path)
        case "page.act":
            return .pageAct(id: id, try BrowserHostPageActRequest(from: decoder))
        case "page.upload":
            let payload = try PageUploadPayload(from: decoder)
            return .pageUpload(id: id, tabId: payload.tabId, ref: payload.ref, path: payload.path)
        case "dialog.resolve":
            let payload = try DialogResolvePayload(from: decoder)
            return .dialogResolve(id: id, tabId: payload.tabId, accept: payload.accept, text: payload.text)
        case "cookies.get":
            return .cookiesGet(id: id, tabId: try TabIdPayload(from: decoder).tabId)
        case "cookies.clear":
            return .cookiesClear(id: id, tabId: try TabIdPayload(from: decoder).tabId)
        case "host.status":
            return .hostStatus(id: id)
        case "host.stop_ack":
            return .hostStopAck(id: id)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [Discriminator.type],
                    debugDescription: "unknown browser host request type \(type)"
                )
            )
        }
    }
}

extension BrowserHostInbound {
    /// Decodes one wire line from the daemon. A line that is not an object,
    /// carries no `type`, or misses or misshapes a field its type requires is
    /// refused, named by the field's path.
    public static func decode(_ line: Data) throws(BrowserHostDecodeFailure) -> BrowserHostInbound {
        do {
            return try JSONDecoder().decode(BrowserHostInbound.self, from: line)
        } catch let error as DecodingError {
            throw Self.classify(error)
        } catch {
            throw .malformedJSON
        }
    }

    private static func classify(_ error: DecodingError) -> BrowserHostDecodeFailure {
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

/// A tab that closed, by however it closed.
public enum BrowserHostTabClosedBy: String, Equatable, Sendable, Encodable {
    case task
    case person
    case page
    case host
}

/// A JavaScript dialog's kind.
public enum BrowserHostDialogKind: String, Equatable, Sendable, Encodable {
    case alert
    case confirm
    case prompt
    case beforeunload
}

/// A download's terminal state.
public enum BrowserHostDownloadState: String, Equatable, Sendable, Encodable {
    case completed
    case failed
    case cancelled
}

/// Everything this build sends unasked, with no `id`.
public enum BrowserHostEvent: Equatable, Sendable {
    case clientHello(protocolVersion: Int)
    case attached(hostVersion: String, profileId: String)
    case availability(available: Bool, reason: String?)
    case tabClosed(tabId: String, by: BrowserHostTabClosedBy)
    case dialogOpened(tabId: String, kind: BrowserHostDialogKind, message: String, defaultText: String?)
    case downloadBegan(downloadId: String, tabId: String, filename: String)
    case downloadProgress(downloadId: String, receivedBytes: Int, totalBytes: Int?)
    case downloadFinished(
        downloadId: String,
        tabId: String,
        state: BrowserHostDownloadState,
        path: String?,
        bytes: Int?,
        reason: String?
    )
    case hostStopping

    public var wireType: String {
        switch self {
        case .clientHello: return "client_hello"
        case .attached: return "attached"
        case .availability: return "availability"
        case .tabClosed: return "tab.closed"
        case .dialogOpened: return "dialog.opened"
        case .downloadBegan: return "download.began"
        case .downloadProgress: return "download.progress"
        case .downloadFinished: return "download.finished"
        case .hostStopping: return "host_stopping"
        }
    }
}

extension BrowserHostEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, available, reason, by, kind, message, filename, state, path, bytes
        case protocolVersion = "protocol_version"
        case hostVersion = "host_version"
        case profileId = "profile_id"
        case tabId = "tab_id"
        case defaultText = "default"
        case downloadId = "download_id"
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)

        switch self {
        case .clientHello(let protocolVersion):
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case .attached(let hostVersion, let profileId):
            try container.encode(hostVersion, forKey: .hostVersion)
            try container.encode(profileId, forKey: .profileId)
        case .availability(let available, let reason):
            try container.encode(available, forKey: .available)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .tabClosed(let tabId, let by):
            try container.encode(tabId, forKey: .tabId)
            try container.encode(by, forKey: .by)
        case .dialogOpened(let tabId, let kind, let message, let defaultText):
            try container.encode(tabId, forKey: .tabId)
            try container.encode(kind, forKey: .kind)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(defaultText, forKey: .defaultText)
        case .downloadBegan(let downloadId, let tabId, let filename):
            try container.encode(downloadId, forKey: .downloadId)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(filename, forKey: .filename)
        case .downloadProgress(let downloadId, let receivedBytes, let totalBytes):
            try container.encode(downloadId, forKey: .downloadId)
            try container.encode(receivedBytes, forKey: .receivedBytes)
            try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        case .downloadFinished(let downloadId, let tabId, let state, let path, let bytes, let reason):
            try container.encode(downloadId, forKey: .downloadId)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(state, forKey: .state)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(bytes, forKey: .bytes)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .hostStopping:
            break
        }
    }

    /// The event as one line, without the newline the line socket adds. A
    /// line the daemon would refuse for its length throws `lineTooLarge`
    /// instead.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let line = try encoder.encode(self)
        guard line.count <= BrowserHostProtocol.maximumLineBytes else {
            throw BrowserHostEncodeFailure.lineTooLarge(bytes: line.count)
        }
        return line
    }
}

// MARK: - Responses (app → daemon)

/// One of the host's enumerated error reasons.
public enum BrowserHostErrorReason: String, Equatable, Sendable, Encodable {
    case tabNotFound = "tab_not_found"
    case capReached = "cap_reached"
    case notOwner = "not_owner"
    case navigationRefused = "navigation_refused"
    case actFailed = "act_failed"
    case staleRef = "stale_ref"
    case dialogBlocked = "dialog_blocked"
    case noDialog = "no_dialog"
    case waitTimeout = "wait_timeout"
    case writeFailed = "write_failed"
    case uploadFailed = "upload_failed"
    case invalidRequest = "invalid_request"
    case hostUnavailable = "host_unavailable"
}

/// A refusal of one request. Never closes the connection by itself.
public struct BrowserHostError: Equatable, Sendable, Encodable {
    public let reason: BrowserHostErrorReason
    public let message: String

    /// `message` is bounded to the contract's own cap: a refusal is never the
    /// line that trips `line_too_large`.
    public init(reason: BrowserHostErrorReason, message: String) {
        self.reason = reason
        self.message = String(message.prefix(BrowserHostProtocol.maximumMessageChars))
    }
}

/// One JSON scalar or nested object, wrapped as the schema's `axValue` wraps
/// a node's role, name and value.
public enum BrowserHostAXScalar: Equatable, Sendable, Encodable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

public struct BrowserHostAXValue: Equatable, Sendable, Encodable {
    public let value: BrowserHostAXScalar

    public init(_ value: BrowserHostAXScalar) {
        self.value = value
    }

    public init(_ value: String) {
        self.value = .string(value)
    }

    public init(_ value: Int) {
        self.value = .integer(value)
    }

    public init(_ value: Bool) {
        self.value = .boolean(value)
    }
}

/// One named property of a node, e.g. `level`, `editable` or `focused`.
public struct BrowserHostAXProperty: Equatable, Sendable, Encodable {
    public let name: String
    public let value: BrowserHostAXValue?

    public init(name: String, value: BrowserHostAXValue?) {
        self.name = name
        self.value = value
    }
}

/// A node's id, or the ref one of its ancestors names as a child: either a
/// string or an integer, the schema's own `anyOf`.
public enum BrowserHostNodeID: Equatable, Sendable, Encodable {
    case integer(Int)
    case string(String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// One accessibility node, in the shape `browser/snapshot.ex` renders.
/// `nodeId`, `backendDOMNodeId` and `childIds` keep the schema's own
/// camelCase spelling; the rest of this wire is snake_case.
public struct BrowserHostNode: Equatable, Sendable, Encodable {
    public let nodeId: BrowserHostNodeID
    public let role: BrowserHostAXValue?
    public let name: BrowserHostAXValue?
    public let value: BrowserHostAXValue?
    public let properties: [BrowserHostAXProperty]?
    public let backendDOMNodeId: Int?
    public let childIds: [BrowserHostNodeID]?

    public init(
        nodeId: BrowserHostNodeID,
        role: BrowserHostAXValue? = nil,
        name: BrowserHostAXValue? = nil,
        value: BrowserHostAXValue? = nil,
        properties: [BrowserHostAXProperty]? = nil,
        backendDOMNodeId: Int? = nil,
        childIds: [BrowserHostNodeID]? = nil
    ) {
        self.nodeId = nodeId
        self.role = role
        self.name = name
        self.value = value
        self.properties = properties
        self.backendDOMNodeId = backendDOMNodeId
        self.childIds = childIds
    }
}

/// A page as this build read it: its committed address, never a value the
/// page itself supplies.
public struct BrowserHostPage: Equatable, Sendable, Encodable {
    public let url: String
    public let title: String
    public let readyState: String
    public let nodes: [BrowserHostNode]

    private enum CodingKeys: String, CodingKey {
        case url, title, nodes
        case readyState = "ready_state"
    }

    public init(url: String, title: String, readyState: String, nodes: [BrowserHostNode]) {
        self.url = url
        self.title = title
        self.readyState = readyState
        self.nodes = nodes
    }
}

/// Cookie metadata. A value never crosses this wire.
public struct BrowserHostCookie: Equatable, Sendable, Encodable {
    public let name: String
    public let domain: String
    public let path: String?
    public let secure: Bool?
    public let httpOnly: Bool?
    public let sameSite: String?
    public let expires: Double?
    public let session: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, domain, path, secure, expires, session
        case httpOnly = "http_only"
        case sameSite = "same_site"
    }

    public init(
        name: String,
        domain: String,
        path: String? = nil,
        secure: Bool? = nil,
        httpOnly: Bool? = nil,
        sameSite: String? = nil,
        expires: Double? = nil,
        session: Bool? = nil
    ) {
        self.name = name
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.expires = expires
        self.session = session
    }
}

/// One tab in a `tab.list` answer.
public struct BrowserHostListedTab: Equatable, Sendable, Encodable {
    public let tabId: String
    public let url: String
    public let title: String
    public let active: Bool?
    public let openerTabId: String?

    private enum CodingKeys: String, CodingKey {
        case url, title, active
        case tabId = "tab_id"
        case openerTabId = "opener_tab_id"
    }

    public init(tabId: String, url: String, title: String, active: Bool? = nil, openerTabId: String? = nil) {
        self.tabId = tabId
        self.url = url
        self.title = title
        self.active = active
        self.openerTabId = openerTabId
    }
}

/// `tab.open` and `tab.navigate` answer the same shape.
public struct BrowserHostTabResult: Equatable, Sendable, Encodable {
    public let tabId: String
    public let url: String
    public let title: String
    public let page: BrowserHostPage?

    private enum CodingKeys: String, CodingKey {
        case url, title, page
        case tabId = "tab_id"
    }

    public init(tabId: String, url: String, title: String, page: BrowserHostPage? = nil) {
        self.tabId = tabId
        self.url = url
        self.title = title
        self.page = page
    }
}

public struct BrowserHostScreenshotResult: Equatable, Sendable, Encodable {
    public let path: String
    public let mimeType: String
    public let bytes: Int
    public let url: String
    public let devicePixelRatio: Double

    private enum CodingKeys: String, CodingKey {
        case path, bytes, url
        case mimeType = "mime_type"
        case devicePixelRatio = "device_pixel_ratio"
    }

    public init(path: String, mimeType: String, bytes: Int, url: String, devicePixelRatio: Double) {
        self.path = path
        self.mimeType = mimeType
        self.bytes = bytes
        self.url = url
        self.devicePixelRatio = devicePixelRatio
    }
}

public struct BrowserHostPdfResult: Equatable, Sendable, Encodable {
    public let path: String
    public let mimeType = "application/pdf"
    public let bytes: Int
    public let url: String

    private enum CodingKeys: String, CodingKey {
        case path, bytes, url
        case mimeType = "mime_type"
    }

    public init(path: String, bytes: Int, url: String) {
        self.path = path
        self.bytes = bytes
        self.url = url
    }
}

/// One JSON value, for `page.act`'s open-ended `value` (a `get`'s answer:
/// text, a count, a flag, or a `rect`).
public enum BrowserHostJSONValue: Equatable, Sendable, Encodable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case object([String: BrowserHostJSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct BrowserHostActResult: Equatable, Sendable, Encodable {
    public let url: String
    public let title: String
    public let value: BrowserHostJSONValue?
    public let page: BrowserHostPage?

    public init(url: String, title: String, value: BrowserHostJSONValue? = nil, page: BrowserHostPage? = nil) {
        self.url = url
        self.title = title
        self.value = value
        self.page = page
    }
}

public struct BrowserHostStatusResult: Equatable, Sendable, Encodable {
    public let hostVersion: String
    public let profileId: String
    public let available: Bool
    public let taskTabs: Int
    public let personTabs: Int

    private enum CodingKeys: String, CodingKey {
        case available
        case hostVersion = "host_version"
        case profileId = "profile_id"
        case taskTabs = "task_tabs"
        case personTabs = "person_tabs"
    }

    public init(hostVersion: String, profileId: String, available: Bool, taskTabs: Int, personTabs: Int) {
        self.hostVersion = hostVersion
        self.profileId = profileId
        self.available = available
        self.taskTabs = taskTabs
        self.personTabs = personTabs
    }
}

/// Which result shape a response carries, decided by the request its `id`
/// names.
public enum BrowserHostResult: Equatable, Sendable {
    case tabOpen(BrowserHostTabResult)
    case tabNavigate(BrowserHostTabResult)
    case tabList([BrowserHostListedTab])
    case tabFocus(tabId: String, url: String, title: String)
    case tabClose(tabId: String)
    case taskRelease([String])
    case pageSnapshot(BrowserHostPage)
    case pageScreenshot(BrowserHostScreenshotResult)
    case pagePdf(BrowserHostPdfResult)
    case pageAct(BrowserHostActResult)
    case pageUpload(tabId: String)
    case dialogResolve(tabId: String)
    case cookiesGet(url: String, cookies: [BrowserHostCookie])
    case cookiesClear(cleared: Int)
    case hostStatus(BrowserHostStatusResult)
    case hostStopAck
}

extension BrowserHostResult: Encodable {
    private enum SimpleKeys: String, CodingKey {
        case url, title, tabs, released, cleared
        case tabId = "tab_id"
    }

    private enum CookiesKeys: String, CodingKey {
        case url, cookies
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .tabOpen(let result):
            try result.encode(to: encoder)
        case .tabNavigate(let result):
            try result.encode(to: encoder)
        case .tabList(let tabs):
            var container = encoder.container(keyedBy: SimpleKeys.self)
            try container.encode(tabs, forKey: .tabs)
        case .tabFocus(let tabId, let url, let title):
            var container = encoder.container(keyedBy: SimpleKeys.self)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(url, forKey: .url)
            try container.encode(title, forKey: .title)
        case .tabClose(let tabId), .pageUpload(let tabId), .dialogResolve(let tabId):
            var container = encoder.container(keyedBy: SimpleKeys.self)
            try container.encode(tabId, forKey: .tabId)
        case .taskRelease(let released):
            var container = encoder.container(keyedBy: SimpleKeys.self)
            try container.encode(released, forKey: .released)
        case .pageSnapshot(let page):
            try page.encode(to: encoder)
        case .pageScreenshot(let result):
            try result.encode(to: encoder)
        case .pagePdf(let result):
            try result.encode(to: encoder)
        case .pageAct(let result):
            try result.encode(to: encoder)
        case .cookiesGet(let url, let cookies):
            var container = encoder.container(keyedBy: CookiesKeys.self)
            try container.encode(url, forKey: .url)
            try container.encode(cookies, forKey: .cookies)
        case .cookiesClear(let cleared):
            var container = encoder.container(keyedBy: SimpleKeys.self)
            try container.encode(cleared, forKey: .cleared)
        case .hostStatus(let result):
            try result.encode(to: encoder)
        case .hostStopAck:
            _ = encoder.container(keyedBy: SimpleKeys.self)
        }
    }
}

/// This build's answer to one request: a result, or an error from the host's
/// vocabulary.
public struct BrowserHostResponse: Equatable, Sendable {
    public let id: Int
    public let outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case success(BrowserHostResult)
        case failure(BrowserHostError)
    }

    public init(id: Int, result: BrowserHostResult) {
        self.id = id
        self.outcome = .success(result)
    }

    public init(id: Int, error: BrowserHostError) {
        self.id = id
        self.outcome = .failure(error)
    }
}

extension BrowserHostResponse: Encodable {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let line = try encoder.encode(self)
        guard line.count <= BrowserHostProtocol.maximumLineBytes else {
            throw BrowserHostEncodeFailure.lineTooLarge(bytes: line.count)
        }
        return line
    }
}
