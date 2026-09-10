import Foundation

/// The update policy this bundle declares, as the rendered Info.plist carries
/// it (M34 §6, R2).
///
/// A plain value read out of the bundle, so the policy can be proved without
/// starting an updater and without touching this account's preferences. The
/// three automatic-installation keys are read as optionals because "the
/// developer said nothing" and "the developer said no" are different states,
/// and only one of them is safe.
public struct UpdatePolicyManifest: Equatable, Sendable {
    public let feedURL: String?
    public let publicEDKey: String?
    /// `SUAllowsAutomaticUpdates`. Absent means Sparkle falls back to whether
    /// automatic checking is on, which is how the whole automatic-installation
    /// path comes back silently.
    public let allowsAutomaticUpdates: Bool?
    /// `SUAutomaticallyUpdate`.
    public let automaticallyUpdate: Bool?

    public init(
        feedURL: String?,
        publicEDKey: String?,
        allowsAutomaticUpdates: Bool?,
        automaticallyUpdate: Bool?
    ) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.automaticallyUpdate = automaticallyUpdate
    }
}

/// Why this bundle may not run an updater at all.
///
/// Every case is a packaging defect rather than a condition of this Mac, so
/// each one names the key that is wrong. The updater is not constructed while
/// any of them stands: Sparkle answers a bad configuration with its own modal
/// alert about a second after start, in words this product never wrote.
public enum UpdateConfigurationRefusal: Error, Equatable, Sendable {
    case feedMissing
    case feedNotHTTPS(String)
    case publicKeyMissing
    /// The value is not base64, which is what the shipped placeholder is: the
    /// production key is R5's and no build carries one until it is plumbed.
    case publicKeyNotBase64
    /// ed25519 public keys are 32 bytes. Anything else verifies nothing.
    case publicKeyWrongLength(Int)
    /// `SUAllowsAutomaticUpdates` is absent or true, so Sparkle can still offer
    /// to install updates by itself, outside the transaction that stops the
    /// engine first.
    case automaticInstallationNotForbidden
    /// `SUAutomaticallyUpdate` is absent or true.
    case automaticDownloadNotForbidden
}

/// The one place the update policy is checked.
public enum UpdateConfiguration {
    /// ed25519 public keys are exactly this many bytes.
    public static let publicKeyByteCount = 32

    /// Refuses a bundle that must not run an updater.
    ///
    /// It runs before the updater is constructed rather than after: the
    /// alternative is Sparkle's own developer-facing alert, which is a
    /// user-visible string this product did not write.
    public static func validate(_ manifest: UpdatePolicyManifest) throws {
        try validateFeed(manifest.feedURL)
        try validateKey(manifest.publicEDKey)

        guard manifest.allowsAutomaticUpdates == false else {
            throw UpdateConfigurationRefusal.automaticInstallationNotForbidden
        }
        guard manifest.automaticallyUpdate == false else {
            throw UpdateConfigurationRefusal.automaticDownloadNotForbidden
        }
    }

    private static func validateFeed(_ feedURL: String?) throws {
        guard let feedURL, !feedURL.isEmpty else { throw UpdateConfigurationRefusal.feedMissing }
        guard feedURL.lowercased().hasPrefix("https://") else {
            throw UpdateConfigurationRefusal.feedNotHTTPS(feedURL)
        }
    }

    private static func validateKey(_ key: String?) throws {
        guard let key, !key.isEmpty else { throw UpdateConfigurationRefusal.publicKeyMissing }
        guard let decoded = Data(base64Encoded: key) else {
            throw UpdateConfigurationRefusal.publicKeyNotBase64
        }
        guard decoded.count == publicKeyByteCount else {
            throw UpdateConfigurationRefusal.publicKeyWrongLength(decoded.count)
        }
    }
}
