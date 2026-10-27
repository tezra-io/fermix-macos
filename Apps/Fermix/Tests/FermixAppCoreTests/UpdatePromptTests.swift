import Foundation
import Testing
@testable import FermixAppCore

/// The update window's words and buttons, read from each phase.
@Suite("Update window content")
struct UpdateWindowContentTests {
    private static let installed = "0.6.0"

    private func content(_ phase: UpdatePromptPhase) -> UpdateWindowContent {
        UpdateWindowContent(phase: phase, installedVersion: Self.installed)
    }

    private func offer(
        isCritical: Bool = false,
        isInformationOnly: Bool = false,
        stage: UpdateUserStage = .notDownloaded
    ) -> UpdatePromptPhase {
        .offered(UpdatePromptOffer(
            version: "0.7.0",
            isCritical: isCritical,
            isInformationOnly: isInformationOnly,
            infoURL: isInformationOnly ? URL(string: "https://fermix.ai") : nil,
            stage: stage
        ))
    }

    private func layout(_ content: UpdateWindowContent) -> [UpdatePromptAction] {
        content.buttons.map(\.action)
    }

    @Test("an update names both versions and offers skip, later and install")
    func offeredUpdate() {
        let offered = content(offer())

        #expect(offered.title == "Fermix 0.7.0 is available")
        #expect(offered.body == "You have 0.6.0. Fermix restarts to finish installing it.")
        #expect(layout(offered) == [.skip, .later, .install])
        #expect(offered.buttons.map(\.role) == [.alternative, .cancel, .primary])
    }

    /// M34 §6: a critical update can wait and never installs by itself, but it
    /// cannot be skipped for good.
    @Test("a critical update has no skip")
    func criticalUpdate() {
        let critical = content(offer(isCritical: true))

        #expect(critical.title == "Fermix 0.7.0 is an important update")
        #expect(layout(critical) == [.later, .install])
    }

    @Test("an information-only release opens its page rather than installing")
    func informationOnlyRelease() {
        let information = content(offer(isInformationOnly: true))

        #expect(layout(information) == [.later, .learnMore])
        #expect(!information.offers(.install))
    }

    /// Only an installing update is armed to replace the app on quit, so only
    /// that one says it will and relaunches from the offer. A downloaded one
    /// still has to be made ready, so it is offered as any other is.
    @Test("an armed update relaunches and says it installs on quit; a downloaded one is an ordinary offer")
    func stagedUpdate() {
        let installing = content(offer(stage: .installing))

        #expect(installing.title == "Fermix 0.7.0 is ready to install")
        #expect(layout(installing) == [.skip, .later, .relaunch])
        #expect(installing.body == ProductStrings[.updateWindowStagedBody])
        #expect(content(offer(stage: .downloaded)) == content(offer()))
        #expect(layout(content(offer(isCritical: true, stage: .installing))) == [.later, .relaunch])
    }

    @Test("a download shows its fraction and how much of the whole has arrived")
    func downloadProgress() {
        let half = content(.downloading(received: 50, expected: 100))

        #expect(half.progress == .fraction(0.5))
        #expect(half.status?.contains(" of ") == true)
        #expect(layout(half) == [.cancel])

        let unsized = content(.downloading(received: 0, expected: nil))
        #expect(unsized.progress == .indeterminate)
        #expect(unsized.status == nil)
        #expect(content(.downloading(received: 2_048, expected: nil)).status?.hasSuffix(" downloaded") == true)
        #expect(content(.downloading(received: 300, expected: 100)).progress == .fraction(1))
    }

    /// The download being unpacked and the install itself cannot be walked
    /// away from, so they offer nothing, and the window has no close button.
    @Test("preparing and installing offer no button; ready offers only the relaunch")
    func phasesWithoutAWayOut() {
        #expect(content(.preparing(fraction: 0.4)).buttons.isEmpty)
        #expect(content(.installing).buttons.isEmpty)
        #expect(layout(content(.ready)) == [.relaunch])
    }

    @Test("a check that found nothing says why, and the newest version where it is this one")
    func notFound() {
        #expect(content(.notFound(.onLatest)).title == "Fermix is up to date")
        #expect(content(.notFound(.onLatest)).body == "Version 0.6.0 is the newest version.")
        #expect(content(.notFound(.unknown)).body == nil)

        for reason in [UpdateNotFoundReason.systemTooOld, .systemTooNew, .hardwareUnsupported] {
            let unavailable = content(.notFound(reason))
            #expect(unavailable.title == "No update for this Mac")
            #expect(unavailable.body != nil)
        }
        #expect(layout(content(.notFound(.onLatest))) == [.done])
    }

    @Test("each failure is a sentence of its own")
    func failures() {
        let failures: [UpdateFailure] = [
            .feedUnreachable, .downloadFailed, .notVerified, .installFailed,
            .busy, .recoveryPending, .unownedDaemon, .notInstallable, .other
        ]
        let sentences = failures.compactMap { content(.failed($0)).body }

        #expect(Set(sentences).count == failures.count)
        #expect(layout(content(.failed(.other))) == [.done])
    }

    /// A refusal says what will change it: retrying never clears a record
    /// Recovery has not looked at, so it is not told to try again later.
    @Test("a refusal of the update transaction reads as that refusal")
    func refusals() {
        #expect(UpdateFailure(.busy(.lifecycle)) == .busy)
        #expect(UpdateFailure(.recoveryPending) == .recoveryPending)
        #expect(UpdateFailure(.unownedDaemon(.requiresApproval)) == .unownedDaemon)
        #expect(UpdateFailure(.notAnUpgrade(installed: 12, offered: 12)) == .notInstallable)
        #expect(UpdateFailure(.priorReleaseUnknown(build: 12)) == .notInstallable)
        #expect(UpdateFailure(.bundledEngineUnknown) == .notInstallable)
        #expect(content(.failed(.recoveryPending)).body != content(.failed(.other)).body)
    }

    /// The copy gate runs over the strings table; this runs it over what the
    /// window composes from it, versions included.
    @Test("everything the window composes keeps the copy rules")
    func composedCopy() {
        let phases: [UpdatePromptPhase] = [
            .permission, .checking, offer(), offer(isCritical: true), offer(isInformationOnly: true),
            offer(stage: .installing), .downloading(received: 1_000_000, expected: 3_000_000),
            .preparing(fraction: 0.5), .ready, .installing, .installed,
            .notFound(.onLatest), .notFound(.newerThanLatest), .notFound(.systemTooOld),
            .notFound(.systemTooNew), .notFound(.hardwareUnsupported), .failed(.feedUnreachable),
            .failed(.downloadFailed), .failed(.notVerified), .failed(.installFailed), .failed(.busy),
            .failed(.recoveryPending), .failed(.unownedDaemon), .failed(.notInstallable), .failed(.other)
        ]

        for phase in phases {
            let shown = content(phase)
            for text in [shown.title, shown.body, shown.status].compactMap({ $0 }) + shown.buttons.map(\.title) {
                #expect(ProductCopyRules.violations(in: text).isEmpty, "\(phase): \(text)")
            }
            #expect(shown.buttons.filter { $0.role == .primary }.count <= 1)
        }
    }
}

/// What the person can do in the update window, and what the updater hears.
@Suite("Update prompt")
@MainActor
struct UpdatePromptTests {
    private let presenter = FakeUpdateWindowPresenter()
    private let prompt: UpdatePrompt

    init() {
        prompt = UpdatePrompt(installedVersion: "0.6.0")
        prompt.presenter = presenter
    }

    private func offer(isCritical: Bool = false, infoURL: URL? = nil) -> UpdatePromptOffer {
        UpdatePromptOffer(
            version: "0.7.0",
            isCritical: isCritical,
            isInformationOnly: infoURL != nil,
            infoURL: infoURL,
            stage: .notDownloaded
        )
    }

    @Test("each answer reaches the updater once, however often it is pressed")
    func answersOnce() {
        var choices: [UpdateUserChoice] = []
        prompt.offer(offer(), userInitiated: true) { choices.append($0) }

        prompt.perform(.install)
        prompt.perform(.install)

        #expect(choices == [.install])
        // Install keeps the window: the updater moves it on to the download.
        #expect(presenter.closed == 0)
    }

    @Test("later and skip close the window with their own answer")
    func laterAndSkip() {
        var choices: [UpdateUserChoice] = []
        prompt.offer(offer(), userInitiated: true) { choices.append($0) }
        prompt.perform(.later)
        prompt.offer(offer(), userInitiated: true) { choices.append($0) }
        prompt.perform(.skip)

        #expect(choices == [.dismiss, .skip])
        #expect(prompt.phase == nil)
        #expect(presenter.closed == 2)
    }

    @Test("a press the phase does not offer is not sent")
    func refusesWhatIsNotOffered() {
        var choices: [UpdateUserChoice] = []
        prompt.offer(offer(isCritical: true), userInitiated: true) { choices.append($0) }

        prompt.perform(.skip)

        #expect(choices.isEmpty)
        #expect(prompt.phase != nil)
    }

    /// The menu bar and Home already say an update is there, so an update no
    /// one asked for does not take focus from whatever the person is doing.
    @Test("an update a scheduled check found waits until Fermix is in front")
    func scheduledUpdateWaits() {
        presenter.isAppActive = false
        prompt.offer(offer(), userInitiated: false) { _ in }

        #expect(presenter.shown == 0)

        prompt.appBecameActive()
        #expect(presenter.shown == 1)
        prompt.appBecameActive()
        #expect(presenter.shown == 1)
    }

    @Test("an update the person asked for comes forward at once")
    func askedForUpdateShows() {
        presenter.isAppActive = false
        prompt.showChecking {}
        prompt.offer(offer(), userInitiated: true) { _ in }

        // One window for the whole update: the offer replaces the check's
        // content in place rather than opening the window again.
        #expect(presenter.shown == 1)
        if case .offered = prompt.phase {} else { Issue.record("the offer did not replace the check") }
    }

    @Test("one window carries an update from the offer to the relaunch")
    func oneWindowThroughout() {
        var relaunched = 0
        prompt.offer(offer(), userInitiated: true) { _ in }
        prompt.perform(.install)
        prompt.showDownloading {}
        prompt.downloadExpected(100)
        prompt.downloadReceived(40)
        prompt.downloadReceived(20)
        #expect(prompt.phase == .downloading(received: 60, expected: 100))
        prompt.showPreparing()
        prompt.preparingProgress(1.4)
        #expect(prompt.phase == .preparing(fraction: 1))
        prompt.showReady { relaunched += 1 }
        prompt.perform(.relaunch)
        prompt.perform(.relaunch)

        #expect(relaunched == 1)
        #expect(presenter.shown == 1)
        #expect(presenter.closed == 0)
        // The download may have outlasted the person's attention: being ready
        // is the one moment that asks for it back.
        #expect(presenter.attentionRequests == 1)
    }

    @Test("cancel stops the check or the download and closes the window")
    func cancel() {
        var cancelled = 0
        prompt.showChecking { cancelled += 1 }
        prompt.perform(.cancel)
        prompt.showDownloading { cancelled += 1 }
        prompt.perform(.cancel)

        #expect(cancelled == 2)
        #expect(prompt.phase == nil)
    }

    @Test("the updater ending the session drops the answer it no longer waits for")
    func dismissDropsThePendingAnswer() {
        var choices: [UpdateUserChoice] = []
        prompt.offer(offer(), userInitiated: true) { choices.append($0) }

        prompt.dismiss()
        prompt.perform(.install)

        #expect(choices.isEmpty)
        #expect(presenter.closed == 1)
    }

    /// The system kept Fermix from quitting: the window goes, and asking for
    /// the update again offers the relaunch once more.
    @Test("a refused relaunch is offered again when the update is asked for")
    func parkedRelaunch() {
        var retries = 0
        prompt.parkRelaunch { retries += 1 }

        #expect(prompt.phase == nil)

        prompt.bringForward()
        #expect(prompt.phase == .ready)
        prompt.perform(.relaunch)
        #expect(retries == 1)
    }

    @Test("learn more opens the release's page and leaves the update for later")
    func learnMore() throws {
        let page = try #require(URL(string: "https://fermix.ai/releases"))
        var choices: [UpdateUserChoice] = []
        prompt.offer(offer(infoURL: page), userInitiated: true) { choices.append($0) }

        prompt.perform(.learnMore)

        #expect(presenter.opened == [page])
        #expect(choices == [.dismiss])
    }

    @Test("the permission question answers yes or no")
    func permission() {
        var answers: [Bool] = []
        prompt.askPermission { answers.append($0) }
        prompt.perform(.allowChecks)
        prompt.askPermission { answers.append($0) }
        prompt.perform(.declineChecks)

        #expect(answers == [true, false])
    }

    @Test("a finished check is acknowledged when the person closes it")
    func acknowledgement() {
        var acknowledged = 0
        prompt.showNotFound(.onLatest) { acknowledged += 1 }

        #expect(acknowledged == 0)
        prompt.perform(.done)
        #expect(acknowledged == 1)
        #expect(prompt.phase == nil)
    }
}

@MainActor
final class FakeUpdateWindowPresenter: UpdateWindowPresenting {
    var isAppActive = true
    private(set) var shown = 0
    private(set) var closed = 0
    private(set) var opened: [URL] = []
    private(set) var attentionRequests = 0

    func showUpdateWindow() { shown += 1 }
    func closeUpdateWindow() { closed += 1 }
    func requestAttention() { attentionRequests += 1 }
    func open(_ url: URL) { opened.append(url) }
}
