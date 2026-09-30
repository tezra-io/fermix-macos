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
    ///
    /// Version 2 is the Live engine's: `task_cancel` outbound, `call_ready`,
    /// `caption` and `task` inbound, and the extra fields on `usage` and
    /// `error`. The daemon's window is N/N-1, so a daemon that speaks 2 still
    /// serves a pet speaking 1 for one release.
    public static let version = 2

    /// What the reader holds: one newline-delimited frame of at most 1 MiB,
    /// and at most 2 MiB of unscanned inbound data at once.
    public static let inboundLimits = LineInboundLimits(
        maximumLineBytes: 1_048_576,
        maximumBufferedBytes: 2_097_152
    )

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

/// Why a frame could not become an event. A frame too long to hold is the
/// line socket's refusal, not a decode failure: it never reaches the decoder.
public enum RealtimeDecodeFailure: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingType
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
    /// Calls off one backend delegation of a Live call. The Realtime engine has
    /// no delegations, and refuses this frame.
    case taskCancel(delegationId: String)

    public var wireType: String {
        switch self {
        case .clientHello: return "client_hello"
        case .callStart: return "call_start"
        case .audioChunk: return "audio_chunk"
        case .interrupt: return "interrupt"
        case .mute: return "mute"
        case .callStop: return "call_stop"
        case .taskCancel: return "task_cancel"
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
        case delegationId = "delegation_id"
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
        case .taskCancel(let delegationId):
            try container.encode(delegationId, forKey: .delegationId)
        case .callStart, .callStop:
            break
        }
    }

    /// The frame as one line, without the newline the line socket adds.
    public func line() throws -> Data {
        try JSONEncoder().encode(self)
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

/// Which side of the conversation a caption fragment came from, with the same
/// open-vocabulary treatment: a speaker this build has never seen keeps its own
/// word rather than being attributed to one of the two it knows.
public enum RealtimeCaptionSpeaker: Equatable, Sendable {
    case user
    case assistant
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "user": self = .user
        case "assistant": self = .assistant
        default: self = .unrecognized(wireValue)
        }
    }
}

/// The provider session is established and the call can carry audio.
///
/// `captions` is whether caption frames will follow at all, which is a property
/// of the call rather than of the transcript so far: false means this call
/// carries no captions, not that none have arrived yet.
public struct RealtimeCallReady: Equatable, Sendable {
    /// The daemon's own word for what is speaking, carried verbatim.
    public let engine: String
    public let callId: String
    public let providerSessionId: String?
    /// Unix seconds, absent where the provider never said when it expires.
    public let expiresAt: Int?
    public let captions: Bool

    public init(
        engine: String,
        callId: String,
        providerSessionId: String? = nil,
        expiresAt: Int? = nil,
        captions: Bool
    ) {
        self.engine = engine
        self.callId = callId
        self.providerSessionId = providerSessionId
        self.expiresAt = expiresAt
        self.captions = captions
    }
}

/// One verbatim transcript fragment.
///
/// `delta` is carried byte for byte: the contract says to concatenate fragments
/// as they arrive, never trimming them or inserting spaces, and user and
/// assistant fragments may overlap in time.
public struct RealtimeCaption: Equatable, Sendable {
    public let speaker: RealtimeCaptionSpeaker
    public let delta: String
    public let startMs: Int
    public let endMs: Int

    public init(speaker: RealtimeCaptionSpeaker, delta: String, startMs: Int, endMs: Int) {
        self.speaker = speaker
        self.delta = delta
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// How one backend delegation is doing, with the open-vocabulary treatment.
public enum RealtimeTaskStatus: Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "pending": self = .pending
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unrecognized(wireValue)
        }
    }

    /// Whether the delegation has stopped. A status this build cannot read is
    /// not terminal: work whose word is unknown is work nothing may claim has
    /// finished.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .running, .unrecognized: return false
        }
    }
}

/// The lifecycle of one backend delegation of a Live call.
///
/// `revision` fences a re-asked task, so a late frame from an earlier revision
/// can be told apart from the current one rather than read as it.
public struct RealtimeTask: Equatable, Sendable {
    public let delegationId: String
    public let revision: Int
    public let status: RealtimeTaskStatus
    /// The daemon's bounded sentence about the work, where it sent one.
    public let summary: String?

    public init(delegationId: String, revision: Int, status: RealtimeTaskStatus, summary: String? = nil) {
        self.delegationId = delegationId
        self.revision = revision
        self.status = status
        self.summary = summary
    }
}

/// What a turn, or a whole Live call, cost.
///
/// Every field is optional because the Realtime engine sends none of them and
/// the Live engine fills them in as the call settles. `backendCost` carries the
/// daemon's own word, which is `unknown` for a backend billing against a
/// subscription allowance: unknown is not zero, so it is never rendered as one.
public struct RealtimeUsage: Equatable, Sendable {
    public let status: String?
    public let voiceSeconds: Double?
    public let voiceCostCents: Double?
    public let backendTurns: Int?
    public let backendCost: String?
    /// `complete`, `incomplete`, or `running`, in the daemon's own word.
    public let accounting: String?

    public init(
        status: String? = nil,
        voiceSeconds: Double? = nil,
        voiceCostCents: Double? = nil,
        backendTurns: Int? = nil,
        backendCost: String? = nil,
        accounting: String? = nil
    ) {
        self.status = status
        self.voiceSeconds = voiceSeconds
        self.voiceCostCents = voiceCostCents
        self.backendTurns = backendTurns
        self.backendCost = backendCost
        self.accounting = accounting
    }
}

/// The typed failure behind a refusal, where the daemon named one. The eight
/// words are the contract's; a ninth keeps its own rather than being folded
/// into a neighbour.
public enum RealtimeErrorKind: Equatable, Sendable {
    case updateRequired
    case providerRefused
    case costLimit
    case sessionExpired
    case closeTimeout
    case bridgeUnavailable
    case maxSessionDuration
    case providerDisconnected
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "update_required": self = .updateRequired
        case "provider_refused": self = .providerRefused
        case "cost_limit": self = .costLimit
        case "session_expired": self = .sessionExpired
        case "close_timeout": self = .closeTimeout
        case "bridge_unavailable": self = .bridgeUnavailable
        case "max_session_duration": self = .maxSessionDuration
        case "provider_disconnected": self = .providerDisconnected
        default: self = .unrecognized(wireValue)
        }
    }
}

/// A structured refusal from the daemon. `reason` is the daemon's own word and
/// is carried verbatim.
public struct RealtimeServerError: Equatable, Sendable {
    public let reason: String
    /// The typed failure, where the daemon named one beside the reason.
    public let kind: RealtimeErrorKind?
    /// The vendor's own bounded sentence, where the provider explained itself.
    /// A terminal status word is not a diagnosis, so this is what a surface
    /// shows when it has one.
    public let detail: String?
    /// On an update_required refusal, the engine that needs the higher version.
    public let requiredFor: String?
    public let direction: RealtimeVersionDirection?
    public let minVersion: Int?
    public let maxVersion: Int?

    public init(
        reason: String,
        kind: RealtimeErrorKind? = nil,
        detail: String? = nil,
        requiredFor: String? = nil,
        direction: RealtimeVersionDirection? = nil,
        minVersion: Int? = nil,
        maxVersion: Int? = nil
    ) {
        self.reason = reason
        self.kind = kind
        self.detail = detail
        self.requiredFor = requiredFor
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
    case usage(RealtimeUsage)
    case error(RealtimeServerError)
    case playbackStop
    case callReady(RealtimeCallReady)
    case caption(RealtimeCaption)
    case task(RealtimeTask)
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
        case .callReady: return "call_ready"
        case .caption: return "caption"
        case .task: return "task"
        case .unrecognized(let type): return type
        }
    }

    public var isUnrecognized: Bool {
        if case .unrecognized = self { return true }

        return false
    }

    /// Decodes one wire frame. A frame that is not an object, or that carries no
    /// `type`, is a contract violation and is refused; an unknown `type` is not.
    ///
    /// `JSONDecoder` declares an untyped error; anything it throws that is not
    /// a `DecodingError` is still bytes that are not a frame.
    public static func decode(_ frame: Data) throws(RealtimeDecodeFailure) -> RealtimeServerEvent {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(RealtimeServerEvent.self, from: frame)
        } catch let failure as RealtimeDecodeFailure {
            throw failure
        } catch let error as DecodingError {
            throw Self.classify(error)
        } catch {
            throw .malformedJSON
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
        case type, state, audio, text, status, reason, direction, kind, detail
        case engine, captions, speaker, delta, revision, summary, accounting
        case minVersion = "min_version"
        case maxVersion = "max_version"
        case requiredFor = "required_for"
        case callId = "call_id"
        case providerSessionId = "provider_session_id"
        case expiresAt = "expires_at"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case delegationId = "delegation_id"
        case voiceSeconds = "voice_seconds"
        case voiceCostCents = "voice_cost_cents"
        case backendTurns = "backend_turns"
        case backendCost = "backend_cost"
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
            self = .usage(try Self.usage(from: container))
        case "playback_stop":
            self = .playbackStop
        case "call_ready":
            self = .callReady(try Self.callReady(from: container))
        case "caption":
            self = .caption(try Self.caption(from: container))
        case "task":
            self = .task(try Self.task(from: container))
        case "error":
            self = .error(try Self.serverError(from: container))
        default:
            self = .unrecognized(type: type)
        }
    }

    private typealias Fields = KeyedDecodingContainer<CodingKeys>

    /// Every field the contract makes optional is read as optional: a Realtime
    /// `usage` frame carries none of the Live ones and must still decode.
    private static func usage(from fields: Fields) throws -> RealtimeUsage {
        RealtimeUsage(
            status: try fields.decodeIfPresent(String.self, forKey: .status),
            voiceSeconds: try fields.decodeIfPresent(Double.self, forKey: .voiceSeconds),
            voiceCostCents: try fields.decodeIfPresent(Double.self, forKey: .voiceCostCents),
            backendTurns: try fields.decodeIfPresent(Int.self, forKey: .backendTurns),
            backendCost: try fields.decodeIfPresent(String.self, forKey: .backendCost),
            accounting: try fields.decodeIfPresent(String.self, forKey: .accounting)
        )
    }

    private static func callReady(from fields: Fields) throws -> RealtimeCallReady {
        RealtimeCallReady(
            engine: try fields.decode(String.self, forKey: .engine),
            callId: try fields.decode(String.self, forKey: .callId),
            providerSessionId: try fields.decodeIfPresent(String.self, forKey: .providerSessionId),
            expiresAt: try fields.decodeIfPresent(Int.self, forKey: .expiresAt),
            captions: try fields.decode(Bool.self, forKey: .captions)
        )
    }

    private static func caption(from fields: Fields) throws -> RealtimeCaption {
        RealtimeCaption(
            speaker: RealtimeCaptionSpeaker(wireValue: try fields.decode(String.self, forKey: .speaker)),
            delta: try fields.decode(String.self, forKey: .delta),
            startMs: try fields.decode(Int.self, forKey: .startMs),
            endMs: try fields.decode(Int.self, forKey: .endMs)
        )
    }

    private static func task(from fields: Fields) throws -> RealtimeTask {
        RealtimeTask(
            delegationId: try fields.decode(String.self, forKey: .delegationId),
            revision: try fields.decode(Int.self, forKey: .revision),
            status: RealtimeTaskStatus(wireValue: try fields.decode(String.self, forKey: .status)),
            summary: try fields.decodeIfPresent(String.self, forKey: .summary)
        )
    }

    private static func serverError(from fields: Fields) throws -> RealtimeServerError {
        RealtimeServerError(
            reason: try fields.decode(String.self, forKey: .reason),
            kind: try fields.decodeIfPresent(String.self, forKey: .kind).map(RealtimeErrorKind.init(wireValue:)),
            detail: try fields.decodeIfPresent(String.self, forKey: .detail),
            requiredFor: try fields.decodeIfPresent(String.self, forKey: .requiredFor),
            direction: try fields.decodeIfPresent(String.self, forKey: .direction)
                .flatMap(RealtimeVersionDirection.init(rawValue:)),
            minVersion: try fields.decodeIfPresent(Int.self, forKey: .minVersion),
            maxVersion: try fields.decodeIfPresent(Int.self, forKey: .maxVersion)
        )
    }
}
