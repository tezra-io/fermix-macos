import Foundation
import Testing

@testable import FermixAppCore

/// The chat wire's adapter over the line socket: which lane a line takes, and
/// what a real socket hands up.
@Suite("CompanionSocketClient", .serialized)
struct CompanionSocketClientTests {
    private func connect(_ client: CompanionSocketClient, to path: String) throws {
        let connected = TestSignal()
        let outcome = ValueBox<Result<Void, LineSocketConnectFailure>>()
        client.connect(path: path) { result in
            outcome.set(result)
            connected.fire()
        }

        #expect(connected.wait(timeout: 3.0), "connect never completed")
        if case .failure(let failure)? = outcome.value {
            Issue.record("connect failed: \(failure)")
        }
    }

    @Test("every event is a line that must arrive, and none is droppable")
    func everyEventMustArrive() throws {
        let socket = FakeCompanionSocket()
        let client = CompanionSocketClient(lines: socket)
        let events: [CompanionClientEvent] = [
            .clientHello(protocolVersion: CompanionProtocol.version),
            .msg(clientMsgId: "mac-1", profileId: CompanionProtocol.profileId, text: "Hello"),
            .historyPull(profileId: CompanionProtocol.profileId, cursor: .after(seq: 12), limit: 200)
        ]

        events.forEach(client.send)

        #expect(try socket.sentObjects() == events.map(wireObject(companion:)))
        #expect(socket.sentDroppable.isEmpty)
    }

    @Test("an incoming line fires onEvent as a typed event")
    func incomingLineFiresOnEvent() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = CompanionSocketClient(lines: CompanionSocketClient.lineSocket())
        let box = ValueBox<CompanionServerEvent>()
        let received = TestSignal()
        client.onEvent = { event in
            box.set(event)
            received.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        server.writeToClient(Data(#"{"type":"server_hello","min_version":1,"max_version":1}"#.utf8) + Data([0x0A]))
        #expect(received.wait(timeout: 3.0), "onEvent never fired for an incoming line")

        #expect(box.value == .serverHello(minVersion: 1, maxVersion: 1))

        client.close()
    }

    /// A line that misses a field its type requires is a contract violation,
    /// not a line to skip: the connection ends and says which field.
    @Test("an undecodable line tears the connection down and names the field")
    func undecodableLineTearsDown() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = CompanionSocketClient(lines: CompanionSocketClient.lineSocket())
        let box = ValueBox<CompanionTransportFailure>()
        let closed = TestSignal()
        client.onFailure = { failure in
            box.set(failure)
            closed.fire()
        }

        try connect(client, to: server.path)
        #expect(server.waitForAccept(timeout: 2.0))

        server.writeToClient(Data(#"{"type":"text_delta","turn_id":"turn-1"}"#.utf8) + Data([0x0A]))
        #expect(closed.wait(timeout: 3.0), "onFailure never fired for an undecodable line")

        #expect(box.value == .undecodable(.missingField("text")))
    }
}
