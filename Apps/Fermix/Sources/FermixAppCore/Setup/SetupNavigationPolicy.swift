import Foundation

/// Why a navigation was refused outright.
public enum SetupNavigationRefusal: String, Equatable, Sendable {
    /// A scheme the Setup surface never uses. `file:`, `javascript:`, and
    /// `data:` are the ones that matter, and none of them is something the
    /// daemon's own LiveView asks for.
    case unsupportedScheme
    case noURL
    /// The configured origin is not loopback, so nothing about this surface is
    /// what it claims to be. Handing the navigation to the browser instead would
    /// send a one-use token off-box.
    case originNotLoopback
    /// An external destination reached without a click: a sub-frame load or a
    /// script-driven redirect. Honouring it would make the app a no-gesture
    /// bridge from web content to the system browser.
    case unattendedExternalNavigation
}

/// One navigation the web view is asking about.
public struct SetupNavigation: Equatable, Sendable {
    public let url: URL?
    /// Whether the navigation targets the window the user is looking at.
    public let isMainFrame: Bool
    /// Whether the user clicked a link to cause it.
    public let isLinkActivation: Bool

    public init(url: URL?, isMainFrame: Bool, isLinkActivation: Bool) {
        self.url = url
        self.isMainFrame = isMainFrame
        self.isLinkActivation = isLinkActivation
    }
}

/// What the web view is allowed to do with a navigation.
public enum SetupNavigationDecision: Equatable, Sendable {
    case allowInline
    case openInSystemBrowser(URL)
    case refuse(SetupNavigationRefusal)
}

/// The hosts the Setup surface may load from.
///
/// The daemon publishes its own Setup origin, and the app connects to a socket
/// path rather than to a name it verified — so "the daemon said so" is not on
/// its own a reason to load a page inside Fermix's chrome with a one-use token
/// in the url. It has to be loopback.
public enum LoopbackHost {
    private static let names: Set<String> = ["localhost"]

    public static func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if names.contains(value) { return true }
        if value == "::1" { return true }

        return isIPv4Loopback(value)
    }

    /// The whole of `127.0.0.0/8`, which is what the kernel treats as loopback.
    private static func isIPv4Loopback(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }

        return octets[0] == "127"
    }
}

/// The only navigation rule the embedded Setup view has.
///
/// Exactly one origin loads inside the view: the loopback origin the daemon
/// published in `hello`. Provider OAuth and every other web destination leave
/// for the system browser *when the user clicked a link*, which is what lets
/// them sign in against their real browser session and keeps Fermix out of the
/// credential path. Anything else is refused rather than handed to the system.
public struct SetupNavigationPolicy: Equatable, Sendable {
    private static let webSchemes: Set<String> = ["http", "https"]

    public let origin: String

    public init(origin: String) {
        self.origin = origin
    }

    /// Whether this policy's own origin is one the surface may host at all.
    public var originIsLoopback: Bool {
        guard let host = URLComponents(string: origin)?.host else { return false }

        return LoopbackHost.isLoopback(host)
    }

    public func decide(_ navigation: SetupNavigation) -> SetupNavigationDecision {
        guard originIsLoopback else { return .refuse(.originNotLoopback) }
        guard let url = navigation.url else { return .refuse(.noURL) }
        guard let scheme = url.scheme?.lowercased(), Self.webSchemes.contains(scheme) else {
            return .refuse(.unsupportedScheme)
        }
        guard !isConfiguredOrigin(url) else { return .allowInline }
        guard navigation.isMainFrame, navigation.isLinkActivation else {
            return .refuse(.unattendedExternalNavigation)
        }

        return .openInSystemBrowser(url)
    }

    /// Scheme, host, and port must all match the published origin. A different
    /// port on the same host is a different server, and treating it as the
    /// daemon would load someone else's page inside Fermix's chrome.
    private func isConfiguredOrigin(_ url: URL) -> Bool {
        guard let expected = URLComponents(string: origin),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }

        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && resolvedPort(actual) == resolvedPort(expected)
    }

    private func resolvedPort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }

        return components.scheme?.lowercased() == "https" ? 443 : 80
    }
}
