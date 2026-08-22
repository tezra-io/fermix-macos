import CryptoKit
import Foundation
import Testing

@testable import FermixAppCore

/// The vendored contracts are the single coordination point between two
/// independently released repositories, so the shipped bundle has to carry the
/// exact bytes the pin records — not merely a file with the right name.
@Suite("Vendored wire contracts")
struct VendoredContractTests {
    @Test("every pinned file is present in the shipped resource bundle")
    func pinnedFilesArePresent() throws {
        let entries = try VendoredContracts.checksums()

        #expect(entries.count == 10)
        for entry in entries {
            let url = try VendoredContracts.url(entry.path)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("the shipped bytes match the recorded digests")
    func shippedBytesMatchTheirDigests() throws {
        for entry in try VendoredContracts.checksums() {
            let data = try Data(contentsOf: try VendoredContracts.url(entry.path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == entry.digest, "digest drift in \(entry.path)")
        }
    }

    /// A manifest that lists nine of ten files verifies clean while the tenth
    /// drifts, so completeness is asserted from the directory, not the manifest.
    @Test("the manifest lists every vendored contract file")
    func manifestCoversTheWholeTree() throws {
        let pinned = Set(try VendoredContracts.checksums().map(\.path))
        let present = Set(try VendoredContracts.contractFilePaths())

        #expect(pinned == present)
    }

    @Test("provenance records an upstream source for every pinned file")
    func provenanceCoversEveryPinnedFile() throws {
        let provenance = try VendoredContracts.provenance()
        let pinned = Set(try VendoredContracts.checksums().map(\.path))

        #expect(Set(provenance.files.map(\.path)) == pinned)
        for file in provenance.files {
            #expect(!file.sourcePath.isEmpty)
        }
    }

    /// The pin is only meaningful if both records agree: a locally edited file
    /// whose checksum was regenerated would pass CHECKSUMS.txt alone.
    @Test("the recorded upstream digests agree with the checksum manifest")
    func provenanceAgreesWithTheManifest() throws {
        let provenance = try VendoredContracts.provenance()
        let manifest = Dictionary(
            uniqueKeysWithValues: try VendoredContracts.checksums().map { ($0.path, $0.digest) }
        )

        for file in provenance.files {
            #expect(manifest[file.path] == file.sha256, "provenance drift in \(file.path)")
        }
    }

    @Test("both contracts are vendored")
    func bothContractsArePresent() throws {
        let paths = try VendoredContracts.contractFilePaths()

        for contract in VendoredContract.allCases {
            #expect(paths.contains { $0.hasPrefix("\(contract.rawValue)/") })
        }
    }
}

@Suite("ManagementContract")
struct ManagementContractTests {
    @Test("the app declares protocol version 1 and reads the published window")
    func declaredVersionComesFromTheSchema() throws {
        let contract = try ManagementContract.vendored()

        #expect(contract.protocolVersion == 1)
        #expect(contract.publishedRange.minimum == 1)
        #expect(contract.publishedRange.maximum == 1)
    }

    @Test("the frame ceiling is read from the schema, not restated")
    func limitsComeFromTheSchema() throws {
        let limits = try ManagementContract.vendored().limits

        #expect(limits.maxFrameBytes == 4_194_304)
        #expect(limits.maxParamsBytes == 65_536)
        #expect(limits.maxResultBytes == 1_048_576)
        #expect(limits.maxErrorDetailsBytes == 4_096)
        #expect(limits.maxJSONDepth == 6)
        #expect(limits.maxJSONCollectionItems == 500)
    }

    @Test("the method catalog is exactly the schema's")
    func methodCatalogMatchesTheSchema() throws {
        let published = try ManagementContract.vendored().methods
        let modelled = ManagementMethod.allCases.map(\.rawValue)

        #expect(Set(published) == Set(modelled))
        #expect(published.count == 11)
    }

    @Test("a schema without the version extension is refused")
    func missingVersionExtensionIsRefused() {
        let document = Data(#"{"x-limits": {}}"#.utf8)

        #expect(throws: ManagementContractDefect.fieldMissing("x-protocol-version")) {
            _ = try ManagementContract.decode(from: document)
        }
    }
}
