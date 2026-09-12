import Foundation

/// Where the agent writes its one kind of line.
///
/// Injected so the entry point is testable without a process, and so the only
/// code that touches the real file descriptors is `StandardAgentOutput`.
public protocol AgentOutput {
    /// A resolved fact, on standard output.
    func report(_ line: String)
    /// A refusal, on standard error.
    func diagnose(_ line: String)
}

public struct StandardAgentOutput: AgentOutput {
    private let log = AppLog.logger(.agent)

    public init() {}

    public func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        log.log("\(line, privacy: .public)")
    }

    /// launchd sends a LaunchAgent's standard error to /dev/null, so a refusal
    /// written only there is a refusal nobody can read. The same sentence goes
    /// to the unified log, which `log show` can always recover.
    public func diagnose(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
        log.error("\(line, privacy: .public)")
    }
}

/// `FermixAgent`'s whole behavior, so its `main.swift` stays a call and an exit.
///
/// The agent reads the product configuration and this account's bootstrap
/// record, validates the engine manifest for the running architecture, puts the
/// bundled tools on the engine's PATH, and `exec`s the engine in the
/// foreground — the same pid launchd started, so the daemon's App Management
/// identity is the signed agent itself.
///
/// It never searches PATH, never substitutes the other architecture's tree, and
/// never downloads anything. A returned status is always a refusal.
public enum AgentEntryPoint {
    public static let successStatus: Int32 = 0
    /// `EX_CONFIG`: the configuration this program needs is wrong or missing.
    public static let configurationFailureStatus: Int32 = 78
    /// `EX_UNAVAILABLE`: the configuration is sound but the engine is not there.
    public static let preflightFailureStatus: Int32 = 69

    /// Performs the launch. On success it does not return — the engine has
    /// replaced this process — so a value coming back is always a refusal.
    public typealias Launcher = (AgentLaunchPlan) -> AgentLaunchError

    /// This account's Fermix home. The default is the bootstrap record, the
    /// sole pre-daemon source on macOS; it is injected so the entry point can
    /// be driven without reading the account it runs in.
    public typealias HomeResolver = () throws -> URL

    public static func defaultHome() throws -> URL {
        try BootstrapStore(location: try BootstrapLocation.currentAccount()).resolvedHome()
    }

    public static func main(
        arguments: [String],
        bundleRoot: URL,
        architecture: String,
        output: AgentOutput,
        home: HomeResolver = defaultHome,
        launcher: Launcher? = nil
    ) -> Int32 {
        guard arguments.count <= 1 else {
            output.diagnose("fermix agent: takes no arguments, received \(arguments.count - 1)")
            return configurationFailureStatus
        }

        guard let configuration = loadConfiguration(output: output) else {
            return configurationFailureStatus
        }

        guard let fermixHome = loadHome(home, output: output) else {
            return configurationFailureStatus
        }

        let plan: AgentLaunchPlan
        do {
            plan = try AgentLauncher.plan(
                configuration: configuration,
                bundleRoot: bundleRoot,
                architecture: architecture,
                fermixHome: fermixHome,
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            output.diagnose("fermix agent: \(describe(error))")
            return preflightFailureStatus
        }

        output.report("engine \(plan.executable.path)")

        // Success never returns: the engine replaces this process, keeping
        // launchd's pid and its file descriptors.
        let failure = (launcher ?? { SystemProcessExecutor().exec($0) })(plan)
        output.diagnose("fermix agent: \(failure.message)")
        return preflightFailureStatus
    }

    private static func loadConfiguration(output: AgentOutput) -> ProductConfiguration? {
        do {
            return try ProductConfiguration.bundled()
        } catch let error as ProductConfigurationError {
            output.diagnose("fermix agent: \(error.message)")
            return nil
        } catch {
            output.diagnose("fermix agent: product configuration is unreadable: \(error)")
            return nil
        }
    }

    /// The agent reads no environment home: a record it cannot read is a
    /// refusal, never a guess at where the data might be.
    private static func loadHome(_ resolve: HomeResolver, output: AgentOutput) -> URL? {
        do {
            return try resolve()
        } catch {
            output.diagnose("fermix agent: \(describe(error))")
            return nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as AgentLaunchError: return failure.message
        case let failure as EngineManifestDefect: return failure.message
        case let failure as EngineResolutionError: return failure.message
        default: return String(describing: error)
        }
    }
}
