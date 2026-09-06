import Foundation
import Testing

@testable import FermixAppCore

@Suite("Provider authentication feedback")
@MainActor
struct ProviderAuthenticationTests {
    @Test("a refused credential import is visible on the shared runner")
    func refusedImportIsVisible() async throws {
        let harness = try SettingsHarness()
        let sentence = "The Codex sign-in on this Mac could not be read."
        harness.gateway.v2Failures[.authImportStart] = ManagementRefusal.daemon(.unavailable, sentence)
        let runner = harness.model.makeJobRunner()

        let refusal = await harness.model.startAuthImport(source: .codexCLI, provider: "openai_codex", on: runner)

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

    @Test("reopening a browser reuses the active URL without another auth job")
    func reopeningReusesTheURL() async throws {
        let gateway = try SettingsFixture.gateway()
        let opener = RecordingExternalOpener()
        let model = SettingsFixture.model(gateway: gateway, opener: opener)
        let runner = model.makeJobRunner()

        #expect(await model.startSignIn(provider: "openai_codex", on: runner) == nil)
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

    @Test("a failed import reports its sentence and permits a browser fallback")
    func failedImportCanUseBrowser() async throws {
        let harness = try SettingsHarness()
        let sentence = "The imported credential has expired."
        harness.gateway.jobScript = [try ManagementValueFixture.job(
            kind: "auth_import", status: "failed", phase: nil,
            failure: (code: "unavailable", sentence: sentence)
        )]
        let runner = harness.model.makeJobRunner()
        #expect(await harness.model.startAuthImport(source: .codexCLI, provider: "openai_codex", on: runner) == nil)
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
        let first = Task {
            guard importing else { return await harness.model.startSignIn(provider: "openai_codex", on: runner) }
            return await harness.model.startAuthImport(source: .codexCLI, provider: "openai_codex", on: runner)
        }
        try await waitUntil { gate.entered }
        #expect(harness.model.startingSignIn)
        let busy = ManagementRefusal.daemon(.unavailable, "A sign-in is already starting.")
        harness.gateway.v2Failures[.authStart] = busy
        harness.gateway.v2Failures[.authImportStart] = busy

        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(await harness.model.startAuthImport(source: .codexCLI, provider: "openai_codex", on: runner) == nil)
        gate.released = true
        #expect(await first.value == nil)
        #expect(!harness.model.startingSignIn)
        #expect(await harness.model.startSignIn(provider: "openai_codex", on: runner) == nil)
        #expect(await harness.model.startAuthImport(source: .codexCLI, provider: "openai_codex", on: runner) == nil)

        #expect(harness.gateway.calls.filter { $0 == .v2(.authStart) || $0 == .v2(.authImportStart) }.count == 1)
        #expect(runner.failure == nil)
        #expect(runner.isRunning)
        #expect(runner.job?.kind == (importing ? .authImport : .auth))
        #expect(harness.model.signingInProvider == "openai_codex")
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
