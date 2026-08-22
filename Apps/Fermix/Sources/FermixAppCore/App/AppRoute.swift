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
public enum WindowKind: String, CaseIterable, Sendable {
    case onboarding
    case main
    case pet
}

extension GlassRecipe {
    /// The glass a window draws (§4.1, §5.7 to §5.9).
    ///
    /// It is a property of the window rather than something each view decides,
    /// so a surface added to the main window inherits the same material instead
    /// of painting its own opaque ground. The pet is a borderless companion
    /// with no window chrome at all, so it has none.
    public static func forWindow(_ kind: WindowKind) -> GlassRecipe? {
        switch kind {
        case .onboarding, .main: return .window
        case .pet: return nil
        }
    }

    /// The glass a window with chrome draws. Asking for a kind that has none is
    /// a defect at the call site, not a window that quietly draws flat.
    public static func required(for kind: WindowKind) -> GlassRecipe {
        guard let recipe = forWindow(kind) else {
            preconditionFailure("\(kind.rawValue) has no window chrome to draw")
        }

        return recipe
    }
}

/// Everywhere the app can be sent, by the user or by the CLI.
public enum AppRoute: String, CaseIterable, Sendable {
    case home
    case setup
    case doctor
    case logs
    case pet
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

    /// Which window shows this route. Recovery is a state of the onboarding
    /// machine; everything else lives in the main window.
    public var window: WindowKind {
        self == .recovery ? .onboarding : .main
    }

    /// The sidebar row this route selects, where it is a sidebar destination.
    public var sidebarItemIdentifier: String? {
        switch self {
        case .home: return "home"
        case .setup: return "setup"
        case .doctor: return "doctor"
        case .logs: return "logs"
        case .pet: return "pet"
        case .update, .uninstall, .recovery: return nil
        }
    }

    public static func parse(_ url: URL) throws -> AppRoute {
        guard url.scheme?.lowercased() == scheme else {
            throw AppRouteError.foreignScheme(url.scheme ?? "")
        }

        guard let host = url.host, !host.isEmpty else {
            throw AppRouteError.routeMissing
        }

        guard let route = AppRoute(rawValue: host.lowercased()) else {
            throw AppRouteError.unknownRoute(host)
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty, url.query == nil, url.fragment == nil else {
            throw AppRouteError.unexpectedParameters(route.rawValue)
        }

        return route
    }
}

/// Why this process is running.
public enum LaunchReason: Equatable, Sendable {
    /// macOS started the app from its login-item registration.
    case login
    /// The user opened it from the Dock, Finder, or Spotlight.
    case user
    /// A `fermix://` url asked for a surface.
    case route(AppRoute)
}

/// Turns what the launch actually was into what the app should do about it.
public enum LaunchClassifier {
    /// A url is an explicit request, so it wins over a quiet login launch: the
    /// user (or the CLI) asked for a surface by name.
    public static func classify(isLoginLaunch: Bool, route: AppRoute?) -> LaunchReason {
        if let route { return .route(route) }

        return isLoginLaunch ? .login : .user
    }
}
