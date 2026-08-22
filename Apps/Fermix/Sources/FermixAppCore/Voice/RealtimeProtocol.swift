import Foundation

/// The realtime voice wire, as this build speaks it.
///
/// The version and the event shapes come from the vendored contract
/// (`Resources/Contracts/realtime/`); the bounds are this client's, because the
/// contract publishes no frame ceiling of its own and an unbounded reader is a
/// memory fault waiting for a bad peer.
public enum RealtimeProtocol {
    /// Wire protocol version this build speaks, validated against the daemon's
    /// advertised range during the handshake.
    public static let version = 1

    /// The largest single newline-delimited frame this client will assemble.
    public static let maximumFrameBytes = 1_048_576

    /// The largest amount of unscanned inbound data held at once.
    public static let maximumInboundBufferBytes = 2_097_152

    /// How long the daemon has to answer `client_hello` with `server_hello`.
    public static let handshakeTimeout: TimeInterval = 3
}

/// The version window a daemon advertised.
public struct RealtimeVersionWindow: Equatable, Sendable {
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
    public func direction(for version: Int) -> RealtimeVersionDirection {
        version < minimum ? .clientTooOld : .clientTooNew
    }
}

/// Which side of the wire is out of date. The daemon publishes the same two
/// words on its refusal, so this reads the same in both directions.
public enum RealtimeVersionDirection: String, Equatable, Sendable {
    case clientTooOld = "client_too_old"
    case clientTooNew = "client_too_new"
}

/// Why a frame could not become an event.
public enum RealtimeDecodeFailure: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingType
    case frameTooLarge(bytes: Int)
    case inboundBufferExceeded(bytes: Int)
}

// MARK: - Client events

/// Everything this client sends. The wire names are the contract's, and a value
/// is the only way to produce a frame: nothing composes a dictionary by hand.
public enum RealtimeClientEvent: Equatable, Sendable, Encodable {
    case clientHello(protocolVersion: Int)
    case callStart
    case audioChunk(base64: String)
    case interrupt(audioEndMs: Int?)
    case mute(enabled: Bool)
    case callStop

    public var wireType: String {
        switch self {
        case .clientHello: return "client_hello"
        case .callStart: return "call_start"
        case .audioChunk: return "audio_chunk"
        case .interrupt: return "interrupt"
        case .mute: return "mute"
        case .callStop: return "call_stop"
        }
    }

    /// Whether this frame may be dropped when the socket backs up. Audio is
    /// real-time droppable media; everything else is control traffic.
    public var isDroppable: Bool {
        if case .audioChunk = self { return true }

        return false
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case audio
        case audioEndMs = "audio_end_ms"
        case enabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)

        switch self {
        case .clientHello(let version):
            try container.encode(version, forKey: .protocolVersion)
        case .audioChunk(let base64):
            try container.encode(base64, forKey: .audio)
        case .interrupt(let audioEndMs):
            try container.encodeIfPresent(audioEndMs, forKey: .audioEndMs)
        case .mute(let enabled):
            try container.encode(enabled, forKey: .enabled)
        case .callStart, .callStop:
            break
        }
    }

    /// The newline-terminated frame as it goes on the wire.
    public func frame() throws -> Data {
        var payload = try JSONEncoder().encode(self)
        payload.append(0x0A)
        return payload
    }
}

// MARK: - Server events

/// The turn state the daemon reports. The vocabulary is open and additive: a
/// value this build has never seen keeps its own word rather than being folded
/// into a neighbour, and the presentation treats it as idle.
public enum RealtimeTurnState: Equatable, Sendable {
    case idle
    case listening
    case speaking
    case muted
    case thinking
    case reconnecting
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "idle": self = .idle
        case "listening": self = .listening
        case "speaking": self = .speaking
        case "muted": self = .muted
        case "thinking": self = .thinking
        case "reconnecting": self = .reconnecting
        default: self = .unrecognized(wireValue)
        }
    }
}

/// A tool call's lifecycle, with the same open-vocabulary treatment.
public enum RealtimeToolStatus: Equatable, Sendable {
    case started
    case completed
    case failed
    case unrecognized(String)

    public init(wireValue: String?) {
        switch wireValue {
        case "completed": self = .completed
        case "error": self = .failed
        case "started", .none: self = .started
        case .some(let value): self = .unrecognized(value)
        }
    }
}

/// A structured refusal from the daemon. `reason` is the daemon's own word and
/// is carried verbatim.
public struct RealtimeServerError: Equatable, Sendable {
    public let reason: String
    public let direction: RealtimeVersionDirection?
    public let minVersion: Int?
    public let maxVersion: Int?

    public init(
        reason: String,
        direction: RealtimeVersionDirection? = nil,
        minVersion: Int? = nil,
        maxVersion: Int? = nil
    ) {
        self.reason = reason
        self.direction = direction
        self.minVersion = minVersion
        self.maxVersion = maxVersion
    }

    /// The window the refusal named, when it named one.
    public var window: RealtimeVersionWindow? {
        guard let minVersion, let maxVersion else { return nil }

        return RealtimeVersionWindow(minimum: minVersion, maximum: maxVersion)
    }
}

/// Everything the daemon sends.
public enum RealtimeServerEvent: Equatable, Sendable {
    case serverHello(minVersion: Int, maxVersion: Int)
    case state(RealtimeTurnState)
    case audioDelta(base64: String)
    case transcriptDelta(text: String)
    case assistantTextDelta(text: String)
    case toolEvent(status: RealtimeToolStatus, reason: String?)
    case usage
    case error(RealtimeServerError)
    case playbackStop
    /// An event type published after this build shipped.
    case unrecognized(type: String)

    public var wireType: String {
        switch self {
        case .serverHello: return "server_hello"
        case .state: return "state"
        case .audioDelta: return "audio_delta"
        case .transcriptDelta: return "transcript_delta"
        case .assistantTextDelta: return "assistant_text_delta"
        case .toolEvent: return "tool_event"
        case .usage: return "usage"
        case .error: return "error"
        case .playbackStop: return "playback_stop"
        case .unrecognized(let type): return type
        }
    }

    public var isUnrecognized: Bool {
        if case .unrecognized = self { return true }

        return false
    }

    /// Decodes one wire frame. A frame that is not an object, or that carries no
    /// `type`, is a contract violation and is refused; an unknown `type` is not.
    public static func decode(_ frame: Data) throws -> RealtimeServerEvent {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(RealtimeServerEvent.self, from: frame)
        } catch let failure as RealtimeDecodeFailure {
            throw failure
        } catch let error as DecodingError {
            throw Self.classify(error)
        }
    }

    private static func classify(_ error: DecodingError) -> RealtimeDecodeFailure {
        switch error {
        case .typeMismatch, .valueNotFound:
            return .notAnObject
        case .keyNotFound:
            return .missingType
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? .malformedJSON : .notAnObject
        @unknown default:
            return .malformedJSON
        }
    }
}

extension RealtimeServerEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, state, audio, text, status, reason, direction
        case minVersion = "min_version"
        case maxVersion = "max_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "server_hello":
            self = .serverHello(
                minVersion: try container.decode(Int.self, forKey: .minVersion),
                maxVersion: try container.decode(Int.self, forKey: .maxVersion)
            )
        case "state":
            let state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
            self = .state(RealtimeTurnState(wireValue: state))
        case "audio_delta":
            self = .audioDelta(base64: try container.decode(String.self, forKey: .audio))
        case "transcript_delta":
            self = .transcriptDelta(text: try container.decode(String.self, forKey: .text))
        case "assistant_text_delta":
            self = .assistantTextDelta(text: try container.decode(String.self, forKey: .text))
        case "tool_event":
            self = .toolEvent(
                status: RealtimeToolStatus(
                    wireValue: try container.decodeIfPresent(String.self, forKey: .status)
                ),
                reason: try container.decodeIfPresent(String.self, forKey: .reason)
            )
        case "usage":
            self = .usage
        case "playback_stop":
            self = .playbackStop
        case "error":
            self = .error(
                RealtimeServerError(
                    reason: try container.decode(String.self, forKey: .reason),
                    direction: try container.decodeIfPresent(String.self, forKey: .direction)
                        .flatMap(RealtimeVersionDirection.init(rawValue:)),
                    minVersion: try container.decodeIfPresent(Int.self, forKey: .minVersion),
                    maxVersion: try container.decodeIfPresent(Int.self, forKey: .maxVersion)
                )
            )
        default:
            self = .unrecognized(type: type)
        }
    }
}
