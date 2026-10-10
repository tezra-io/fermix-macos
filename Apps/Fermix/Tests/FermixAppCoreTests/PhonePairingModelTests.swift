import Foundation
import Testing

@testable import FermixAppCore

/// The Phone sheet's session against the fixture daemon (M60 §3.4): when each
/// call is made, the window read once a second, and the cancel a closing
/// sheet sends.
///
/// No window is touched: the sheet's presentation is the model's own flag, and
/// what closing it does is the model's `closed`.
@Suite("Phone pairing model")
@MainActor
struct PhonePairingModelTests {
    static let session = PhonePairingTests.session

    @Test("pairing opens the window on the code, and a phone that scans it is compared")
    func opensAndFollows() async throws {
        let (model, gateway) = try Self.model(polls: 1)

        model.present(.pair)
        #expect(model.isPresented)
        await model.settle()

        guard case .compare(let compare) = model.step else {
            Issue.record("expected Compare, got \(model.step)")
            return
        }
        #expect(compare.digits == "481062")
        #expect(gateway.calls.filter { $0 == .v2(.mobilePairStart) }.count == 1)
        #expect(gateway.pairingReads == [Self.session], "one read a second, and one second has passed")
    }

    @Test("Scan stays on the code while the window waits for a scan")
    func scanWaits() async throws {
        let (model, gateway) = try Self.model(polls: 3)
        gateway.pairingSessionScript = [try PairingGolden.session("mobile_pair_get_awaiting_scan")]

        model.present(.pair)
        await model.settle()

        guard case .scan(let scan) = model.step else {
            Issue.record("expected Scan, got \(model.step)")
            return
        }
        #expect(scan.ttlMs == 112_000, "the countdown is the daemon's latest answer")
        #expect(gateway.pairingReads.count == 3)
    }

    @Test("Approve decides yes and ends on Paired, and Deny decides no")
    func decisions() async throws {
        let (approving, approvals) = try Self.model(polls: 1)
        approving.present(.pair)
        await approving.settle()
        approving.approve()
        await approving.settle()

        #expect(approvals.pairingDecisions == [PairingDecision(session: Self.session, approved: true)])
        #expect(approving.step == .paired(name: "Sam's phone"))
        #expect(!approving.isDeciding)

        let (denying, denials) = try Self.model(polls: 1)
        denials.pairingDecisionResult = try PairingGolden.session("mobile_pair_get_denied")
        denying.present(.pair)
        await denying.settle()
        denying.deny()
        await denying.settle()

        #expect(denials.pairingDecisions == [PairingDecision(session: Self.session, approved: false)])
        #expect(denying.step == .ended(PhoneEnding(sentence: "You denied this phone.", action: .pairAgain)))
    }

    // MARK: - Closing

    @Test("closing the sheet in Scan cancels the window")
    func closingScanCancels() async throws {
        let (model, gateway) = try Self.model(polls: 0)
        model.present(.pair)
        await model.settle()
        guard case .scan = model.step else {
            Issue.record("expected Scan, got \(model.step)")
            return
        }

        model.dismiss()
        model.closed()
        await model.settle()

        #expect(!model.isPresented)
        #expect(gateway.cancelledPairings == [Self.session])
        #expect(model.step == .waiting(session: nil), "the code leaves memory with the step")
    }

    @Test("closing the sheet in Compare cancels the window")
    func closingCompareCancels() async throws {
        let (model, gateway) = try Self.model(polls: 1)
        model.present(.pair)
        await model.settle()

        // The window closing takes the sheet with it, with no Cancel pressed.
        model.closed()
        await model.settle()

        #expect(gateway.cancelledPairings == [Self.session])
        #expect(!model.isPresented, "a sheet that left with its window is not put back up")
    }

    @Test("closing the sheet once the session has ended cancels nothing")
    func closingAfterTheEndCancelsNothing() async throws {
        let (paired, approvals) = try Self.model(polls: 1)
        paired.present(.pair)
        await paired.settle()
        paired.approve()
        await paired.settle()
        paired.closed()
        await paired.settle()

        #expect(approvals.cancelledPairings.isEmpty)

        let (expired, expiries) = try Self.model(polls: 1)
        expiries.pairingSessionScript = [try PairingGolden.session("mobile_pair_get_expired")]
        expired.present(.pair)
        await expired.settle()
        #expect(expired.step == .ended(PhoneEnding(sentence: ProductStrings[.phoneEndedExpired], action: .pairAgain)))

        expired.closed()
        await expired.settle()
        #expect(expiries.cancelledPairings.isEmpty)
    }

    /// A start that answers after the sheet closed opened a window nobody will
    /// see, so it is cancelled at once rather than left for two minutes.
    @Test("a window that opens after the sheet closed is cancelled at once")
    func lateStartIsCancelled() async throws {
        let (model, gateway) = try Self.model(polls: 0)
        let gate = AsyncGate()
        let opening = CountingBox()
        gateway.pairingStartGate = {
            opening.increment()
            await gate.wait()
        }

        model.present(.pair)
        while opening.count == 0 { await Task.yield() }
        model.closed()
        gate.release()
        await model.settle()

        #expect(gateway.cancelledPairings == [Self.session])
        #expect(model.step == .waiting(session: nil))
    }

    // MARK: - busy

    @Test("busy with a phone waiting elsewhere reads that window at once and compares it")
    func busyResumes() async throws {
        let (model, gateway) = try Self.model(polls: 0)
        gateway.v2Failures[.mobilePairStart] = try ManagementRefusal.published("busy_mobile_pair")

        model.present(.pair)
        await model.settle()

        guard case .compare(let compare) = model.step else {
            Issue.record("expected Compare, got \(model.step)")
            return
        }
        #expect(compare.session == Self.session)
        #expect(gateway.pairingReads == [Self.session], "the resumed window is read without waiting a second")
    }

    @Test("busy with a code waiting elsewhere starts over by cancelling it and opening a new one")
    func busyStartsOver() async throws {
        let (model, gateway) = try Self.model(polls: 0)
        gateway.v2Failures[.mobilePairStart] = try ManagementRefusal.published("busy_mobile_pair")
        gateway.mobileStatusResult = try PairingGolden.status { status in
            status["pairing"] = ["session_id": Self.session, "state": "awaiting_scan"]
        }

        model.present(.pair)
        await model.settle()
        #expect(model.step == .ended(PhoneEnding(
            sentence: ProductStrings[.phoneEndedElsewhere],
            action: .startOver(session: Self.session)
        )))
        #expect(gateway.cancelledPairings.isEmpty, "nothing is cancelled until Start over is pressed")

        gateway.v2Failures[.mobilePairStart] = nil
        model.takeEndingAction()
        await model.settle()

        #expect(gateway.cancelledPairings == [Self.session])
        guard case .scan = model.step else {
            Issue.record("expected Scan, got \(model.step)")
            return
        }
    }

    // MARK: - Refusals

    /// The daemon restarted under an open window: the session is not
    /// retained, and the sheet ends with the daemon's own message.
    @Test("a window the daemon no longer retains ends with its message")
    func unknownSessionEnds() async throws {
        let (model, gateway) = try Self.model(polls: 1)
        gateway.v2Failures[.mobilePairGet] = try ManagementRefusal.published("unknown_pairing_session")

        model.present(.pair)
        await model.settle()

        #expect(model.step == .ended(PhoneEnding(
            sentence: "The pairing session is not retained by this daemon.",
            action: .pairAgain
        )))
    }

    @Test("a start refused for a channel that is not running ends with the daemon's sentence")
    func refusedStart() async throws {
        let (model, gateway) = try Self.model(polls: 3)
        gateway.pairingStartResult = try PairingGolden.start("mobile_pair_start_channel_off")

        model.present(.pair)
        await model.settle()

        #expect(model.step == .ended(PhoneEnding(sentence: "The mobile channel is turned off.", action: .pairAgain)))
        #expect(gateway.pairingReads.isEmpty, "nothing was opened, so nothing is read")
    }

    @Test("an answer that fails a guard ends and cancels the window it left open")
    func guardCancels() async throws {
        let (model, gateway) = try Self.model(polls: 1)
        gateway.pairingSessionScript = [try PairingGolden.session("mobile_pair_get_awaiting_decision") { session in
            var request = session["request"] as? [String: Any] ?? [:]
            request["sas"] = "4810"
            session["request"] = request
        }]

        model.present(.pair)
        await model.settle()

        #expect(model.step == PhonePairingTests.unreadable)
        #expect(gateway.cancelledPairings == [Self.session])
    }

    // MARK: - Turn on

    @Test("a channel that is not running opens on Turn on, and opens no window")
    func notRunningOpensTurnOn() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status {
            $0["enabled"] = false
            $0["started"] = false
        }

        harness.model.present(.pair)
        await harness.model.settle()

        #expect(harness.model.step == .turnOn(PhoneTurnOn(throwsSwitch: true)))
        #expect(!harness.gateway.calls.contains(.v2(.mobilePairStart)))
    }

    /// Turn on throws the switch, takes the app's one restart, and opens the
    /// window on the channel that restart started.
    @Test("Turn on and restart Fermix writes the switch, restarts, and opens the window")
    func turnOnWritesRestartsAndOpens() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status {
            $0["enabled"] = false
            $0["started"] = false
        }
        harness.restarter.restarted = { harness.gateway.mobileStatusResult = nil }
        harness.model.present(.pair)
        await harness.model.settle()

        harness.model.turnOn()
        await harness.model.settle()

        #expect(harness.gateway.appliedSettings == [
            SettingsWrite(section: PhoneChannel.section, values: [PhoneChannel.switchKey: .flag(true)])
        ])
        #expect(harness.restarter.restarts == 1)
        guard case .scan = harness.model.step else {
            Issue.record("expected Scan, got \(harness.model.step)")
            return
        }
        #expect(harness.model.row.status == "Sam's phone", "the row follows the restart")
    }

    @Test("Restart Fermix restarts without writing the switch it already has")
    func restartOnly() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status { $0["started"] = false }
        harness.restarter.restarted = { harness.gateway.mobileStatusResult = nil }
        harness.model.present(.pair)
        await harness.model.settle()
        #expect(harness.model.step == .turnOn(PhoneTurnOn(throwsSwitch: false)))

        harness.model.turnOn()
        await harness.model.settle()

        #expect(harness.gateway.appliedSettings.isEmpty)
        #expect(harness.restarter.restarts == 1)
        guard case .scan = harness.model.step else {
            Issue.record("expected Scan, got \(harness.model.step)")
            return
        }
    }

    @Test("a refused restart stays on Turn on in its own words, with the switch already thrown")
    func refusedRestartStays() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status {
            $0["enabled"] = false
            $0["started"] = false
        }
        harness.restarter.refusal = ProductStrings[.lifecycleServiceBusy]
        harness.model.present(.pair)
        await harness.model.settle()

        harness.model.turnOn()
        await harness.model.settle()

        #expect(harness.model.step == .turnOn(PhoneTurnOn(throwsSwitch: false, refusal: ProductStrings[.lifecycleServiceBusy])))
        #expect(!harness.gateway.calls.contains(.v2(.mobilePairStart)))
    }

    @Test("a refused switch stays on Turn on with the daemon's sentence, and restarts nothing")
    func refusedSwitchStays() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status {
            $0["enabled"] = false
            $0["started"] = false
        }
        harness.gateway.v2Failures[.settingsApply] = try ManagementRefusal.published("unavailable_owner_decision")
        harness.model.present(.pair)
        await harness.model.settle()

        harness.model.turnOn()
        await harness.model.settle()

        #expect(harness.model.step == .turnOn(PhoneTurnOn(
            throwsSwitch: true,
            refusal: "Only the owner can pair or forget a phone; run this from your own terminal."
        )))
        #expect(harness.restarter.restarts == 0)
    }

    /// The window is asked for whatever the restart did, so a channel that
    /// still could not start says why in the daemon's sentence rather than
    /// asking for a second restart.
    @Test("after the restart a channel that still cannot start ends with the daemon's sentence")
    func stillNotStarted() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.gateway.mobileStatusResult = try PairingGolden.status { $0["started"] = false }
        let sentence = "The mobile channel could not start this boot. See the daemon log."
        harness.gateway.pairingStartResult = try PairingGolden.start("mobile_pair_start_channel_off") {
            $0["failure"] = ["code": "refused", "sentence": sentence]
        }
        harness.model.present(.pair)
        await harness.model.settle()

        harness.model.turnOn()
        await harness.model.settle()

        #expect(harness.model.step == .ended(PhoneEnding(sentence: sentence, action: .pairAgain)))
    }

    // MARK: - Phones

    @Test("Change… opens the phones and reads them")
    func changeOpensThePhones() async throws {
        let harness = try PhoneHarness(polls: 0)

        harness.model.present(.phones)
        #expect(harness.model.step == .phones)
        await harness.model.settle()

        #expect(harness.model.devices.value?.devices.map(\.name) == ["Sam's phone"])
        #expect(!harness.gateway.calls.contains(.v2(.mobilePairStart)), "the phones open no window")
    }

    @Test("Done on Paired goes on to the phones, with the new phone read again")
    func pairedDoneShowsThePhones() async throws {
        let harness = try PhoneHarness(polls: 1)
        harness.model.present(.pair)
        await harness.model.settle()
        harness.model.approve()
        await harness.model.settle()
        let listsBefore = harness.gateway.calls.filter { $0 == .v2(.mobileDevicesList) }.count

        harness.model.showPhones()
        await harness.model.settle()

        #expect(harness.model.step == .phones)
        #expect(harness.gateway.calls.filter { $0 == .v2(.mobileDevicesList) }.count == listsBefore + 1)
    }

    @Test("Pair another phone opens a window from the phones")
    func pairAnother() async throws {
        let harness = try PhoneHarness(polls: 0)
        harness.model.present(.phones)
        await harness.model.settle()

        harness.model.pairAnother()
        await harness.model.settle()

        guard case .scan = harness.model.step else {
            Issue.record("expected Scan, got \(harness.model.step)")
            return
        }
    }

    /// Forget asks in the row, with no dialog over the sheet: the first press
    /// forgets nothing, Cancel takes the question back, and only the second
    /// press forgets the phone, which then leaves the list.
    @Test("Forget asks in the row, and only Forget this phone forgets it")
    func forgetTakesTwoPresses() async throws {
        let harness = try PhoneHarness(polls: 0)
        let device = "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"
        harness.model.present(.phones)
        await harness.model.settle()

        harness.model.askToForget(device)
        #expect(harness.model.forgetting.asking == device)
        harness.model.withdrawForget()
        harness.model.forget()
        await harness.model.settle()
        #expect(harness.gateway.revokedDevices.isEmpty, "a question taken back forgets nothing")

        harness.model.askToForget(device)
        harness.gateway.mobileDevicesResult = try PairingGolden.devices { $0["devices"] = [[String: Any]]() }
        harness.model.forget()
        await harness.model.settle()

        #expect(harness.gateway.revokedDevices == [device])
        #expect(harness.model.devices.value?.devices.isEmpty == true, "the forgotten phone leaves the list")
        #expect(harness.model.forgetting == PhoneForgetting())
    }

    @Test("a refused Forget stays under its row in the daemon's words")
    func refusedForget() async throws {
        let harness = try PhoneHarness(polls: 0)
        let device = "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"
        harness.gateway.v2Failures[.mobileDevicesRevoke] = try ManagementRefusal.published("unavailable_owner_decision")
        harness.model.present(.phones)
        await harness.model.settle()

        harness.model.askToForget(device)
        harness.model.forget()
        await harness.model.settle()

        #expect(
            harness.model.forgetting.refusals[device]
                == "Only the owner can pair or forget a phone; run this from your own terminal."
        )
        #expect(harness.model.devices.value?.devices.count == 1)

        harness.model.closed()
        #expect(harness.model.forgetting == PhoneForgetting(), "a closed sheet asks nothing")
    }

    // MARK: - The row

    @Test("the row reads the channel and its phones")
    func rowReads() async throws {
        let (model, _) = try Self.model(polls: 0)
        #expect(model.row == .unanswered)

        await model.readRow()

        #expect(model.row.status == "Sam's phone")
        #expect(model.row.opens == .phones)
    }

    /// The channel starts only at boot, so a row already read is read again
    /// after a restart, and a row nobody has drawn is not read at all.
    @Test("a restart re-reads a row that has been read, and only one")
    func restartRereadsTheRow() async throws {
        let (model, gateway) = try Self.model(polls: 0)

        await model.restartCompleted()
        #expect(!gateway.calls.contains(.v2(.mobileStatus)))

        await model.readRow()
        gateway.mobileStatusResult = try PairingGolden.status { $0["paired_devices"] = 0 }
        await model.restartCompleted()

        #expect(model.row.status == ProductStrings[.phoneStatusNoPhone])
    }

    // MARK: - Helpers

    static func model(polls: Int) throws -> (PhonePairingModel, FakeDaemonGateway) {
        let harness = try PhoneHarness(polls: polls)

        return (harness.model, harness.gateway)
    }
}

/// One phone model over the fixture daemon, with the settings model it hangs
/// off and the restart it takes. The settings model is held here because the
/// phone model only borrows it, as it does in the app.
@MainActor
struct PhoneHarness {
    let gateway: FakeDaemonGateway
    let settings: SettingsModel
    let model: PhonePairingModel
    let restarter = PhoneRestarter()

    init(polls: Int) throws {
        gateway = try SettingsFixture.gateway()
        settings = SettingsFixture.model(gateway: gateway)
        model = PhonePairingModel(settings: settings, sleeper: LimitedSleeper(allowing: polls))
        model.restarter = restarter
        PhoneHarness.retained.append(settings)
    }

    /// Every settings model a case built, kept for the length of the run: the
    /// phone model's reference to it is unowned, as in the app, where the
    /// settings model owns the phone model.
    static var retained: [SettingsModel] = []
}

/// The app's restart, recorded. A restart that works starts the channel as
/// its switch says, which is what the daemon does at boot.
@MainActor
final class PhoneRestarter: DaemonRestarting {
    private(set) var restarts = 0
    /// The sentence a refusal answers with, or nil where the restart worked.
    var refusal: String?
    /// What the restart changes about the daemon, run when it works.
    var restarted: () -> Void = {}

    func restartDaemonAwaitingCompletion() async -> String? {
        restarts += 1
        guard refusal == nil else { return refusal }

        restarted()
        return nil
    }
}

/// Lets a set number of polls wait and ends the next, the way a cancelled
/// task's sleep ends: a case walks a window a known number of reads and then
/// reads what the sheet shows.
final class LimitedSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(allowing polls: Int) {
        remaining = polls
    }

    func sleep(seconds: TimeInterval) async throws {
        try lock.withLock {
            guard remaining > 0 else { throw CancellationError() }

            remaining -= 1
        }
    }
}
