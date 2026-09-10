import Foundation
import Testing

@testable import FermixAppCore

/// What this bundle is allowed to do about updates, and what a feed has to say
/// before the transaction will touch it (M34 §6, R2).
@Suite("Update policy and feed")
struct UpdatePolicyTests {
    // MARK: - The declared policy

    /// The shipped placeholder is not base64 at all, so it decodes to nothing
    /// and verifies nothing. The updater is refused rather than constructed:
    /// starting it would answer with the framework's own modal alert, in words
    /// this product never wrote.
    @Test("the placeholder public key runs no updater")
    func placeholderKeyIsRefused() {
        #expect(throws: UpdateConfigurationRefusal.publicKeyNotBase64) {
            try UpdateConfiguration.validate(UpdatePolicyFixture.manifest())
        }
    }

    @Test("a public key that is not thirty-two bytes verifies nothing")
    func shortKeyIsRefused() {
        #expect(throws: UpdateConfigurationRefusal.publicKeyWrongLength(4)) {
            try UpdateConfiguration.validate(
                UpdatePolicyFixture.manifest(publicEDKey: Data([1, 2, 3, 4]).base64EncodedString())
            )
        }
    }

    @Test("a feed that is not https is refused")
    func plainFeedIsRefused() {
        #expect(throws: UpdateConfigurationRefusal.feedNotHTTPS("http://fermix.com/appcast.xml")) {
            try UpdateConfiguration.validate(
                UpdatePolicyFixture.manifest(
                    feedURL: "http://fermix.com/appcast.xml",
                    publicEDKey: UpdatePolicyFixture.wellFormedKey
                )
            )
        }
    }

    /// `SUAllowsAutomaticUpdates` is the load-bearing key: absent, the framework
    /// falls back to whether automatic checking is on, and the whole
    /// automatic-installation path comes back silently. Absent and true are
    /// both refused, because only an explicit no is a no.
    @Test(
        "automatic installation has to be forbidden explicitly",
        arguments: [nil, true] as [Bool?]
    )
    func automaticInstallationMustBeForbidden(allows: Bool?) {
        #expect(throws: UpdateConfigurationRefusal.automaticInstallationNotForbidden) {
            try UpdateConfiguration.validate(
                UpdatePolicyFixture.manifest(
                    publicEDKey: UpdatePolicyFixture.wellFormedKey,
                    allowsAutomaticUpdates: allows
                )
            )
        }
    }

    @Test("automatic downloading has to be forbidden explicitly", arguments: [nil, true] as [Bool?])
    func automaticDownloadMustBeForbidden(downloads: Bool?) {
        #expect(throws: UpdateConfigurationRefusal.automaticDownloadNotForbidden) {
            try UpdateConfiguration.validate(
                UpdatePolicyFixture.manifest(
                    publicEDKey: UpdatePolicyFixture.wellFormedKey,
                    automaticallyUpdate: downloads
                )
            )
        }
    }

    @Test("a complete policy is accepted")
    func completePolicyIsAccepted() throws {
        try UpdateConfiguration.validate(
            UpdatePolicyFixture.manifest(publicEDKey: UpdatePolicyFixture.wellFormedKey)
        )
    }

    /// The cheapest gate on "automatic installation is unavailable": the
    /// checked-in Info.plist is the one the GUI binary carries, and
    /// `scripts/render_info_plist.sh` is its only writer. Reading it here needs
    /// no bundle, no defaults and no updater, and it catches the key going
    /// missing under a change that never mentions updates.
    @Test("the rendered Info.plist forbids automatic installation")
    func renderedPlistForbidsAutomaticInstallation() throws {
        let policy = try UpdatePolicyFixture.checkedInPolicy()

        #expect(policy.allowsAutomaticUpdates == false)
        #expect(policy.automaticallyUpdate == false)
        #expect(policy.feedURL?.hasPrefix("https://") == true)
    }

    /// Omitting `SUEnableAutomaticChecks` is the plan's deliberate choice: with
    /// no value the framework asks once and keeps the answer, and this build
    /// never overwrites the person's choice on launch.
    @Test("the rendered Info.plist states no automatic-check preference")
    func renderedPlistLeavesTheCheckPreferenceToThePerson() throws {
        #expect(try UpdatePolicyFixture.checkedInPlist()["SUEnableAutomaticChecks"] == nil)
    }

    // MARK: - Reading a feed entry

    @Test("an entry becomes a release with both sides of its identity")
    func entryBecomesARelease() throws {
        let offer = try UpdateFeedReading.offer(from: UpdateFeedFixture.offered)

        #expect(offer.app == AppBuild(marketingVersion: "0.2.0", buildNumber: 2))
        #expect(offer.engine == EngineBuild(buildId: "engine-target", productVersion: "0.11.0"))
        #expect(offer.releaseClass == .normal)
        #expect(offer.installer.url == UpdateFeedFixture.offeredURL)
    }

    @Test("a critical entry reads as a critical release")
    func criticalEntryReadsAsCritical() throws {
        let offer = try UpdateFeedReading.offer(from: UpdateFeedFixture.entry(isCritical: true))

        #expect(offer.releaseClass == .critical)
    }

    @Test("an information-only entry installs nothing")
    func informationOnlyEntryIsRefused() {
        #expect(throws: UpdateFeedRefusal.informationOnly) {
            try UpdateFeedReading.offer(from: UpdateFeedFixture.entry(isInformationOnly: true))
        }
    }

    /// The framework orders releases by `CFBundleVersion` numerically, so a
    /// value that is not a plain positive integer either compares as older than
    /// itself or does not compare at all.
    @Test("a build number that is not a positive integer is refused", arguments: ["0", "1.2", "02", "", "x"])
    func badBuildNumbersAreRefused(versionString: String) {
        #expect(throws: UpdateFeedRefusal.buildNumberNotAnInteger(versionString)) {
            try UpdateFeedReading.offer(from: UpdateFeedFixture.entry(versionString: versionString))
        }
    }

    @Test("an entry with no enclosure names no artifact")
    func missingEnclosureIsRefused() {
        #expect(throws: UpdateFeedRefusal.missingEnclosure) {
            try UpdateFeedReading.offer(from: UpdateFeedFixture.entry(enclosureURL: nil))
        }
    }

    /// A blank element is a missing one: an empty engine build id names no
    /// engine, and an empty digest vouches for nothing.
    @Test("a blank required element is a missing one", arguments: UpdateFeedElement.required)
    func blankElementsAreMissing(element: String) {
        var elements = UpdateFeedFixture.offered.elements
        elements[element] = ""
        let entry = UpdateFeedEntry(
            displayVersion: "0.2.0",
            versionString: "2",
            isCritical: false,
            isInformationOnly: false,
            enclosureURL: UpdateFeedFixture.offeredURL,
            elements: elements
        )

        #expect(throws: UpdateFeedRefusal.missingElement(element)) {
            try UpdateFeedReading.offer(from: entry)
        }
    }

    @Test("the entry for the installed build is found by its build number")
    func installedEntryIsFoundByBuildNumber() {
        let entries = [UpdateFeedFixture.installed, UpdateFeedFixture.offered]

        #expect(UpdateFeedReading.entry(for: 1, in: entries)?.displayVersion == "0.1.0")
        #expect(UpdateFeedReading.entry(for: 2, in: entries)?.displayVersion == "0.2.0")
        #expect(UpdateFeedReading.entry(for: 3, in: entries) == nil)
    }
}

/// What the updater adapter is structurally allowed to do.
///
/// The adapter is not in this test target — it links the framework, which only
/// the GUI executable may — so these read its shipped source. A rule about what
/// a module must never *call* is invisible to every value assertion, and both
/// of these are traps a later contributor would otherwise walk into.
@Suite("Updater adapter")
struct SparkleAdapterTests {
    /// Both executables link `FermixAppCore`, so an import there would put the
    /// framework into `FermixAgent` as well, which M34 §6 forbids outright.
    @Test("only the updater adapter imports the framework")
    func onlyTheAdapterImportsSparkle() throws {
        let importers = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.text.contains("import Sparkle") }

        // A scan that finds nothing passes every assertion it was written to
        // make, so the adapter itself has to show up in it.
        #expect(!importers.isEmpty, "the scan found no file importing the updater framework at all")

        for file in importers {
            #expect(
                file.path.contains("/FermixSparkle/"),
                "\(file.path) imports the updater framework outside the adapter"
            )
        }
    }

    /// Two writes the adapter must never make.
    ///
    /// `setFeedURL` writes the feed into this account's defaults, where it wins
    /// over the Info.plist for ever afterwards. And the automatic-check
    /// preference is the person's: M34 §6 says not to reset runtime preferences
    /// on launch, so the adapter reads that value and never assigns it.
    @Test("the adapter writes no preference and never sets the feed at runtime")
    func adapterWritesNoPreference() throws {
        let forbidden = ["setFeedURL", "automaticallyChecksForUpdates =", "automaticallyDownloadsUpdates ="]
        let adapter = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.path.contains("/FermixSparkle/") }

        #expect(!adapter.isEmpty, "the scan found no adapter source at all")

        for file in adapter {
            for call in forbidden {
                #expect(!file.text.contains(call), "\(file.path) writes \(call)")
            }
        }
    }
}

enum SparkleAdapterSource {
    /// Every shipped Swift file, across all four modules.
    ///
    /// It reads the tree rather than a list, so a module added later is scanned
    /// without anybody remembering to add it.
    static func everySwiftFileUnderSources() throws -> [SourceTree.File] {
        let sources = SourceTree.root.deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(atPath: sources.path) else {
            throw UpdatePolicyFixtureError.unreadable(path: sources.path)
        }

        var files: [SourceTree.File] = []
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            let path = sources.appendingPathComponent(name).path
            files.append(SourceTree.File(path: path, text: try String(contentsOfFile: path, encoding: .utf8)))
        }

        guard !files.isEmpty else { throw UpdatePolicyFixtureError.unreadable(path: sources.path) }
        return files
    }
}

/// The one lock over everything that can change the background service.
@Suite("Service mutation gate")
@MainActor
struct ServiceMutationGateTests {
    @Test("one owner at a time")
    func oneOwnerAtATime() {
        let gate = ServiceMutationGate()

        #expect(gate.acquire(.lifecycle))
        #expect(gate.holder == .lifecycle)
        #expect(!gate.acquire(.update))
        #expect(!gate.acquire(.reconcile))
        #expect(gate.holder == .lifecycle)
    }

    @Test("a released gate is free again")
    func releasedGateIsFree() {
        let gate = ServiceMutationGate()

        #expect(gate.acquire(.update))
        gate.release(.update)

        #expect(!gate.isHeld)
        #expect(gate.acquire(.lifecycle))
    }

    /// Every owner is refused by every other one. The set comes from the enum
    /// rather than from a pair somebody remembered to write down, so an owner
    /// added later either joins the invariant or fails this.
    @Test("every owner refuses every other", arguments: ServiceMutation.allCases)
    func everyOwnerRefusesEveryOther(holder: ServiceMutation) {
        let gate = ServiceMutationGate()
        #expect(gate.acquire(holder))

        for other in ServiceMutation.allCases {
            #expect(!gate.acquire(other), "\(other.rawValue) took a gate held by \(holder.rawValue)")
        }
    }
}

/// The policy values, and the one place they are actually written.
enum UpdatePolicyFixture {
    /// An obviously fake key of the right shape: thirty-two bytes, base64.
    /// No private half exists and none is wanted here — key custody is R5's,
    /// and the shipped configuration carries the placeholder until an owner
    /// plumbs a real one.
    static let wellFormedKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    static func manifest(
        feedURL: String? = "https://fermix.com/appcast.xml",
        publicEDKey: String? = "replace-with-the-production-sparkle-public-key",
        allowsAutomaticUpdates: Bool? = false,
        automaticallyUpdate: Bool? = false
    ) -> UpdatePolicyManifest {
        UpdatePolicyManifest(
            feedURL: feedURL,
            publicEDKey: publicEDKey,
            allowsAutomaticUpdates: allowsAutomaticUpdates,
            automaticallyUpdate: automaticallyUpdate
        )
    }

    /// The Info.plist this checkout ships, read off disk.
    ///
    /// It is the plist linked into the GUI binary, written only by
    /// `scripts/render_info_plist.sh` and gated against `Product.json` by
    /// `scripts/check_product_config.sh`. Reading the real file is what makes
    /// this a gate on the shipped policy rather than on a copy of it.
    static func checkedInPlist() throws -> [String: Any] {
        let url = SourceTree.root
            .deletingLastPathComponent()
            .appendingPathComponent("Fermix/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else {
            throw UpdatePolicyFixtureError.unreadable(path: url.path)
        }

        return plist
    }

    static func checkedInPolicy() throws -> UpdatePolicyManifest {
        let plist = try checkedInPlist()

        return UpdatePolicyManifest(
            feedURL: plist["SUFeedURL"] as? String,
            publicEDKey: plist["SUPublicEDKey"] as? String,
            allowsAutomaticUpdates: plist["SUAllowsAutomaticUpdates"] as? Bool,
            automaticallyUpdate: plist["SUAutomaticallyUpdate"] as? Bool
        )
    }
}

enum UpdatePolicyFixtureError: Error, Equatable {
    case unreadable(path: String)
}
