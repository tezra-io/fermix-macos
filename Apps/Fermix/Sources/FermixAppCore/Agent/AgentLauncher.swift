import Darwin
import Foundation

/// Why the agent refused to launch the engine.
public enum AgentLaunchError: Error, Equatable, Sendable {
    case bootstrapUnavailable(BootstrapStoreError)
    /// The inherited environment has no PATH. It is not invented: launchd
    /// always provides one, so its absence means this process was started by
    /// something that is not the agent's launcher.
    case pathUnavailable
    case execFailed(path: String, errno: Int32)

    public var message: String {
        switch self {
        case .bootstrapUnavailable(let failure):
            return "the launcher record is unusable: \(String(describing: failure))"
        case .pathUnavailable:
            return "the launch environment has no PATH"
        case .execFailed(let path, let code):
            return "could not execute \(path): errno \(code)"
        }
    }
}

/// What the agent hands to `exec`.
public struct AgentLaunchPlan: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Replaces this process with another one.
///
/// `exec` keeps launchd's pid, its file descriptors, and its job identity, so
/// the daemon *is* the agent rather than a child of it. The seam exists so the
/// plan can be proven without running anything.
public protocol ProcessExecuting {
    /// Never returns on success.
    func exec(_ plan: AgentLaunchPlan) -> AgentLaunchError
}

public struct SystemProcessExecutor: ProcessExecuting {
    public init() {}

    public func exec(_ plan: AgentLaunchPlan) -> AgentLaunchError {
        let path = plan.executable.path
        // argv[0] is the program itself, by convention and because the engine's
        // launch script reads it to find its own release root.
        let argv: [String] = [path] + plan.arguments
        let envp = plan.environment.map { "\($0.key)=\($0.value)" }

        withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                _ = execve(path, argvPointers, envPointers)
            }
        }

        // Reached only when execve failed: on success this process is gone.
        return .execFailed(path: path, errno: errno)
    }

    /// Builds the null-terminated `char *[]` `execve` needs, and frees every
    /// duplicate on the way out — including the path where `execve` returns.
    private func withCStrings(_ values: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Void) {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        body(pointers)
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
}

/// Turns the bundle plus this account's bootstrap into the exact launch.
///
/// There is no PATH search, no architecture retry, and no download: the running
/// machine has one valid engine tree inside this bundle, and every mismatch is
/// a hard refusal that names what it inspected.
public enum AgentLauncher {
    public static func plan(
        configuration: ProductConfiguration,
        bundleRoot: URL,
        architecture: String,
        fermixHome: URL,
        environment: [String: String],
        probe: any EngineProbe = FileSystemEngineProbe()
    ) throws -> AgentLaunchPlan {
        let resolver = EngineResolver(
            configuration: configuration,
            bundleRoot: bundleRoot,
            architecture: architecture,
            probe: probe
        )

        let engineTree = try resolver.engineTree()
        let tools = try resolver.toolsDirectory()

        let manifest = try EngineManifest.load(
            from: engineTree.appendingPathComponent(EngineManifest.fileName, isDirectory: false)
        )
        try manifest.validate(
            architecture: architecture,
            managementVersion: try ManagementContract.vendored().protocolVersion,
            realtimeVersion: RealtimeProtocol.version
        )

        let executable = try resolver.engineExecutable()

        return AgentLaunchPlan(
            executable: executable,
            arguments: ["start"],
            environment: try engineEnvironment(inheriting: environment, home: fermixHome, tools: tools)
        )
    }

    /// The engine's environment: everything the agent inherited, plus the
    /// bootstrap home and the bundled tools on PATH.
    ///
    /// Inheriting matters as much as adding. The engine authenticates with
    /// vendor CLIs that read their own credential context out of the
    /// environment, so a sanitizer here would produce a daemon that starts and
    /// then cannot log in.
    private static func engineEnvironment(
        inheriting inherited: [String: String],
        home: URL,
        tools: URL
    ) throws -> [String: String] {
        guard let path = inherited["PATH"], !path.isEmpty else {
            throw AgentLaunchError.pathUnavailable
        }

        var environment = inherited
        environment["PATH"] = "\(tools.path):\(path)"
        // The bootstrap record is the only home the engine is told about; the
        // agent's own inherited FERMIX_HOME, if any, is not authoritative.
        environment["FERMIX_HOME"] = home.path
        return environment
    }
}
