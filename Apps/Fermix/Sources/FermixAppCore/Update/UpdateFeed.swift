import Foundation

/// How a release is meant to be treated (M34 §6).
///
/// Two classes ship in the first release. Critical is reserved for security,
/// data loss, or an unusable release: its alert offers no Skip, and it is still
/// never installed without the person choosing Install.
public enum UpdateReleaseClass: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case critical
}

/// The elements a Fermix release publishes in its appcast entry, beside
/// Sparkle's own.
///
/// The app has no other way to learn them. The engine build is what the launch
/// reconcile compares the arriving bundle against, and the artifact facts are
/// what Recovery offers for an explicit reinstall — both are required by the
/// journal contract, and neither can be derived from a bundle that is not
/// installed yet. A feed entry that omits any of them is refused before
/// anything is downloaded rather than journaled as a guess.
public enum UpdateFeedElement {
    public static let engineBuildId = "fermix:engineBuildId"
    public static let engineVersion = "fermix:engineVersion"
    public static let sha256 = "fermix:sha256"
    public static let signingIdentity = "fermix:signingIdentity"

    /// Every element an entry has to carry, for the refusal to name the first
    /// one missing rather than reporting "something".
    public static let required = [engineBuildId, engineVersion, sha256, signingIdentity]
}

/// One appcast entry, in the app's own vocabulary.
///
/// It is a plain value so the whole of feed reading is provable without Sparkle:
/// the adapter that owns `SUAppcastItem` fills this in and nothing else knows
/// what an appcast is.
public struct UpdateFeedEntry: Equatable, Sendable {
    /// `CFBundleShortVersionString` of the release, which is what a person
    /// reads.
    public let displayVersion: String
    /// `CFBundleVersion` of the release, which is the ordering fact.
    public let versionString: String
    public let isCritical: Bool
    /// The entry describes a release note rather than something installable.
    public let isInformationOnly: Bool
    public let enclosureURL: String?
    /// The custom elements above, as the feed spelled them.
    public let elements: [String: String]

    public init(
        displayVersion: String,
        versionString: String,
        isCritical: Bool,
        isInformationOnly: Bool,
        enclosureURL: String?,
        elements: [String: String]
    ) {
        self.displayVersion = displayVersion
        self.versionString = versionString
        self.isCritical = isCritical
        self.isInformationOnly = isInformationOnly
        self.enclosureURL = enclosureURL
        self.elements = elements
    }
}

/// One release the feed describes, complete enough to journal a transaction
/// across it.
///
/// The same shape is read for both sides of an update: the offered release is
/// the target, and the entry for the build that is already installed is where
/// the prior installer comes from.
public struct UpdateOffer: Equatable, Sendable {
    public let release: UpdateRelease
    public let releaseClass: UpdateReleaseClass
    /// The exact artifact this release publishes, which is what Recovery
    /// reinstalls.
    public let installer: UpdateInstaller

    public init(release: UpdateRelease, releaseClass: UpdateReleaseClass, installer: UpdateInstaller) {
        self.release = release
        self.releaseClass = releaseClass
        self.installer = installer
    }

    public var app: AppBuild { release.app }
    public var engine: EngineBuild { release.engine }
}

/// Why a feed entry cannot be transacted.
///
/// Each is a defect in what was published, so each names the element that is
/// wrong: an operator reading the log has to be able to fix the appcast.
public enum UpdateFeedRefusal: Error, Equatable, Sendable {
    /// `CFBundleVersion` in the feed is not the positive integer Sparkle orders
    /// releases by.
    case buildNumberNotAnInteger(String)
    case missingElement(String)
    case missingEnclosure
    /// The entry installs nothing, so there is no transaction to run.
    case informationOnly
}

/// Turning one feed entry into a release this app can transact.
public enum UpdateFeedReading {
    public static func offer(from entry: UpdateFeedEntry) throws -> UpdateOffer {
        guard !entry.isInformationOnly else { throw UpdateFeedRefusal.informationOnly }

        let build = try buildNumber(entry.versionString)
        let elements = try required(entry.elements)
        guard let enclosure = entry.enclosureURL, !enclosure.isEmpty else {
            throw UpdateFeedRefusal.missingEnclosure
        }

        return UpdateOffer(
            release: UpdateRelease(
                app: AppBuild(marketingVersion: entry.displayVersion, buildNumber: build),
                engine: EngineBuild(
                    buildId: elements[UpdateFeedElement.engineBuildId] ?? "",
                    productVersion: elements[UpdateFeedElement.engineVersion] ?? ""
                )
            ),
            releaseClass: entry.isCritical ? .critical : .normal,
            installer: UpdateInstaller(
                url: enclosure,
                version: entry.displayVersion,
                sha256: elements[UpdateFeedElement.sha256] ?? "",
                signingIdentity: elements[UpdateFeedElement.signingIdentity] ?? ""
            )
        )
    }

    /// The entry for one build number, where the feed carries it.
    public static func entry(for buildNumber: Int, in entries: [UpdateFeedEntry]) -> UpdateFeedEntry? {
        entries.first { Int($0.versionString) == buildNumber }
    }

    private static func buildNumber(_ versionString: String) throws -> Int {
        guard let build = Int(versionString), build > 0, String(build) == versionString else {
            throw UpdateFeedRefusal.buildNumberNotAnInteger(versionString)
        }

        return build
    }

    /// Every required element, present and not blank. A blank value is missing:
    /// an empty engine build id names no engine, and an empty digest vouches
    /// for nothing.
    private static func required(_ elements: [String: String]) throws -> [String: String] {
        for name in UpdateFeedElement.required {
            guard let value = elements[name], !value.isEmpty else {
                throw UpdateFeedRefusal.missingElement(name)
            }
        }

        return elements
    }
}
