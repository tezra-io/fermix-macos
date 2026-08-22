import Foundation

/// Answers the two layout questions the engine tree raises.
///
/// Injected so resolution is testable without staging a real application
/// bundle, and so the production probe is the only code that touches disk.
public protocol EngineProbe: Sendable {
    func directoryExists(at url: URL) -> Bool
    func executableExists(at url: URL) -> Bool
}

public struct FileSystemEngineProbe: EngineProbe {
    public init() {}

    public func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    public func executableExists(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}

public enum EngineResolutionError: Error, Equatable {
    case unsupportedArchitecture(String)
    case engineTreeMissing(String)
    case engineExecutableMissing(String)
    case toolsDirectoryMissing(String)

    public var message: String {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "no engine tree is published for architecture \(architecture)"
        case .engineTreeMissing(let path):
            return "engine tree is not present at \(path)"
        case .engineExecutableMissing(let path):
            return "engine executable is not present at \(path)"
        case .toolsDirectoryMissing(let path):
            return "bundled tools directory is not present at \(path)"
        }
    }
}

/// Resolves the exactly-one engine release tree, its executable, and the tools
/// directory the agent is allowed to use.
///
/// There is no search path, no download, and no retry with the other
/// architecture: the running machine has one valid tree, and its absence is a
/// hard failure that names the path it looked at.
public struct EngineResolver {
    /// The launch script inside a plain Elixir release tree. `start` runs it in
    /// the foreground, which is what launchd supervises.
    public static let executableRelativePath = "bin/fermix_app_engine"

    private let configuration: ProductConfiguration
    private let bundleRoot: URL
    private let architecture: String
    private let probe: any EngineProbe

    public init(
        configuration: ProductConfiguration,
        bundleRoot: URL,
        architecture: String,
        probe: any EngineProbe = FileSystemEngineProbe()
    ) {
        precondition(!architecture.isEmpty, "architecture must not be empty")
        self.configuration = configuration
        self.bundleRoot = bundleRoot
        self.architecture = architecture
        self.probe = probe
    }

    /// The architecture-specific engine tree, proven present.
    public func engineTree() throws -> URL {
        guard configuration.supportedArchitectures.contains(architecture) else {
            throw EngineResolutionError.unsupportedArchitecture(architecture)
        }

        let url = bundleRoot
            .appendingPathComponent(configuration.engineRelativePath)
            .appendingPathComponent(architecture)
        guard probe.directoryExists(at: url) else {
            throw EngineResolutionError.engineTreeMissing(url.path)
        }
        return url
    }

    /// The engine binary inside that tree, proven executable.
    public func engineExecutable() throws -> URL {
        let url = try engineTree().appendingPathComponent(Self.executableRelativePath)
        guard probe.executableExists(at: url) else {
            throw EngineResolutionError.engineExecutableMissing(url.path)
        }
        return url
    }

    /// The bundled tools directory the engine's service PATH is extended with.
    public func toolsDirectory() throws -> URL {
        let url = bundleRoot.appendingPathComponent(configuration.toolsRelativePath)
        guard probe.directoryExists(at: url) else {
            throw EngineResolutionError.toolsDirectoryMissing(url.path)
        }
        return url
    }

    /// The architecture of the process performing the resolution.
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        #error("unsupported host architecture")
        #endif
    }
}
