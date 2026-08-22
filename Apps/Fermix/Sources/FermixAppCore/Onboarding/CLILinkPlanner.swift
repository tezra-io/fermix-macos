import Foundation

/// The filesystem questions the CLI planner asks, behind a seam.
public protocol SymbolicLinkInspecting: Sendable {
    func exists(atPath path: String) -> Bool
    func destinationOfSymbolicLink(atPath path: String) -> String?
}

public struct FileManagerLinkInspector: SymbolicLinkInspecting {
    public init() {}

    public func exists(atPath path: String) -> Bool {
        // `fileExists` follows symlinks, so a link pointing at a deleted target
        // answers false. The link itself is what matters here.
        FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    public func destinationOfSymbolicLink(atPath path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}

/// What Ready can offer about the `fermix` command.
public enum CLILinkPlan: Equatable, Sendable {
    /// A link this app owns is already in place.
    case linkedByThisApp(path: String)
    /// Homebrew owns the one launcher link under its active prefix, so the
    /// hardcoded `/usr/local/bin` command must not run at all.
    case ownedByHomebrew(path: String)
    /// Something else holds the target path. The app names it and stops.
    case foreignFileInPlace(path: String)
    /// This bundle ships no command-line launcher, so there is nothing to link
    /// to. Offering the command anyway would ask for a password and produce a
    /// dangling root-owned symlink on PATH.
    case launcherMissing(path: String)
    case available(command: String, path: String)

    /// The sentence Ready draws under the row title.
    public var hint: String {
        switch self {
        case .linkedByThisApp:
            return ProductStrings[.readyCLIHintLinked]
        case .ownedByHomebrew:
            return ProductStrings[.readyCLIHintHomebrew]
        case .foreignFileInPlace:
            return ProductStrings[.readyCLIHintForeign]
        case .launcherMissing:
            return ProductStrings[.readyCLIHintNoLauncher]
        case .available:
            return ProductStrings[.readyCLIHint]
        }
    }

    /// Whether there is anything for the user to copy.
    public var offersCommand: Bool {
        if case .available = self { return true }

        return false
    }
}

/// Plans the `fermix` command for Terminal.
///
/// M34 §4 and planned deviation 12: no privileged helper, no one-shot elevation,
/// and no `ln -sf` over a file this app did not create. The row starts
/// unchecked, the command is copied and run by the user, and the app verifies
/// the result afterwards by inspecting the path again.
public struct CLILinkPlanner: Sendable {
    /// The DMG install's target. A cask install never uses it: Homebrew owns
    /// the link under its own prefix.
    public static let systemPath = "/usr/local/bin/fermix"
    /// The Apple-silicon Homebrew prefix. On Intel the prefix *is*
    /// `/usr/local`, so a link there is indistinguishable from a hand-made one
    /// and is reported as already linked rather than guessed at.
    public static let homebrewPath = "/opt/homebrew/bin/fermix"
    /// The redline draws the row checked; M34 ships it unchecked, so nothing is
    /// installed unless the user asks.
    public static let startsChecked = false

    private let launcherPath: String
    private let inspector: any SymbolicLinkInspecting

    public init(launcherPath: String, inspector: any SymbolicLinkInspecting = FileManagerLinkInspector()) {
        precondition(!launcherPath.isEmpty, "the planner needs the bundled launcher's path")

        self.launcherPath = launcherPath
        self.inspector = inspector
    }

    public func plan() -> CLILinkPlan {
        // The launcher is what the link points at, so its absence is the first
        // question: a bundle that ships none has nothing to offer, and saying so
        // is the difference between an honest row and a broken root-owned link.
        guard inspector.exists(atPath: launcherPath) else {
            return .launcherMissing(path: launcherPath)
        }
        if pointsAtLauncher(Self.homebrewPath) {
            return .ownedByHomebrew(path: Self.homebrewPath)
        }
        if pointsAtLauncher(Self.systemPath) {
            return .linkedByThisApp(path: Self.systemPath)
        }
        if inspector.exists(atPath: Self.systemPath) {
            return .foreignFileInPlace(path: Self.systemPath)
        }

        return .available(command: command, path: Self.systemPath)
    }

    /// The post-verification: after the user runs the command, the app looks
    /// again. A row that says "installed" says it because the link is there
    /// *and* resolves — a link whose target is absent is a broken command, not
    /// an installed one.
    public func verify() -> Bool {
        guard inspector.exists(atPath: launcherPath) else { return false }

        return pointsAtLauncher(Self.systemPath) || pointsAtLauncher(Self.homebrewPath)
    }

    /// The copyable command. It is a plain shell line the user reads before
    /// running, which is the whole reason it is not a helper: `ln -s` refuses
    /// an occupied path, so it cannot silently replace anything.
    public var command: String {
        "sudo ln -s \"\(launcherPath)\" \(Self.systemPath)"
    }

    private func pointsAtLauncher(_ path: String) -> Bool {
        inspector.destinationOfSymbolicLink(atPath: path) == launcherPath
    }
}

/// The Telegram pairing tile.
///
/// M34 §7 and planned deviation 5: the artboard's "QR, scan from your phone"
/// tile is mock art. A code is rendered only from a real daemon-supplied
/// pairing payload; without one the tile carries the truthful instruction that
/// pairing happens in Setup. The geometry is kept for the real code.
public struct ChannelPairingTile: Equatable, Sendable {
    /// The redline's 92-point tile.
    public static let size: Double = 92

    public let payload: String?

    public init(payload: String?) {
        self.payload = payload
    }

    public var rendersCode: Bool { payload?.isEmpty == false }

    public var title: String {
        rendersCode ? ProductStrings[.connectChannelPairingReady] : ProductStrings[.connectChannelPairing]
    }

    public var instruction: String {
        rendersCode ? ProductStrings[.connectChannelPairingScan] : ProductStrings[.connectChannelPairingHint]
    }
}
