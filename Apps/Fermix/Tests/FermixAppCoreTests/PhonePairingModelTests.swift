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

        model.closed()
        await model.settle()

        #expect(gateway.cancelledPairings == [Self.session])
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
        gateway.pairingStartGate = { await gate.wait() }

        model.present(.pair)
        await Task.yield()
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
        let gateway = try SettingsFixture.gateway()

        return (PhonePairingModel(gateway: gateway, sleeper: LimitedSleeper(allowing: polls)), gateway)
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
