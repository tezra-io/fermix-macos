import Foundation

/// The uniform job view, and the results of the methods that mint one.
///
/// M34 §7.3: long operations are jobs, never held requests. One shape covers
/// every family, so a poller, a progress row and a failure sentence are written
/// once rather than per operation.

/// Counted progress, where a job has any. Every job this daemon runs publishes
/// `progress: null`: the installers and the download stream report stages, not
/// bytes, so the field is decoded and rendered where it arrives rather than
/// invented. A caller with no progress shows an indeterminate indicator.
public struct ManagementJobProgress: Decodable, Equatable, Sendable {
    public let done: Int
    /// Nil while the total is not yet known, which a byte-progress install has
    /// before its first response header.
    public let total: Int?
    public let unit: String?

    /// The fraction done, only where a total is known. A caller with nil shows
    /// an indeterminate indicator rather than inventing a denominator.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(done) / Double(total)
    }
}

/// Why a job ended badly, in the daemon's own words. The app renders the
/// sentence; it never composes one from the code.
public struct ManagementJobFailure: Decodable, Equatable, Sendable {
    public let code: ManagementJobFailureCode
    public let sentence: String
}

public struct ManagementJob: Decodable, Equatable, Sendable {
    public let jobId: String
    public let kind: ManagementJobKind
    public let status: ManagementJobStatus
    /// A free-form phase name for the current step. It is display copy from the
    /// daemon and never a state the app switches on: `status` is the state.
    ///
    /// The daemon clears it on `completed` and `cancelled`, and keeps it on
    /// `failed` and `timed_out`, so the phase a job stopped in is still
    /// readable next to its failure sentence.
    public let phase: String?
    public let progress: ManagementJobProgress?
    public let budgetMs: Int
    public let startedAt: String
    public let finishedAt: String?
    /// The job's own answer, flat and bounded: public scalars only.
    public let result: ManagementScalarMap?
    public let failure: ManagementJobFailure?

    private enum CodingKeys: String, CodingKey {
        case kind, status, phase, progress, result, failure
        case jobId = "job_id"
        case budgetMs = "budget_ms"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

public struct ManagementJobList: Decodable, Equatable, Sendable {
    public let jobs: [ManagementJob]
}

/// `auth.start`'s result: the job view, plus the authorize url the daemon hands
/// back exactly once.
///
/// The url is flat on the wire, so the job half is decoded from the same
/// container rather than from a nested object that is not there.
public struct ManagementAuthStart: Decodable, Equatable, Sendable {
    public let job: ManagementJob
    /// Returned once, on the call that starts the flow. Never logged, never
    /// persisted, never put on the pasteboard.
    public let authorizeURL: String?
    public let expiresInMs: Int?

    private enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
        case expiresInMs = "expires_in_ms"
    }

    public init(from decoder: Decoder) throws {
        job = try ManagementJob(from: decoder)

        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizeURL = try container.decodeIfPresent(String.self, forKey: .authorizeURL)
        expiresInMs = try container.decodeIfPresent(Int.self, forKey: .expiresInMs)
    }
}

/// The result of a write whose only consequence is a restart requirement.
public struct ManagementRestartOnly: Decodable, Equatable, Sendable {
    public let restart: ManagementRestartState
}
