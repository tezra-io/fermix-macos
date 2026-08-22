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

    // MARK: - Telegram pairing

    /// M34 §7 and planned deviation 5: never a mock QR. A code is rendered only
    /// from a real daemon-supplied payload; without one the user is routed to
    /// the truthful Setup instructions.
    @Test("with no pairing payload the tile routes to Setup instead of drawing a code")
    func pairingWithoutAPayload() {
        let tile = ChannelPairingTile(payload: nil)

        #expect(tile.rendersCode == false)
        #expect(tile.title == ProductStrings[.connectChannelPairing])
        #expect(tile.instruction == ProductStrings[.connectChannelPairingHint])
    }

    @Test("a real daemon payload is what makes a code render")
    func pairingWithAPayload() {
        let tile = ChannelPairingTile(payload: "https://t.me/fermixbot?start=abc123")

        #expect(tile.rendersCode)
        #expect(tile.payload == "https://t.me/fermixbot?start=abc123")
    }

    /// The tile keeps its 92-point geometry for the real code, which is what the
    /// redline asked for when it said to remove the mock and keep the frame.
    @Test("the tile keeps the redline geometry for the real code")
    func pairingTileGeometry() {
        #expect(ChannelPairingTile.size == 92)
    }
}
