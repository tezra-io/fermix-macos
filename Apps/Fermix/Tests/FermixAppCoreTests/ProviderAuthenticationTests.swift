import Foundation
import Testing

@testable import FermixAppCore

@Suite("Provider authentication feedback")
@MainActor
struct ProviderAuthenticationTests {
    @Test("a refused credential import is visible on the shared runner")
    func refusedImportIsVisible() async throws {
        let harness = try SettingsHarness()
        let sentence = "The Claude Code sign-in on this Mac could not be read."
        harness.gateway.v2Failures[.authImportStart] = ManagementRefusal.daemon(.unavailable, sentence)
        let runner = harness.model.makeJobRunner()

        let refusal = await harness.model.startAuthImport(source: .claudeCode, provider: "anthropic", on: runner)

        #expect(refusal == sentence)
        #expect(runner.failure == sentence)
        #expect(!runner.isRunning)
        #expect(harness.model.signingInProvider == nil)
    }

    @Test("a refused browser sign-in is visible on the shared runner")
    func refusedBrowserSignInIsVisible() async throws {
        let harness = try SettingsHarness()
        let sentence = "This provider could not start sign-in."
        harness.gateway.v2Failures[.authStart] = ManagementRefusal.daemon(.unavailable, sentence)
        let runner = harness.model.makeJobRunner()

        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == sentence)
        #expect(runner.failure == sentence)
    }

    /// The click opens no browser: the sheet waiting on the sign-in does, once
    /// it is on screen, so the browser is the last window to come forward
    /// (owner report of 2026-10-03: the sheet presented after the browser and
    /// came up over it). That first open happens once per run.
    @Test("the browser opens once, when the waiting surface asks, and reopening reuses the URL")
    func reopeningReusesTheURL() async throws {
        let gateway = try SettingsFixture.gateway()
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: gateway, opener: opener)
        let runner = model.makeJobRunner()

        #expect(await model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(opener.urls.isEmpty, "starting a sign-in opened the browser before its sheet was up")
        model.openSignIn(on: runner)
        model.openSignIn(on: runner)
        #expect(opener.urls.count == 1, "a surface drawn again opened the same run a second time")
        model.reopenSignIn(on: runner)

        #expect(opener.urls.count == 2)
        #expect(opener.urls.first == opener.urls.last)
        #expect(gateway.calls.filter { $0 == .v2(.authStart) }.count == 1)
        await runner.drainPendingWork()
        #expect(runner.authorizationURL == nil)
        model.reopenSignIn(on: runner)
        #expect(opener.urls.count == 2)
    }

    @Test("a rejected browser launch preserves the accepted job for reopening")
    func browserRejectionPreservesJob() async throws {
        let gateway = try SettingsFixture.gateway()
        let opener = RecordingExternalOpener(succeeds: false)
        let model = SettingsFixture.model(gateway: gateway, opener: opener)
        let runner = model.makeJobRunner()

        #expect(await model.startSignIn(provider: "openai_codex", on: runner) == nil)
        model.openSignIn(on: runner)
        #expect(runner.isRunning)
        #expect(runner.browserFailure == ProductStrings[.providerSignInOpenFailed])
        #expect(runner.authorizationURL != nil)
        #expect(model.signingInProvider == "openai_codex")
        runner.dismiss()
    }

    @Test("terminal jobs and successful cancellation discard the browser URL", arguments: ["completed", "failed", "timed_out"])
    func terminalJobsDiscardURL(_ status: String) async throws {
        let harness = try SettingsHarness()
        harness.gateway.jobScript = [try ManagementValueFixture.job(kind: "auth", status: status, phase: nil)]
        let runner = harness.model.makeJobRunner()
        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)

        await runner.drainPendingWork()
        #expect(runner.authorizationURL == nil)

        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        await runner.cancelJob()
        #expect(runner.authorizationURL == nil)
    }

    @Test("an expired URL cannot reopen even while the job is still running")
    func expiredURLCannotReopen() throws {
        let harness = try SettingsHarness()
        let clock = ManualClock()
        let runner = JobRunner(gateway: harness.gateway, sleeper: NoWaitSleeper(), now: clock.reader)
        runner.start(
            try ManagementValueFixture.job(kind: "auth"),
            authorizeURL: URL(string: "https://auth.openai.com/authorize"),
            expiresInMs: 1_000
        )
        clock.advance(1)

        harness.model.reopenSignIn(on: runner)

        #expect(runner.authorizationURL == nil)
        #expect(runner.browserFailure == ProductStrings[.providerSignInExpired])
        #expect(!harness.gateway.calls.contains(.v2(.authStart)))
        runner.dismiss()
    }

    /// The pane follows every sign-in on one runner, so a failed import is
    /// followed by whatever sign-in the person tries next, and that one starts
    /// clean rather than under the import's sentence.
    @Test("a failed import reports its sentence, and the next sign-in on its runner starts clean")
    func failedImportLeavesTheRunnerClean() async throws {
        let harness = try SettingsHarness()
        let sentence = "The imported credential has expired."
        harness.gateway.jobScript = [try ManagementValueFixture.job(
            kind: "auth_import", status: "failed", phase: nil,
            failure: (code: "unavailable", sentence: sentence)
        )]
        let runner = harness.model.makeJobRunner()
        #expect(await harness.model.startAuthImport(source: .claudeCode, provider: "anthropic", on: runner) == nil)
        #expect(runner.job?.kind == .authImport)
        #expect(runner.authorizationURL == nil)
        await runner.drainPendingWork()
        #expect(runner.failure == sentence)

        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(runner.failure == nil)
        #expect(runner.job?.kind == .auth)
        #expect(runner.authorizationURL != nil)
        runner.dismiss()
    }

    @Test("an imported sign-in shows its job progress without opening a browser")
    func successfulImportReportsProgress() async throws {
        let gateway = try SettingsFixture.gateway()
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: gateway, opener: opener)
        let runner = model.makeJobRunner()

        #expect(await model.startAuthImport(source: .claudeCode, provider: "anthropic", on: runner) == nil)
        #expect(runner.isRunning)
        #expect(runner.phase == ProductStrings[.jobPhaseReadingKeychain])
        #expect(model.jobs.contains { $0.jobId == runner.job?.jobId })
        #expect(opener.urls.isEmpty)
        await runner.drainPendingWork()
        await model.signInFinished()

        #expect(runner.job?.status == .completed)
        #expect(runner.failure == nil)
        #expect(model.signingInProvider == nil)
    }

    @Test("a refused cancellation keeps the running sign-in recoverable")
    func refusedCancelPreservesTheURL() async throws {
        let harness = try SettingsHarness()
        let sentence = "The sign-in could not be cancelled."
        harness.gateway.v2Failures[.jobCancel] = ManagementRefusal.daemon(.unavailable, sentence)
        let runner = harness.model.makeJobRunner()
        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)

        await runner.cancelJob()

        #expect(runner.failure == sentence)
        #expect(runner.isRunning)
        #expect(runner.authorizationURL != nil)
        runner.dismiss()
    }

    @Test("a stale poll cannot resurrect a cancelled sign-in")
    func stalePollCannotResurrectCancelledSignIn() async throws {
        let harness = try SettingsHarness()
        let running = try ManagementValueFixture.job(kind: "auth", phase: "awaiting_browser")
        harness.gateway.jobScript = [running]
        let gate = PausedAuthenticationReply()
        harness.gateway.jobGate = { await gate.wait() }
        defer { gate.released = true }
        let runner = harness.model.makeJobRunner()
        runner.start(running, authorizeURL: URL(string: "https://auth.openai.com/authorize"))
        try await waitUntil { gate.entered }
        var observingPoll = false
        let draining = Task {
            observingPoll = true
            await runner.drainPendingWork()
        }
        try await waitUntil { observingPoll }

        await runner.cancelJob()
        #expect(runner.job?.status == .cancelled)
        gate.released = true
        await draining.value

        #expect(runner.job?.status == .cancelled)
        #expect(runner.authorizationURL == nil)
        #expect(harness.gateway.polledJobs.count == 1)
    }

    @Test("an immediately failed sign-in preserves its failure without polling or expired-link copy")
    func immediateFailureDoesNotPoll() async throws {
        let harness = try SettingsHarness()
        let sentence = "The browser callback port is unavailable."
        let failed = try ManagementValueFixture.job(
            kind: "auth", status: "failed", phase: nil,
            failure: (code: "unavailable", sentence: sentence)
        )
        let runner = harness.model.makeJobRunner()

        runner.start(failed)
        harness.model.reopenSignIn(on: runner)
        await runner.drainPendingWork()

        #expect(runner.job == failed)
        #expect(runner.failure == sentence)
        #expect(runner.browserFailure == nil)
        #expect(runner.authorizationURL == nil)
        #expect(harness.gateway.polledJobs.isEmpty)
    }

    // MARK: - ChatGPT's plan

    /// Manage usage is one of the app's three browser hops, to a fixed page of
    /// OpenAI's that carries no credential.
    @Test("Manage usage opens exactly ChatGPT's usage settings")
    func manageUsageOpensTheUsagePage() throws {
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: try SettingsFixture.gateway(), opener: opener)

        #expect(model.openChatGPTUsage() == nil)
        #expect(opener.urls.map(\.absoluteString) == ["https://chatgpt.com/settings/usage"])
    }

    /// A browser that does not open is said under the button rather than
    /// swallowed, in the same words a sign-in's tab uses.
    @Test("Manage usage answers a sentence when the browser could not open")
    func manageUsageStatesARefusedBrowser() throws {
        let opener = RecordingExternalOpener(succeeds: false)
        let model = SettingsFixture.model(gateway: try SettingsFixture.gateway(), opener: opener)

        #expect(model.openChatGPTUsage() == ProductStrings[.providerSignInOpenFailed])
        #expect(opener.urls.count == 1, "the open was asked for once")
    }

    /// What the sheet does as each job ends. Only a completed sign-in that
    /// ends on the notice keeps the sheet; a cancelled one closes it as it
    /// always did, and a failed one keeps its sentence for a person to read.
    @Test("the sign-in sheet's phase follows the job it follows")
    func signInSheetPhases() {
        let endings: [(ManagementJobStatus?, Bool, SignInSheetPhase)] = [
            (.completed, true, .planNotice),
            (.completed, false, .closed),
            (.cancelled, true, .closed),
            (.cancelled, false, .closed),
            (.running, true, .waiting),
            (.failed, true, .waiting),
            (.failed, false, .waiting),
            (.timedOut, true, .waiting),
            (.unrecognized("paused"), true, .waiting),
            (nil, true, .waiting)
        ]

        for (status, notice, phase) in endings {
            #expect(
                SignInSheetPhase(status: status, showsPlanNotice: notice) == phase,
                "\(String(describing: status)), notice \(notice)"
            )
        }
    }

    /// The one decision both sheets read: a completed ChatGPT sign-in ends on
    /// OpenAI's notice, whose Manage usage opens the usage page, and a
    /// completed SpaceXAI one closes the sheet as before.
    @Test("a completed ChatGPT sign-in ends on the plan notice, and a SpaceXAI one closes")
    func onlyChatGPTEndsOnThePlanNotice() async throws {
        let opener = RecordingExternalOpener()
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway, opener: opener)

        for (provider, ending) in [("openai_codex", SignInSheetPhase.planNotice), ("xai", .closed)] {
            gateway.jobScript = [try ManagementValueFixture.job(kind: "auth", status: "completed", phase: nil)]
            let runner = model.makeJobRunner()
            #expect(await model.startSignIn(provider: provider, on: runner) == nil)
            await runner.drainPendingWork()

            let usage = model.manageUsage(after: provider)
            #expect(runner.job?.status == .completed)
            #expect(SignInSheetPhase(status: runner.job?.status, showsPlanNotice: usage != nil) == ending, "\(provider)")
            await model.signInFinished()
        }

        #expect(model.manageUsage(after: "anthropic") == nil)
        let usage = try #require(model.manageUsage(after: "openai_codex"))
        let browserHops = opener.urls.count
        #expect(usage() == nil)
        #expect(opener.urls.dropFirst(browserHops).map(\.absoluteString) == ["https://chatgpt.com/settings/usage"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }

        try #require(condition(), "the controlled poll did not reach its expected suspension")
    }

    @Test("repeated browser and import clicks keep the first pending sign-in", arguments: [false, true])
    func repeatedClicksKeepFirstSignIn(importing: Bool) async throws {
        let harness = try SettingsHarness()
        let gate = PausedAuthenticationReply()
        let pollGate = PausedAuthenticationReply()
        harness.gateway.authStartGate = { await gate.wait() }
        harness.gateway.jobGate = { await pollGate.wait() }
        harness.gateway.jobScript = [try ManagementValueFixture.job(kind: importing ? "auth_import" : "auth")]
        let runner = harness.model.makeJobRunner()
        defer {
            gate.released = true
            pollGate.released = true
            runner.dismiss()
        }
        let provider = importing ? "anthropic" : "openai_codex"
        let first = Task {
            guard importing else { return await harness.model.startSignIn(provider: provider, on: runner) }
            return await harness.model.startAuthImport(source: .claudeCode, provider: provider, on: runner)
        }
        try await waitUntil { gate.entered }
        #expect(harness.model.startingSignIn)
        let busy = ManagementRefusal.daemon(.unavailable, "A sign-in is already starting.")
        harness.gateway.v2Failures[.authStart] = busy
        harness.gateway.v2Failures[.authImportStart] = busy

        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(await harness.model.startAuthImport(source: .claudeCode, provider: "anthropic", on: runner) == nil)
        gate.released = true
        #expect(await first.value == nil)
        #expect(!harness.model.startingSignIn)
        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(await harness.model.startAuthImport(source: .claudeCode, provider: "anthropic", on: runner) == nil)

        #expect(harness.gateway.calls.filter { $0 == .v2(.authStart) || $0 == .v2(.authImportStart) }.count == 1)
        #expect(runner.failure == nil)
        #expect(runner.isRunning)
        #expect(runner.job?.kind == (importing ? .authImport : .auth))
        #expect(harness.model.signingInProvider == provider)
        #expect((runner.authorizationURL != nil) == !importing)
    }
}

@MainActor
private final class PausedAuthenticationReply {
    var entered = false
    var released = false

    func wait() async {
        entered = true
        for _ in 0..<10_000 {
            if released { return }
            await Task.yield()
        }

        Issue.record("the controlled poll response was not released")
    }
}
