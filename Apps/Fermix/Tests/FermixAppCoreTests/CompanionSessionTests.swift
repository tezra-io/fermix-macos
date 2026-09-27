import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents

/// A session over the real adapter on a fake line socket, with a clock the case
/// drives and message ids it can name.
@MainActor
private struct Harness {
    nonisolated static let path = "/tmp/fermix-test/companion.sock"

    let socket = FakeCompanionSocket()
    let scheduler = ManualDeadlineScheduler()
    let session: CompanionSession

    init(socketPath: @escaping () throws -> String = { Harness.path }) {
        var issued = 0
        session = CompanionSession(
            transport: CompanionSocketClient(lines: socket),
            socketPath: socketPath,
            deadlines: scheduler,
            messageIds: {
                issued += 1
                return "mac-\(issued)"
            }
        )
    }

    var model: CompanionModel { session.model }

    /// Connects and completes the handshake.
    func connected() {
        session.connect()
        socket.deliver(E.hello())
    }

    func sent() throws -> [NSDictionary] {
        try socket.sentObjects()
    }
}

private func wire(_ events: CompanionClientEvent...) throws -> [NSDictionary] {
    try events.map(wireObject(companion:))
}

private let hello = CompanionClientEvent.clientHello(protocolVersion: CompanionProtocol.version)

private enum HomeUnreadable: Error {
    case malformed
}

/// The connection's lifetime: the handshake and its deadline, both version
/// directions, the missing socket, the bounded reconnect, and every request
/// crossing the wire only once the daemon has said hello.
@Suite("Companion session")
@MainActor
struct CompanionSessionTests {
    // MARK: - The handshake

    @Test("connecting sends exactly one client hello and waits for the daemon")
    func sendsClientHello() throws {
        let harness = Harness()

        harness.session.connect()

        #expect(harness.socket.connectedPaths == [Harness.path])
        #expect(try harness.sent() == wire(hello))
        #expect(harness.model.connection == .connecting)
        #expect(harness.scheduler.scheduledDelays == [CompanionProtocol.handshakeTimeout])
    }

    @Test("a server hello inside the window connects, cancels the deadline and asks for the newest page")
    func negotiatesAndPullsTheNewestPage() throws {
        let harness = Harness()

        harness.connected()

        #expect(harness.model.connection == .connected)
        #expect(harness.scheduler.liveCount == 0)
        #expect(try harness.sent() == wire(hello, newestPagePull))
    }

    @Test("asking again while connected changes nothing")
    func connectIsIdempotent() {
        let harness = Harness()
        harness.connected()

        harness.session.connect()

        #expect(harness.socket.connectedPaths.count == 1)
        #expect(harness.model.connection == .connected)
    }

    @Test("a daemon that never says hello is dropped at the deadline and tried again")
    func handshakeDeadline() throws {
        let harness = Harness()
        harness.session.connect()

        harness.scheduler.fireAll()

        #expect(harness.model.connection == .disconnected(ProductStrings[.companionConnectionReconnecting]))
        #expect(harness.socket.closeCount == 1)
        #expect(harness.scheduler.scheduledDelays == [CompanionSession.reconnectDelays[0]])

        harness.scheduler.fireAll()

        #expect(harness.socket.connectedPaths.count == 2)
        #expect(try harness.sent() == wire(hello, hello))
    }

    /// The daemon's window starts above this build's version: this app is the
    /// side out of date.
    @Test("a daemon whose window is above this build refuses and says to update the app")
    func windowAboveThisBuild() {
        let harness = Harness()
        harness.session.connect()

        harness.socket.deliver(E.hello(2, 3))

        #expect(harness.model.connection == .refused(ProductStrings[.companionConnectionUpdateApp]))
        #expect(harness.socket.closeCount == 1)
        #expect(harness.scheduler.liveCount == 0)
    }

    @Test("a daemon whose window is below this build refuses and says to update the engine")
    func windowBelowThisBuild() {
        let harness = Harness()
        harness.session.connect()

        harness.socket.deliver(E.hello(0, 0))

        #expect(harness.model.connection == .refused(ProductStrings[.companionConnectionUpdateEngine]))
        #expect(harness.scheduler.liveCount == 0)
    }

    @Test("the daemon's own version refusal names the side to update, in both directions")
    func daemonVersionRefusals() {
        let tooNew = Harness()
        tooNew.session.connect()
        tooNew.socket.deliver(
            E.refusal("unsupported_protocol_version", direction: .clientTooNew, window: .init(minimum: 0, maximum: 0))
        )

        let tooOld = Harness()
        tooOld.session.connect()
        tooOld.socket.deliver(
            E.refusal("unsupported_protocol_version", direction: .clientTooOld, window: .init(minimum: 2, maximum: 2))
        )

        #expect(tooNew.model.connection == .refused(ProductStrings[.companionConnectionUpdateEngine]))
        #expect(tooOld.model.connection == .refused(ProductStrings[.companionConnectionUpdateApp]))
        #expect(tooNew.scheduler.liveCount == 0)
        #expect(tooOld.scheduler.liveCount == 0)
    }

    /// Four connections is the daemon's limit, and one may close: this refusal
    /// is not the version's, so it is tried again.
    @Test("any other refusal during the handshake is shown in the daemon's words and tried again")
    func otherHandshakeRefusal() {
        let harness = Harness()
        harness.session.connect()

        harness.socket.deliver(E.refusal("max_clients_reached"))

        #expect(harness.model.connection == .disconnected("The daemon reported: max_clients_reached"))
        #expect(harness.scheduler.scheduledDelays == [CompanionSession.reconnectDelays[0]])
    }

    @Test("asking again after a version refusal tries once more")
    func connectAfterRefusal() {
        let harness = Harness()
        harness.session.connect()
        harness.socket.deliver(E.hello(2, 2))

        harness.session.connect()
        harness.socket.deliver(E.hello())

        #expect(harness.socket.connectedPaths.count == 2)
        #expect(harness.model.connection == .connected)
    }

    // MARK: - No socket

    /// The pinned engine serves no companion socket at all, which is its own
    /// state rather than a connection that failed.
    @Test("a missing socket means the engine has no chat, and the session keeps looking")
    func missingSocket() throws {
        let harness = Harness()
        harness.socket.connectResult = .failure(.system(errno: ENOENT))

        harness.session.connect()

        #expect(harness.model.connection == .engineHasNoChat)
        #expect(harness.model.connection.sentence == ProductStrings[.companionConnectionEngineHasNoChat])
        #expect(harness.socket.sent.isEmpty)
        #expect(harness.scheduler.scheduledDelays == [CompanionSession.reconnectDelays[0]])

        harness.socket.connectResult = .success(())
        harness.scheduler.fireAll()
        harness.socket.deliver(E.hello())

        #expect(harness.model.connection == .connected)
    }

    @Test("a refused connect is a failure to reach the daemon, not a missing engine")
    func refusedConnect() {
        let harness = Harness()
        harness.socket.connectResult = .failure(.system(errno: ECONNREFUSED))

        harness.session.connect()

        #expect(harness.model.connection == .disconnected(ProductStrings[.companionConnectionReconnecting]))
    }

    @Test("an unreadable home is said, and tried again")
    func unreadableHome() {
        let harness = Harness(socketPath: { throw HomeUnreadable.malformed })

        harness.session.connect()

        #expect(harness.model.connection == .disconnected(ProductStrings[.companionConnectionHomeUnavailable]))
        #expect(harness.socket.connectedPaths.isEmpty)
        #expect(harness.scheduler.liveCount == 1)
    }

    // MARK: - Reconnecting

    @Test("consecutive failures back off to a bound, and a handshake starts the sequence again")
    func boundedBackoff() {
        let harness = Harness()
        harness.socket.connectResult = .failure(.system(errno: ECONNREFUSED))
        harness.session.connect()

        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            delays += harness.scheduler.scheduledDelays
            harness.scheduler.fireAll()
        }

        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])

        harness.socket.connectResult = .success(())
        harness.scheduler.fireAll()
        harness.socket.deliver(E.hello())
        harness.socket.fail(.peerClosed)

        #expect(harness.scheduler.scheduledDelays == [1])
    }

    @Test("a lost connection drops the draft and reconnects with the catch-up read")
    func lostConnectionReconnects() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.backward([10, 11, 12], head: 12))
        harness.socket.deliver(.textDelta(turnId: "turn-1", text: "Partial"))
        #expect(harness.model.turn != nil)

        harness.socket.fail(.peerClosed)

        #expect(harness.model.connection == .disconnected(ProductStrings[.companionConnectionReconnecting]))
        #expect(harness.model.turn == nil)
        #expect(harness.model.rows.map(\.serverSeq) == [10, 11, 12])

        harness.scheduler.fireAll()
        harness.socket.deliver(E.hello())

        #expect(try harness.sent() == wire(hello, newestPagePull, hello, historyPull(.after(seq: 12))))
    }

    // MARK: - The outbox

    @Test("a message sent before the handshake waits for it, then goes after the catch-up read")
    func messageWaitsForTheHandshake() throws {
        let harness = Harness()
        harness.session.connect()

        harness.session.send("Hello")

        #expect(try harness.sent() == wire(hello))
        #expect(harness.model.pending.map(\.clientMsgId) == ["mac-1"])

        harness.socket.deliver(E.hello())

        #expect(
            try harness.sent()
                == wire(hello, newestPagePull, .msg(clientMsgId: "mac-1", profileId: "main", text: "Hello"))
        )
    }

    @Test("every unaccepted message is resent after a reconnect and cleared by accepted, duplicate or not")
    func outboxResendsAfterReconnect() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.backward([10, 11, 12], head: 12))
        harness.session.send("First")
        harness.session.send("Second")
        let first = CompanionClientEvent.msg(clientMsgId: "mac-1", profileId: "main", text: "First")
        let second = CompanionClientEvent.msg(clientMsgId: "mac-2", profileId: "main", text: "Second")

        harness.socket.fail(.peerClosed)
        harness.scheduler.fireAll()
        harness.socket.deliver(E.hello())

        #expect(
            try harness.sent()
                == wire(hello, newestPagePull, first, second, hello, historyPull(.after(seq: 12)), first, second)
        )
        #expect(harness.model.pending.map(\.clientMsgId) == ["mac-1", "mac-2"])

        harness.socket.deliver(E.accepted("mac-1", duplicate: true, serverSeq: 13))
        #expect(harness.model.pending.map(\.clientMsgId) == ["mac-2"])

        harness.socket.deliver(E.accepted("mac-2", duplicate: false))
        #expect(harness.model.pending.isEmpty)
    }

    @Test("cancel sends the request's client message id")
    func cancelSendsTheId() throws {
        let harness = Harness()
        harness.connected()
        harness.session.send("Plan my week")
        harness.socket.deliver(E.accepted("mac-1", duplicate: false))

        harness.session.cancel(clientMsgId: "mac-1")

        #expect(try harness.sent().last == wireObject(companion: .cancel(profileId: "main", clientMsgId: "mac-1")))
    }

    @Test("an approval's answer is its route, sent as a command through the outbox")
    func answerApproval() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.approval("sandbox-1"))

        harness.session.answerApproval("sandbox-1", approve: true)

        #expect(
            try harness.sent().last
                == wireObject(
                    companion: .command(clientMsgId: "mac-1", profileId: "main", name: "confirm", args: "opaque-token")
                )
        )
        #expect(harness.model.pending.map(\.clientMsgId) == ["mac-1"])

        harness.socket.deliver(.approvalResolved(approvalId: "sandbox-1", outcome: .approved))
        #expect(harness.model.approvals.isEmpty)
    }

    // MARK: - Reads

    @Test("older rows are refused while a pull is out, then pulled below the oldest row")
    func pullOlderWaitsForThePullOut() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.backward([8, 9, 10], head: 10, older: 8))
        #expect(harness.model.hasOlder)
        harness.socket.deliver(E.row(12))

        harness.session.pullOlder()
        #expect(try harness.sent() == wire(hello, newestPagePull, historyPull(.after(seq: 10))))

        harness.socket.deliver(E.forward([11, 12], head: 12, next: 12))
        harness.session.pullOlder()

        #expect(try harness.sent().last == wireObject(companion: historyPull(.before(seq: 8))))
    }

    @Test("a search is sent with the contract's limit, answered, and cleared")
    func searchAndClear() throws {
        let harness = Harness()
        harness.connected()

        harness.session.search("dentist")
        #expect(
            try harness.sent().last
                == wireObject(
                    companion: .historySearch(profileId: "main", query: "dentist", limit: 50, beforeSeq: nil)
                )
        )

        harness.socket.deliver(E.results("dentist", seqs: [88], older: 88))
        #expect(harness.model.search?.hits == [E.hit(88)])
        #expect(harness.model.search?.nextBeforeSeq == 88)

        harness.session.clearSearch()
        #expect(harness.model.search == nil)
    }

    @Test("reads are not asked of a daemon that is not connected")
    func readsNeedAConnection() {
        let harness = Harness()
        harness.session.connect()

        harness.session.search("dentist")
        harness.session.pullOlder()
        harness.session.newestRowSeen()

        #expect(harness.socket.sent.count == 1)
        #expect(harness.model.search == nil)
    }

    @Test("the read frontier is sent once per newest row")
    func readStateOncePerRow() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.backward([10, 11, 12], head: 12))

        harness.session.newestRowSeen()
        harness.session.newestRowSeen()
        harness.socket.deliver(E.row(13))
        harness.session.newestRowSeen()

        let reads = try harness.sent().filter { $0["type"] as? String == "read_state" }
        #expect(
            reads == (try wire(
                .readState(profileId: "main", readUpToSeq: 12),
                .readState(profileId: "main", readUpToSeq: 13)
            ))
        )
    }

    // MARK: - Routing

    @Test("a live row reaches the model, and a gap is pulled rather than shown")
    func liveRowsReachTheModel() throws {
        let harness = Harness()
        harness.connected()
        harness.socket.deliver(E.backward([10, 11, 12], head: 12))

        harness.socket.deliver(E.row(13))
        harness.socket.deliver(E.row(15))

        #expect(harness.model.rows.map(\.serverSeq) == [10, 11, 12, 13])
        #expect(harness.model.cursor == 13)
        #expect(harness.model.historyHeadSeq == 12)
        #expect(try harness.sent().last == wireObject(companion: historyPull(.after(seq: 13))))
    }

    @Test("a turn error reaches the model as a sentence")
    func turnErrorReachesTheModel() {
        let harness = Harness()
        harness.connected()

        harness.socket.deliver(.turnError(turnId: "turn-mac-3", code: "cancelled", message: "cancelled"))

        #expect(harness.model.lastError == ProductStrings[.companionErrorReplyStopped])
    }

    @Test("events before the handshake and unknown events change nothing")
    func ignoredEvents() {
        let harness = Harness()
        harness.session.connect()

        harness.socket.deliver(E.row(1))
        harness.socket.deliver(E.hello())
        harness.socket.deliver(.unrecognized(type: "reaction"))
        harness.socket.deliver(E.hello(2, 2))

        #expect(harness.model.rows.isEmpty)
        #expect(harness.model.connection == .connected)
    }
}
