import Foundation

/// Why a bundled engine tree was refused. Each case names both sides of the
/// mismatch, so the refusal is diagnosable from the message alone.
public enum EngineManifestDefect: Error, Equatable, Sendable {
    case missing(path: String)
    case malformed(path: String)
    case unsupportedSchemaVersion(Int)
    case architectureMismatch(expected: String, found: String)
    case distributionMismatch(expected: String, found: String)
    case engineMismatch(expected: String, found: String)
    case protocolUnsupported(name: String, declared: Int, minimum: Int, maximum: Int)

    public var message: String {
        switch self {
        case .missing(let path):
            return "the engine manifest is not present at \(path)"
        case .malformed(let path):
            return "the engine manifest at \(path) is not the published shape"
        case .unsupportedSchemaVersion(let found):
            return "engine manifest schema \(found) is not supported "
                + "(this build reads \(EngineManifest.supportedSchemaVersion))"
        case .architectureMismatch(let expected, let found):
            return "the engine tree declares architecture \(found), not \(expected)"
        case .distributionMismatch(let expected, let found):
            return "the engine declares distribution \(found), not \(expected)"
        case .engineMismatch(let expected, let found):
            return "the engine declares itself \(found), not \(expected)"
        case .protocolUnsupported(let name, let declared, let minimum, let maximum):
            return "the engine's \(name) protocol window is \(minimum) to \(maximum), "
                + "which excludes the version \(declared) this app speaks"
        }
    }
}

/// One protocol window the engine publishes.
public struct EngineProtocolRange: Decodable, Equatable, Sendable {
    public let currentVersion: Int
    public let minimumVersion: Int
    public let maximumVersion: Int

    public func contains(_ version: Int) -> Bool {
        version >= minimumVersion && version <= maximumVersion
    }

    private enum CodingKeys: String, CodingKey {
        case currentVersion = "current_version"
        case minimumVersion = "minimum_version"
        case maximumVersion = "maximum_version"
    }
}

public struct EngineIdentity: Decodable, Equatable, Sendable {
    public let engineId: String
    public let productVersion: String
    public let buildId: String
    public let sourceCommit: String
    public let distributionIdentity: String
    public let artifactTarget: String
    public let architecture: String

    private enum CodingKeys: String, CodingKey {
        case engineId = "engine_id"
        case productVersion = "product_version"
        case buildId = "build_id"
        case sourceCommit = "source_commit"
        case distributionIdentity = "distribution_identity"
        case artifactTarget = "artifact_target"
        case architecture
    }
}

public struct EngineProtocols: Decodable, Equatable, Sendable {
    public let management: EngineProtocolRange
    public let realtime: EngineProtocolRange
}

/// `engine-manifest.json`, as the daemon's release writes it.
///
/// The agent validates identity and protocol windows before executing anything.
/// It does not re-hash the tree: the bundle's own code signature covers the
/// bytes, and hashing a whole release on every launch would buy nothing the
/// seal does not already prove.
public struct EngineManifest: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    public static let fileName = "engine-manifest.json"
    /// The only engine this app runs, and the only distribution identity it
    /// accepts inside its own bundle.
    public static let expectedEngineId = "fermix-core"
    public static let expectedDistribution = "macos_app"

    public let schemaVersion: Int
    public let identity: EngineIdentity
    public let protocols: EngineProtocols
    public let treeSha256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case identity, protocols
        case treeSha256 = "tree_sha256"
    }

    public static func load(from url: URL) throws -> EngineManifest {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw EngineManifestDefect.missing(path: url.path)
        }

        do {
            return try JSONDecoder().decode(EngineManifest.self, from: data)
        } catch {
            throw EngineManifestDefect.malformed(path: url.path)
        }
    }

    /// Every mismatch is fatal and named. There is no arch retry, no download,
    /// and no "close enough" version window.
    public func validate(architecture: String, managementVersion: Int, realtimeVersion: Int) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw EngineManifestDefect.unsupportedSchemaVersion(schemaVersion)
        }
        guard identity.engineId == Self.expectedEngineId else {
            throw EngineManifestDefect.engineMismatch(
                expected: Self.expectedEngineId,
                found: identity.engineId
            )
        }
        guard identity.architecture == architecture else {
            throw EngineManifestDefect.architectureMismatch(
                expected: architecture,
                found: identity.architecture
            )
        }
        guard identity.distributionIdentity == Self.expectedDistribution else {
            throw EngineManifestDefect.distributionMismatch(
                expected: Self.expectedDistribution,
                found: identity.distributionIdentity
            )
        }
        try check(protocols.management, named: "management", declared: managementVersion)
        try check(protocols.realtime, named: "realtime", declared: realtimeVersion)
    }

    private func check(_ range: EngineProtocolRange, named name: String, declared: Int) throws {
        guard range.contains(declared) else {
            throw EngineManifestDefect.protocolUnsupported(
                name: name,
                declared: declared,
                minimum: range.minimumVersion,
                maximum: range.maximumVersion
            )
        }
    }
}
