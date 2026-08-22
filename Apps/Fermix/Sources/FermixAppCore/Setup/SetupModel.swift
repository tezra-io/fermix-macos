import AppKit
import Foundation

/// Handing a url to the system browser, behind a seam.
public protocol ExternalOpening: Sendable {
    func open(_ url: URL)
}

/// One daemon-minted Setup session.
///
/// The url carries a one-use token, so it exists to be loaded and nothing else.
/// This type deliberately has no description, no `Codable` conformance, and no
/// accessor that renders the whole url as text: the only thing about a session
/// the app may write down is its origin.
public struct SetupSession: Equatable, Sendable {
    public let url: URL
    public let origin: String
    public let expiresAt: Date

    /// M34 §5.3/5.4: only the configured loopback origin loads inline.
    ///
    /// The app reaches the daemon over a socket path, so the url it answers with
    /// is not evidence of anything on its own. A non-loopback origin is refused
    /// here, before the one-use token can reach a web view at all.
    public init?(_ minted: ManagementSetupSession) {
        guard let url = URL(string: minted.url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              LoopbackHost.isLoopback(host)
        else { return nil }

        self.url = url
        self.expiresAt = minted.expiresAt
        self.origin = components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

/// The Setup surface's state. `ready` is the only case that holds a url, and it
/// is read by exactly one caller: the web view that loads it.
public enum SetupState: Equatable, Sendable {
    case idle
    case minting
    case ready(SetupSession)
    case failed(String)
}

/// The daemon-served Setup surface.
///
/// Swift supplies the shell and nothing else. It parses no provider, channel,
/// secret, or config value; it mints a session, loads it, and hands every other
/// destination to the system browser. A fresh session is minted on every open,
/// because the token is one-use and a reused url fails in front of the user.
@MainActor
public final class SetupModel: ObservableObject {
    /// The liveness gate for presenting Setup. `/health/ready` answers whether
    /// the daemon has finished warming, which is a different question and would
    /// keep a working Setup hidden.
    public static let livenessPath = HTTPWebLiveness.path

    @Published public private(set) var state: SetupState = .idle

    private let gateway: any DaemonQuerying
    private let opener: any ExternalOpening
    private let log = AppLog.logger(.app)
    /// The origin last seen, kept so the footer can name it before a session
    /// exists and after one has been dropped. It carries no token.
    private var lastKnownOrigin: String?

    public init(gateway: any DaemonQuerying, opener: any ExternalOpening) {
        self.gateway = gateway
        self.opener = opener
    }

    public var navigationPolicy: SetupNavigationPolicy? {
        guard let origin = currentOrigin else { return nil }

        let policy = SetupNavigationPolicy(origin: origin)
        guard policy.originIsLoopback else { return nil }

        return policy
    }

    /// The footer line: the loopback origin the daemon published, never the
    /// tokenized url. Before a session exists there is no origin to name, and
    /// naming a default port the daemon may not be using would be a guess.
    public var footerOrigin: String {
        guard let origin = currentOrigin else { return ProductStrings[.setupFooterServedLocally] }

        return ProductStrings.middot(ProductStrings[.setupFooterServedLocally], displayOrigin(origin))
    }

    /// What the app is allowed to say about this surface in a log or a
    /// diagnostic. The token is not part of it.
    public var diagnosticDescription: String {
        switch state {
        case .idle: return "setup: idle"
        case .minting: return "setup: minting"
        case .ready: return "setup: session for \(currentOrigin ?? "unknown origin")"
        case .failed: return "setup: refused"
        }
    }

    /// Mints a fresh one-use session and puts it in front of the web view.
    public func open() async {
        state = .minting

        do {
            let session = try await mint()
            state = .ready(session)
        } catch {
            log.error("setup session refused: \(ManagementMessage.sentence(for: error), privacy: .public)")
            state = .failed(ManagementMessage.sentence(for: error))
        }
    }

    /// Hands Setup to the system browser on its own fresh session, so the two
    /// surfaces never share a token that only one of them can spend.
    public func openInSystemBrowser() async {
        do {
            opener.open(try await mint().url)
        } catch {
            state = .failed(ManagementMessage.sentence(for: error))
        }
    }

    /// Drops the session when the surface goes away. The web view is ephemeral,
    /// and a token left in memory after the view is gone is a token with no
    /// reader.
    public func close() {
        state = .idle
    }

    private func mint() async throws -> SetupSession {
        let minted = try await gateway.createSetupSession()
        guard let session = SetupSession(minted) else {
            throw ManagementError.malformedEnvelope(
                .resultShapeMismatch(method: .setupSessionCreate, field: "url")
            )
        }

        lastKnownOrigin = session.origin
        return session
    }

    private var currentOrigin: String? {
        if case .ready(let session) = state { return session.origin }

        return lastKnownOrigin
    }

    /// The origin as the footer draws it: host and port, without the scheme.
    private func displayOrigin(_ origin: String) -> String {
        guard let components = URLComponents(string: origin), let host = components.host else { return origin }

        return components.port.map { "\(host):\($0)" } ?? host
    }
}

/// The production opener: the user's default browser, through the workspace.
public struct WorkspaceExternalOpener: ExternalOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
