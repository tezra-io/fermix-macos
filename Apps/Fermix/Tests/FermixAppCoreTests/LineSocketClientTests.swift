import Darwin
import Foundation
import Testing

@testable import FermixAppCore

/// Why the text wire refuses a line. It carries the line, so a case can prove a
/// refusal is the decoder's own and not the transport's.
enum TextLineRefusal: Error, Equatable, Sendable {
    case refused(String)
}

/// The line socket against a real AF_UNIX peer, owned by a wire that knows
/// nothing but text: what any owner gets from it, whatever its lines carry.
/// The realtime suite drives the same client through the voice adapter,
/// including both write deadlines.
@Suite("LineSocketClient", .serialized)
struct LineSocketClientTests {
    private typealias TextSocket = LineSocketClient<String, TextLineRefusal>

    /// Lines starting with "!" are refused by the decoder.
    private func textSocket() -> TextSocket {
        LineSocketClient(
            name: "text",
            log: AppLog.logger(.app),
            inbound: LineInboundLimits(maximumLineBytes: 64, maximumBufferedBytes: 256),
            outbound: LineOutboundLimits(flushDeadline: 5, maximumPendingDroppableLines: 4, stallDeadline: 8),
            decode: { line throws(TextLineRefusal) in
                let text = String(decoding: line, as: UTF8.self)
                guard !text.hasPrefix("!") else { throw .refused(text) }
                return text
            }
        )
    }

    private func outcome(connecting client: TextSocket, to path: String) -> Result<Void, LineSocketConnectFailure>? {
        let finished = TestSignal()
        let outcome = ValueBox<Result<Void, LineSocketConnectFailure>>()
        client.connect(path: path) { result in
            outcome.set(result)
            finished.fire()
        }

        #expect(finished.wait(timeout: 3.0), "connect never reported an outcome")
        return outcome.value
    }

    private func connect(_ client: TextSocket, to server: UnixSocketTestServer) {
        if case .failure(let failure)? = outcome(connecting: client, to: server.path) {
            Issue.record("connect failed: \(failure)")
        }
        #expect(server.waitForAccept(timeout: 2.0))
    }

    /// Records messages and the one failure, both of which arrive on the
    /// socket's queue.
    private final class Recorder: @unchecked Sendable {
        let messages = ValueBox<[String]>()
        let failure = ValueBox<LineSocketFailure<TextLineRefusal>>()
        let failed = TestSignal()

        func attach(to client: TextSocket, firing arrived: TestSignal? = nil, after count: Int = 0) {
            client.onMessage = { [self] message in
                let received = (messages.value ?? []) + [message]
                messages.set(received)
                if received.count == count { arrived?.fire() }
            }
            client.onFailure = { [self] failure in
                self.failure.set(failure)
                failed.fire()
            }
        }
    }

    @Test("a sent line reaches the peer with exactly one newline")
    func sentLineIsFramed() throws {
        let server = try UnixSocketTestServer(drainReads: true)
        defer { server.shutdown() }

        let client = textSocket()
        connect(client, to: server)

        client.send(Data("hello".utf8))

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, server.receivedData().count < 6 {
            usleep(5_000)
        }
        #expect(server.receivedData() == Data("hello\n".utf8))

        client.close()
    }

    /// Framing is the transport's: the owner sees whole lines, in order, no
    /// matter where the reads fell, and an empty line carries nothing.
    @Test("lines arrive decoded and in order however the reads split them")
    func linesArriveInOrder() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = textSocket()
        let recorder = Recorder()
        let arrived = TestSignal()
        recorder.attach(to: client, firing: arrived, after: 3)
        connect(client, to: server)

        server.writeToClient(Data("alpha\nbe".utf8))
        server.writeToClient(Data("ta\n\ngamma\n".utf8))

        #expect(arrived.wait(timeout: 3.0), "three lines never arrived")
        #expect(recorder.messages.value == ["alpha", "beta", "gamma"])

        client.close()
    }

    /// A line the owner cannot decode is a contract violation, not a line to
    /// skip: the lines before it were delivered, nothing after it is.
    @Test("a line the decoder refuses ends the connection with the decoder's reason")
    func undecodableLineEndsTheConnection() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = textSocket()
        let recorder = Recorder()
        recorder.attach(to: client)
        connect(client, to: server)

        server.writeToClient(Data("one\n!two\nthree\n".utf8))

        #expect(recorder.failed.wait(timeout: 3.0), "a refused line never ended the connection")
        #expect(recorder.failure.value == .undecodable(.refused("!two")))
        #expect(recorder.messages.value == ["one"])

        client.close()
    }

    /// The caps are the owner's, not the transport's.
    @Test("a line past the owner's cap ends the connection")
    func lineOverTheOwnersCapEndsTheConnection() throws {
        let server = try UnixSocketTestServer(drainReads: false)
        defer { server.shutdown() }

        let client = textSocket()
        let recorder = Recorder()
        recorder.attach(to: client)
        connect(client, to: server)

        server.writeToClient(Data(repeating: 0x41, count: 65) + Data("\n".utf8))

        #expect(recorder.failed.wait(timeout: 3.0), "an oversized line never ended the connection")
        #expect(recorder.failure.value == .framingViolation(.lineTooLong(bytes: 65)))
        #expect(recorder.messages.value == nil)

        client.close()
    }

    /// `sun_path` is 104 bytes and holds the terminator, so 103 is the longest
    /// path there is. One byte more is refused by length, before any socket,
    /// rather than as an errno the system never returned.
    @Test("a path longer than a socket address holds is refused by its length")
    func overlongPathIsRefused() {
        let longest = "/" + String(repeating: "a", count: 102)
        let overlong = longest + "a"

        let attempted = outcome(connecting: textSocket(), to: longest)
        let refused = outcome(connecting: textSocket(), to: overlong)

        guard case .failure(let attemptFailure)? = attempted, case .failure(let refusal)? = refused else {
            Issue.record("neither path names a listening socket, so both must fail")
            return
        }
        #expect(attemptFailure == .system(errno: ENOENT))
        #expect(refusal == .pathTooLong(bytes: 104, maximum: 103))
    }
}
