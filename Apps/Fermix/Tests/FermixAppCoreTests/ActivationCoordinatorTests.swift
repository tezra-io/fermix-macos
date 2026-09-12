import Foundation
import Testing

@testable import FermixAppCore

/// Activation: adopt the migration handoff, refuse on every condition that
/// would make the mutation wrong, register both principals independently, wait
/// for the daemon, negotiate, prove the local web surface answers, and read what
/// is already set up — inside one 90-second budget, with every failure it can
/// end in named separately.
@Suite("Activation coordinator")
@MainActor
struct ActivationCoordinatorTests {
    private func harness(
        registered: Bool = false,
        daemonRunning: Bool = true
    ) throws -> ActivationHarness {
        try ActivationHarness(registered: registered, daemonRunning: daemonRunning)
    }

    @Test("a clean activation registers, negotiates, proves the web surface, and reads the home")
    func cleanActivation() async throws {
        let harness = try harness()

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated(let hello, let prepared) = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
        #expect(hello.engine.pid == "4242")
        #expect(harness.loginItems.registerCalls.contains(.agent))
        #expect(harness.gateway.calls.contains(.negotiate))
        #expect(harness.web.probedOrigins == ["http://127.0.0.1:4030"])
        // Row four: what this home already has, read once and handed on.
        #expect(prepared.state != nil)
        #expect(prepared.detections != nil)
        #expect(!prepared.requiresNewerEngine)
        #expect(prepared.refusal == nil)
    }

    /// Row four is protocol v2, so a daemon one release behind refuses it. That
    /// is a named state carried on the outcome, never a boot failure (M34 §7.1).
    @Test("a daemon one release behind still activates and reports the newer-engine state")
    func n1DaemonStillActivates() async throws {
        let harness = try harness()
        harness.gateway.hello = try ManagementValueFixture.hello(maximum: 1)

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated(_, let prepared) = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
        #expect(prepared.requiresNewerEngine)
        #expect(prepared.state == nil)
    }

    /// Any other refusal of row four is returned rather than swallowed: the
    /// daemon is up, and the assistant states what it said.
    @Test("another refusal of the fourth row is carried on the outcome")
    func rowFourRefusalIsCarried() async throws {
        let harness = try harness()
        harness.gateway.v2Failure = ManagementRefusal.daemon(.internalError, "The daemon refused.")

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated(_, let prepared) = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
        #expect(prepared.refusal == "The daemon refused.")
        #expect(!prepared.requiresNewerEngine)
    }

    /// Both login registrations default on and are registered independently.
    @Test("activation registers the daemon and the GUI as two separate items")
    func bothPrincipalsAreRegistered() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(Set(harness.loginItems.registerCalls) == Set(LoginItemPrincipal.allCases))
    }

    @Test("the ladder is reported in order, once per stage")
    func stagesAreReportedInOrder() async throws {
        let harness = try harness()
        let stages = StageRecorder()

        _ = await harness.coordinator.activate { stages.record($0) }

        #expect(stages.recorded == [.registering, .starting, .answering, .reading])
    }

    /// Cancelling the task an activation runs in has to end its bounded waits
    /// rather than let them spin to the 90-second budget: the ladder's Cancel
    /// control is that cancellation, and a wait that ignored it would keep the
    /// socket poll running after the person left the screen.
    @Test("a cancelled wait ends activation rather than spinning to the budget")
    func cancellationEndsTheSocketWait() async throws {
        let harness = try harness(daemonRunning: false)
        harness.sleeper.cancelled = true

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.timedOut))
        #expect(harness.clock.now == harness.start, "the wait ended on the cancellation, not on the budget")
    }

    // MARK: - The migration handoff

    /// The journal wins over `launcher.json` and is consumed once (M34 §15.2).
    @Test("a handoff journal's home is adopted and cleared after the daemon answers")
    func journalHomeWins() async throws {
        let harness = try harness()
        let journalHome = harness.root.appendingPathComponent("journal-home", isDirectory: true)
        try harness.writeHandoff(home: journalHome)

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
        #expect(try harness.store.load().fermixHome.path == journalHome.path)
        #expect(!harness.handoff.exists(), "the journal is consumed once")
    }

    /// The foreign-daemon probe has to ask about the home the journal named:
    /// probing the account default would clear a daemon sitting on the operator's
    /// real home.
    @Test("the foreign-daemon probe asks about the journal's home, not the default")
    func foreignProbeUsesTheJournalHome() async throws {
        let harness = try harness()
        let journalHome = harness.root.appendingPathComponent("journal-home", isDirectory: true)
        try harness.writeHandoff(home: journalHome)

        _ = await harness.coordinator.activate { _ in }

        #expect(harness.identities.probedHomes == [journalHome.path])
        #expect(harness.identities.probedHomes != [harness.location.defaultFermixHome.path])
    }

    /// A journal naming a home this app cannot adopt refuses and stays: clearing
    /// it would delete the only record of the home the operator was using.
    @Test("an invalid journal refuses and stays")
    func invalidJournalRefusesAndStays() async throws {
        let harness = try harness()
        try harness.writeHandoff(raw: "{\"schema_version\": 1, \"fermix_home\": \"/\"}")

        let outcome = await harness.coordinator.activate { _ in }

        guard case .failed(let cause, let evidence) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(cause == .migrationHandoffInvalid)
        // The journal's own path and the validator's reason reach the card: a
        // sentence naming a condition and no file is not diagnosable, and the
        // remedy it used to name was a verb the migration had already removed.
        #expect(evidence.contains(harness.handoff.journalURL.path))
        #expect(evidence.count == 2)
        // The reason is the catalogue sentence for the validator failure, not a
        // description of the Swift value: `forbiddenLocation(path: "/", reason:
        // ...)` is a diagnosis nobody outside this repository can read.
        #expect(evidence.contains(ProductStrings[.handoffHomeFilesystemRoot]))
        #expect(harness.handoff.exists(), "the journal is kept so the verb can be re-run")
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// Every way a journal can be refused renders a sentence. The gate is over
    /// the whole defect vocabulary rather than over the one case the fixture
    /// above produces, so a defect added to any of the three enums fails here
    /// unless it is given copy (M34 §15.2).
    @Test("every handoff defect renders a sentence and never a Swift value")
    func everyHandoffDefectHasASentence() {
        let homes: [BootstrapHomeDefect] = [
            .empty,
            .notAbsolute(path: "relative/home"),
            .relativeTraversal(path: "/tmp/../home"),
            .notADirectory(path: "/tmp/home"),
            .notOwnedByCurrentUser(path: "/tmp/home", owner: 0),
            .notWritable(path: "/tmp/home")
        ]
        let forbidden = ForbiddenHomeReason.allCases.map {
            BootstrapHomeDefect.forbiddenLocation(path: "/", reason: $0)
        }
        let defects: [MigrationHandoffDefect] = [
            .unreadable(path: "/tmp/journal.json"),
            .malformed(path: "/tmp/journal.json"),
            .unsupportedSchemaVersion(2)
        ] + (homes + forbidden).map { MigrationHandoffDefect.invalidHome($0) }

        for defect in defects {
            let sentence = ProductStrings.handoffDefect(defect)

            #expect(sentence.hasSuffix("."), "\(defect) has no sentence")
            #expect(!sentence.contains("("), "\(defect) renders a Swift value")
            #expect(ProductCopyRules.violations(in: sentence).isEmpty, "\(defect)")
        }
        #expect(defects.count == 16)
    }

    // MARK: - The named failures

    /// macOS reports one status for "waiting for your approval" and "you turned
    /// it off", so the second signal is whether this activation is the one that
    /// registered: a fresh registration awaiting consent is approval pending.
    @Test("a fresh registration awaiting consent is approval pending")
    func approvalPending() async throws {
        let harness = try harness()
        harness.loginItems.nextStatus[.agent] = .requiresApproval

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.approvalPending))
    }

    /// The same status on an item that was already registered before this run
    /// means the user turned the background item off.
    @Test("an already-registered item still awaiting approval is a disabled background item")
    func backgroundItemDisabled() async throws {
        let harness = try harness()
        harness.loginItems.preregisterApprovalPending(.agent)
        harness.loginItems.nextStatus[.agent] = .requiresApproval

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.backgroundItemDisabled))
    }

    /// An item macOS cannot find is a registration this Mac refused, not a bad
    /// bundle: sending the operator to reinstall an app that is fine is the
    /// wrong remedy (M34 §15.2).
    @Test("an item macOS cannot find is a registration failure, not a bad package")
    func registrationFailure() async throws {
        let harness = try harness()
        harness.loginItems.nextStatus[.agent] = .notFound

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.registrationFailed))
    }

    @Test("a daemon sharing no protocol version with this app is an incompatible version")
    func incompatibleVersion() async throws {
        let harness = try harness()
        harness.gateway.negotiateFailure = ManagementError.incompatibleProtocol(
            app: [1, 2],
            daemon: try ManagementValueFixture.protocolRange(minimum: 3, maximum: 4)
        )

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.incompatibleVersion))
    }

    @Test("a daemon-too-old refusal is also an incompatible version")
    func daemonTooOld() async throws {
        let harness = try harness()
        harness.gateway.negotiateFailure = ManagementError.daemon(
            ManagementFailure(
                code: .daemonTooOld,
                message: "daemon speaks v0 only",
                details: ManagementScalarMap(values: [:])
            )
        )

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.incompatibleVersion))
    }

    /// A socket that appears and vanishes three times is launchd restarting a
    /// daemon that keeps dying, which is a different failure from a slow start.
    @Test("three socket disappearances are a crash loop")
    func crashLoop() async throws {
        let harness = try harness(daemonRunning: true)
        harness.socket.flapCount = ActivationPolicy.crashLoopThreshold

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.crashLoop))
        #expect(harness.gateway.calls.isEmpty, "a crash loop never reaches negotiation")
    }

    /// The daemon answered, so the engine is alive; something else is holding
    /// the port it needs.
    @Test("a live daemon whose origin is held by another program is a bind failure")
    func bindFailure() async throws {
        let harness = try harness()
        harness.web.isLive = false
        harness.ports.accepting = true

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.bindFailure))
        #expect(harness.ports.probedOrigins == ["http://127.0.0.1:4030"])
    }

    @Test("a live daemon with nothing listening at its origin is a web-unavailable failure")
    func webUnavailable() async throws {
        let harness = try harness()
        harness.web.isLive = false
        harness.ports.accepting = false

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.webUnavailable))
    }

    @Test("a socket that never appears inside the budget times out")
    func timesOut() async throws {
        let harness = try harness(daemonRunning: false)
        harness.socket.neverAppears = true

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.timedOut))
    }

    /// The whole run is bounded at 90 seconds, and the bound is what turns a
    /// stalled start into a surface the user can act on.
    @Test("activation spends no more than its 90-second budget")
    func budgetIsNinetySeconds() async throws {
        let harness = try harness(daemonRunning: false)
        harness.socket.neverAppears = true

        _ = await harness.coordinator.activate { _ in }

        let elapsed = harness.clock.now.timeIntervalSince(harness.start)
        #expect(ActivationPolicy.budget == 90)
        #expect(elapsed <= ActivationPolicy.budget + ActivationPolicy.pollInterval)
    }

    /// Onboarding asks for no microphone and no computer-use permission. The
    /// whole consent surface of activation is the two login registrations, and
    /// no cause it can end in names a permission it would have had to prompt for.
    @Test("the only consent activation touches is the two login registrations")
    func consentSurfaceIsOnlyLoginItems() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(Set(harness.loginItems.registerCalls) == Set(LoginItemPrincipal.allCases))
        #expect(!BootFailureCause.allCases.contains { $0.rawValue.lowercased().contains("microphone") })
        #expect(!BootFailureCause.allCases.contains { $0.rawValue.lowercased().contains("permission") })
    }

    /// The liveness gate is `/health/live`. `/health/ready` reports whether the
    /// daemon has finished warming, which is a different question and would keep
    /// Setup hidden long after it works.
    @Test("the liveness gate is health/live and never health/ready")
    func gatesOnHealthLive() {
        #expect(HTTPWebLiveness.path == "/health/live")
    }

    /// The live incident this guards: a dist-staged bundle activated by the
    /// masked window's default button wrote the record and registered login
    /// items. A refusal must precede every mutation.
    @Test("a bundle outside Applications is refused before anything is written or registered")
    func refusesOutsideApplications() async throws {
        let harness = try ActivationHarness(registered: false, daemonRunning: true)
        harness.installation.canonical = false

        let outcome = await harness.coordinator.activate { _ in }

        guard case .failed(let cause, _) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(cause == .notInApplications)
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
        #expect(harness.loginItems.status(.agent) != .enabled)
        #expect(harness.loginItems.status(.mainApp) != .enabled)
    }

    /// Scope-complete over both launchd paths, and the two scopes keep their own
    /// sentences because removing a system unit needs administrator rights the
    /// app does not take (M34 §15.2).
    @Test("each legacy service scope is refused as its own cause, mutating nothing")
    func refusesBesideLegacyInstall() async throws {
        for (scope, expected) in [
            (LegacyServiceScope.user, BootFailureCause.legacyInstallPresent),
            (.system, .legacySystemInstallPresent)
        ] {
            let harness = try ActivationHarness(registered: false, daemonRunning: true)
            harness.installation.legacyUnit = scope

            let outcome = await harness.coordinator.activate { _ in }

            #expect(outcome == .failed(expected), "\(scope.rawValue)")
            #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
            #expect(harness.loginItems.status(.agent) != .enabled)
        }
    }

    /// A management daemon from another distribution owns this home, so nothing
    /// is changed and the sentence does not name a command that depends on how
    /// that daemon was started.
    @Test("a daemon from another distribution is refused before any mutation")
    func refusesBesideAForeignDaemon() async throws {
        let harness = try harness()
        harness.identities.answer = .foreign("homebrew")

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.foreignDaemonRunning))
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// A connect that succeeds and an answer that does not decode as management
    /// is the pre-management (0.9.x) daemon.
    @Test("a pre-management daemon is refused with its own cause")
    func refusesBesideAPreManagementDaemon() async throws {
        let harness = try harness()
        harness.identities.answer = .preManagement

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.preManagementDaemonRunning))
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// M34 §15.2: a successful connect plus any non-management answer is the
    /// whole probe. So every failure after the connect refuses, and only the
    /// ones that reached no peer at all read as a free home. A `default` here
    /// would let a new transport kind fall open into "nothing is listening" and
    /// activate onto another daemon's home.
    @Test("every management failure is classified, and only a no-peer one reads as free")
    func identityProbeClassifiesEveryFailure() {
        let noPeer: [ManagementTransportFailure] = [
            .socketMissing(path: "/tmp/daemon.sock"),
            .daemonNotListening(path: "/tmp/daemon.sock"),
            .connectFailed(errno: 61),
            .socketPathTooLong(path: "/tmp/daemon.sock"),
            .invalidTimeout(.seconds(0))
        ]
        for failure in noPeer {
            #expect(
                ManagementDaemonIdentityProbe.classify(.transport(failure)) == .none,
                "\(failure)"
            )
        }

        // The pre-management daemon is the one that **answered**, so only a
        // decode-class failure earns it: a frame that is not a frame (M34
        // §15.2). Anything that reached a peer which then said nothing is a
        // daemon that did not answer, and telling its owner to run the upgrade
        // commands is a wrong diagnosis and, on a DMG install, a dead end.
        let didNotDecode: [ManagementTransportFailure] = [
            .shortFrame(expected: 64, received: 8),
            .frameTooLarge(byteCount: 1 << 20, limit: 1 << 16),
            .emptyFrame
        ]
        for failure in didNotDecode {
            #expect(
                ManagementDaemonIdentityProbe.classify(.transport(failure)) == .preManagement,
                "\(failure)"
            )
        }

        let neverAnswered: [ManagementTransportFailure] = [
            .writeFailed(errno: 32),
            .readFailed(errno: 5),
            .pollFailed(errno: 4),
            .peerClosedBeforeResponse,
            .timedOut(after: .seconds(2))
        ]
        for failure in neverAnswered {
            #expect(
                ManagementDaemonIdentityProbe.classify(.transport(failure)) == .unresponsive,
                "\(failure)"
            )
        }

        // The two decode-class failures: an answer arrived on the socket and
        // this app could not read it as management v1, which is what the
        // pre-management daemon looks like from here.
        #expect(
            ManagementDaemonIdentityProbe.classify(.malformedEnvelope(.undecodableJSON)) == .preManagement
        )
        #expect(
            ManagementDaemonIdentityProbe.classify(
                .correlationMismatch(expected: "req-1", received: "req-2")
            ) == .preManagement
        )
    }

    /// A daemon that answers in management's own vocabulary is a management
    /// daemon. Folding those onto `preManagement` told the operator to run
    /// `brew upgrade fermix`, `fermix restart` and `fermix migrate-to-app`
    /// against a daemon already past all three, and on a DMG install with no
    /// Homebrew that is a dead end (M34 §15.2).
    @Test("a daemon that answers in management's vocabulary is not the older daemon")
    func structuredRefusalsAreTheirOwnAnswer() {
        let spoken: [ManagementError] = [
            .daemon(
                ManagementFailure(
                    code: .internalError,
                    message: "the daemon could not answer",
                    details: ManagementScalarMap(values: [:])
                )
            ),
            .incompatibleProtocol(
                app: [1, 2],
                daemon: ManagementProtocolRange(currentVersion: 9, minimum: 7, maximum: 9)
            ),
            .requestTooLarge(byteCount: 1 << 20, limit: 1 << 16),
            .invalidParameter(.empty(field: "home")),
            .invalidRequestIdentifier("req"),
            .notNegotiated(method: .hello),
            .methodRequiresNewerEngine(method: .settingsGet, required: 2, negotiated: 1)
        ]

        for failure in spoken {
            guard case .refusedIdentity(let sentence) = ManagementDaemonIdentityProbe.classify(failure) else {
                Issue.record("\(failure) was not classified as a refusal")
                continue
            }

            #expect(!sentence.isEmpty, "\(failure) carries no sentence")
        }
    }

    /// The bytes a released 0.9.x daemon writes when it is asked a method it
    /// does not know (`Fermix.CLI.Daemon`, `%{status: "error", reason: "unknown
    /// method", method: method}`), replayed through the envelope decoder into
    /// the classifier. It carries neither `result` nor `error`, so it is a
    /// malformed management envelope, which is exactly the pre-management
    /// answer: the state that names the upgrade commands.
    @Test("the released pre-management reply classifies as the older daemon")
    func preManagementReplyBytesClassify() throws {
        let bytes = Data(#"{"status":"error","reason":"unknown method","method":"hello"}"#.utf8)

        do {
            _ = try ManagementResponse.decode(
                bytes,
                expecting: "req-hello-1",
                method: .hello,
                as: ManagementHello.self
            )
            Issue.record("a v0 reply decoded as a management response")
        } catch let failure as ManagementError {
            #expect(ManagementDaemonIdentityProbe.classify(failure) == .preManagement)
        }
    }

    /// A probe that could not be made at all is this bundle's own contract
    /// failing to load. It is not a report that the home is free, so activation
    /// refuses rather than registering over another daemon's home.
    @Test("a probe that cannot run refuses activation instead of clearing the home")
    func probeFailureRefusesActivation() async throws {
        let harness = try harness()
        harness.identities.failure = ManagementContractDefect.documentIsNotAnObject

        let outcome = await harness.coordinator.activate { _ in }

        #expect(outcome == .failed(.invalidPackage))
        #expect(harness.loginItems.registerCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.location.recordURL.path))
    }

    /// A record that exists and cannot be read is neither a fresh account nor a
    /// clear home: answering "no foreign daemon" from a read failure would skip
    /// all three coexistence probes and mutate anyway.
    @Test("an unreadable bootstrap record refuses before any probe or mutation")
    func unreadableRecordRefusesBeforeTheProbes() async throws {
        let harness = try harness()
        try FileManager.default.createDirectory(
            at: harness.location.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: harness.location.recordURL)

        let outcome = await harness.coordinator.activate { _ in }

        // The file under Application Support is broken, not the bundle.
        #expect(outcome == .failed(.bootstrapRecordUnusable))
        #expect(harness.identities.probedHomes.isEmpty)
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// The app-managed daemon on this home is this app's own, so it is not a
    /// coexistence problem and activation proceeds.
    @Test("an app-managed daemon on this home is not a refusal")
    func appDaemonIsNotForeign() async throws {
        let harness = try harness()
        harness.identities.answer = .app

        let outcome = await harness.coordinator.activate { _ in }

        guard case .activated = outcome else {
            Issue.record("expected an activated outcome, got \(outcome)")
            return
        }
    }

    /// More than one copy means the registration would pin whichever copy macOS
    /// happened to resolve.
    @Test("a second installed copy is refused before any mutation")
    func refusesBesideADuplicateCopy() async throws {
        let harness = try harness()
        harness.installation.copies = 2

        let outcome = await harness.coordinator.activate { _ in }

        guard case .failed(let cause, let evidence) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(cause == .duplicateCopyPresent)
        // The paths reach the card. `Keep the copy in the Applications folder,
        // remove the others` names no path at all, and with the unified app
        // sharing the pet's bundle id the sentence often fits neither copy.
        #expect(evidence.count == 2)
        #expect(harness.loginItems.registerCalls.isEmpty)
    }

    /// LaunchServices remembers every url it has ever registered, including a
    /// deleted bundle and one in the Trash. Neither is a copy anybody can
    /// launch, and counting them refused an ordinary install (M34 §15.6).
    @Test("a trashed or deleted copy is not an installed one")
    func rememberedCopiesAreNotInstalled() throws {
        let trashed = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash/Fermix.app", isDirectory: true)

        #expect(!BundleInstallationProbe.isInstalled(trashed))
        #expect(!BundleInstallationProbe.isInstalled(URL(fileURLWithPath: "/Applications/NoSuchFermix.app")))
        #expect(BundleInstallationProbe.isInstalled(URL(fileURLWithPath: "/Applications")))
    }

    /// The GUI login item is a consent, asked for once. Every later activation —
    /// and `fermix setup` on a configured home is one — leaves it exactly as the
    /// operator left it in Home, because switching it back on without asking is
    /// a consent taken rather than given (M34 §7.2).
    @Test("a re-run activation does not re-enable a GUI login item the user disabled")
    func reRunLeavesTheGUILoginItemAlone() async throws {
        let harness = try harness()

        let first = await harness.coordinator.activate { _ in }
        guard case .activated = first else {
            Issue.record("expected the first activation to succeed, got \(first)")
            return
        }
        #expect(harness.loginItems.status(.mainApp) == .enabled)

        // The operator turns it off in Home, then a url re-runs activation.
        try harness.loginItems.unregister(.mainApp)
        harness.loginItems.forgetRegisterCalls()

        let second = await harness.coordinator.activate { _ in }
        guard case .activated = second else {
            Issue.record("expected the re-run to succeed, got \(second)")
            return
        }

        #expect(harness.loginItems.status(.mainApp) != .enabled)
        #expect(!harness.loginItems.registerCalls.contains(.mainApp))
        #expect(harness.loginItems.status(.agent) == .enabled, "the background service is not a preference")
    }

    /// `SMAppService` publishes a status and never the plist it registered, so
    /// the registration writes a receipt the next launch can compare against
    /// (M34 §7.2 step 5).
    @Test("a successful registration records the bundled plist digest")
    func registrationWritesItsReceipt() async throws {
        let harness = try harness()

        _ = await harness.coordinator.activate { _ in }

        #expect(try harness.store.load().registeredAgentPlistSHA256 == ActivationHarness.plistDigest)
    }
}

/// The activation coordinator with every seam replaced, wired to a throwaway
/// directory so no real account is touched.
@MainActor
final class ActivationHarness {
    let root: URL
    let location: BootstrapLocation
    let store: BootstrapStore
    let loginItems: ApprovalAwareLoginItemService
    let gateway = FakeDaemonGateway()
    let socket = FlappingPathPresence()
    let installation = FakeInstallationProbe()
    let identities = FakeDaemonIdentityProbe()
    let handoff: MigrationHandoffReader
    let web = FakeWebLiveness()
    let ports = FakePortProbe()
    let clock = ManualClock()
    let sleeper: ClockAdvancingSleeper
    let start: Date
    let coordinator: ActivationCoordinator

    init(registered: Bool, daemonRunning: Bool, plan: ActivationPlan = .installed) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-activation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)
        try FileManager.default.createDirectory(
            at: location.defaultFermixHome,
            withIntermediateDirectories: true
        )

        store = BootstrapStore(location: location)
        handoff = MigrationHandoffReader(location: location)
        loginItems = ApprovalAwareLoginItemService()
        if registered {
            loginItems.preregister(.agent)
        }
        socket.present = daemonRunning
        sleeper = ClockAdvancingSleeper(clock: clock)
        start = clock.now

        gateway.hello = try ManagementValueFixture.hello()
        gateway.overviewResult = try ManagementValueFixture.overview()

        coordinator = ActivationCoordinator(
            store: store,
            handoff: handoff,
            services: ServiceController(
                loginItems: loginItems,
                plists: StubAgentPlistDigest(digest: ActivationHarness.plistDigest)
            ),
            gateway: gateway,
            paths: socket,
            installation: installation,
            identities: identities,
            web: web,
            ports: ports,
            sleeper: sleeper,
            plan: plan,
            now: clock.reader
        )
    }

    /// The digest the fake bundle reports for its agent plist.
    static let plistDigest = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

    /// Writes a handoff journal the way `fermix migrate-to-app` would.
    func writeHandoff(home: URL) throws {
        try writeHandoff(raw: "{\"schema_version\": 1, \"fermix_home\": \"\(home.path)\"}")
    }

    func writeHandoff(raw json: String) throws {
        try FileManager.default.createDirectory(at: location.directoryURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: handoff.journalURL)
    }

    deinit {
        let path = root.path
        guard path.contains("fermix-activation-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The installation facts activation preflights on: canonical by default so
/// the existing scenarios run unrefused; each refusal test flips one fact.
final class FakeInstallationProbe: InstallationProbing, @unchecked Sendable {
    var canonical = true
    var legacyUnit: LegacyServiceScope?
    var copies = 1

    func isCanonicallyInstalled() -> Bool { canonical }
    func legacyServiceUnitScope() -> LegacyServiceScope? { legacyUnit }
    func installedCopies() -> [String] {
        (0..<copies).map { "/Applications/Fermix\($0).app" }
    }
}

/// Who already answers on a home's management socket, scripted, and which homes
/// were asked about. Nothing here opens a socket.
final class FakeDaemonIdentityProbe: DaemonIdentityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var homes: [String] = []

    var answer: DaemonIdentityAnswer = .none
    /// A probe that could not be made at all, which is a broken bundle rather
    /// than an answer about the home.
    var failure: (any Error)?

    var probedHomes: [String] { lock.withLock { homes } }

    func identify(home: URL) async throws -> DaemonIdentityAnswer {
        lock.withLock { homes.append(home.path) }
        if let failure { throw failure }

        return answer
    }
}

/// The shipped installation probe's own answers, over a temporary account home
/// and an injected system-unit path: nothing here reads or writes the real
/// `/Library` or the operator's own home.
@Suite("Legacy service unit scope")
struct LegacyServiceScopeTests {
    /// With both units present the system scope wins.
    ///
    /// `fermix migrate-to-app` refuses while a system-scope unit exists, so
    /// answering `user` sent the operator to the verb that then refused, and
    /// bounced them between two refusals (M34 §15.0 retires the system-scope
    /// install first).
    @Test("the system scope is reported first when both units exist")
    func systemWinsOverUser() throws {
        let root = try Self.temporaryRoot()
        defer { Self.remove(root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let systemUnit = root.appendingPathComponent("io.tezra.fermix.plist")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            withIntermediateDirectories: true
        )

        func probe() -> BundleInstallationProbe {
            BundleInstallationProbe(home: home.path, systemUnitPath: systemUnit.path)
        }

        #expect(probe().legacyServiceUnitScope() == nil)

        let userUnit = home.appendingPathComponent(BundleInstallationProbe.legacyUserUnitPath)
        try Data("{}".utf8).write(to: userUnit)
        #expect(probe().legacyServiceUnitScope() == .user)

        try Data("{}".utf8).write(to: systemUnit)
        #expect(probe().legacyServiceUnitScope() == .system, "the system unit is the one to remove first")

        try FileManager.default.removeItem(at: userUnit)
        #expect(probe().legacyServiceUnitScope() == .system)
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-scope-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        return root
    }

    /// Removed only when the path is the one this suite made.
    private static func remove(_ root: URL) {
        let path = root.path
        guard path.contains("fermix-scope-tests"), path.split(separator: "/").count >= 4 else { return }

        try? FileManager.default.removeItem(at: root)
    }
}

/// The bundled agent plist's digest, scripted, so no test reads a real bundle.
struct StubAgentPlistDigest: AgentPlistDigesting {
    var digest: String?

    func bundledAgentPlistDigest() -> String? { digest }
}

/// Records the ladder stages activation reported, in order.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ActivationStage] = []

    var recorded: [ActivationStage] { lock.withLock { stages } }

    func record(_ stage: ActivationStage) {
        lock.withLock { stages.append(stage) }
    }
}

/// A login-item double that can start in the approval-pending state, which is
/// what separates "waiting for consent" from "the user turned it off".
final class ApprovalAwareLoginItemService: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]

    var nextStatus: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]
    var registerError: (any Error)?

    private(set) var registerCalls: [LoginItemPrincipal] = []

    /// Forgets what was registered while keeping what is registered, so a case
    /// can assert what a *second* activation asked for.
    func forgetRegisterCalls() {
        lock.withLock { registerCalls.removeAll() }
    }

    func preregister(_ principal: LoginItemPrincipal) {
        lock.withLock { statuses[principal] = .enabled }
    }

    func preregisterApprovalPending(_ principal: LoginItemPrincipal) {
        lock.withLock { statuses[principal] = .requiresApproval }
    }

    func register(_ principal: LoginItemPrincipal) throws {
        try lock.withLock {
            registerCalls.append(principal)
            if let registerError { throw registerError }
            statuses[principal] = nextStatus[principal] ?? .enabled
        }
    }

    func unregister(_ principal: LoginItemPrincipal) throws {
        lock.withLock { statuses[principal] = .notRegistered }
    }

    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        lock.withLock { statuses[principal] ?? .notRegistered }
    }
}

/// A socket path that can be absent forever, present immediately, or flap a
/// chosen number of times before settling.
final class FlappingPathPresence: PathPresence, @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0

    var present = true
    var neverAppears = false
    /// How many present-then-absent transitions to produce before settling.
    var flapCount = 0

    func exists(atPath path: String) -> Bool {
        lock.withLock {
            guard !neverAppears else { return false }
            polls += 1
            guard flapCount > 0 else { return present }

            // Alternate present/absent for twice the flap count, then settle.
            let flapping = polls <= flapCount * 2
            return flapping ? polls.isMultiple(of: 2) == false : true
        }
    }
}

/// Counts microphone permission requests so a surface that asks for one can be
/// caught. Nothing else on the engine is exercised here.
final class PermissionCountingAudioEngine: VoiceAudioEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var isPlayingBack = false

    var permissionRequests: Int { lock.withLock { requests } }

    /// The failure `requestCapturePermission` reports, if there is one. Nil by
    /// default, so a case that only counts requests is unaffected.
    var permissionError: (any Error)?

    func requestCapturePermission() async throws {
        lock.withLock { requests += 1 }
        if let permissionError { throw permissionError }
    }

    func prepareCapture() throws {}
    func beginStreaming(onChunk: @escaping @Sendable (Data) -> Void) throws {}
    func setCaptureMuted(_ muted: Bool) {}
    func play(base64PCM16 encoded: String) {}
    func stopPlayback() {}
    func resetUtteranceAnchor() {}
    func currentUtterancePlayedMs() -> Int? { nil }
    func shutdown() {}
    func diagnostics() -> String { "stub" }
}
