import Foundation
import Testing

@testable import FermixAppCore

/// Ready's one admin moment: the `fermix` command for Terminal.
///
/// M34 §4 replaces the artboard's pre-checked, password-prompting row with an
/// unchecked row that copies a Terminal command and verifies the result
/// afterwards. There is no privileged helper anywhere in this app.
@Suite("Ready CLI row")
struct ReadySurfaceTests {
    private let launcher = "/Applications/Fermix.app/Contents/MacOS/fermix"

    private func planner(_ inspector: StubLinkInspector) -> CLILinkPlanner {
        CLILinkPlanner(launcherPath: launcher, inspector: inspector)
    }

    /// The redline draws the row checked; M34 ships it unchecked, so nothing is
    /// installed unless the user asks.
    @Test("the CLI row starts unchecked")
    func startsUnchecked() {
        #expect(!CLILinkPlanner.startsChecked)
    }

    /// The command is only offered once the launcher it links to is proven to
    /// be there. A bundle that ships none would otherwise have the user create
    /// a dangling root-owned symlink on PATH.
    private func staged(_ inspector: StubLinkInspector = StubLinkInspector()) -> StubLinkInspector {
        var staged = inspector
        staged.files.insert(launcher)
        return staged
    }

    @Test("a clean machine offers a copyable command naming the launcher")
    func offersACommand() {
        let plan = planner(staged()).plan()

        guard case .available(let command, let path) = plan else {
            Issue.record("expected an available plan, got \(plan)")
            return
        }
        #expect(path == "/usr/local/bin/fermix")
        #expect(command.contains(launcher))
        #expect(command.contains("/usr/local/bin/fermix"))
    }

    @Test("the command asks for no privileged helper, only a shell the user runs")
    func noPrivilegedHelper() {
        guard case .available(let command, _) = planner(staged()).plan() else {
            Issue.record("expected an available plan")
            return
        }

        #expect(command.hasPrefix("sudo ln -s"))
        #expect(!command.contains("SMJobBless"))
        #expect(!command.contains("AuthorizationExecuteWithPrivileges"))
    }

    /// A bundle with no CLI launcher has nothing to link to. Offering the
    /// command anyway asks for a password and produces a broken root-owned link
    /// whose target the app would then report as installed.
    @Test("a bundle that ships no launcher offers no command at all")
    func missingLauncherOffersNothing() {
        let plan = planner(StubLinkInspector()).plan()

        #expect(plan == .launcherMissing(path: launcher))
        #expect(!plan.offersCommand)
        #expect(!plan.hint.isEmpty)
    }

    /// The verification is what turns "here is a command" into "it worked", so
    /// it has to answer for the target as well as the link: a link pointing at
    /// a launcher that is not there is not an installed command.
    @Test("a link pointing at an absent launcher does not count as installed")
    func danglingLinkIsNotInstalled() {
        let dangling = StubLinkInspector(links: ["/usr/local/bin/fermix": launcher])

        #expect(!planner(dangling).verify())
        #expect(planner(staged(dangling)).verify())
    }

    @Test("a link this app already owns needs no command at all")
    func alreadyLinked() {
        let inspector = staged(StubLinkInspector(links: ["/usr/local/bin/fermix": launcher]))

        #expect(planner(inspector).plan() == .linkedByThisApp(path: "/usr/local/bin/fermix"))
        #expect(planner(inspector).verify())
    }

    /// A cask install lets Homebrew own the one launcher link under its active
    /// prefix, so the hardcoded `/usr/local/bin` command must not run at all.
    @Test("a Homebrew-owned link means the command is skipped")
    func homebrewOwnsTheLink() {
        let inspector = staged(StubLinkInspector(links: ["/opt/homebrew/bin/fermix": launcher]))

        #expect(planner(inspector).plan() == .ownedByHomebrew(path: "/opt/homebrew/bin/fermix"))
    }

    /// Recommending `ln -sf` over someone else's file would delete it. The app
    /// names what it found and stops.
    @Test("a foreign file in the target path is reported, never replaced")
    func foreignFileIsRefused() {
        let inspector = staged(StubLinkInspector(files: ["/usr/local/bin/fermix"]))

        #expect(planner(inspector).plan() == .foreignFileInPlace(path: "/usr/local/bin/fermix"))
    }

    @Test("a symlink pointing somewhere else is foreign too")
    func foreignSymlinkIsRefused() {
        let inspector = staged(StubLinkInspector(links: ["/usr/local/bin/fermix": "/opt/other/bin/fermix"]))

        #expect(planner(inspector).plan() == .foreignFileInPlace(path: "/usr/local/bin/fermix"))
    }

    /// The post-verification is what turns "here is a command" into "it worked":
    /// the user runs it in Terminal and the app re-inspects.
    @Test("verification answers no until the link actually points at this app")
    func verificationIsRealInspection() {
        #expect(!planner(staged()).verify())
        #expect(!planner(staged(StubLinkInspector(files: ["/usr/local/bin/fermix"]))).verify())
        #expect(planner(staged(StubLinkInspector(links: ["/usr/local/bin/fermix": launcher]))).verify())
    }

    @Test("each plan carries the sentence Ready shows for it")
    func everyPlanHasCopy() {
        let plans: [CLILinkPlan] = [
            .available(command: "sudo ln -s a b", path: "b"),
            .linkedByThisApp(path: "b"),
            .ownedByHomebrew(path: "b"),
            .foreignFileInPlace(path: "b"),
            .launcherMissing(path: "b")
        ]

        for plan in plans {
            #expect(!plan.hint.isEmpty, "\(plan)")
            #expect(ProductCopyRules.violations(in: plan.hint).isEmpty, "\(plan): \(plan.hint)")
        }
    }

    // MARK: - The brand mark

    /// Ready's hero is the mascot, which is what redline §5.5 always asked for.
    /// The wordmark that stood in its place said `Fermix` directly above a line
    /// that already says `Fermix is live`, and the blooming rings stay gone:
    /// the success is carried by the pill's words.
    ///
    /// There is still exactly one mascot component, and it still lives with the
    /// Pet surface, because the Pet surface is where the mascot is content
    /// rather than an illustration.
    @Test("ready draws the mascot through the one component that owns it")
    func mascotIsReadysHero() throws {
        let ready = try SourceTree.swiftFiles(matching: "Onboarding/ReadySurface.swift")

        #expect(ready.count == 1)
        #expect(ready.first?.text.contains("MascotArtwork(") == true)
        #expect(ready.first?.text.contains("FermixWordmark(") == false)
        #expect(ready.first?.text.contains("BloomingMascot") == false)

        let mascotOwners = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("struct MascotArtwork") }

        #expect(mascotOwners.map(\.path).allSatisfy { $0.contains("/Pet/") }, "\(mascotOwners.map(\.path))")
        #expect(mascotOwners.count == 1)

        // Every still mascot in the product is that one component: Ready and
        // the Pet tab. A surface that hand-composed the layers again
        // is how the Pet tab ended up drawing a different frame from the app's
        // own icon, so the drawing is asserted to happen in exactly one file.
        let composers = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("layerAssetName(") }
            .map(\.path)

        #expect(composers.allSatisfy { $0.contains("/Pet/") }, "\(composers)")

        let users = try SourceTree
            .swiftFiles(under: "", excluding: false)
            .filter { $0.text.contains("MascotArtwork(") }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
            .sorted()

        #expect(users == ["PetSurfaceView.swift", "ReadySurface.swift"], "\(users)")
    }

    /// Ready asks the daemon whether the install is live.
    ///
    /// The screen's whole claim is the daemon's, and readiness used to arrive
    /// only from the activation that walked here. Every other way in — a route
    /// that resumes at Ready (§3.4), and every fixture launch of this surface —
    /// therefore drew the "not answering yet" block against a daemon that was
    /// up, which is why the redesigned screen could not be looked at at all.
    /// Connect your AI already reads readiness on appear for the same reason.
    @Test("ready reads readiness from the daemon when it appears")
    func readyRefreshesReadiness() throws {
        let ready = try #require(
            try SourceTree.swiftFiles(matching: "Onboarding/ReadySurface.swift").first?.text
        )

        #expect(ready.contains(".task { await model.refreshReadiness() }"))
    }

    /// The same block, reached the way a fixture and a resumed route reach it:
    /// the stage is applied with no activation behind it, so readiness has to
    /// come from the daemon rather than from the walk that never happened.
    @MainActor
    @Test("a resumed Ready is live once readiness is read")
    func resumedReadyGoesLive() async throws {
        let harness = try OnboardingHarness()
        // A configured install: no gating failure and nothing waiting on a
        // restart, which is the only state Ready renders on.
        harness.gateway.setupStateResult = try ManagementValueFixture.setupState(
            failures: false,
            restartRequired: false
        )

        harness.model.resume(at: .ready)
        #expect(
            harness.model.readiness.block == .daemonNotLive,
            "a resumed Ready starts on the notice that the daemon is not answering"
        )

        await harness.model.refreshReadiness()

        #expect(harness.model.readiness.block == nil, "the daemon reports a live install")
    }
}
