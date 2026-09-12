import Foundation
import Testing

@testable import FermixAppCore

/// The pane store, in memory. Nothing here reaches `UserDefaults`: a test that
/// wrote the real domain would carry its choice into the next run and into the
/// operator's own window.
@MainActor
final class FakeSettingsPaneStore: SettingsPaneStoring {
    var lastSettingsPane: String?

    init(lastSettingsPane: String? = nil) {
        self.lastSettingsPane = lastSettingsPane
    }
}

/// The microphone right, scripted. The real reader answers for the running
/// process, so a test that touched it would assert against whatever this Mac
/// happens to have granted.
struct StubMicrophoneAuthorization: MicrophoneAuthorizationReading {
    var state: PermissionState = .granted
    /// What the operator decides when the dialog is raised.
    var granting: PermissionState = .granted

    var microphoneState: PermissionState { state }

    func requestMicrophone() async -> PermissionState { granting }
}

/// A fixed application list, so the picker is provable without reading the
/// operator's own `/Applications`.
struct StubInstalledApps: InstalledAppsEnumerating {
    var apps: [InstalledApp] = []

    func installedApps() -> [InstalledApp] { apps }
}

/// Builds the launch reconciler for a surface test.
///
/// The default is an aligned pair: the reconcile is its own suite's subject, and
/// a surface test that got a pending one by accident would draw an Attention row
/// nobody asked for.
enum EngineReconcilerFixture {
    /// The build id `ManagementValueFixture.hello` reports.
    static let runningBuildId = "1"

    static func aligned(plistDigest: String? = "digest-a") -> EngineReconciler {
        EngineReconciler(
            bundled: EngineBuild(buildId: runningBuildId, productVersion: "0.9.0"),
            bundledPlistDigest: plistDigest
        )
    }

    static func upgraded(plistDigest: String? = "digest-a") -> EngineReconciler {
        EngineReconciler(
            bundled: EngineBuild(buildId: "2", productVersion: "0.10.0"),
            bundledPlistDigest: plistDigest
        )
    }
}

/// Builds the one settings model the surfaces share.
///
/// Every seam is a double: the gateway is the fixture daemon, the store is in
/// memory, the sleeper consumes its wait instantly, the browser records rather
/// than opens, and the microphone is scripted.
@MainActor
enum SettingsFixture {
    static func model(
        gateway: FakeDaemonGateway,
        store: FakeSettingsPaneStore? = nil,
        opener: RecordingExternalOpener = RecordingExternalOpener(),
        microphone: StubMicrophoneAuthorization = StubMicrophoneAuthorization(),
        loginItems: FakeLoginItemService = FakeLoginItemService()
    ) -> SettingsModel {
        SettingsModel(
            gateway: gateway,
            store: store ?? FakeSettingsPaneStore(),
            sleeper: NoWaitSleeper(),
            opener: opener,
            permissions: PermissionLedger(
                gateway: gateway,
                services: ServiceController(loginItems: loginItems),
                microphone: microphone
            )
        )
    }

    /// A gateway scripted to answer every v2 method from the vendored contract's
    /// own fixtures, which is what a settings surface needs to render at all.
    static func gateway() throws -> FakeDaemonGateway {
        let gateway = FakeDaemonGateway()
        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()

        return gateway
    }

    /// A gateway whose `hello` reports a daemon one release behind, so every
    /// protocol v2 method refuses with `methodRequiresNewerEngine`.
    static func n1Gateway() throws -> FakeDaemonGateway {
        let gateway = FakeDaemonGateway()
        gateway.hello = try ManagementValueFixture.hello(minimum: 1, maximum: 1)
        gateway.overviewResult = try ManagementValueFixture.overview()

        return gateway
    }
}

extension ManagementValueFixture {
    /// One job view, as the wire carries it.
    static func job(
        id: String = "job:install-1",
        kind: String = "capability_install",
        status: String = "running",
        phase: String? = "sidecar_downloading",
        budgetMs: Int = 2_000,
        failure: (code: String, sentence: String)? = nil
    ) throws -> ManagementJob {
        let phaseField = phase.map { "\"\($0)\"" } ?? "null"
        let failureField = failure.map {
            """
            {"code": "\($0.code)", "sentence": "\($0.sentence)"}
            """
        } ?? "null"

        return try decode(
            """
            {
              "job_id": "\(id)",
              "kind": "\(kind)",
              "status": "\(status)",
              "phase": \(phaseField),
              "progress": {"done": 1, "total": 4, "unit": "steps"},
              "budget_ms": \(budgetMs),
              "started_at": "2026-09-02T09:00:00Z",
              "finished_at": null,
              "result": null,
              "failure": \(failureField)
            }
            """,
            as: ManagementJob.self
        )
    }

    /// The published catalogue with one plugin's own answer replaced.
    ///
    /// Built by editing the golden `plugins.list` record rather than by writing
    /// a plugin row in Swift, so every field a case does not vary is still the
    /// one the engine sends. The four it varies are what a switch-on changes:
    /// where the plugin stands, and which method it leads with next.
    static func pluginCatalog(
        named name: String,
        status: String,
        sentence: String,
        primaryVerb: String,
        primaryAction: String
    ) throws -> ManagementPluginCatalog {
        let fixture = try #require(
            try ManagementFixtures.load(.success, from: .management).first { $0.name == "plugins_list" }
        )
        var body = try #require(try fixture.object("response")["result"] as? [String: Any])
        var plugins = try #require(body["plugins"] as? [[String: Any]])
        let index = try #require(plugins.firstIndex { $0["name"] as? String == name })

        plugins[index]["status"] = status
        plugins[index]["status_sentence"] = sentence
        plugins[index]["primary_verb"] = primaryVerb
        plugins[index]["primary_action"] = primaryAction
        plugins[index]["verbs"] = [primaryVerb]
        plugins[index]["actions"] = [primaryAction]
        body["plugins"] = plugins

        return try JSONDecoder().decode(
            ManagementPluginCatalog.self,
            from: try JSONSerialization.data(withJSONObject: body)
        )
    }

    /// One descriptor row, so a control test can vary exactly one field.
    static func settingRow(
        key: String = "realtime_enabled",
        kind: String = "toggle",
        label: String = "Talk to Fermix",
        footer: String? = nil,
        value: String = "true",
        present: Bool? = nil,
        options: [(value: String, label: String)] = [],
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil,
        restart: Bool = false,
        readOnly: Bool = false,
        suggestions: Bool = false,
        unit: String? = nil,
        format: String? = nil
    ) throws -> ManagementSettingRow {
        let optionList: String = options
            .map { option in
                let value: String = option.value
                let label: String = option.label
                return "{\"value\": \"\(value)\", \"label\": \"\(label)\", \"hint\": null, \"disabled\": false}"
            }
            .joined(separator: ",")
        let footerField: String = footer.map { "\"\($0)\"" } ?? "null"
        let presentField: String = present.map { $0 ? "true" : "false" } ?? "null"
        let minField: String = number(min)
        let maxField: String = number(max)
        let stepField: String = number(step)
        let unitField: String = unit.map { "\"\($0)\"" } ?? "null"
        let formatField: String = format.map { "\"\($0)\"" } ?? "null"

        return try decode(
            """
            {
              "key": "\(key)",
              "kind": "\(kind)",
              "label": "\(label)",
              "footer": \(footerField),
              "value": \(value),
              "present": \(presentField),
              "options": [\(optionList)],
              "min": \(minField),
              "max": \(maxField),
              "step": \(stepField),
              "unit": \(unitField),
              "format": \(formatField),
              "restart": \(restart),
              "read_only": \(readOnly),
              "suggestions": \(suggestions)
            }
            """,
            as: ManagementSettingRow.self
        )
    }

    /// A bound as JSON, or the absence of one.
    private static func number(_ value: Double?) -> String {
        guard let value else { return "null" }

        return String(value)
    }
}
