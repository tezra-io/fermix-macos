import AppKit
import Foundation

@testable import FermixAppCore

/// The one daemon double the surfaces run against.
///
/// It answers each v1 method from a script the test sets and records what was
/// asked, in order, so a surface's traffic is an assertion rather than a
/// side effect nobody can see. A method with no scripted answer raises: a
/// surface that calls something the scenario never prepared is a test defect,
/// never a silent empty result.
///
/// The protocol v2 methods are served from the vendored contract's own golden
/// fixtures (see `SurfaceTestDoublesV2.swift`), so every surface renders against
/// the shapes the engine actually sends. Their version gate is
/// the scripted `hello`'s window, run through the client's own rule: a test that
/// sets `hello` to a `{1, 1}` daemon gets an N-1 daemon here, with the same
/// refusal the real client would raise.
final class FakeDaemonGateway: DaemonQuerying, @unchecked Sendable {
    enum Call: Equatable {
        case negotiate
        case overview
        case doctorStart(ManagementDoctorScope)
        case doctorGet(String)
        case doctorCancel(String)
        case logs(ManagementLogsQuery)
        case diagnostics
        /// Any protocol v2 method, by the wire name it was asked under.
        case v2(ManagementMethod)
    }

    enum Defect: Error, Equatable {
        case notScripted(String)
        case fixtureMissing(method: String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var hello: ManagementHello?
    var overviewResult: ManagementOverview?
    /// Overview answers consumed in order, for a case that watches a fact move.
    /// An exhausted script keeps answering with the last one, which is what a
    /// settled daemon actually does.
    var overviewScript: [ManagementOverview] = []
    /// Doctor answers, consumed in order: start takes the first, each get the
    /// next. An exhausted script keeps answering with the last one, which is
    /// what a finished session actually does.
    var doctorScript: [ManagementDoctorSession] = []
    var logPages: [ManagementLogPage] = []
    var diagnostics: ManagementDiagnostics?

    /// Holds `doctor.start` open, so a test can act inside the window between
    /// the surface declaring a run and the daemon issuing its session id.
    var startGate: (@Sendable () async -> Void)?

    /// Runs inside `settings.get`, before the answer, so a test can observe what
    /// the window is showing while a section is being re-read.
    var settingsGate: (@Sendable () async -> Void)?

    var negotiateFailure: (any Error)?
    var overviewFailure: (any Error)?
    var doctorFailure: (any Error)?
    var logsFailure: (any Error)?
    /// Applied to every protocol v2 method, so a scenario can drive the refusal
    /// path without scripting thirty-one answers.
    var v2Failure: (any Error)?
    /// A refusal for one method only, which is what a write-path case needs: the
    /// pane still has to read its rows while its apply refuses.
    var v2Failures: [ManagementMethod: any Error] = [:]

    /// The answer every `setup.state.get` gives, where a case needs one the
    /// golden fixture cannot express: it always reports a gating provider
    /// failure and a pending restart.
    var setupStateResult: ManagementSetupState?
    /// Holds a setup reply while the user chooses another destination.
    var setupStateGate: (@Sendable () async -> Void)?

    /// A daemon whose readiness is DERIVED from its own providers rather than
    /// flipped by a test.
    ///
    /// When this is set, `setup.state.get` reports a gating
    /// `provider:missing_credentials:<id>` failure exactly while no provider is
    /// both primary and configured, and a connect promotes the provider it
    /// connected the way the engine's own first-provider promotion does. That is
    /// what makes "the block clears" a fact about the daemon's answer rather
    /// than about a scripted result the test replaced afterwards.
    var providerReadiness: FakeProviderReadiness?

    /// The answer every `plugins.list` gives, where a case needs one the golden
    /// fixture cannot express: the golden publishes one posture per plugin, and
    /// what a switch-on leaves behind is a different one.
    var pluginsResult: ManagementPluginCatalog?

    /// The answer every `settings.apply` gives, where a case needs one the
    /// golden fixture cannot express: the golden's write reports no side
    /// effects, and a daemon that changed something the operator did not type
    /// is exactly what the side-effect line exists to surface.
    var settingsAppliedResult: ManagementSettingsApplied?
    var providerSettings: StatefulProviderSettings?

    /// What the surfaces wrote, in order.
    var appliedSettings: [SettingsWrite] = []
    var storedSecrets: [SecretWrite] = []
    var readSections: [String] = []
    var polledJobs: [String] = []
    /// The job views a poll walks through. Empty means the fixture's completed
    /// job, which is what most cases want.
    var jobScript: [ManagementJob] = []
    /// Holds a selected poll response while a test changes the active job.
    var jobGate: (@Sendable () async -> Void)?
    /// Holds the first authentication reply so duplicate clicks can be tested.
    var authStartGate: (@Sendable () async -> Void)?
    var jobIndex = 0

    /// The window this double has negotiated, cached exactly as the shipping
    /// gateway caches it. Without the cache a scripted `hello` change would take
    /// effect on the next call, which is more forgiving than the socket: the
    /// real gateway keeps the window until something drops it.
    private var negotiatedWindow: ManagementProtocolRange?

    private var doctorIndex = 0
    private var logIndex = 0
    private var overviewIndex = 0

    var calls: [Call] { lock.withLock { recorded } }

    func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    func negotiate() async throws -> ManagementHello {
        record(.negotiate)
        if let negotiateFailure { throw negotiateFailure }
        guard let hello else { throw Defect.notScripted("hello") }

        lock.withLock { negotiatedWindow = hello.protocolRange }
        return hello
    }

    func invalidateNegotiation() async {
        lock.withLock { negotiatedWindow = nil }
    }

    /// The window every v2 gate reads, learned on first use and kept until it is
    /// invalidated, which is what the shipping gateway does.
    func negotiatedRange() throws -> ManagementProtocolRange {
        guard let hello else { throw Defect.notScripted("hello") }

        return lock.withLock {
            guard let negotiatedWindow else {
                let learned = hello.protocolRange
                negotiatedWindow = learned
                return learned
            }

            return negotiatedWindow
        }
    }

    func overview() async throws -> ManagementOverview {
        record(.overview)
        if let overviewFailure { throw overviewFailure }

        return try lock.withLock {
            guard !overviewScript.isEmpty else {
                guard let overviewResult else { throw Defect.notScripted("overview.get") }
                return overviewResult
            }

            let answer = overviewScript[min(overviewIndex, overviewScript.count - 1)]
            overviewIndex += 1
            return answer
        }
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

    static func protocolRange(
        current: Int = 1,
        minimum: Int,
        maximum: Int
    ) throws -> ManagementProtocolRange {
        try decode(
            """
            {"current_version": \(current), "minimum_version": \(minimum), "maximum_version": \(maximum)}
            """,
            as: ManagementProtocolRange.self
        )
    }

    /// A daemon that speaks everything this build speaks, unless a test narrows
    /// the window deliberately. The ceiling comes from the contract the double
    /// serves rather than from an integer written here, so the fixture
    /// gateway's default posture cannot quietly become an N-1 daemon — which
    /// would refuse every v2 method while a pane test still passed.
    static func hello(
        version: String = "0.9.0",
        pid: String = "4242",
        origin: String = "http://127.0.0.1:4030",
        minimum: Int = 1,
        maximum: Int? = nil,
        buildId: String? = "1"
    ) throws -> ManagementHello {
        let ceiling = try maximum ?? ManagementContract.vendored().publishedRange.maximum
        let build = buildId.map { "\"\($0)\"" } ?? "null"

        return try decode(
            """
            {
              "protocol": {"current_version": \(ceiling), "minimum_version": \(minimum), "maximum_version": \(ceiling)},
              "capabilities": {"methods": ["hello", "overview.get"]},
              "engine": {
                "engine_id": "fermix_app_engine",
                "product_version": "\(version)",
                "build_id": \(build),
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
        failedJobs: Int = 0,
        activeConversations: Int = 0,
        pendingConversations: Int = 0
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
                  "active_conversations": \(activeConversations),
                  "pending_conversations": \(pendingConversations)
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

    /// A Doctor session. `remediation` is the protocol v2 object a check
    /// carries; absent by default, because a daemon one release behind sends
    /// none and that is the shape most cases are about.
    static func doctorSession(
        id: String = "doctor:abc123",
        scope: String = "local",
        status: String = "completed",
        checks: [(String, String)] = [("provider_auth", "passed"), ("codex_login", "warning")],
        remediation: (title: String, kind: String, target: String?)? = nil
    ) throws -> ManagementDoctorSession {
        let remedy = remediation.map { entry in
            // `target` is null on the kinds that name a surface of their own:
            // the engine publishes `restart` and `reload` with nothing left to
            // name, and a stand-in that could not send null could not drive
            // either of them.
            let target = entry.target.map { "\"\($0)\"" } ?? "null"
            return """
            "remediation": {
                "title": "\(entry.title)",
                "body": "What to do about it.",
                "action": {"kind": "\(entry.kind)", "target": \(target)}
              },
            """
        } ?? ""

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
              \(remedy)
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

    /// The daemon's own `setup.state.get` answer.
    ///
    /// The default is the vendored contract's golden fixture, so the assistant's
    /// readiness is read from the shape the engine actually sends. The knobs
    /// exist for the four cases the fixture cannot carry at once: no failure at
    /// all, an advisory-only home, a home that needs nothing but a restart, and
    /// a provider whose only way in is a typed key.
    static func setupState(
        gating: Bool = true,
        failures: Bool = true,
        restartRequired: Bool = true,
        primaryConfigured: Bool = true,
        primaryModel: String? = "gpt-5.6-sol",
        keyOnlyProvider: Bool = false
    ) throws -> ManagementSetupState {
        guard gating, failures, restartRequired, primaryConfigured,
              primaryModel == "gpt-5.6-sol", !keyOnlyProvider
        else {
            return try decode(
                setupStateJSON(
                    gating: gating,
                    failures: failures,
                    restartRequired: restartRequired,
                    primaryConfigured: primaryConfigured,
                    primaryModel: primaryModel,
                    keyOnlyProvider: keyOnlyProvider
                ),
                as: ManagementSetupState.self
            )
        }

        return try FakeDaemonGateway.fixtureResult(named: "setup_state_get", as: ManagementSetupState.self)
    }

    /// The same shape as the golden fixture, with the one field a case varies.
    private static func setupStateJSON(
        gating: Bool,
        failures: Bool,
        restartRequired: Bool,
        primaryConfigured: Bool,
        primaryModel: String?,
        keyOnlyProvider: Bool
    ) -> String {
        let failureList = failures
            ? """
              {
                "component": "personalization",
                "gating": \(gating),
                "pane": "personality",
                "detail_key": "personalization"
              }
              """
            : ""
        let model = primaryModel.map { "\"\($0)\"" } ?? "null"
        // A provider whose only way in is a typed key, so its row leads with
        // `Add key…` and needs the slot its own section names.
        let keyProvider = keyOnlyProvider
            ? """
              ,
              {
                "id": "xai",
                "label": "SpaceXAI",
                "auth_modes": ["api_key"],
                "auth_mode": "api_key",
                "configured": false,
                "primary": false,
                "present_key": false,
                "default_model": null,
                "reasoning_effort": null,
                "fast": null,
                "account_label": null,
                "token_state": null
              }
              """
            : ""

        return """
        {
          "readiness": {"status": "setup_required", "failures": [\(failureList)]},
          "restart": {"required": \(restartRequired), "reasons": []},
          "providers": [
            {
              "id": "openai_codex",
              "label": "OpenAI Codex (ChatGPT)",
              "auth_modes": ["oauth"],
              "auth_mode": "oauth",
              "configured": \(primaryConfigured),
              "primary": true,
              "present_key": false,
              "default_model": \(model),
              "reasoning_effort": null,
              "fast": null,
              "account_label": null,
              "token_state": "valid"
            }\(keyProvider)
          ],
          "channels": [],
          "personalization": {
            "present": {"user_name": true, "timezone": true, "communication_style": true}
          },
          "features": {
            "voice": false,
            "voice_notes": false,
            "meetings": false,
            "computer_use": false,
            "computer_history": {"enabled": false, "installed": false, "ready": false}
          },
          "profile": "general",
          "coexistence": {
            "legacy_service_unit": {"present": false, "scope": null, "path": null},
            "config_state": "clear",
            "secret_acl_restricted": {"present": false, "keys": []}
          }
        }
        """
    }

    static func detections() throws -> ManagementDetections {
        try FakeDaemonGateway.fixtureResult(named: "setup_detect", as: ManagementDetections.self)
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

    /// Whether every sleep answers as a cancelled one, which is what a task the
    /// person cancelled does to each bounded wait underneath it.
    var cancelled = false

    init(clock: ManualClock) {
        self.clock = clock
    }

    func sleep(seconds: TimeInterval) async throws {
        guard !cancelled else { throw CancellationError() }

        clock.advance(seconds)
    }
}

/// Records every external url the app hands to the system browser.
final class RecordingExternalOpener: ExternalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    private let succeeds: Bool

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    var urls: [URL] { lock.withLock { opened } }

    func open(_ url: URL) -> Bool {
        lock.withLock { opened.append(url) }
        return succeeds
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

/// The status item, without a status bar.
///
/// `NSStatusBar` is machine-wide: a test that made a real item would put one on
/// the operator's own menu bar and leave it there. This records what the
/// controller asked for instead, so the item's configuration, its glyph and its
/// menu are assertions rather than something only a screenshot could show.
@MainActor
final class FakeStatusItem: StatusItemPresenting {
    /// True to start with, which is what macOS restores for an item nobody has
    /// removed. Every change reports itself, as the real item's `isVisible`
    /// does through KVO, whether the app made it or a Command-drag did.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }

            onVisibilityChanged?()
        }
    }
    var onVisibilityChanged: (() -> Void)?
    private(set) var image: NSImage?
    private(set) var label: String?
    private(set) var identifier: String?
    private(set) var menu: NSMenu?

    func present(_ image: NSImage, label: String, identifier: String) {
        self.image = image
        self.label = label
        self.identifier = identifier
    }

    func attach(_ menu: NSMenu) {
        self.menu = menu
    }
}
