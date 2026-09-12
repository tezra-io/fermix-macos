import AppKit
import FermixAppCore
import Foundation
import Sparkle

/// Every Sparkle callback the update transaction binds, forwarded and nothing
/// else (M34 §6, R3).
///
/// The protocol is declared `NS_SWIFT_UI_ACTOR`, so this is a main-actor
/// `NSObject`, and Sparkle holds it weakly: `SparkleUpdater` owns it. It makes
/// no decision of its own — every method here is a translation into the
/// coordinator's vocabulary — because a rule written on this side of the seam
/// could not be tested without a framework, a feed and a bundle to replace.
///
/// **Two callbacks read like vetoes and are not.** Returning `false` from
/// `updaterShouldRelaunchApplication` aborts the driver and leaves the armed
/// installer running, and the same is true of `willInstallUpdateOnQuit`, whose
/// own source comment is "the installer tool will keep the installation alive".
/// Neither is a safety valve; both are commented at the call site so the class
/// of bug does not come back.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private weak var coordinator: UpdateCoordinator?

    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Discovery

    /// Ahead of every driver, the resumption of a staged installer included.
    /// Throwing aborts the whole cycle.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try coordinator?.mayCheck()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        coordinator?.feedLoaded(SparkleAppcast.entries(appcast))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        coordinator?.found(SparkleAppcast.entry(item))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        coordinator?.foundNothing()
    }

    /// The pre-download veto. Throwing means the item is never shown, never
    /// downloaded and never installed, which is the only refusal that exists
    /// once a cycle has started.
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        try coordinator?.mayProceed(with: SparkleAppcast.entry(updateItem))
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        coordinator?.cycleFinished(SparkleAppcast.outcome(error))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        coordinator?.aborted((error as NSError).localizedDescription)
    }

    // MARK: - The person's choice

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        coordinator?.userChose(SparkleAppcast.choice(choice), stage: SparkleAppcast.stage(state.stage))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        coordinator?.downloadFailed((error as NSError).localizedDescription)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        coordinator?.downloadCancelled()
    }

    // MARK: - The point of no return

    /// The last callback guaranteed to run before the installer can arm.
    ///
    /// Ten lines after this returns, Sparkle hands the download to a separate
    /// process which registers a kernel watch on this process's pid; from that
    /// moment any exit — Quit, log out, crash, force quit — completes the
    /// bundle replacement with no in-process code and no further callback. So
    /// the engine has to be stopped before this returns, and holding the
    /// callback is the only mechanism there is.
    ///
    /// The bound is the coordinator's own: it answers whether the engine is
    /// down, and the record it keeps is what recovers a replacement that
    /// happened anyway.
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        guard let coordinator else { return }

        let outcome = coordinator.prepareForReplacement()

        guard outcome != .ready else { return }

        AppLog.logger(.lifecycle).error(
            "the update is being staged with the engine not proven stopped: \(outcome.rawValue, privacy: .public)"
        )
    }

    /// Already too late to prevent a replacement on quit. It is the phase
    /// marker that says the app is armed.
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        coordinator?.staged()
    }

    // MARK: - Installation and relaunch

    /// The final commit point, not the drain window.
    ///
    /// Returning `true` holds the relaunch until the handler is invoked, and it
    /// is invoked exactly once: a second invocation is not consulted, because
    /// the driver re-enters its install path with the postponement already
    /// spent. Holding it forever would leave the app armed and unusable rather
    /// than safe, so the wait is bounded and the handler always runs.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let coordinator else { return false }

        Task { @MainActor in
            _ = await coordinator.commitBeforeRelaunch()
            installHandler()
        }

        return true
    }

    /// Not a veto. Returning `false` reaches `abortInstall`, which invalidates
    /// one connection and leaves the armed installer running: the update
    /// installs anyway and no transaction runs at all. It is bound to `true`
    /// so a later reader does not reach for it as an emergency stop.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        coordinator?.willRelaunch()
    }

    /// Also not a veto: Sparkle's own comment on the `false` branch is that the
    /// installer tool keeps the installation alive. Its only caller is the
    /// automatic driver, which is never constructed while
    /// `SUAllowsAutomaticUpdates` is `NO` in the Info.plist, so reaching this
    /// at all means the policy key is gone. It records that and returns
    /// `false`, which changes nothing but says what happened.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        coordinator?.installOnQuitReached()
        return false
    }

}

/// The two answers the standard user driver needs.
///
/// A separate object because `SPUStandardUserDriverDelegate` is not declared on
/// the main actor, and both answers are constants: nothing here reads state, so
/// nothing here needs isolation.
final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// The gentle path is not implemented, so it is not advertised.
    var supportsGentleScheduledUpdateReminders: Bool { false }

    /// The ready-to-install window may not be parked out of sight. It is not
    /// closable, but minimizing it hides the one surface that says the app is
    /// about to replace itself, and quitting from behind it installs the
    /// update.
    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool { false }
}
