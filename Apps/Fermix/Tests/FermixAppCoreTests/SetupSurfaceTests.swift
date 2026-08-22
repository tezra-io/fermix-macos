import Foundation
import Testing

@testable import FermixAppCore

/// The Setup surface: a daemon-minted one-use session in an ephemeral web view,
/// loopback-origin-only navigation, and everything else handed to the system
/// browser. Swift parses no provider, channel, secret, or config value.
@Suite("Setup surface")
@MainActor
struct SetupSurfaceTests {
    private let origin = "http://127.0.0.1:4030"

    private func policy() -> SetupNavigationPolicy {
        SetupNavigationPolicy(origin: origin)
    }

    /// The navigation a user actually performs: a link, clicked, in the window
    /// they are looking at.
    private func clicked(_ raw: String?) -> SetupNavigation {
        SetupNavigation(
            url: raw.flatMap { URL(string: $0) },
            isMainFrame: true,
            isLinkActivation: true
        )
    }

    // MARK: - Navigation policy

    @Test("the configured loopback origin loads inside the view")
    func loopbackLoadsInline() {
        let decision = policy().decide(clicked("http://127.0.0.1:4030/setup?token=abc"))

        #expect(decision == .allowInline)
    }

    @Test("a different port on the same host is not the configured origin")
    func differentPortIsExternal() {
        let decision = policy().decide(clicked("http://127.0.0.1:4031/setup"))

        #expect(decision == .openInSystemBrowser(URL(string: "http://127.0.0.1:4031/setup")!))
    }

    /// Provider OAuth is the case this rule exists for: it must leave the app,
    /// so the user signs in against the vendor's real browser session.
    @Test("provider OAuth and every other https destination open in the browser")
    func oauthGoesToTheBrowser() {
        let url = URL(string: "https://auth.openai.com/authorize?client_id=fermix")!

        #expect(policy().decide(clicked(url.absoluteString)) == .openInSystemBrowser(url))
    }

    @Test("a scheme the setup surface never uses is refused, not opened")
    func foreignSchemesAreRefused() {
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>", "mailto:a@b.c"] {
            let decision = policy().decide(clicked(raw))

            #expect(decision == .refuse(.unsupportedScheme), "\(raw)")
        }
    }

    @Test("a navigation with no url at all is refused")
    func missingURLIsRefused() {
        #expect(policy().decide(clicked(nil)) == .refuse(.noURL))
    }

    /// The browser hand-off exists so the user can sign in against their real
    /// browser session, which is a link they clicked. A sub-frame load or a
    /// script-driven redirect would make the app a no-gesture bridge from web
    /// content to the system browser, one tab per frame.
    @Test("only a clicked link in the main frame may leave for the browser")
    func onlyUserInitiatedNavigationLeaves() {
        let url = URL(string: "https://attacker.example/x")!

        let subFrame = SetupNavigation(url: url, isMainFrame: false, isLinkActivation: true)
        let scripted = SetupNavigation(url: url, isMainFrame: true, isLinkActivation: false)

        #expect(policy().decide(subFrame) == .refuse(.unattendedExternalNavigation))
        #expect(policy().decide(scripted) == .refuse(.unattendedExternalNavigation))
        #expect(policy().decide(clicked(url.absoluteString)) == .openInSystemBrowser(url))
    }

    /// A sub-frame of the daemon's own page is still the daemon's page: the
    /// gesture rule governs leaving, not loading.
    @Test("the configured origin still loads in a sub-frame")
    func configuredOriginLoadsInSubFrames() {
        let navigation = SetupNavigation(
            url: URL(string: "http://127.0.0.1:4030/setup/panel"),
            isMainFrame: false,
            isLinkActivation: false
        )

        #expect(policy().decide(navigation) == .allowInline)
    }

    // MARK: - Loopback

    /// M34 §5.3/5.4: only the configured loopback origin loads inline. The app
    /// connects to a socket path, and a hostile or hijacked daemon behind it
    /// could answer with any origin at all.
    @Test("a session whose url is not loopback is refused before it is loaded")
    func nonLoopbackSessionIsRefused() throws {
        for raw in [
            "https://attacker.example/setup?t=TOKEN",
            "http://192.168.1.10:4030/setup?t=TOKEN",
            "http://fermix.ai/setup?t=TOKEN"
        ] {
            let minted = try ManagementValueFixture.setupSession(url: raw)

            #expect(SetupSession(minted) == nil, "\(raw)")
        }
    }

    @Test("every loopback form the daemon can publish is accepted")
    func loopbackFormsAreAccepted() throws {
        for raw in [
            "http://127.0.0.1:4030/setup?t=TOKEN",
            "http://127.5.5.5:4030/setup?t=TOKEN",
            "http://localhost:4030/setup?t=TOKEN",
            "http://[::1]:4030/setup?t=TOKEN"
        ] {
            let minted = try ManagementValueFixture.setupSession(url: raw)

            #expect(SetupSession(minted) != nil, "\(raw)")
        }
    }

    /// Defense in depth: even if an origin reached the policy, it refuses to
    /// treat a non-loopback one as the daemon, and refuses rather than handing
    /// the tokenized url to the system browser.
    @Test("a policy built on a non-loopback origin refuses every navigation")
    func nonLoopbackPolicyRefusesEverything() {
        let hostile = SetupNavigationPolicy(origin: "https://attacker.example")

        #expect(hostile.decide(clicked("https://attacker.example/setup?t=TOKEN")) == .refuse(.originNotLoopback))
        #expect(hostile.decide(clicked("https://elsewhere.example/x")) == .refuse(.originNotLoopback))
    }

    @Test("a refused mint leaves no navigation policy at all")
    func nonLoopbackMintIsReported() async throws {
        let harness = try SetupHarness()
        harness.gateway.setupSession = try ManagementValueFixture.setupSession(
            url: "https://attacker.example/setup?t=TOKEN"
        )

        await harness.model.open()

        guard case .failed = harness.model.state else {
            Issue.record("expected a failed state, got \(harness.model.state)")
            return
        }
        #expect(harness.model.navigationPolicy == nil)
    }

    // MARK: - Sessions

    @Test("opening Setup mints a session and hands it to the view")
    func openMintsASession() async throws {
        let harness = try SetupHarness()

        await harness.model.open()

        #expect(harness.gateway.calls == [.setupSession])
        guard case .ready(let session) = harness.model.state else {
            Issue.record("expected a ready session, got \(harness.model.state)")
            return
        }
        #expect(session.origin == "http://127.0.0.1:4030")
    }

    /// M34 §5: mint a fresh session whenever Setup is reopened. A reused url is
    /// a spent one-use token, which fails in front of the user.
    @Test("reopening Setup mints a fresh session every time")
    func reopeningMintsAfresh() async throws {
        let harness = try SetupHarness()

        await harness.model.open()
        await harness.model.open()
        await harness.model.open()

        #expect(harness.gateway.calls == [.setupSession, .setupSession, .setupSession])
    }

    @Test("open in browser mints its own session rather than sharing the view's")
    func browserHandoffMintsAfresh() async throws {
        let harness = try SetupHarness()

        await harness.model.open()
        await harness.model.openInSystemBrowser()

        #expect(harness.gateway.calls == [.setupSession, .setupSession])
        #expect(harness.opener.urls.count == 1)
        #expect(harness.opener.urls.first?.absoluteString.contains("token=") == true)
    }

    /// The tokenized url is never logged, persisted, or copied. What the surface
    /// can say about a session is its origin, and the gate is that the token
    /// does not appear in anything the app writes.
    @Test("nothing the app writes about a session carries its token")
    func tokenNeverLeaves() async throws {
        let harness = try SetupHarness()

        await harness.model.open()

        #expect(!harness.model.diagnosticDescription.contains("token"))
        #expect(!harness.model.diagnosticDescription.contains("s3cr3t"))
        #expect(harness.model.footerOrigin.contains("127.0.0.1:4030"))
        #expect(!harness.model.footerOrigin.contains("s3cr3t"))
    }

    @Test("a refused mint is reported rather than leaving an empty view")
    func mintFailureIsReported() async throws {
        let harness = try SetupHarness()
        harness.gateway.setupFailure = ManagementError.daemon(
            ManagementFailure(
                code: .unavailable,
                message: "setup endpoint is not listening",
                details: ManagementScalarMap(values: [:])
            )
        )

        await harness.model.open()

        guard case .failed(let message) = harness.model.state else {
            Issue.record("expected a failed state, got \(harness.model.state)")
            return
        }
        #expect(message == "setup endpoint is not listening")
    }

    /// Setup presentation is gated on `/health/live`. `/health/ready` answers a
    /// different question and would hide a working Setup while the daemon warms.
    @Test("Setup presentation is gated on health/live")
    func gatedOnHealthLive() {
        #expect(SetupModel.livenessPath == "/health/live")
    }
}

@MainActor
final class SetupHarness {
    let gateway = FakeDaemonGateway()
    let opener = RecordingExternalOpener()
    let model: SetupModel

    init() throws {
        gateway.setupSession = try ManagementValueFixture.setupSession()
        model = SetupModel(gateway: gateway, opener: opener)
    }
}
