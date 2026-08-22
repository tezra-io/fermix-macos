import Foundation

/// A wire contract vendored from the fermix repository.
public enum VendoredContract: String, CaseIterable, Sendable {
    case management
    case realtime
}

public enum VendoredContractError: Error, Equatable, Sendable {
    case resourceBundleUnavailable
    case fileMissing(path: String)
    case manifestMalformed(line: Int)
    case provenanceMalformed
}

/// One line of `CHECKSUMS.txt`, in `shasum -a 256 -c` form.
public struct ContractChecksum: Equatable, Sendable {
    public let digest: String
    public let path: String
}

/// `SOURCE.json`: where each vendored file came from and what it hashed to
/// upstream. The checksum manifest proves the shipped bytes are unchanged; this
/// proves they are the bytes that were retrieved.
public struct ContractProvenance: Decodable, Equatable, Sendable {
    public struct Upstream: Decodable, Equatable, Sendable {
        public let repository: String
        public let commit: String
        public let branch: String
        public let workingTree: String
        public let retrievedAt: String
    }

    public struct File: Decodable, Equatable, Sendable {
        public let path: String
        public let sourcePath: String
        public let sha256: String
    }

    public struct Contract: Decodable, Equatable, Sendable {
        public let name: String
        public let sourceDirectory: String
        public let protocolVersion: Int
        public let committedUpstream: Bool
        public let files: [File]
    }

    public let schemaVersion: Int
    public let upstream: Upstream
    public let contracts: [Contract]

    public var files: [File] { contracts.flatMap(\.files) }
}

/// Access to the contract tree copied into the application resource bundle.
///
/// The tree keeps its `<protocol>/…` layout: both contracts publish a
/// `PROTOCOL.md` and a `protocol.schema.json`, so a flattened bundle would lose
/// one of each.
public enum VendoredContracts {
    public static let directoryName = "Contracts"
    public static let checksumManifestName = "CHECKSUMS.txt"
    public static let provenanceName = "SOURCE.json"

    public static func url(_ contract: VendoredContract, _ relativePath: String) throws -> URL {
        try url("\(contract.rawValue)/\(relativePath)")
    }

    /// A path relative to the contract tree root, e.g.
    /// `management/fixtures/requests.jsonl`.
    public static func url(_ relativePath: String) throws -> URL {
        let candidate = try root().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw VendoredContractError.fileMissing(path: relativePath)
        }
        return candidate
    }

    public static func data(_ contract: VendoredContract, _ relativePath: String) throws -> Data {
        try Data(contentsOf: url(contract, relativePath))
    }

    /// Every pinned digest, in manifest order.
    public static func checksums() throws -> [ContractChecksum] {
        let manifest = try root().appendingPathComponent(checksumManifestName)
        let text = String(decoding: try Data(contentsOf: manifest), as: UTF8.self)

        return try text.split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count == 2, fields[0].count == 64 else {
                    throw VendoredContractError.manifestMalformed(line: index + 1)
                }
                return ContractChecksum(digest: String(fields[0]), path: String(fields[1]))
            }
    }

    public static func provenance() throws -> ContractProvenance {
        let document = try root().appendingPathComponent(provenanceName)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ContractProvenance.self, from: try Data(contentsOf: document))
    }

    /// Every contract file present in the shipped tree, relative to its root.
    /// Derived from the directory rather than from the manifest, so a file the
    /// manifest forgot still shows up.
    public static func contractFilePaths() throws -> [String] {
        let root = try root()
        let bookkeeping: Set<String> = [checksumManifestName, provenanceName]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw VendoredContractError.fileMissing(path: directoryName)
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return walker.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            let relative = String(url.path.dropFirst(prefix.count))
            return bookkeeping.contains(relative) ? nil : relative
        }
    }

    private static func root() throws -> URL {
        guard let resources = Bundle.module.resourceURL else {
            throw VendoredContractError.resourceBundleUnavailable
        }
        return resources.appendingPathComponent(directoryName)
    }
}
