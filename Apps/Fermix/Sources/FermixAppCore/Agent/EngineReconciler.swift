import Foundation

/// What the launch reconcile found (M34 §7.2).
///
/// Replacing the bundle does not stop the running FermixAgent, so after an
/// upgrade the app in `/Applications` and the daemon in memory are different
/// engines. This is the fact that says so, and it is a state with one action
/// rather than an error: `hello`, `overview.get`, `logs.query`, `lifecycle.*`,
/// `doctor.*` and `diagnostics.build` keep working the whole time.
public enum EngineReconcileOutcome: Equatable, Sendable {
    /// The daemon in memory is the engine in this bundle.
    case aligned
    /// The daemon is running a different build than the bundle ships.
    case pendingEngineRestart(running: EngineBuild, bundled: EngineBuild)
    /// Nothing answered, so there is nothing to compare. Starting owns that
    /// case, not the reconciler.
    case daemonUnreachable

    public var isPending: Bool {
        guard case .pendingEngineRestart = self else { return false }

        return true
    }
}

/// One engine build, as both sides of the comparison publish it.
///
/// `Codable` because the update journal records the engine on each side of a
/// transaction and the reconcile compares them with this same value. A second
/// engine-identity type written only for that file would be a second answer to
/// "which engine is that".
public struct EngineBuild: Codable, Equatable, Sendable {
    public let buildId: String
    public let productVersion: String

    public init(buildId: String, productVersion: String) {
        precondition(!buildId.isEmpty, "an engine build is identified by its build id")

        self.buildId = buildId
        self.productVersion = productVersion
    }

    private enum CodingKeys: String, CodingKey {
        case buildId = "build_id"
        case productVersion = "product_version"
    }

    /// Decoding asserts what the memberwise initializer asserts. A record
    /// naming an engine with no build id names no engine at all, and the update
    /// journal is read after a crash, when nothing else can vouch for it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let buildId = try container.decode(String.self, forKey: .buildId)
        guard !buildId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .buildId,
                in: container,
                debugDescription: "an engine build is identified by its build id"
            )
        }

        self.init(
            buildId: buildId,
            productVersion: try container.decode(String.self, forKey: .productVersion)
        )
    }

    /// The build the running daemon reported. `build_id` is optional on the wire
    /// for a daemon released before it existed; such a daemon cannot be compared
    /// and is left alone rather than declared stale.
    public init?(hello: ManagementHello) {
        guard let buildId = hello.engine.buildId, !buildId.isEmpty else { return nil }

        self.buildId = buildId
        self.productVersion = hello.engine.productVersion
    }

    public init(manifest: EngineManifest) {
        self.buildId = manifest.identity.buildId
        self.productVersion = manifest.identity.productVersion
    }
}

/// Whether the agent registration has to be renewed before the restart.
public enum AgentRegistrationVerdict: Equatable, Sendable {
    case unchanged
    /// The bundled plist differs from the receipt the last registration wrote,
    /// or no receipt was ever written. Both re-register: an absent receipt is a
    /// difference, never a match (M34 §7.2 step 5).
    case renew
}

/// Compares the daemon in memory with the engine in this bundle, on every
/// launch and on every route activation, before any window renders content.
///
/// It performs no restart of its own: it answers what is true, and the Home
/// Attention row, the `Finish updating Fermix` sheet and the status-menu line
/// are the one action that follows. Sparkle, when it lands, becomes one more
/// caller of this and never a second comparison.
public struct EngineReconciler: Sendable {
    private let bundled: EngineBuild?
    private let bundledPlistDigest: String?
    private let log = AppLog.logger(.lifecycle)

    /// The engine version this copy of Fermix ships, where the manifest could be
    /// read. The Update surface states it beside the one that is answering.
    public var bundledVersion: String? { bundled?.productVersion }

    /// The whole build this copy of Fermix ships, which the update reconcile
    /// compares with the target its journal recorded. Read from the one owner
    /// of the bundled manifest rather than by opening it a second time.
    public var bundledBuild: EngineBuild? { bundled }

    public init(bundled: EngineBuild?, bundledPlistDigest: String?) {
        self.bundled = bundled
        self.bundledPlistDigest = bundledPlistDigest
    }

    /// Reads the bundled manifest and the plist this bundle ships.
    ///
    /// It takes the digest reader itself rather than a `ServiceController`: the
    /// comparison needs one digest, and asking for the controller would make a
    /// second instance of the one type allowed to change what macOS runs at
    /// login.
    public init(manifestURL: URL, plists: any AgentPlistDigesting) {
        self.init(
            bundled: Self.bundledBuild(at: manifestURL),
            bundledPlistDigest: plists.bundledAgentPlistDigest()
        )
    }

    /// The build the bundled manifest names, where this bundle ships an engine.
    ///
    /// Two ways to have nothing to compare, and only one of them is normal. A
    /// bundle staged before the engine slot is populated carries no manifest at
    /// all, which `verify_staged_app.sh` accepts as a declared state. A manifest
    /// that is *there* and cannot be read is a packaging defect, and it is
    /// logged rather than swallowed: every reconcile would otherwise answer
    /// aligned for the life of the process and the `Finish updating Fermix` row
    /// would never appear again. The GUI cannot refuse the bundle over it —
    /// `AgentLauncher.plan` validates the engine, and that runs in FermixAgent,
    /// not here — so the loud line in the log is what says so.
    private static func bundledBuild(at manifestURL: URL) -> EngineBuild? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }

        do {
            return EngineBuild(manifest: try EngineManifest.load(from: manifestURL))
        } catch {
            AppLog.logger(.lifecycle).error(
                """
                the bundled engine manifest at \(manifestURL.path, privacy: .public) could not be read, \
                so no upgrade can be detected: \(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }

    /// The comparison. `hello` is the daemon's own answer, so a daemon that did
    /// not answer is unreachable rather than stale.
    public func reconcile(hello: ManagementHello?) -> EngineReconcileOutcome {
        guard let hello else { return .daemonUnreachable }
        guard let bundled, let running = EngineBuild(hello: hello) else { return .aligned }
        guard running.buildId != bundled.buildId else { return .aligned }

        log.log(
            "the running engine is \(running.buildId, privacy: .public) and the bundle ships \(bundled.buildId, privacy: .public)"
        )
        return .pendingEngineRestart(running: running, bundled: bundled)
    }

    /// Whether the agent has to be unregistered and registered again before the
    /// restart, from the receipt the last registration wrote.
    public func registration(recordedIn record: BootstrapRecord) -> AgentRegistrationVerdict {
        guard let bundledPlistDigest, let recorded = record.registeredAgentPlistSHA256 else { return .renew }

        return recorded == bundledPlistDigest ? .unchanged : .renew
    }
}

/// The Attention row and the status line a pending reconcile renders.
///
/// The wording is the app's, keyed on the same `restart_pending` vocabulary Home
/// already uses, so the reconcile's row and a daemon-reported pending restart
/// cannot read as two different products (M34 §3.2).
public enum EngineReconcilePresentation {
    public static func attentionRow(for outcome: EngineReconcileOutcome) -> AttentionRow? {
        guard case .pendingEngineRestart(let running, let bundled) = outcome else { return nil }

        return AttentionRow(
            id: "engine_restart_pending",
            title: ProductStrings[.settingsEngineSheetTitle],
            body: ProductStrings.middot(running.productVersion, bundled.productVersion),
            action: .restartDaemon
        )
    }

    /// The status item's disabled state line while an update is waiting.
    public static func statusLine(for outcome: EngineReconcileOutcome) -> String? {
        outcome.isPending ? ProductStrings[.statusMenuRestartPending] : nil
    }
}
