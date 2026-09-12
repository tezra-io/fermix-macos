import Darwin
import Foundation
import Testing

@testable import FermixAppCore

/// A throwaway directory under the per-user temporary directory. The removal
/// path asserts the prefix and depth before deleting anything, so a collapsed
/// interpolation can never point it at a real directory.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = root.appendingPathComponent("fermix-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(NSTemporaryDirectory()),
              url.pathComponents.count >= 4,
              !path.contains("..") else {
            Issue.record("refusing to remove \(path)")
            return
        }
        // A test that made a directory read-only has to be reopened first.
        chmod(path, 0o700)
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("BootstrapStore")
struct BootstrapStoreTests {
    /// Three answers, because "no record" and "a record I cannot read" send the
    /// app to different surfaces: onboarding for a fresh account, recovery for
    /// a broken install.
    @Test("the condition tells a fresh account from a broken record")
    func conditionHasThreeAnswers() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        #expect(store.condition() == .absent)

        try FileManager.default.createDirectory(at: location.defaultFermixHome, withIntermediateDirectories: true)
        try store.save(fermixHome: location.defaultFermixHome)
        #expect(store.condition() == .present)

        try Data("{ not json".utf8).write(to: location.recordURL)
        #expect(store.condition() == .unreadable(.malformed(path: location.recordURL.path)))
    }

    /// The home a fresh account will use is the account default, and it is a
    /// property of the machine rather than of the environment.
    @Test("an account with no record resolves the default home")
    func resolvedHomeFallsBackToTheAccountDefault() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        #expect(try store.resolvedHome() == location.defaultFermixHome)
        #expect(try store.realtimeSocketPath().hasSuffix("/.fermix/realtime.sock"))
    }

    /// A record that exists and cannot be read is never quietly replaced by the
    /// default home: that would point the daemon at the wrong data.
    @Test("an unreadable record refuses to resolve a home")
    func unreadableRecordRefusesToResolve() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)
        try FileManager.default.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: location.recordURL)

        #expect(throws: BootstrapStoreError.malformed(path: location.recordURL.path)) {
            _ = try store.resolvedHome()
        }
    }

    @Test("the record lands at the one supported path with owner-only permissions")
    func recordIsWrittenAtTheSupportedPath() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        let record = try store.save(fermixHome: location.defaultFermixHome)

        #expect(location.recordURL.path.hasSuffix("/Library/Application Support/Fermix/launcher.json"))
        #expect(record.schemaVersion == BootstrapRecord.supportedSchemaVersion)
        #expect(record.fermixHome.path == temporary.url.appendingPathComponent(".fermix").path)
        #expect(try Self.permissions(of: location.recordURL) == 0o600)
        #expect(try Self.permissions(of: location.directoryURL) == 0o700)
    }

    @Test("the document carries only a schema version and a normalized home")
    func documentCarriesOnlyTheBootstrapFields() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)

        _ = try BootstrapStore(location: location).save(fermixHome: location.defaultFermixHome)

        let data = try Data(contentsOf: location.recordURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?.count == 2)
        #expect(object?["schema_version"] as? Int == 1)
        #expect(object?["fermix_home"] as? String == location.defaultFermixHome.path)
    }

    @Test("a written record loads back unchanged")
    func recordRoundTrips() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        let written = try store.save(fermixHome: location.defaultFermixHome)
        let loaded = try store.load()

        #expect(loaded == written)
        #expect(loaded.daemonSocketURL.lastPathComponent == "daemon.sock")
        #expect(loaded.daemonSocketURL.path == loaded.fermixHome.path + "/daemon.sock")
    }

    @Test("a fresh account reports the record as absent rather than guessing")
    func freshAccountReportsAbsence() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)

        #expect(throws: BootstrapStoreError.absent(path: location.recordURL.path)) {
            _ = try BootstrapStore(location: location).load()
        }
    }

    @Test("the default home is the existing account home")
    func defaultHomeIsTheAccountHome() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)

        #expect(location.defaultFermixHome.path == temporary.url.appendingPathComponent(".fermix").path)
    }

    @Test("an unsupported schema version is refused")
    func unsupportedSchemaVersionIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        try Self.writeRaw(
            #"{"schema_version": 2, "fermix_home": "\#(temporary.url.path)/.fermix"}"#,
            to: location
        )

        #expect(throws: BootstrapStoreError.unsupportedSchemaVersion(2)) {
            _ = try BootstrapStore(location: location).load()
        }
    }

    @Test("a malformed record is refused by name, not silently replaced")
    func malformedRecordIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        try Self.writeRaw("{ not json", to: location)

        #expect(throws: BootstrapStoreError.malformed(path: location.recordURL.path)) {
            _ = try BootstrapStore(location: location).load()
        }
    }

    @Test("a record pointing at a forbidden location is refused on load too")
    func loadRevalidatesTheRecordedHome() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        try Self.writeRaw(#"{"schema_version": 1, "fermix_home": "/System/Fermix"}"#, to: location)

        #expect(
            throws: BootstrapStoreError.invalidHome(
                .forbiddenLocation(path: "/System/Fermix", reason: .systemDirectory)
            )
        ) {
            _ = try BootstrapStore(location: location).load()
        }
    }

    @Test("paths are normalized before they are recorded")
    func pathsAreNormalized() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        let trailing = try store.save(path: temporary.url.path + "/.fermix/")
        let dotted = try store.save(path: temporary.url.path + "/./.fermix")

        #expect(trailing.fermixHome.path == location.defaultFermixHome.path)
        #expect(dotted.fermixHome.path == location.defaultFermixHome.path)
    }

    @Test("a tilde resolves against the account home, never the environment")
    func tildeResolvesAgainstTheAccountHome() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)

        let record = try BootstrapStore(location: location).save(path: "~/.fermix")

        #expect(record.fermixHome.path == location.defaultFermixHome.path)
    }

    @Test("a traversal component is refused rather than resolved")
    func traversalIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let candidate = temporary.url.path + "/.fermix/../../escape"

        #expect(throws: BootstrapStoreError.invalidHome(.relativeTraversal(path: candidate))) {
            _ = try BootstrapStore(location: location).save(path: candidate)
        }
    }

    @Test("a relative path is refused")
    func relativePathIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)

        #expect(throws: BootstrapStoreError.invalidHome(.notAbsolute(path: "fermix-home"))) {
            _ = try BootstrapStore(location: location).save(path: "fermix-home")
        }
    }

    @Test("every forbidden location is refused with the reason inspected")
    func forbiddenLocationsAreRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)

        // The reported path is the one that was inspected, which is the path
        // with its symbolic links resolved: `/private/tmp` is `/tmp`, and the
        // rules are applied to where the home really lands.
        let cases: [(candidate: String, inspected: String, reason: ForbiddenHomeReason)] = [
            ("/", "/", .filesystemRoot),
            (temporary.url.path, temporary.url.path, .accountHome),
            ("/System/Library/Fermix", "/System/Library/Fermix", .systemDirectory),
            ("/usr/local/fermix", "/usr/local/fermix", .systemDirectory),
            (
                "/Applications/Fermix.app/Contents/home",
                "/Applications/Fermix.app/Contents/home",
                .applicationsDirectory
            ),
            ("/tmp/fermix", "/tmp/fermix", .temporaryDirectory),
            ("/private/tmp/fermix", "/tmp/fermix", .temporaryDirectory),
            (
                temporary.url.path + "/Library/Mobile Documents/fermix",
                temporary.url.path + "/Library/Mobile Documents/fermix",
                .cloudSyncedDirectory
            ),
            (location.directoryURL.path, location.directoryURL.path, .bootstrapDirectory)
        ]

        for (candidate, inspected, reason) in cases {
            #expect(
                throws: BootstrapStoreError.invalidHome(
                    .forbiddenLocation(path: inspected, reason: reason)
                ),
                "\(candidate) must be refused as \(reason)"
            ) {
                _ = try store.save(path: candidate)
            }
        }
    }

    /// The forbidden-location rules are about where the home really lands, not
    /// about how its path is spelled. A user-owned symbolic link one level up
    /// walks a home straight into iCloud Drive, where file locking corrupts the
    /// database the rule exists to protect.
    @Test("a symbolic link into a forbidden location is refused")
    func symlinkedForbiddenLocationIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let cloud = temporary.url
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)

        let link = temporary.url.appendingPathComponent("cloudlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cloud)
        let candidate = link.appendingPathComponent("fermix", isDirectory: true).path

        #expect(
            throws: BootstrapStoreError.invalidHome(
                .forbiddenLocation(path: cloud.appendingPathComponent("fermix").path, reason: .cloudSyncedDirectory)
            )
        ) {
            _ = try BootstrapStore(location: location).save(path: candidate)
        }
    }

    /// The same rule, one directory deeper and pointed at the account home
    /// itself, so the walk is proven to resolve every ancestor rather than only
    /// the immediate parent.
    @Test("a symbolic link into the account home is refused")
    func symlinkedAccountHomeIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let link = temporary.url.appendingPathComponent("selflink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temporary.url)

        #expect(
            throws: BootstrapStoreError.invalidHome(
                .forbiddenLocation(path: temporary.url.path, reason: .accountHome)
            )
        ) {
            _ = try BootstrapStore(location: location).save(path: link.path)
        }
    }

    @Test("an existing non-directory at the home path is refused")
    func existingFileIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let occupied = temporary.url.appendingPathComponent(".fermix")
        try Data("occupied".utf8).write(to: occupied)

        #expect(throws: BootstrapStoreError.invalidHome(.notADirectory(path: occupied.path))) {
            _ = try BootstrapStore(location: location).save(fermixHome: occupied)
        }
    }

    /// The home may not exist yet on a fresh account, so ownership is probed on
    /// the nearest ancestor that does — a gate that inspects a directory the
    /// caller has not created yet inspects nothing.
    @Test("a home under a directory owned by another account is refused")
    func foreignOwnershipIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let store = BootstrapStore(location: BootstrapLocation(homeDirectory: temporary.url))
        let candidate = "/Users/fermix-not-this-account-\(UUID().uuidString.prefix(8))"

        do {
            _ = try store.save(path: candidate)
            Issue.record("expected a foreign-ownership refusal for \(candidate)")
        } catch let error as BootstrapStoreError {
            guard case .invalidHome(.notOwnedByCurrentUser(let path, _)) = error else {
                Issue.record("expected foreign ownership, got \(error)")
                return
            }
            #expect(path == "/Users")
        }
    }

    @Test("a home under a read-only ancestor is refused")
    func unwritableAncestorIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let readOnly = temporary.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        #expect(chmod(readOnly.path, 0o500) == 0)
        defer { chmod(readOnly.path, 0o700) }

        let candidate = readOnly.appendingPathComponent("fermix")
        #expect(throws: BootstrapStoreError.invalidHome(.notWritable(path: readOnly.path))) {
            _ = try BootstrapStore(location: location).save(fermixHome: candidate)
        }
    }

    @Test("rewriting the record replaces it atomically and keeps it owner-only")
    func rewriteIsAtomic() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)
        let other = temporary.url.appendingPathComponent("workspaces/fermix", isDirectory: true)

        _ = try store.save(fermixHome: location.defaultFermixHome)
        let second = try store.save(fermixHome: other)

        #expect(try store.load() == second)
        #expect(try Self.permissions(of: location.recordURL) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: location.directoryURL.path
        )
        #expect(leftovers == ["launcher.json"])
    }

    @Test("removing the record clears the bootstrap")
    func removalClearsTheBootstrap() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)
        _ = try store.save(fermixHome: location.defaultFermixHome)

        try store.remove()

        #expect(throws: BootstrapStoreError.absent(path: location.recordURL.path)) {
            _ = try store.load()
        }
        #expect(throws: BootstrapStoreError.absent(path: location.recordURL.path)) {
            try store.remove()
        }
    }

    // MARK: - The registration receipt

    /// The one field M34 §7.2 adds, and it is a registration receipt rather than
    /// a configuration overlay: `SMAppService` publishes a status and never the
    /// plist it registered.
    @Test("the registration receipt round-trips through the record")
    func receiptRoundTrips() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let store = BootstrapStore(location: BootstrapLocation(homeDirectory: temporary.url))
        _ = try store.save(fermixHome: BootstrapLocation(homeDirectory: temporary.url).defaultFermixHome)

        #expect(try store.load().registeredAgentPlistSHA256 == nil)

        _ = try store.recordAgentRegistration(plistSHA256: "aa11bb22")

        #expect(try store.load().registeredAgentPlistSHA256 == "aa11bb22")
    }

    /// Recording a home is not a registration. Dropping the receipt on an
    /// ordinary save would make every launch unregister and register the agent
    /// again, which is exactly the loop the receipt exists to avoid.
    @Test("recording a home carries the existing receipt forward")
    func receiptSurvivesAnOrdinarySave() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        let store = BootstrapStore(location: location)
        _ = try store.save(fermixHome: location.defaultFermixHome)
        _ = try store.recordAgentRegistration(plistSHA256: "aa11bb22")

        let saved = try store.save(fermixHome: location.defaultFermixHome)

        #expect(saved.registeredAgentPlistSHA256 == "aa11bb22")
        #expect(try store.load().registeredAgentPlistSHA256 == "aa11bb22")
    }

    /// A record written before the field existed reads back with none, which the
    /// reconciler treats as a difference rather than as a match.
    @Test("a record written before the receipt existed reads back without one")
    func recordWithoutAReceipt() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let location = BootstrapLocation(homeDirectory: temporary.url)
        try Self.writeRaw(
            """
            {"schema_version": 1, "fermix_home": "\(location.defaultFermixHome.path)"}
            """,
            to: location
        )

        #expect(try BootstrapStore(location: location).load().registeredAgentPlistSHA256 == nil)
    }

    // MARK: - Helpers

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func writeRaw(_ contents: String, to location: BootstrapLocation) throws {
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: location.recordURL)
    }
}
