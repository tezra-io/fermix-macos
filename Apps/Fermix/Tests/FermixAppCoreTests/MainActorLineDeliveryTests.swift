import Foundation
import Testing

@testable import FermixAppCore

/// The one hop from a line socket's queue to the main actor, which the voice
/// and companion wires share.
@Suite("Main-actor line delivery")
@MainActor
struct MainActorLineDeliveryTests {
    private typealias Lines = FakeLineSocketTransport<String, CompanionDecodeFailure>

    @Test("a message and a failure raised off the main thread arrive on it")
    func callbacksArriveOnTheMainThread() async {
        let lines = Lines()
        let delivery = MainActorLineDelivery(wrapping: lines)

        let message: (String, Bool) = await withCheckedContinuation { continuation in
            delivery.onMessage = { continuation.resume(returning: ($0, Thread.isMainThread)) }
            DispatchQueue.global().async { lines.deliver("server_hello") }
        }
        let failure: (LineSocketFailure<CompanionDecodeFailure>, Bool) = await withCheckedContinuation { continuation in
            delivery.onFailure = { continuation.resume(returning: ($0, Thread.isMainThread)) }
            DispatchQueue.global().async { lines.fail(.peerClosed) }
        }

        #expect(message.0 == "server_hello")
        #expect(message.1)
        #expect(failure.0 == .peerClosed)
        #expect(failure.1)
    }

    @Test("a connect outcome arrives on the main thread")
    func connectOutcomeArrivesOnTheMainThread() async {
        let lines = Lines()
        lines.connectResult = .failure(.system(errno: ENOENT))
        let delivery = MainActorLineDelivery(wrapping: lines)

        let outcome: (Result<Void, LineSocketConnectFailure>, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                delivery.connect(path: "/tmp/fermix-test/companion.sock") { result in
                    continuation.resume(returning: (result, Thread.isMainThread))
                }
            }
        }

        guard case .failure(let failure) = outcome.0 else {
            Issue.record("connect succeeded against a missing socket")
            return
        }
        #expect(failure == .system(errno: ENOENT))
        #expect(outcome.1)
    }

    @Test("every outbound line passes straight through")
    func outboundPassesThrough() {
        let lines = Lines()
        let delivery = MainActorLineDelivery(wrapping: lines)

        delivery.send(Data("reliable".utf8))
        delivery.sendDroppable(Data("droppable".utf8))
        delivery.sendDroppable(producing: { Data("produced".utf8) })
        delivery.close()

        #expect(lines.sent == [Data("reliable".utf8)])
        #expect(lines.sentDroppable == [Data("droppable".utf8), Data("produced".utf8)])
        #expect(lines.closeCount == 1)
    }
}
