import AppKit
import Foundation

/// One application this Mac has installed.
public struct InstalledApp: Identifiable, Equatable, Sendable, Comparable {
    public let bundleIdentifier: String
    public let name: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String) {
        precondition(!bundleIdentifier.isEmpty, "an application is addressed by bundle identifier")
        precondition(!name.isEmpty, "an application has a name")

        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    public static func < (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// Where the picker's list comes from.
///
/// A seam because the answer is the operator's own machine: a test that read
/// `/Applications` would assert against whatever happens to be installed.
public protocol InstalledAppsEnumerating: Sendable {
    func installedApps() -> [InstalledApp]
}

/// The shipped enumerator (M34 §5.5).
///
/// It reads the three application directories and takes each bundle's own
/// identifier. Nothing is launched and nothing is executed: a bundle that
/// carries no identifier is skipped rather than guessed at from its file name.
public struct SystemInstalledApps: InstalledAppsEnumerating {
    /// The directories macOS puts applications in.
    public static let directories = ["/Applications", "/System/Applications"]
    /// The ceiling on one scan. A directory this size is already pathological;
    /// the bound is here so the scan cannot become unbounded work on a machine
    /// with a broken mount.
    public static let maximumScanned = 2_000

    private let log = AppLog.logger(.app)

    public init() {}

    public func installedApps() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]

        for directory in Self.searchPaths() {
            for url in bundles(in: directory).prefix(Self.maximumScanned) {
                guard let app = Self.app(at: url) else { continue }

                found[app.bundleIdentifier] = app
            }
        }

        return found.values.sorted()
    }

    /// The two system directories plus the account's own, resolved from the
    /// home directory rather than composed from a user name.
    static func searchPaths() -> [String] {
        directories + [NSHomeDirectory() + "/Applications"]
    }

    /// `FileManager.default` rather than an injected one: the seam this type
    /// sits behind is `InstalledAppsEnumerating`, and a second seam inside it
    /// would be one nobody uses.
    ///
    /// A directory that is simply not there is expected: most Macs have no
    /// `~/Applications`. Anything else is a directory the operator has but this
    /// process could not read, which is why it is logged with its path rather
    /// than reported as an empty shelf.
    private func bundles(in directory: String) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            log.error(
                "applications unreadable in \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// One bundle's identity, read from its own `Info.plist`.
    static func app(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }

        let name = bundle.infoDictionary?["CFBundleName"] as? String
        let fallback = url.deletingPathExtension().lastPathComponent

        return InstalledApp(
            bundleIdentifier: identifier,
            name: (name?.isEmpty == false ? name : nil) ?? fallback
        )
    }
}

/// What the picker will let the operator send.
///
/// The daemon refuses an empty list and refuses more than the published cap
/// with a sentence naming the field, so the picker says both before the write
/// rather than after it.
public enum InstalledAppsSelection {
    /// M34 §5.5's cap, which the daemon enforces and this reports.
    public static let maximumApps = 200

    public static func isSendable(_ selected: Set<String>) -> Bool {
        !selected.isEmpty && selected.count <= maximumApps
    }

    /// The line under the picker's default button: how many are chosen, and the
    /// limit, so an over-wide selection is legible before it is refused.
    public static func summary(_ selected: Set<String>) -> String {
        String(format: ProductStrings[.computerAppsSelectedFormat], selected.count, maximumApps)
    }
}
