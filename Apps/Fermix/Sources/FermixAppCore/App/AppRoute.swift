import Foundation

/// Why a `fermix://` url could not be honoured. Every case names what was
/// inspected: a url that does not resolve is refused, never quietly turned into
/// Home, which would tell the user their command worked.
public enum AppRouteError: Error, Equatable, Sendable {
    case foreignScheme(String)
    case routeMissing
    case unknownRoute(String)
    /// v1 routes carry no parameters. A url with any is refused rather than
    /// having its extras ignored.
    case unexpectedParameters(String)
}

/// A window this app can put on screen.
///
/// Setup and Settings are presentations of the primary window. The floating
/// pet is the only auxiliary window.
public enum WindowKind: String, CaseIterable, Sendable {
    case main
    case pet
}

/// Everywhere the app can be sent, by the user or by the CLI.
///
/// Setup is a task rather than a sidebar destination (M34 §5), so it has no row
/// in the primary window. `fermix://setup` opens the assistant at the screen a
/// gating readiness failure names, or Settings when nothing gates (M34 §3.4).
/// `SetupRouting` resolves that presentation from the daemon's readiness.
public enum AppRoute: String, CaseIterable, Sendable {
    case home
    case doctor
    case logs
    case pet
    /// The Setup Assistant, at whichever screen the daemon's own readiness
    /// names. It is the one route whose landing is resolved rather than fixed.
    case setup
    /// `fermix upgrade` opens the native update surface.
    case update = "upgrade"
    case uninstall
    /// The recovery entry: reachable from a failed activation, an interrupted
    /// update, or `fermix://recovery`.
    case recovery

    public static let scheme = "fermix"

    public var url: URL {
        guard let url = URL(string: "\(Self.scheme)://\(rawValue)") else {
            preconditionFailure("route \(rawValue) does not form a url")
        }
        return url
    }

    /// Every route is a presentation of the primary window.
    public var window: WindowKind { .main }

    /// The sidebar row this route selects, where it is a sidebar destination.
    public var sidebarItemIdentifier: String? {
        switch self {
        case .home: return "home"
        case .doctor: return "doctor"
        case .logs: return "logs"
        case .pet: return "pet"
        case .setup, .update, .uninstall, .recovery: return nil
        }
    }

    /// The one url host that carries a path segment (M34 §3.4).
    public static let settingsHost = "settings"

    public static func parse(_ url: URL) throws -> AppDestination {
        guard url.scheme?.lowercased() == scheme else {
            throw AppRouteError.foreignScheme(url.scheme ?? "")
        }

        guard let host = url.host, !host.isEmpty else {
            throw AppRouteError.routeMissing
        }

        let name = host.lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard url.query == nil, url.fragment == nil else {
            throw AppRouteError.unexpectedParameters(name)
        }

        if name == settingsHost {
            return .settings(try settingsPane(inPath: path))
        }

        guard let route = AppRoute(rawValue: name) else {
            throw AppRouteError.unknownRoute(host)
        }

        // Every other family carries no path at all: extras are refused rather
        // than ignored, which would tell the user their command worked.
        guard path.isEmpty else {
            throw AppRouteError.unexpectedParameters(name)
        }

        return .surface(route)
    }

    /// The settings family's one allowlisted segment.
    ///
    /// Exactly one, and it has to name a pane: a second segment, none at all, or
    /// a slug this build does not publish is `unknownRoute`, never a silent fall
    /// to a pane nobody asked for.
    private static func settingsPane(inPath path: String) throws -> SettingsPane {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count == 1, let pane = SettingsPane(rawValue: segments[0].lowercased()) else {
            throw AppRouteError.unknownRoute("\(settingsHost)/\(path)")
        }

        return pane
    }
}

/// Everywhere a `fermix://` url can land.
///
/// Two families, because one of them carries a value: every surface route is a
/// bare host, and the settings family names the pane it opens. Keeping the pane
/// in the destination is what lets `AppCoordinator` open the window *and* select
/// the pane from one parsed value rather than from a url read twice.
public enum AppDestination: Equatable, Sendable {
    case surface(AppRoute)
    case settings(SettingsPane)

    public var url: URL {
        switch self {
        case .surface(let route):
            return route.url
        case .settings(let pane):
            guard let url = URL(string: "\(AppRoute.scheme)://\(AppRoute.settingsHost)/\(pane.slug)") else {
                preconditionFailure("settings pane \(pane.slug) does not form a url")
            }

            return url
        }
    }

    /// The window this destination puts on screen. Settings is a presentation
    /// of the primary window (decision D1), so it names that window and the
    /// presentation switch decides what is drawn inside it.
    public var window: WindowKind {
        switch self {
        case .surface(let route): return route.window
        case .settings: return .main
        }
    }
}

/// Why this process is running.
public enum LaunchReason: Equatable, Sendable {
    /// macOS started the app from its login-item registration.
    case login
    /// The user opened it from the Dock, Finder, or Spotlight.
    case user
    /// A `fermix://` url asked for a surface.
    case route(AppDestination)
}

/// Turns what the launch actually was into what the app should do about it.
public enum LaunchClassifier {
    /// A url is an explicit request, so it wins over a quiet login launch: the
    /// user (or the CLI) asked for a surface by name.
    public static func classify(isLoginLaunch: Bool, destination: AppDestination?) -> LaunchReason {
        if let destination { return .route(destination) }

        return isLoginLaunch ? .login : .user
    }
}
