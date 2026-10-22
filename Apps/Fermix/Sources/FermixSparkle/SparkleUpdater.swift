import FermixAppCore
import Foundation
import Sparkle

/// The GUI's one updater, and the only module in the repository that imports
/// Sparkle.
///
/// M34 §6 states the constraint this target exists to satisfy: the daemon and
/// `FermixAgent` never load Sparkle. Both executables link `FermixAppCore`, so
/// a Sparkle dependency there would put the framework into the agent as well.
/// `FermixAppCore` therefore declares the seams and imports nothing, this
/// target implements them, and only the `Fermix` executable links this target.
///
/// It holds no state and decides nothing. Every rule about what an update may
/// do lives in `UpdateCoordinator`, which has no Sparkle types in it and is
/// provable without a framework, a feed, a signature, or a bundle to replace.
///
/// One updater for the whole process, as M34 §6 requires: scheduled checks
/// belong to a live updater, and an updater rebuilt per question would have no
/// schedule to keep.
@MainActor
public final class SparkleUpdater: UpdaterDriving {
    private var updater: SPUUpdater?
    /// The delegate and the user driver. Sparkle holds the delegate weakly and
    /// the driver strongly; both are held here so neither question has to be
    /// asked again.
    private var delegate: SparkleUpdaterDelegate?
    private var userDriver: SparkleUserDriver?
    /// Kept for the updater's lifetime: the observation is what publishes
    /// `canCheckForUpdates` changes to the menu row.
    private var canCheckObservation: NSKeyValueObservation?
    private var canCheckLatched = false

    public init() {}

    public var canCheckForUpdates: Bool { canCheckLatched }

    /// Starts the updater, or refuses to construct one at all.
    ///
    /// The policy is validated here rather than left to Sparkle, and a start
    /// Sparkle refuses comes back as a refusal rather than the alert its
    /// standard controller raises a second later: every user-visible string in
    /// this product goes through `ProductStrings`. The shipped public key is
    /// R5's placeholder until an owner plumbs a real one, and this is what
    /// turns that into one truthful sentence on the update surface.
    ///
    /// The user driver is the app's own (`SparkleUserDriver`), so every window
    /// an update shows is the app's update window rather than Sparkle's.
    public func start(_ coordinator: UpdateCoordinator, prompt: UpdatePrompt) -> UpdateConfigurationRefusal? {
        precondition(updater == nil, "the updater is started once")

        do {
            try UpdateConfiguration.validate(Self.declaredPolicy())
        } catch let refusal as UpdateConfigurationRefusal {
            return refusal
        } catch {
            preconditionFailure("UpdateConfiguration.validate throws only UpdateConfigurationRefusal")
        }

        let delegate = SparkleUpdaterDelegate(coordinator: coordinator)
        let userDriver = SparkleUserDriver(prompt: prompt)
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: delegate
        )
        self.delegate = delegate
        self.userDriver = userDriver

        do {
            try updater.start()
        } catch {
            return .updaterDidNotStart((error as NSError).localizedDescription)
        }

        self.updater = updater
        observeCanCheck(updater)
        checkAtLaunch(updater)

        return nil
    }

    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// The launch-time background check, and only where the person's stored
    /// preference allows it (M34 §6, R2).
    ///
    /// Sparkle logs a developer error for a background check made while
    /// automatic checking is off, and it schedules its own once started, so
    /// this runs immediately after starting and never later.
    private func checkAtLaunch(_ updater: SPUUpdater) {
        guard updater.automaticallyChecksForUpdates else { return }

        updater.checkForUpdatesInBackground()
    }

    /// Follows the updater's own answer for the menu row and Home.
    ///
    /// It stays true while an update is merely being shown, because asking
    /// again is what brings the update window back into focus. The observation
    /// is held for the updater's lifetime; without it the latched value would
    /// never change.
    private func observeCanCheck(_ updater: SPUUpdater) {
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            MainActor.assumeIsolated { [weak self] in
                self?.canCheckLatched = updater.canCheckForUpdates
            }
        }
    }

    /// The policy this bundle declares, read from the one place that carries it.
    ///
    /// `scripts/render_info_plist.sh` is the only writer of these keys, and the
    /// release audience of `scripts/verify_staged_app.sh` refuses a bundle that
    /// ships the placeholder public key.
    private static func declaredPolicy() -> UpdatePolicyManifest {
        let info = Bundle.main.infoDictionary ?? [:]

        return UpdatePolicyManifest(
            feedURL: info["SUFeedURL"] as? String,
            publicEDKey: info["SUPublicEDKey"] as? String,
            allowsAutomaticUpdates: info["SUAllowsAutomaticUpdates"] as? Bool,
            automaticallyUpdate: info["SUAutomaticallyUpdate"] as? Bool
        )
    }
}
