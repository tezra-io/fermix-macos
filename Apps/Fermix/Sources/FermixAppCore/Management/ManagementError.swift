import Foundation

/// A structured error the daemon returned. `message` is the daemon's own
/// operator-facing sentence and is carried verbatim — the app renders what the
/// engine said rather than paraphrasing it.
public struct ManagementFailure: Error, Equatable, Sendable {
    public let code: ManagementErrorCode
    public let message: String
    public let details: ManagementErrorDetails

    public init(code: ManagementErrorCode, message: String, details: ManagementErrorDetails) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension ManagementFailure: Decodable {
    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(ManagementErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        details = try container.decode(ManagementErrorDetails.self, forKey: .details)
    }
}

/// What was wrong with a response envelope. A response carries exactly one of
/// `result` or `error`; anything else is a contract violation, and the app says
/// which one rather than reporting a generic decode failure.
public enum ManagementEnvelopeDefect: Equatable, Sendable {
    case undecodableJSON
    case resultAndErrorPresent
    case neitherResultNorError
    case requestIdentifierMissing
    case resultShapeMismatch(method: ManagementMethod, field: String)
}

/// A parameter the client refused to send. Bounds come from the schema, so an
/// oversized request is rejected here rather than at an opaque wire failure.
public enum ManagementParameterDefect: Equatable, Sendable {
    case empty(field: String)
    case outOfRange(field: String)
    case encodedParamsTooLarge(byteCount: Int, limit: Int)
}

/// Everything a management call can fail with, as typed values. No case carries
/// a free-form diagnostic string: the only prose that crosses this boundary is
/// the daemon's own `message`, on `daemon`.
public enum ManagementError: Error, Equatable, Sendable {
    /// The daemon answered with a structured error.
    case daemon(ManagementFailure)
    /// A response arrived under a different request id than the one sent.
    case correlationMismatch(expected: String, received: String?)
    case malformedEnvelope(ManagementEnvelopeDefect)
    /// The encoded request exceeds the published frame ceiling.
    case requestTooLarge(byteCount: Int, limit: Int)
    case invalidParameter(ManagementParameterDefect)
    /// The generated request id does not match the published pattern. The id is
    /// refused whole; it is never truncated into one that does.
    case invalidRequestIdentifier(String)
    /// A call was made before `hello` established the daemon's window.
    case notNegotiated(method: ManagementMethod)
    /// The app and the daemon share no protocol version. There is nothing to
    /// negotiate and nothing to restart into: this is a boot failure.
    case incompatibleProtocol(app: [Int], daemon: ManagementProtocolRange)
    /// The negotiated version is below the method's published minimum, which is
    /// the ordinary state of a running daemon one release behind the bundle it
    /// was launched from. It is **not** a boot failure: everything at minimum 1
    /// still works, so the app reads the state, says why, and offers the
    /// restart that fixes it.
    case methodRequiresNewerEngine(method: ManagementMethod, required: Int, negotiated: Int)
    case transport(ManagementTransportFailure)
}

/// A transport-level failure, at the layer that observed it.
public enum ManagementTransportFailure: Error, Equatable, Sendable {
    /// No socket file at the bootstrap path: the daemon is not running.
    case socketMissing(path: String)
    /// A socket file with nobody listening: a stale socket from a dead daemon.
    case daemonNotListening(path: String)
    case socketPathTooLong(path: String)
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case pollFailed(errno: Int32)
    /// The peer closed before writing any part of a response.
    case peerClosedBeforeResponse
    /// A frame arrives whole or not at all, so a partial one is never retried.
    case shortFrame(expected: Int, received: Int)
    case frameTooLarge(byteCount: Int, limit: Int)
    case emptyFrame
    case timedOut(after: Duration)
    /// A deadline that is not a deadline: zero, negative, or beyond the ceiling
    /// on a single exchange. Distinct from `timedOut`, which means a real wait
    /// elapsed.
    case invalidTimeout(Duration)
}
