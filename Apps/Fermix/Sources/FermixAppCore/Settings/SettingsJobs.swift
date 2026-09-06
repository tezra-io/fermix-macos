import Foundation

/// Starting the jobs the panes offer (M34 §7.3).
///
/// Every one of them mints a job view and hands it to a `JobRunner`, so the row
/// that shows it, the poll that follows it and the cancel that stops it are the
/// same three pieces everywhere. The model records the running jobs so a pane
/// reopened over one can find it.
extension SettingsModel {

    /// A runner wired to this model's gateway and its injected sleeper, so a
    /// test can prove a bounded poll without spending its wall-clock time.
    public func makeJobRunner() -> JobRunner {
        JobRunner(gateway: gateway, sleeper: sleeper)
    }

    public func startCapabilityInstall(
        _ target: ManagementCapabilityTarget,
        on runner: JobRunner
    ) async {
        await start(runner) { try await self.gateway.startCapabilityInstall(target: target) }
    }

    /// The Meetings switch, both ways (M34 §5.4).
    ///
    /// Turning it on installs first: the notetaker and its browser have to be
    /// on this Mac before the daemon's flag means anything, so the write goes
    /// out only once that job has completed. A refused or cancelled run writes
    /// nothing, puts the switch back where it was, and leaves the daemon's own
    /// sentence under it.
    ///
    /// The engine's install is idempotent and fast when both are already there,
    /// which is why this is the whole gesture: there is no installed read to
    /// make and no second door to offer.
    ///
    /// Turning it off is the plain write every other switch makes. Nothing is
    /// uninstalled and nothing is asked.
    public func setMeetingsEnabled(_ isOn: Bool, on runner: JobRunner) async {
        let key = SettingsDraftKey(
            section: SettingsBinding.meetingsSection,
            key: SettingsBinding.meetingsEnabled
        )

        guard isOn else {
            await apply(section: key.section, key: key.key, value: .flag(false))
            return
        }

        // Optimistic in the control, as every write here is: the switch stays
        // where the person put it while the install runs, and goes back only if
        // the run does not finish.
        setDraft(.flag(true), for: key)
        setMessage(nil, for: key)
        await startCapabilityInstall(.meetbot, on: runner)
        await runner.drainPendingWork()

        guard runner.completed else {
            setDraft(nil, for: key)
            return
        }

        let written = await apply(section: key.section, key: key.key, value: .flag(true))
        guard !written else { return }

        // The one refusal `apply` leaves standing: with writes blocked it sets
        // no draft of its own, so it has none to revert and this one is ours.
        setDraft(nil, for: key)
    }

    public func startMeetingsSignIn(on runner: JobRunner) async {
        await start(runner) { try await self.gateway.startMeetingsSignIn() }
    }

    public func startComputerUseGrant(on runner: JobRunner) async {
        await start(runner) { try await self.gateway.startComputerUseGrant() }
    }

    public func startPluginInstall(name: String, on runner: JobRunner) async {
        precondition(!name.isEmpty, "a plugin is installed by name")

        await start(runner) { try await self.gateway.startPluginInstall(name: name) }
    }

    public func startPluginCheck(name: String, on runner: JobRunner) async {
        precondition(!name.isEmpty, "a plugin is checked by name")

        await start(runner) { try await self.gateway.startPluginCheck(name: name) }
    }

    public func startProviderProbe(provider: String, on runner: JobRunner) async {
        precondition(!provider.isEmpty, "a probe names its provider")

        await start(runner) { try await self.gateway.startProviderProbe(provider: provider) }
    }

    /// Starts one job and records it. A refusal is the daemon's own sentence on
    /// the row rather than a silent no-op.
    private func start(_ runner: JobRunner, _ mint: @escaping () async throws -> ManagementJob) async {
        do {
            let job = try await mint()
            runner.start(job)
            note(job)
        } catch {
            runner.adopt(failure: ManagementMessage.sentence(for: error))
            noteReconcile(error)
        }
    }

    /// Records what is running, so a pane can tell that work is in flight
    /// without holding a runner of its own.
    func note(_ job: ManagementJob) {
        jobs.removeAll { $0.jobId == job.jobId }
        guard job.status == .running else { return }

        jobs.append(job)
    }

    /// Re-reads what the daemon is running. The panes re-attach from this, which
    /// is why a closed sheet never orphans an install.
    public func refreshJobs() async {
        do {
            jobs = try await gateway.jobs().jobs.filter { $0.status == .running }
        } catch {
            log.error("job list refused: \(ManagementMessage.sentence(for: error), privacy: .public)")
            noteReconcile(error)
        }
    }
}
