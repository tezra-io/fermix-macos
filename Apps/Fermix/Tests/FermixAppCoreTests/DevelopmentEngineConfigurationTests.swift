import Foundation
import Testing

@testable import FermixAppCore

/// The launch argument that selects the development configuration.
///
/// Parsing ships in every build; the configuration behind it does not. These
/// cases are about the argument alone, so they hold in a release build too.
@Suite("Development engine launch argument")
struct DevelopmentEngineLaunchRequestTests {
    @Test("a launch with no flag asks for nothing")
    func absentFlag() throws {
        #expect(try DevelopmentEngineLaunchRequest.parse(["/path/Fermix"]) == false)
        #expect(try DevelopmentEngineLaunchRequest.parse(["/path/Fermix", "--fixture"]) == false)
    }

    @Test("the flag asks for the development configuration")
    func flagPresent() throws {
        #expect(try DevelopmentEngineLaunchRequest.parse(["/path/Fermix", "--development-engine"]))
    }

    @Test("background startup requires one explicit development request", arguments: [
        ["Fermix", "--register-background-service"],
        ["Fermix", "--development-engine", "--register-background-service", "--register-background-service"]
    ])
    func invalidBackgroundRequest(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try DevelopmentEngineLaunchRequest.parse(arguments)
        }
    }

    /// A repeated flag is the one that reads as though the launch was composed
    /// twice, and a launch argument that is quietly dropped is what makes a
    /// wrong configuration look like the one that was asked for.
    @Test("a repeated flag is refused")
    func repeatedFlag() {
        #expect(throws: DevelopmentEngineLaunchRequest.Refusal.flagRepeated) {
            try DevelopmentEngineLaunchRequest.parse([
                "/path/Fermix", "--development-engine", "--development-engine"
            ])
        }
    }

    /// The release refusal has to say why, not just that. A developer handed
    /// "unrecognised argument" goes looking for a typo.
    @Test("every refusal carries a sentence that names what was inspected")
    func refusalsSpeak() {
        let refusals: [DevelopmentEngineLaunchRequest.Refusal] = [
            .flagRepeated, .notAvailableInThisBuild, .combinedWithFixture
        ]

        for refusal in refusals {
            #expect(!refusal.sentence.isEmpty)
        }
        #expect(DevelopmentEngineLaunchRequest.Refusal.notAvailableInThisBuild.sentence.contains("debug"))
        #expect(DevelopmentEngineLaunchRequest.Refusal.flagRepeated.sentence
            .hasPrefix(DevelopmentEngineLaunchRequest.flag))
        #expect(DevelopmentEngineLaunchRequest.Refusal.combinedWithFixture.sentence
            .contains(FixtureLaunchRequest.flag))
    }
}

/// Which steps an activation runs, and therefore which rows the ladder draws.
///
/// The plan is the one owner of that pairing: a ladder built from anything else
/// can show a row the transaction never takes, which is the defect the Starting
/// screen already shipped once.
@Suite("Activation plan")
struct ActivationPlanTests {
    @Test("the installed plan runs every step in M34 order")
    func installedStages() {
        #expect(ActivationPlan.installed.stages == [.registering, .starting, .answering, .reading])
        #expect(ActivationPlan.installed.registersLoginItems)
        #expect(ActivationPlan.installed.inspectsInstallation)
    }

    /// Development exercises the same background lifecycle on an isolated port;
    /// only the installed-copy preflights and GUI login default differ.
    @Test("the development plan registers the background service without inspecting installation")
    func developerRunStages() {
        #expect(ActivationPlan.developmentBackgroundService.stages == [.registering, .starting, .answering, .reading])
        #expect(ActivationPlan.developmentBackgroundService.registersLoginItems)
        #expect(!ActivationPlan.developmentBackgroundService.inspectsInstallation)
    }

    @Test("each plan indexes its own stages from zero")
    func rowIndexes() {
        #expect(ActivationPlan.installed.rowIndex(of: .registering) == 0)
        #expect(ActivationPlan.installed.rowIndex(of: .reading) == 3)
        #expect(ActivationPlan.developmentBackgroundService.rowIndex(of: .starting) == 1)
        #expect(ActivationPlan.developmentBackgroundService.rowIndex(of: .reading) == 3)
    }

    /// Both configurations draw the background registration they perform.
    @Test("the ladder draws exactly the rows the plan runs")
    func ladderRows() {
        let installed = ProgressLadderModel.starting(activeIndex: 0, includesRegistration: true)
        let developer = ProgressLadderModel.starting(
            activeIndex: 0, includesRegistration: ActivationPlan.developmentBackgroundService.registersLoginItems
        )

        #expect(installed.rows.map(\.id) == ["service", "daemon", "answering", "reading"])
        #expect(developer.rows.map(\.id) == ["service", "daemon", "answering", "reading"])
        #expect(developer.rows.first?.title == installed.rows.first?.title)
        #expect(developer.headline == installed.headline)
    }
}

/// Activation against the staged development background agent. Identity and
/// readiness checks remain the same as the installed app.
@Suite("Activation on a developer-run engine")
@MainActor
struct DeveloperRunActivationTests {
    private func harness(daemonRunning: Bool = true) throws -> ActivationHarness {
        try ActivationHarness(
            registered: false,
            daemonRunning: daemonRunning,
            plan: .developmentBackgroundService
        )
    }

    /// Every condition that refuses the shipped activation on the owner's Mac,
    /// all at once: the bundle runs from a build directory, a Homebrew launch
    /// agent is registered, and a second copy is installed.
    @Test("the three refusals that name an installed copy are not asked")
    func installationRefusalsAreNotAsked() async throws {
        let harness = try harness()
        harness.installation.canonical = false
        harness.installation.legacyUnit = .user
        harness.installation.copies = 2

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
    }

    @Test("only the development background service is registered")
    func nothingIsRegistered() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(harness.loginItems.registerCalls == [.agent])
    }

    @Test("the ladder includes background registration")
    func stagesAreReportedInOrder() async throws {
        let harness = try harness()
        let stages = StageRecorder()

        _ = await harness.coordinator.activate { stages.record($0) }

        #expect(stages.recorded == [.registering, .starting, .answering, .reading])
    }

    /// The daemon identity probe is the one preflight both plans run. A foreign
    /// daemon on the recorded home is a refusal no configuration overrides:
    /// activation would otherwise adopt a home the operator's real Fermix owns.
    @Test("a foreign daemon on the home is still a refusal")
    func foreignDaemonStillRefuses() async throws {
        let harness = try harness()
        harness.identities.answer = .foreign("homebrew")

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.foreignDaemonRunning))
    }

    @Test("a pre-management daemon on the home is still a refusal")
    func preManagementDaemonStillRefuses() async throws {
        let harness = try harness()
        harness.identities.answer = .preManagement

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.preManagementDaemonRunning))
    }

    /// Registration alone is not proof that the engine started.
    @Test("a socket that never appears still times out inside the budget")
    func socketWaitIsUnchanged() async throws {
        let harness = try harness(daemonRunning: false)

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.timedOut))
    }

    /// The record the loop's script wrote is the record activation confirms.
    /// Nothing here reads a shell value: `FERMIX_HOME` is forbidden in GUI code
    /// and this configuration does not reintroduce it.
    @Test("the recorded home is the home every probe is asked about")
    func recordedHomeIsUsed() async throws {
        let harness = try harness()
        let home = harness.root.appendingPathComponent("developer-home", isDirectory: true)
        _ = try harness.store.save(fermixHome: home)

        _ = await harness.coordinator.activate { _ in }

        #expect(harness.identities.probedHomes == [home.path])
        #expect(try harness.store.resolvedHome() == home)
    }
}

/// The structural gates the development configuration makes true.
@Suite("Development engine source gates")
struct DevelopmentEngineSourceGateTests {
    /// The configuration compiles into debug builds only, whole files at a
    /// time, exactly as the fixture configuration does. A type half inside the
    /// guard is how a release build acquires a seam nobody meant to ship.
    @Test("every development-engine source is wholly inside the debug guard")
    func sourcesAreGuarded() throws {
        let guarded = try Self.sources()
            // The parser compiles into every build: it is what a release build
            // refuses the flag with, so it is the one that must not be guarded.
            .filter { !$0.path.hasSuffix("App/DevelopmentEngineLaunchRequest.swift") }
        #expect(!guarded.isEmpty, "the development-engine sources have moved")

        for file in guarded {
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.first == "#if DEBUG", "\(file.path) does not open with the guard")
            #expect(lines.last == "#endif", "\(file.path) does not close with the guard")
            #expect(
                file.text.components(separatedBy: "#if DEBUG").count == 2,
                "\(file.path) carries a second guard"
            )
        }
    }

    /// The configuration is selected by a launch argument and never by an
    /// environment value. `FERMIX_HOME` in particular stays forbidden in GUI
    /// code: the bootstrap record is the one macOS source, and the dev loop's
    /// script writes it.
    @Test("no development-engine source reads the environment")
    func readsNoEnvironment() throws {
        let offenders = try Self.sources().filter {
            $0.text.contains("ProcessInfo") || $0.text.contains("getenv")
                || $0.text.contains("environment[") || $0.text.contains("FERMIX_HOME")
        }

        #expect(offenders.isEmpty, "environment read in: \(offenders.map(\.path))")
    }

    private static func sources() throws -> [SourceTree.File] {
        let sources = try SourceTree.swiftFiles(under: "", excluding: false)
            .filter { $0.path.contains("DevelopmentEngine") }
        #expect(!sources.isEmpty, "no development-engine source is in the tree")

        return sources
    }
}
