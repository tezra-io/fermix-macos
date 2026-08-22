import Foundation

@testable import FermixAppCore

/// The one daemon double the five surfaces run against.
///
/// It answers each method from a script the test sets and records what was
/// asked, in order, so a surface's traffic is an assertion rather than a
/// side effect nobody can see. A method with no scripted answer raises: a
/// surface that calls something the scenario never prepared is a test defect,
/// never a silent empty result.
final class FakeDaemonGateway: DaemonQuerying, @unchecked Sendable {
    enum Call: Equatable {
        case negotiate
        case overview
        case setupSession
        case doctorStart(ManagementDoctorScope)
        case doctorGet(String)
        case doctorCancel(String)
        case logs(ManagementLogsQuery)
        case diagnostics
    }

    enum Defect: Error, Equatable {
        case notScripted(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var hello: ManagementHello?
    var overviewResult: ManagementOverview?
    var setupSession: ManagementSetupSession?
    /// Doctor answers, consumed in order: start takes the first, each get the
    /// next. An exhausted script keeps answering with the last one, which is
    /// what a finished session actually does.
    var doctorScript: [ManagementDoctorSession] = []
    var logPages: [ManagementLogPage] = []
    var diagnostics: ManagementDiagnostics?

    /// Holds `doctor.start` open, so a test can act inside the window between
    /// the surface declaring a run and the daemon issuing its session id.
    var startGate: (@Sendable () async -> Void)?

    var negotiateFailure: (any Error)?
    var overviewFailure: (any Error)?
    var setupFailure: (any Error)?
    var doctorFailure: (any Error)?
    var logsFailure: (any Error)?

    private var doctorIndex = 0
    private var logIndex = 0

    var calls: [Call] { lock.withLock { recorded } }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    func negotiate() async throws -> ManagementHello {
        record(.negotiate)
        if let negotiateFailure { throw negotiateFailure }
        guard let hello else { throw Defect.notScripted("hello") }
        return hello
    }

    func overview() async throws -> ManagementOverview {
        record(.overview)
        if let overviewFailure { throw overviewFailure }
        guard let overviewResult else { throw Defect.notScripted("overview.get") }
        return overviewResult
    }

    func createSetupSession() async throws -> ManagementSetupSession {
        record(.setupSession)
        if let setupFailure { throw setupFailure }
        guard let setupSession else { throw Defect.notScripted("setup.session.create") }
        return setupSession
    }

    func startDoctor(scope: ManagementDoctorScope) async throws -> ManagementDoctorSession {
        record(.doctorStart(scope))
        if let startGate { await startGate() }
        return try nextDoctor()
    }

    func doctorSession(id: String) async throws -> ManagementDoctorSession {
        record(.doctorGet(id))
        return try nextDoctor()
    }

    func cancelDoctorSession(id: String) async throws -> ManagementDoctorSession {
        record(.doctorCancel(id))
        return try nextDoctor()
    }

    func queryLogs(_ query: ManagementLogsQuery) async throws -> ManagementLogPage {
        record(.logs(query))
        if let logsFailure { throw logsFailure }
        return try lock.withLock {
            guard !logPages.isEmpty else { throw Defect.notScripted("logs.query") }
            let page = logPages[min(logIndex, logPages.count - 1)]
            logIndex += 1
            return page
        }
    }

    func buildDiagnostics() async throws -> ManagementDiagnostics {
        record(.diagnostics)
        guard let diagnostics else { throw Defect.notScripted("diagnostics.build") }
        return diagnostics
    }

    private func nextDoctor() throws -> ManagementDoctorSession {
        if let doctorFailure { throw doctorFailure }
        return try lock.withLock {
            guard !doctorScript.isEmpty else { throw Defect.notScripted("doctor") }
            let session = doctorScript[min(doctorIndex, doctorScript.count - 1)]
            doctorIndex += 1
            return session
        }
    }
}

/// Builds the management values the surfaces project, from JSON that matches the
/// vendored schema. Building them as wire objects rather than as Swift literals
/// keeps the doubles honest about the shape the daemon actually sends.
enum ManagementValueFixture {
    static func decode<Value: Decodable>(_ json: String, as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    static func hello(
        version: String = "0.9.0",
        pid: String = "4242",
        origin: String = "http://127.0.0.1:4030",
        minimum: Int = 1,
        maximum: Int = 1
    ) throws -> ManagementHello {
        try decode(
            """
            {
              "protocol": {"current_version": 1, "minimum_version": \(minimum), "maximum_version": \(maximum)},
              "capabilities": {"methods": ["hello", "overview.get"]},
              "engine": {
                "engine_id": "fermix_app_engine",
                "product_version": "\(version)",
                "build_id": "1",
                "source_commit": "abc1234",
                "distribution_identity": "macos_app",
                "artifact_target": "macos_aarch64",
                "architecture": "arm64",
                "pid": "\(pid)"
              },
              "setup": {"origin": "\(origin)", "path": "/setup"}
            }
            """,
            as: ManagementHello.self
        )
    }

    static func overview(
        provider: String? = "openai_codex",
        model: String = "gpt-5.6-sol",
        channelName: String = "telegram",
        channelEnabled: Bool = true,
        channelStatus: String = "ok",
        readiness: String = "ready",
        health: String = "ok",
        restartRequired: Bool = false,
        uptimeMs: Int = 273_600_000,
        failedJobs: Int = 0
    ) throws -> ManagementOverview {
        let active = provider.map { "\"\($0)\"" } ?? "null"
        return try decode(
            """
            {
              "generated_at": "2026-08-21T09:00:00Z",
              "readiness": {"status": "\(readiness)", "failure_count": 0},
              "health": {
                "status": "\(health)",
                "restart_required": \(restartRequired),
                "providers": [{"name": "openai_codex", "status": "ok", "auth_mode": "oauth", "primary": true}]
              },
              "daemon": {"status": "running", "version": "0.9.0", "uptime_ms": \(uptimeMs), "pid": "4242"},
              "provider": {
                "active": \(active),
                "model": "\(model)",
                "auth_mode": "oauth",
                "reasoning_effort": "high"
              },
              "channels": [
                {
                  "name": "\(channelName)",
                  "status": "\(channelStatus)",
                  "enabled": \(channelEnabled),
                  "mode": "polling",
                  "process_alive": true
                }
              ],
              "memory": {"repo": "ok", "conversation_store": "ok", "store": "ok"},
              "jobs": {"scheduled": 2, "running": 0, "paused": 0, "failed_recent": \(failedJobs), "next": null, "status": "ok"},
              "agents": {
                "main": {
                  "health": "ok",
                  "activity": "idle",
                  "status": "ok",
                  "active_conversations": 0,
                  "pending_conversations": 0
                },
                "skill_workers": 0,
                "running_skill_workers": 0
              },
              "realtime": {
                "enabled": true,
                "status": "ok",
                "provider": "openai",
                "model": "gpt-realtime",
                "socket_alive": true,
                "active_sessions": 0,
                "active_clients": 0,
                "companion_connected": false
              },
              "capabilities": {"builtin": 40, "skill": 12, "mcp": 3, "total": 55}
            }
            """,
            as: ManagementOverview.self
        )
    }

    static func doctorSession(
        id: String = "doctor:abc123",
        scope: String = "local",
        status: String = "completed",
        checks: [(String, String)] = [("provider_auth", "passed"), ("codex_login", "warning")]
    ) throws -> ManagementDoctorSession {
        let rows = checks.map { id, status in
            """
            {
              "id": "\(id)",
              "category": "runtime",
              "severity": "warning",
              "applicability": "always",
              "origin": "engine",
              "status": "\(status)",
              "summary": "\(id) reported \(status)",
              "evidence": {},
              "remediation_code": "run_codex_login",
              "duration_ms": 12,
              "finished_at": "2026-08-21T09:00:01Z"
            }
            """
        }
        .joined(separator: ",")

        let passed = checks.filter { $0.1 == "passed" }.count
        let warning = checks.filter { $0.1 == "warning" }.count
        let failed = checks.filter { $0.1 == "failed" }.count
        let notApplicable = checks.filter { $0.1 == "not_applicable" }.count

        return try decode(
            """
            {
              "session_id": "\(id)",
              "scope": "\(scope)",
              "status": "\(status)",
              "budget_ms": 10000,
              "duration_ms": 120,
              "started_at": "2026-08-21T09:00:00Z",
              "finished_at": "2026-08-21T09:00:01Z",
              "total": \(checks.count),
              "completed_count": \(checks.count),
              "summary": {
                "passed": \(passed),
                "warning": \(warning),
                "failed": \(failed),
                "not_applicable": \(notApplicable),
                "unavailable": 0,
                "skipped": 0,
                "cancelled": 0,
                "timed_out": 0
              },
              "checks": [\(rows)]
            }
            """,
            as: ManagementDoctorSession.self
        )
    }

    static func logPage(
        messages: [String],
        level: String = "info",
        cursor: String? = "cursor-1",
        truncated: Bool = false
    ) throws -> ManagementLogPage {
        let entries = messages.map { message in
            """
            {"time": "2026-08-21T09:00:00Z", "level": "\(level)", "subsystem": "agent", "message": "\(message)"}
            """
        }
        .joined(separator: ",")
        let cursorField = cursor.map { "\"\($0)\"" } ?? "null"

        return try decode(
            """
            {
              "entries": [\(entries)],
              "count": \(messages.count),
              "truncated": \(truncated),
              "direction": "backward",
              "cursor": \(cursorField)
            }
            """,
            as: ManagementLogPage.self
        )
    }

    static func diagnostics() throws -> ManagementDiagnostics {
        try decode(
            """
            {
              "schema_version": 1,
              "generated_at": "2026-08-21T09:00:00Z",
              "engine": {
                "engine_id": "fermix_app_engine",
                "product_version": "0.9.0",
                "build_id": "1",
                "source_commit": "abc1234",
                "distribution_identity": "macos_app",
                "artifact_target": "macos_aarch64",
                "architecture": "arm64",
                "pid": "4242"
              },
              "protocol": {"current_version": 1, "minimum_version": 1, "maximum_version": 1},
              "service": {"scope": "user", "state": "enabled"},
              "doctor": {
                "session_id": "doctor:abc123",
                "scope": "local",
                "status": "completed",
                "finished_at": "2026-08-21T09:00:01Z",
                "checks": []
              },
              "logs": {"count": 1, "truncated": false, "entries": [
                {"time": "2026-08-21T09:00:00Z", "level": "info", "subsystem": "agent", "message": "a line"}
              ]}
            }
            """,
            as: ManagementDiagnostics.self
        )
    }

    static func setupSession(
        url: String = "http://127.0.0.1:4030/setup?token=s3cr3t-one-use-token",
        expiresAtMs: Int = 1_755_561_900_000
    ) throws -> ManagementSetupSession {
        try decode(
            """
            {"url": "\(url)", "expires_at_ms": \(expiresAtMs)}
            """,
            as: ManagementSetupSession.self
        )
    }
}

/// Answers the two liveness probes activation uses, and records what it was
/// asked. Both start refusing so a test has to say what world it is in.
final class FakePortProbe: PortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var origins: [String] = []

    var accepting = false

    var probedOrigins: [String] { lock.withLock { origins } }

    func isAccepting(origin: String) async -> Bool {
        lock.withLock {
            origins.append(origin)
            return accepting
        }
    }
}

/// A clock a test advances by hand, so a 90-second budget is provable in
/// microseconds and the deadline is never a wall-clock race.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_755_561_000)) {
        instant = start
    }

    var now: Date { lock.withLock { instant } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { instant = instant.addingTimeInterval(seconds) }
    }

    /// The closure the coordinator reads its time through.
    var reader: @Sendable () -> Date {
        { [self] in now }
    }
}

/// A sleeper that advances a manual clock instead of waiting, so a bounded poll
/// makes real progress toward its deadline without wall-clock time.
final class ClockAdvancingSleeper: Sleeping, @unchecked Sendable {
    private let clock: ManualClock

    init(clock: ManualClock) {
        self.clock = clock
    }

    func sleep(seconds: TimeInterval) async throws {
        clock.advance(seconds)
    }
}

/// Records every external url the app hands to the system browser.
final class RecordingExternalOpener: ExternalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []

    var urls: [URL] { lock.withLock { opened } }

    func open(_ url: URL) {
        lock.withLock { opened.append(url) }
    }
}

/// Answers the filesystem questions the CLI planner asks, from two fixed maps.
struct StubLinkInspector: SymbolicLinkInspecting {
    var files: Set<String> = []
    var links: [String: String] = [:]

    func exists(atPath path: String) -> Bool {
        files.contains(path) || links[path] != nil
    }

    func destinationOfSymbolicLink(atPath path: String) -> String? {
        links[path]
    }
}
