import Foundation

/// One long operation, polled (M34 §7.3, §8).
///
/// Every long operation on the wire is a job rather than a held request, so one
/// poller, one progress row and one failure sentence serve all of them. The
/// budget is the daemon's, carried on the job view, which is what bounds the
/// poll: this never waits longer than the daemon said it would take.
///
/// Dismissing the view stops the polling and leaves the job running, which is
/// why `attach` exists: a sheet reopened over a running install finds it again
/// through `job.list` rather than starting a second one.
@MainActor
public final class JobRunner: ObservableObject {
    @Published public private(set) var job: ManagementJob?
    /// Why the run ended badly, in the daemon's own words.
    @Published public private(set) var failure: String?
    /// A browser handoff can fail while the daemon's job is still running.
    @Published public private(set) var browserFailure: String?
    /// Kept only in memory while its sign-in is active.
    @Published public private(set) var authorizationURL: URL?

    /// The published poll interval.
    public static let pollSeconds: TimeInterval = 0.5
    /// The ceiling on one run's polls, whatever budget the daemon reports. A
    /// budget that would outrun this is a daemon defect, and the poll stops
    /// rather than running forever.
    public static let maximumPolls = 2_000

    private let gateway: any DaemonQuerying
    private let sleeper: any Sleeping
    private let now: @Sendable () -> Date
    private var authorizationExpiresAt: Date?
    private let log = AppLog.logger(.app)
    private var poll: Task<Void, Never>?

    public init(
        gateway: any DaemonQuerying,
        sleeper: any Sleeping,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.sleeper = sleeper
        self.now = now
    }

    public var isRunning: Bool { job?.status == .running }

    /// Whether the run this runner followed finished, and finished well.
    ///
    /// A caller that chains work onto a job asks this rather than reading the
    /// absence of a failure: a cancelled run carries no failure sentence of its
    /// own, and treating it as a success is how a switch turns a feature on
    /// over an install the operator stopped.
    public var completed: Bool { job?.status == .completed && failure == nil }

    /// The sentence for the step the daemon named, where it named one.
    ///
    /// The wire value is an atom (`awaiting_browser`), not a sentence, so the
    /// app owns the copy for it. A phase this build has never seen is logged
    /// and drawn as nothing: a raw wire token on a sign-in sheet is not English,
    /// and inventing one from the token would be worse.
    public var phase: String? {
        guard let job, let named = job.phase else { return nil }
        guard let sentence = JobPhaseCopy.sentence(kind: job.kind, phase: named) else {
            log.error(
                "no sentence for \(job.kind.wireValue, privacy: .public) phase \(named, privacy: .public)"
            )
            return nil
        }

        return sentence
    }

    public var progress: ManagementJobProgress? { job?.progress }

    /// Adopts a job the caller just started and follows it to its end.
    public func start(_ started: ManagementJob, authorizeURL: URL? = nil, expiresInMs: Int? = nil) {
        precondition(authorizeURL == nil || started.kind == .auth, "only browser authentication carries a URL")
        dismiss()
        job = started
        failure = started.failure?.sentence
        browserFailure = nil
        guard !started.status.isTerminal else { return }

        authorizationURL = authorizeURL
        authorizationExpiresAt = authorizeURL.map { _ in
            now().addingTimeInterval(Double(max(0, expiresInMs ?? started.budgetMs)) / 1_000)
        }
        beginPolling()
    }

    /// The job never started: the daemon refused the call that would have minted
    /// it, and the row shows why rather than sitting idle.
    public func adopt(failure sentence: String) {
        precondition(!sentence.isEmpty, "a refused job states why")
        dismiss()
        job = nil
        failure = sentence
        browserFailure = nil
    }

    /// Returns the original browser destination only within its lifetime.
    public func activeBrowserURL() -> URL? {
        guard isRunning else { return nil }
        guard let authorizationExpiresAt, now() < authorizationExpiresAt else {
            clearAuthorization()
            browserFailure = ProductStrings[.providerSignInExpired]
            return nil
        }

        return authorizationURL
    }

    public func browserOpened(_ succeeded: Bool) {
        guard isRunning else { return }

        browserFailure = succeeded ? nil : ProductStrings[.providerSignInOpenFailed]
    }

    /// Finds a job of this kind the daemon is already running, and follows it.
    ///
    /// This is what makes reopening a sheet safe: the run continues, the row
    /// picks it up, and nothing starts a second one.
    public func attach(kind: ManagementJobKind) async {
        guard job == nil else { return }

        do {
            let running = try await gateway.jobs().jobs.first { $0.kind == kind && $0.status == .running }
            guard let running else { return }

            start(running)
        } catch {
            log.error("job list refused: \(ManagementMessage.sentence(for: error), privacy: .public)")
        }
    }

    /// Asks the daemon to stop the run. The row then follows the job to
    /// whatever terminal status it reports, which may be `completed` if the
    /// cancel arrived too late to matter.
    public func cancelJob() async {
        guard let identifier = job?.jobId else { return }

        do {
            let cancelled = try await gateway.cancelJob(id: identifier)
            job = cancelled
            failure = cancelled.failure?.sentence
            if cancelled.status.isTerminal { dismiss() }
        } catch {
            failure = ManagementMessage.sentence(for: error)
        }
    }

    /// The view went away. Polling stops; the job does not.
    public func dismiss() {
        poll?.cancel()
        poll = nil
        clearAuthorization()
    }

    /// Lets a caller observe the poll this runner started and forgot.
    public func drainPendingWork() async {
        await poll?.value
    }

    // MARK: - Polling

    private func beginPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            await self?.pollUntilTerminal()
            if !Task.isCancelled { self?.poll = nil }
        }
    }

    /// Polls to the daemon's own budget. The bound is explicit and the cap is
    /// published: a job whose status never becomes terminal ends the poll here
    /// rather than holding the runner open.
    private func pollUntilTerminal() async {
        guard let identifier = job?.jobId else { return }
        defer { if !Task.isCancelled { clearAuthorization() } }

        for _ in 0..<pollCount() {
            do {
                try await sleeper.sleep(seconds: Self.pollSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if let authorizationExpiresAt, now() >= authorizationExpiresAt {
                clearAuthorization()
                browserFailure = ProductStrings[.providerSignInExpired]
            }

            do {
                let latest = try await gateway.job(id: identifier)
                guard !Task.isCancelled else { return }

                job = latest
                guard !latest.status.isTerminal else {
                    failure = latest.failure?.sentence
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }

                failure = ManagementMessage.sentence(for: error)
                return
            }
        }

        // The poll stops here; the run does not. `attach(kind:)` is what picks
        // it up again, which is why the sentence says it is still going.
        failure = ProductStrings[.settingsJobTimedOut]
    }

    private func clearAuthorization() {
        authorizationURL = nil
        authorizationExpiresAt = nil
    }

    /// How many polls the daemon's budget allows, bounded by the published cap.
    private func pollCount() -> Int {
        let budget = job?.budgetMs ?? 0
        let allowed = Int((Double(budget) / 1_000 / Self.pollSeconds).rounded(.up)) + 1

        return max(1, min(allowed, Self.maximumPolls))
    }
}

/// What each job phase says, in the app's own words (M34 §7.3).
///
/// The wire carries an atom per step; this is the one place it becomes a
/// sentence, so the sign-in sheet, an install row and a probe row cannot spell
/// the same step three ways.
///
/// The vocabulary is **per kind**, and the overlaps are not the same step:
/// `binding` on an `auth` job is opening the loopback port that receives the
/// reply, and `binding` on a `plugin_workspace_select` job is tying the plugin
/// to the workspace. Keyed on the phase alone, the workspace sheet told the
/// operator it was opening a local port.
public enum JobPhaseCopy {
    /// One key per (kind, phase) pair the contract publishes.
    public struct Step: Hashable, Sendable {
        public let kind: ManagementJobKind
        public let phase: String

        public init(_ kind: ManagementJobKind, _ phase: String) {
            precondition(!phase.isEmpty, "a job step names its phase")

            self.kind = kind
            self.phase = phase
        }
    }

    /// Every (kind, phase) pair PROTOCOL.md's per-kind vocabulary publishes.
    /// `computer_use_grant` has none, which is why it has no entry.
    public static let published: [Step: ProductStringKey] = [
        Step(.providerProbe, "calling"): .jobPhaseCalling,
        Step(.auth, "binding"): .jobPhaseBinding,
        Step(.auth, "awaiting_browser"): .jobPhaseAwaitingBrowser,
        Step(.auth, "verifying"): .jobPhaseVerifyingSignIn,
        Step(.authImport, "reading_keychain"): .jobPhaseReadingKeychain,
        Step(.authImport, "verifying"): .jobPhaseVerifyingSignIn,
        Step(.pluginInstall, "downloading"): .jobPhaseDownloading,
        Step(.pluginCheck, "probing"): .jobPhaseProbing,
        Step(.pluginWorkspacesDiscover, "listing"): .jobPhaseListing,
        Step(.pluginWorkspaceSelect, "binding"): .jobPhaseBindingWorkspace,
        Step(.capabilityInstall, "sidecar_downloading"): .jobPhaseSidecarDownloading,
        Step(.capabilityInstall, "downloading"): .jobPhaseDownloading,
        Step(.capabilityInstall, "verifying"): .jobPhaseVerifying,
        Step(.meetingsSignin, "awaiting_signin"): .jobPhaseAwaitingSignIn
    ]

    public static func sentence(kind: ManagementJobKind, phase: String) -> String? {
        published[Step(kind, phase)].map { ProductStrings[$0] }
    }
}
