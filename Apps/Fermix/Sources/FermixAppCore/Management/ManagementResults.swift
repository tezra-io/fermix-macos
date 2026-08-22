import Foundation

/// The typed results of the eleven management methods. Each type mirrors the
/// vendored schema; the coding keys are the wire names, so a shape can be read
/// against `protocol.schema.json` line by line.

public struct ManagementProtocolRange: Codable, Equatable, Sendable {
    public let currentVersion: Int
    public let minimum: Int
    public let maximum: Int

    public var window: ManagementVersionWindow {
        ManagementVersionWindow(minimum: minimum, maximum: maximum)
    }

    private enum CodingKeys: String, CodingKey {
        case currentVersion = "current_version"
        case minimum = "minimum_version"
        case maximum = "maximum_version"
    }
}

/// The immutable identity of the engine behind this socket.
public struct ManagementEngineIdentity: Codable, Equatable, Sendable {
    public let engineId: String
    public let productVersion: String
    public let buildId: String?
    public let sourceCommit: String?
    public let distributionIdentity: String
    public let artifactTarget: String?
    public let architecture: String
    public let pid: String

    private enum CodingKeys: String, CodingKey {
        case engineId = "engine_id"
        case productVersion = "product_version"
        case buildId = "build_id"
        case sourceCommit = "source_commit"
        case distributionIdentity = "distribution_identity"
        case artifactTarget = "artifact_target"
        case architecture
        case pid
    }
}

public struct ManagementCapabilityCatalog: Decodable, Equatable, Sendable {
    public let methods: [String]
}

public struct ManagementSetupEndpoint: Decodable, Equatable, Sendable {
    public let origin: String
    public let path: String
}

public struct ManagementHello: Decodable, Equatable, Sendable {
    public let protocolRange: ManagementProtocolRange
    public let capabilities: ManagementCapabilityCatalog
    public let engine: ManagementEngineIdentity
    public let setup: ManagementSetupEndpoint

    private enum CodingKeys: String, CodingKey {
        case protocolRange = "protocol"
        case capabilities, engine, setup
    }
}

/// A one-use Setup URL. The durable token never crosses this boundary, and the
/// url is never logged or persisted by the app.
public struct ManagementSetupSession: Decodable, Equatable, Sendable {
    public let url: String
    public let expiresAtMs: Int

    /// The absolute expiry the daemon minted, which needs no client clock.
    public var expiresAt: Date {
        Date(timeIntervalSince1970: Double(expiresAtMs) / 1000)
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case expiresAtMs = "expires_at_ms"
    }
}

public struct ManagementDoctorSummary: Decodable, Equatable, Sendable {
    public let passed: Int
    public let warning: Int
    public let failed: Int
    public let notApplicable: Int
    public let unavailable: Int
    public let skipped: Int
    public let cancelled: Int
    public let timedOut: Int

    private enum CodingKeys: String, CodingKey {
        case passed, warning, failed, unavailable, skipped, cancelled
        case notApplicable = "not_applicable"
        case timedOut = "timed_out"
    }
}

public struct ManagementDoctorCheck: Codable, Equatable, Sendable {
    public let id: String
    public let category: ManagementCheckCategory
    public let severity: ManagementCheckSeverity
    public let applicability: ManagementCheckApplicability
    public let origin: String
    public let status: ManagementCheckStatus
    public let summary: String
    public let evidence: ManagementScalarMap
    public let remediationCode: String?
    public let durationMs: Int
    public let finishedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, category, severity, applicability, origin, status, summary, evidence
        case remediationCode = "remediation_code"
        case durationMs = "duration_ms"
        case finishedAt = "finished_at"
    }
}

/// A Doctor run. It is the one management operation that is a run: it has its
/// own session id, a whole-run budget, and cancellation.
public struct ManagementDoctorSession: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let scope: ManagementDoctorScope
    public let status: ManagementDoctorStatus
    public let budgetMs: Int
    public let durationMs: Int
    public let startedAt: String
    public let finishedAt: String?
    public let total: Int
    public let completedCount: Int
    public let summary: ManagementDoctorSummary
    public let checks: [ManagementDoctorCheck]

    private enum CodingKeys: String, CodingKey {
        case scope, status, total, summary, checks
        case sessionId = "session_id"
        case budgetMs = "budget_ms"
        case durationMs = "duration_ms"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case completedCount = "completed_count"
    }
}

public struct ManagementLogEntry: Codable, Equatable, Sendable {
    public let time: String
    public let level: ManagementLogLevel
    public let subsystem: String?
    public let message: String
}

/// One bounded page of redacted log entries plus the opaque cursor for the next
/// page in the same direction.
public struct ManagementLogPage: Decodable, Equatable, Sendable {
    public let entries: [ManagementLogEntry]
    public let count: Int
    public let truncated: Bool
    public let direction: ManagementLogDirection
    public let cursor: String?
}

/// The wire shape of a prepared drain window.
struct ManagementLifecyclePrepared: Decodable, Equatable, Sendable {
    let leaseId: String
    let ttlMs: Int

    private enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case ttlMs = "ttl_ms"
    }
}

/// A drain lease. `ttl_ms` is relative on purpose — the daemon's expiry timer
/// runs on monotonic time, which a wall-clock deadline would disagree with —
/// so the client resolves it against its own clock on receipt.
public struct ManagementLifecycleLease: Equatable, Sendable {
    public let leaseId: String
    public let ttlMs: Int
    public let expiresAt: Date

    public init(leaseId: String, ttlMs: Int, expiresAt: Date) {
        self.leaseId = leaseId
        self.ttlMs = ttlMs
        self.expiresAt = expiresAt
    }
}

public struct ManagementLifecycleTransition: Decodable, Equatable, Sendable {
    public let leaseId: String
    public let status: ManagementLifecycleOutcome

    private enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case status
    }
}

public struct ManagementServiceState: Codable, Equatable, Sendable {
    public let scope: String?
    public let state: String?
}

public struct ManagementDiagnosticsDoctor: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let scope: String?
    public let status: String?
    public let finishedAt: String?
    public let checks: [ManagementDoctorCheck]

    private enum CodingKeys: String, CodingKey {
        case scope, status, checks
        case sessionId = "session_id"
        case finishedAt = "finished_at"
    }
}

public struct ManagementDiagnosticsLogs: Codable, Equatable, Sendable {
    public let count: Int
    public let truncated: Bool
    public let entries: [ManagementLogEntry]
}

/// A bounded, field-allowlisted, scrubbed diagnostic object for user-selected
/// export.
public struct ManagementDiagnostics: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let engine: ManagementEngineIdentity
    public let protocolRange: ManagementProtocolRange
    public let service: ManagementServiceState
    public let doctor: ManagementDiagnosticsDoctor?
    public let logs: ManagementDiagnosticsLogs

    private enum CodingKeys: String, CodingKey {
        case engine, service, doctor, logs
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case protocolRange = "protocol"
    }
}

/// The support bundle, as bytes.
///
/// The object is written back through the same coding keys it was read with, so
/// the exported file is the object the contract describes rather than a second
/// representation of it. The daemon is what bounds, allowlists, and scrubs the
/// content; nothing here adds a field or reads a file.
public enum ManagementDiagnosticsDocument {
    public static func json(_ diagnostics: ManagementDiagnostics) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(diagnostics)
    }
}
