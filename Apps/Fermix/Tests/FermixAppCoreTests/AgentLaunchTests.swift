import Foundation
import Testing

@testable import FermixAppCore

/// The agent's launch decision: the engine manifest it validates, and the exact
/// program, argument, and environment it hands to `exec`.
///
/// Every case stages a real bundle tree in a throwaway directory, so the
/// resolution runs against the filesystem it will run against in production.
/// Nothing is executed here.
@Suite("Agent launch plan")
struct AgentLaunchTests {
    // MARK: - The staged bundle

    private func stage(
        architecture: String = "arm64",
        manifest: [String: Any]? = nil,
        includeEngineExecutable: Bool = true,
        includeTools: Bool = true
    ) throws -> StagedBundle {
        try StagedBundle(
            architecture: architecture,
            manifest: manifest ?? EngineManifestFixture.document(architecture: architecture),
            includeEngineExecutable: includeEngineExecutable,
            includeTools: includeTools
        )
    }

    private func plan(
        _ bundle: StagedBundle,
        architecture: String = "arm64",
        environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester"],
        home: String = "/Users/tester/.fermix"
    ) throws -> AgentLaunchPlan {
        try AgentLauncher.plan(
            configuration: try ProductConfiguration.decode(from: ProductFixture.json()),
            bundleRoot: bundle.root,
            architecture: architecture,
            fermixHome: URL(fileURLWithPath: home, isDirectory: true),
            environment: environment,
            probe: FileSystemEngineProbe()
        )
    }

    // MARK: - The plan

    @Test("the plan executes the bundled engine in the foreground")
    func executesTheBundledEngine() throws {
        let bundle = try stage()

        let plan = try plan(bundle)

        #expect(plan.executable == bundle.engineExecutable)
        #expect(plan.arguments == ["start"])
    }

    @Test("the bootstrap home is the only home the engine is told about")
    func passesTheBootstrapHome() throws {
        let bundle = try stage()

        let plan = try plan(
            bundle,
            environment: ["PATH": "/usr/bin:/bin", "FERMIX_HOME": "/Users/tester/.somewhere-else"],
            home: "/Users/tester/.fermix"
        )

        #expect(plan.environment["FERMIX_HOME"] == "/Users/tester/.fermix")
    }

    @Test("the bundled tools directory is prepended to the engine's PATH")
    func prependsTheToolsDirectory() throws {
        let bundle = try stage()

        let plan = try plan(bundle)

        #expect(plan.environment["PATH"] == "\(bundle.toolsDirectory.path):/usr/bin:/bin")
    }

    /// The sanitizer test that matters is what the child KEEPS: an engine that
    /// cannot see its credential context starts and then cannot authenticate.
    @Test("every inherited variable survives into the engine's environment")
    func inheritsTheParentEnvironment() throws {
        let bundle = try stage()
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/tester",
            "USER": "tester",
            "TMPDIR": "/var/folders/xx/T/",
            "CLAUDE_CONFIG_DIR": "/Users/tester/.claude",
            "LANG": "en_US.UTF-8",
            "PORT": "4530"
        ]

        let plan = try plan(bundle, environment: inherited)

        for (key, value) in inherited where key != "PATH" {
            #expect(plan.environment[key] == value, "\(key)")
        }
        #expect(plan.environment["PATH"]?.hasSuffix("/usr/bin:/bin") == true)
    }

    @Test("the plan adds nothing beyond the home and the tools path")
    func addsNothingElse() throws {
        let bundle = try stage()
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester"]

        let plan = try plan(bundle, environment: inherited)

        #expect(Set(plan.environment.keys) == Set(inherited.keys).union(["FERMIX_HOME"]))
    }

    @Test("an environment without a PATH is refused rather than invented")
    func refusesAnEmptyPath() throws {
        let bundle = try stage()

        #expect(throws: AgentLaunchError.pathUnavailable) {
            _ = try plan(bundle, environment: ["HOME": "/Users/tester"])
        }
    }

    // MARK: - Refusals

    @Test("a missing engine executable names the exact path")
    func refusesAMissingExecutable() throws {
        let bundle = try stage(includeEngineExecutable: false)

        #expect(throws: EngineResolutionError.engineExecutableMissing(bundle.engineExecutable.path)) {
            _ = try plan(bundle)
        }
    }

    @Test("a missing tools directory names the exact path")
    func refusesMissingTools() throws {
        let bundle = try stage(includeTools: false)

        #expect(throws: (any Error).self) {
            _ = try plan(bundle)
        }
    }

    /// No arch retry: an arm64 host with only an x86_64 tree staged refuses,
    /// naming the tree it looked for.
    @Test("the other architecture's tree is never substituted")
    func refusesTheOtherArchitecture() throws {
        let bundle = try stage(architecture: "x86_64")

        #expect(
            throws: EngineResolutionError.engineTreeMissing(
                bundle.root.appendingPathComponent("Contents/Resources/Engine/arm64").path
            )
        ) {
            _ = try plan(bundle, architecture: "arm64")
        }
    }

    // MARK: - The manifest

    @Test("the manifest must be the schema this build reads")
    func refusesAnUnknownSchema() throws {
        let bundle = try stage(manifest: EngineManifestFixture.document(schemaVersion: 2))

        #expect(throws: EngineManifestDefect.unsupportedSchemaVersion(2)) {
            _ = try plan(bundle)
        }
    }

    @Test("a manifest for another architecture is refused")
    func refusesAForeignArchitecture() throws {
        let bundle = try stage(manifest: EngineManifestFixture.document(manifestArchitecture: "x86_64"))

        #expect(throws: EngineManifestDefect.architectureMismatch(expected: "arm64", found: "x86_64")) {
            _ = try plan(bundle)
        }
    }

    /// The bundled engine must be the one built for the app, not a standalone
    /// or brew tree that happens to be lying in the bundle.
    @Test("only the macOS app distribution identity is accepted")
    func refusesAForeignDistribution() throws {
        let bundle = try stage(manifest: EngineManifestFixture.document(distribution: "standalone"))

        #expect(throws: EngineManifestDefect.distributionMismatch(expected: "macos_app", found: "standalone")) {
            _ = try plan(bundle)
        }
    }

    @Test("an engine whose management window excludes this app is refused")
    func refusesAnIncompatibleManagementWindow() throws {
        let bundle = try stage(manifest: EngineManifestFixture.document(managementRange: (3, 3, 4)))

        #expect(
            throws: EngineManifestDefect.protocolUnsupported(
                name: "management",
                declared: 2,
                minimum: 3,
                maximum: 4
            )
        ) {
            _ = try plan(bundle)
        }
    }

    @Test("an engine whose realtime window excludes this app is refused")
    func refusesAnIncompatibleRealtimeWindow() throws {
        let bundle = try stage(manifest: EngineManifestFixture.document(realtimeRange: (2, 2, 2)))

        #expect(
            throws: EngineManifestDefect.protocolUnsupported(
                name: "realtime",
                declared: RealtimeProtocol.version,
                minimum: 2,
                maximum: 2
            )
        ) {
            _ = try plan(bundle)
        }
    }

    @Test("a missing manifest names the path it looked at")
    func refusesAMissingManifest() throws {
        let bundle = try stage()
        try FileManager.default.removeItem(at: bundle.manifestURL)

        #expect(throws: EngineManifestDefect.missing(path: bundle.manifestURL.path)) {
            _ = try plan(bundle)
        }
    }

    @Test("a manifest that is not the published shape is refused, not guessed at")
    func refusesAMalformedManifest() throws {
        let bundle = try stage()
        try Data("{".utf8).write(to: bundle.manifestURL)

        #expect(throws: EngineManifestDefect.malformed(path: bundle.manifestURL.path)) {
            _ = try plan(bundle)
        }
    }

    @Test("the manifest reports the engine identity the app displays")
    func manifestCarriesTheIdentity() throws {
        let bundle = try stage()

        let manifest = try EngineManifest.load(from: bundle.manifestURL)

        #expect(manifest.identity.productVersion == "0.9.0")
        #expect(manifest.identity.engineId == "fermix-core")
        #expect(manifest.identity.architecture == "arm64")
    }
}

/// The agent's whole entry point, over its output, home, and launch seams.
@Suite("Agent entry point")
struct AgentEntryPointTests {
    @Test("the exit statuses are the two the launcher can produce")
    func exitStatuses() {
        #expect(AgentEntryPoint.configurationFailureStatus == 78)
        #expect(AgentEntryPoint.preflightFailureStatus == 69)
    }

    @Test("arguments are refused: the agent takes none")
    func refusesArguments() {
        let output = RecordingAgentOutput()

        let status = AgentEntryPoint.main(
            arguments: ["FermixAgent", "--verbose"],
            bundleRoot: URL(fileURLWithPath: "/Applications/Fermix.app"),
            architecture: "arm64",
            output: output,
            home: { URL(fileURLWithPath: "/Users/tester/.fermix", isDirectory: true) },
            launcher: { _ in .pathUnavailable }
        )

        #expect(status == AgentEntryPoint.configurationFailureStatus)
        #expect(output.diagnostics.contains { $0.contains("takes no arguments") })
    }

    /// A home that cannot be resolved is a refusal, not a guess at where the
    /// data might be.
    @Test("an unresolvable home exits with the configuration status")
    func unresolvableHomeIsRefused() {
        let output = RecordingAgentOutput()

        let status = AgentEntryPoint.main(
            arguments: ["FermixAgent"],
            bundleRoot: URL(fileURLWithPath: "/Applications/Fermix.app"),
            architecture: "arm64",
            output: output,
            home: { throw BootstrapLocationError.accountHomeUnavailable },
            launcher: { _ in .pathUnavailable }
        )

        #expect(status == AgentEntryPoint.configurationFailureStatus)
        #expect(output.reports.isEmpty)
    }

    /// The launcher never returns on success, so a value coming back is always
    /// a refusal — and it has to reach standard error with its own path.
    @Test("a launch refusal is reported on standard error and exits unavailable")
    func launchRefusalIsReported() throws {
        let bundle = try StagedBundle(
            architecture: "arm64",
            manifest: EngineManifestFixture.document(),
            includeEngineExecutable: true,
            includeTools: true
        )
        let output = RecordingAgentOutput()

        let status = AgentEntryPoint.main(
            arguments: ["FermixAgent"],
            bundleRoot: bundle.root,
            architecture: "arm64",
            output: output,
            home: { URL(fileURLWithPath: "/Users/tester/.fermix", isDirectory: true) },
            launcher: { plan in .execFailed(path: plan.executable.path, errno: ENOEXEC) }
        )

        #expect(status == AgentEntryPoint.preflightFailureStatus)
        #expect(output.reports.contains { $0.contains(bundle.engineExecutable.path) })
        #expect(output.diagnostics.contains { $0.contains(bundle.engineExecutable.path) })
    }

    /// An engine tree that is not there fails before anything is executed, and
    /// the diagnostic names the path that was inspected.
    @Test("an unstaged engine exits non-zero naming the absent path")
    func unstagedEngineIsReported() {
        let output = RecordingAgentOutput()

        let status = AgentEntryPoint.main(
            arguments: ["FermixAgent"],
            bundleRoot: URL(fileURLWithPath: "/Applications/Fermix.app"),
            architecture: "arm64",
            output: output,
            home: { URL(fileURLWithPath: "/Users/tester/.fermix", isDirectory: true) },
            launcher: { _ in Issue.record("the launcher must not run without an engine"); return .pathUnavailable }
        )

        #expect(status == AgentEntryPoint.preflightFailureStatus)
        #expect(output.diagnostics.contains {
            $0.contains("/Applications/Fermix.app/Contents/Resources/Engine/arm64")
        })
    }
}

// MARK: - Fixtures

/// A bundle tree staged on disk: `Contents/Resources/Engine/<arch>/` with a
/// manifest and a `bin/fermix_app_engine`, plus `Contents/Resources/Tools`.
final class StagedBundle {
    let root: URL
    let architecture: String

    init(architecture: String, manifest: [String: Any], includeEngineExecutable: Bool, includeTools: Bool) throws {
        self.architecture = architecture
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-agent-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fermix.app", isDirectory: true)

        let engineRoot = root.appendingPathComponent("Contents/Resources/Engine/\(architecture)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineRoot.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONSerialization
            .data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: engineRoot.appendingPathComponent("engine-manifest.json"))

        if includeEngineExecutable {
            let executable = engineRoot.appendingPathComponent("bin/fermix_app_engine")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        if includeTools {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Contents/Resources/Tools", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    deinit {
        // Owned exclusively by this fixture: a fresh UUID under the per-user
        // temporary directory, written by nothing else.
        let container = root.deletingLastPathComponent()
        guard container.path.contains("fermix-agent-tests"), container.pathComponents.count >= 4 else { return }
        try? FileManager.default.removeItem(at: container)
    }

    var engineTree: URL {
        root.appendingPathComponent("Contents/Resources/Engine/\(architecture)", isDirectory: true)
    }

    var engineExecutable: URL {
        engineTree.appendingPathComponent("bin/fermix_app_engine")
    }

    var manifestURL: URL {
        engineTree.appendingPathComponent("engine-manifest.json")
    }

    var toolsDirectory: URL {
        root.appendingPathComponent("Contents/Resources/Tools", isDirectory: true)
    }
}

enum EngineManifestFixture {
    /// The manifest shape `FermixCore.Release.AppEngineManifest` writes.
    static func document(
        schemaVersion: Int = 1,
        architecture: String = "arm64",
        manifestArchitecture: String? = nil,
        distribution: String = "macos_app",
        managementRange: (Int, Int, Int) = (2, 1, 2),
        realtimeRange: (Int, Int, Int) = (1, 1, 1)
    ) -> [String: Any] {
        let declared = manifestArchitecture ?? architecture
        return [
            "schema_version": schemaVersion,
            "identity": [
                "engine_id": "fermix-core",
                "product_version": "0.9.0",
                "build_id": "local-test",
                "source_commit": String(repeating: "0", count: 40),
                "distribution_identity": distribution,
                "artifact_target": declared == "arm64" ? "macos_aarch64" : "macos_x86_64",
                "architecture": declared
            ],
            "protocols": [
                "management": range(managementRange),
                "realtime": range(realtimeRange)
            ],
            "provenance": [
                "oidc_issuer": "https://token.actions.githubusercontent.com",
                "certificate_identity": "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v0.9.0"
            ],
            "tree_sha256": String(repeating: "a", count: 64),
            "inventory": [
                "artifact_target": declared == "arm64" ? "macos_aarch64" : "macos_x86_64",
                "architecture": declared,
                "entries": []
            ]
        ]
    }

    private static func range(_ value: (Int, Int, Int)) -> [String: Int] {
        ["current_version": value.0, "minimum_version": value.1, "maximum_version": value.2]
    }
}
