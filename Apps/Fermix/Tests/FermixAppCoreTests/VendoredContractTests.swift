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

        // Two contract trees: management's PROTOCOL.md, schema and four
        // fixture files, and realtime's PROTOCOL.md, schema and two.
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

    @Test("provenance records an upstream source for every pinned vendored file")
    func provenanceCoversEveryPinnedFile() throws {
        let provenance = try VendoredContracts.provenance()
        let pinned = Set(try VendoredContracts.checksums().map(\.path))

        #expect(Set(provenance.files.map(\.path)) == pinned)
        for file in provenance.vendoredContracts.flatMap(\.files) {
            #expect(file.sourcePath?.isEmpty == false, "no upstream source for \(file.path)")
        }
    }

    /// Nothing ships as a draft. A draft was a designed transition with an
    /// expiry: management protocol v2 was authored here while the engine still
    /// published v1, and the expiry passed when the engine published it. A
    /// record that reappeared would be an artifact with no upstream operand,
    /// which `verify_protocol_contract.sh --source` cannot compare and the
    /// release audience refuses outright.
    @Test("no contract in the shipped tree is a draft")
    func noDraftContractShips() throws {
        let provenance = try VendoredContracts.provenance()

        #expect(
            provenance.draftContracts.isEmpty,
            """
            SOURCE.json declares a draft contract \
            (\(provenance.draftContracts.map(\.name).joined(separator: ", "))): vendor it \
            from the engine and delete the record, or the release audience of \
            verify_staged_app.sh will refuse the bundle
            """
        )
        #expect(provenance.contracts.count == VendoredContract.allCases.count)
        for file in provenance.files {
            #expect(file.sourcePath?.isEmpty == false, "no upstream source for \(file.path)")
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

    @Test("every declared contract tree ships")
    func everyContractTreeIsPresent() throws {
        let paths = try VendoredContracts.contractFilePaths()

        for contract in VendoredContract.allCases {
            #expect(paths.contains { $0.hasPrefix("\(contract.rawValue)/") })
        }
    }
}

@Suite("ManagementContract")
struct ManagementContractTests {
    /// M34 §7.1: the speakable set is derived from the published range, not
    /// from a second key, so the set and the daemon window stay one fact.
    @Test("the vendored schema publishes protocol version 2 and its window")
    func versionComesFromTheSchema() throws {
        let contract = try ManagementContract.vendored()

        #expect(contract.protocolVersion == 2)
        #expect(contract.publishedRange.minimum == 1)
        #expect(contract.publishedRange.maximum == 2)
        #expect(contract.speakableVersions == [1, 2])
    }

    @Test("the frame ceiling is read from the schema, not restated")
    func limitsComeFromTheSchema() throws {
        let contract = try ManagementContract.vendored()

        #expect(contract.limits.maxFrameBytes == 4_194_304)
        #expect(contract.limits.maxParamsBytes == 65_536)
        #expect(contract.limits.maxResultBytes == 1_048_576)
        #expect(contract.limits.maxErrorDetailsBytes == 4_096)
        #expect(contract.limits.maxJSONDepth == 6)
        #expect(contract.limits.maxJSONCollectionItems == 500)
    }

    /// The catalog is exactly what this build models. A method the engine
    /// publishes and Swift never names is unreachable; one Swift names and the
    /// engine does not serve is a call that always refuses.
    @Test("the method catalog is exactly the schema's")
    func methodCatalogMatchesTheSchema() throws {
        let modelled = Set(ManagementMethod.allCases.map(\.rawValue))
        let published = try ManagementContract.vendored().methods

        #expect(Set(published) == modelled)
        #expect(published.count == 42)
    }

    /// The per-method minimum is what makes an N-1 daemon usable rather than a
    /// trap: `lifecycle.prepare` is the call that restarts it.
    ///
    /// The table has to cover the catalog exactly. A method missing from it
    /// answers the window's floor, which is the one answer that cannot be told
    /// apart from a method that really is serveable at 1 — so the §7.1 gate
    /// would send it to an N-1 daemon and the designed refusal would never be
    /// reached.
    @Test("the schema publishes a minimum for all 42 methods and the app models exactly those")
    func perMethodMinimumsComeFromTheSchema() throws {
        let contract = try ManagementContract.vendored()

        #expect(Set(contract.minimumVersions.keys) == Set(contract.methods))
        #expect(Set(contract.minimumVersions.keys) == Set(ManagementMethod.allCases.map(\.rawValue)))
        #expect(contract.minimumVersions.count == 42)
        #expect(contract.minimumVersions.values.filter { $0 == 1 }.count == 11)
        #expect(contract.minimumVersions.values.filter { $0 == 2 }.count == 31)

        #expect(contract.minimumVersion(for: .lifecyclePrepare) == 1)
        #expect(contract.minimumVersion(for: .settingsGet) == 2)
    }

    /// A schema that publishes no per-method minimums has none: everything it
    /// lists is serveable at the floor of its own range.
    @Test("a schema without per-method minimums answers its own floor")
    func absentMinimumsAnswerTheFloor() throws {
        let document = Data(
            """
            {
              "x-protocol-version": 1,
              "x-supported-version-range": {"min": 1, "max": 1},
              "x-limits": {
                "max_frame_bytes": 1, "max_params_bytes": 1, "max_result_bytes": 1,
                "max_error_details_bytes": 1, "max_json_depth": 1,
                "max_json_collection_items": 1
              },
              "$defs": {"request": {"properties": {"method": {"enum": ["hello", "settings.get"]}}}}
            }
            """.utf8
        )
        let contract = try ManagementContract.decode(from: document)

        #expect(contract.minimumVersions.isEmpty)
        #expect(contract.minimumVersion(for: .settingsGet) == 1)
    }

    /// The half of that pair that matters at re-vendor: a schema that speaks
    /// two versions and publishes no minimums would answer its floor for every
    /// method.
    @Test("a two-version schema without per-method minimums is refused")
    func missingMinimumsAboveOneVersionAreRefused() {
        let document = Data(
            """
            {
              "x-protocol-version": 2,
              "x-supported-version-range": {"min": 1, "max": 2},
              "x-limits": {
                "max_frame_bytes": 1, "max_params_bytes": 1, "max_result_bytes": 1,
                "max_error_details_bytes": 1, "max_json_depth": 1,
                "max_json_collection_items": 1
              },
              "$defs": {"request": {"properties": {"method": {"enum": ["hello"]}}}}
            }
            """.utf8
        )

        #expect(throws: ManagementContractDefect.fieldMissing("x-method-minimum-versions")) {
            _ = try ManagementContract.decode(from: document)
        }
    }

    /// A partial table is the same defect wearing a present key. `settings.get`
    /// is missing here, so the floor default would report it serveable at 1 and
    /// the §7.1 gate would send it to a daemon that cannot answer it.
    @Test("a two-version schema whose minimums table is partial is refused")
    func partialMinimumsAreRefused() {
        let document = Data(
            """
            {
              "x-protocol-version": 2,
              "x-supported-version-range": {"min": 1, "max": 2},
              "x-limits": {
                "max_frame_bytes": 1, "max_params_bytes": 1, "max_result_bytes": 1,
                "max_error_details_bytes": 1, "max_json_depth": 1,
                "max_json_collection_items": 1
              },
              "x-method-minimum-versions": {"hello": 1},
              "$defs": {"request": {"properties": {"method": {"enum": ["hello", "settings.get"]}}}}
            }
            """.utf8
        )

        #expect(throws: ManagementContractDefect.fieldMissing("x-method-minimum-versions.settings.get")) {
            _ = try ManagementContract.decode(from: document)
        }
    }

    @Test("a schema without the version extension is refused")
    func missingVersionExtensionIsRefused() {
        let document = Data(#"{"x-limits": {}}"#.utf8)

        #expect(throws: ManagementContractDefect.fieldMissing("x-protocol-version")) {
            _ = try ManagementContract.decode(from: document)
        }
    }
}
