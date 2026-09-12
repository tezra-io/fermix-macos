import Darwin
import Foundation

public enum BootstrapLocationError: Error, Equatable, Sendable {
    case accountHomeUnavailable
}

/// Where the sole pre-daemon bootstrap record lives, and where the default
/// Fermix home is.
///
/// The account home is read from the password database rather than from the
/// environment: `$HOME` can be re-pointed by whatever launched the process, and
/// a bootstrap record written against a spoofed home would send the daemon to
/// the wrong data. Both directories are injected, so tests never touch the real
/// account.
public struct BootstrapLocation: Equatable, Sendable {
    public static let directoryName = "Fermix"
    public static let recordName = "launcher.json"
    public static let defaultHomeName = ".fermix"

    public let homeDirectory: URL
    public let applicationSupportDirectory: URL

    public init(homeDirectory: URL, applicationSupportDirectory: URL) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public init(homeDirectory: URL) {
        self.init(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        )
    }

    /// The location for the macOS account running this process.
    public static func currentAccount() throws -> BootstrapLocation {
        guard let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir else {
            throw BootstrapLocationError.accountHomeUnavailable
        }
        let home = String(cString: directory)
        guard !home.isEmpty, home != "/" else {
            throw BootstrapLocationError.accountHomeUnavailable
        }
        return BootstrapLocation(homeDirectory: URL(fileURLWithPath: home, isDirectory: true))
    }

    public var directoryURL: URL {
        applicationSupportDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var recordURL: URL {
        directoryURL.appendingPathComponent(Self.recordName, isDirectory: false)
    }

    /// The account home Fermix has always used, and the default this app writes
    /// on a fresh account. The engine's own first-boot path creates its
    /// contents; the app never scaffolds them.
    public var defaultFermixHome: URL {
        homeDirectory.appendingPathComponent(Self.defaultHomeName, isDirectory: true)
    }
}
