import Foundation
import Testing

@testable import FermixAppCore

/// The transport is exercised against a real AF_UNIX peer speaking packet-4, so
/// the framing, the ceiling, and every short-read path are proven on real bytes
/// rather than against a stub that agrees with them.
@Suite("UnixSocketManagementTransport")
struct UnixSocketManagementTransportTests {
    private let limits = ManagementLimits(
        maxFrameBytes: 4_194_304,
        maxParamsBytes: 65_536,
        maxResultBytes: 1_048_576,
        maxErrorDetailsBytes: 4_096,
        maxJSONDepth: 6,
        maxJSONCollectionItems: 500
    )

    @Test("one request, one response, then the connection is done")
    func exchangeRoundTrips() async throws {
        let response = Data(#"{"request_id":"req-1","result":{}}"#.utf8)
        let peer = try ManagementSocketTestPeer(behavior: .answer(response))
        defer { peer.shutdown() }

        let transport = UnixSocketManagementTransport(socketPath: peer.path, limits: limits)
        let request = Data(#"{"request_id":"req-1","protocol_version":1,"method":"hello"}"#.utf8)
        let received = try await transport.exchange(request, timeout: .seconds(5))

        #expect(received == response)
        #expect(peer.requestPayload(timeout: 2) == request)
    }

    @Test("an inbound frame over the ceiling is refused from its header")
    func inboundOverCeilingIsRefused() async throws {
        var header = Data()
        withUnsafeBytes(of: UInt32(4_194_305).bigEndian) { header.append(contentsOf: $0) }
        let peer = try ManagementSocketTestPeer(behavior: .rawBytes(header))
        defer { peer.shutdown() }

        let transport = UnixSocketManagementTransport(socketPath: peer.path, limits: limits)

        await #expect(
            throws: ManagementTransportFailure.frameTooLarge(byteCount: 4_194_305, limit: 4_194_304)
        ) {
            _ = try await transport.exchange(Data(#"{"a":1}"#.utf8), timeout: .seconds(5))
        }
    }

    @Test("an outbound payload over the ceiling is refused before connecting")
    func outboundOverCeilingIsRefused() async throws {
        let transport = UnixSocketManagementTransport(
            socketPath: "/nonexistent/daemon.sock",
            limits: limits
        )
        let payload = Data(repeating: 0x20, count: 4_194_305)

        await #expect(
            throws: ManagementTransportFailure.frameTooLarge(byteCount: 4_194_305, limit: 4_194_304)
        ) {
            _ = try await transport.exchange(payload, timeout: .seconds(5))
        }
    }

    @Test("a peer that closes before answering is a hard error")
    func peerClosingBeforeAnsweringIsRefused() async throws {
        let peer = try ManagementSocketTestPeer(behavior: .closeWithoutAnswering)
        defer { peer.shutdown() }

        let transport = UnixSocketManagementTransport(socketPath: peer.path, limits: limits)

        await #expect(throws: ManagementTransportFailure.peerClosedBeforeResponse) {
            _ = try await transport.exchange(Data(#"{"a":1}"#.utf8), timeout: .seconds(5))
        }
    }

    @Test("a truncated frame is a hard error, never a partial result")
    func truncatedFrameIsRefused() async throws {
        var bytes = Data()
        withUnsafeBytes(of: UInt32(64).bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(Data(repeating: 0x7B, count: 10))
        let peer = try ManagementSocketTestPeer(behavior: .rawBytes(bytes))
        defer { peer.shutdown() }

        let transport = UnixSocketManagementTransport(socketPath: peer.path, limits: limits)

        await #expect(throws: ManagementTransportFailure.shortFrame(expected: 64, received: 10)) {
            _ = try await transport.exchange(Data(#"{"a":1}"#.utf8), timeout: .seconds(5))
        }
    }

    @Test("a missing socket names the path rather than an errno")
    func missingSocketNamesThePath() async throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fermix-absent-\(UUID().uuidString.prefix(8)).sock")
        let transport = UnixSocketManagementTransport(socketPath: path, limits: limits)

        await #expect(throws: ManagementTransportFailure.socketMissing(path: path)) {
            _ = try await transport.exchange(Data(#"{"a":1}"#.utf8), timeout: .seconds(5))
        }
    }

    /// Each half is proven on its own above and in the client suites; this is
    /// the join. A golden envelope goes out over a real socket, framed by the
    /// production path, and comes back as a typed result.
    @Test("the client negotiates hello over a real socket")
    func clientNegotiatesOverTheRealTransport() async throws {
        let identifier = "app-hello-integration-1"
        var envelope = try ManagementFixtures.load(.success)
            .first { $0.name == "hello" }
            .map { try $0.object("response") } ?? [:]
        envelope["request_id"] = identifier

        let peer = try ManagementSocketTestPeer(
            behavior: .answer(try ManagementFixtures.encode(envelope))
        )
        defer { peer.shutdown() }

        let contract = try ManagementContract.vendored()
        let client = ManagementClient(
            transport: UnixSocketManagementTransport(
                socketPath: peer.path,
                limits: contract.limits
            ),
            contract: contract,
            identifiers: FixedRequestIdentifierGenerator(identifier: identifier)
        )

        let hello = try await client.hello()

        #expect(hello.engine.engineId == "fermix-core")
        #expect(hello.protocolRange.maximum == 1)
        let sent = try ManagementFixtures.decode(try #require(peer.requestPayload(timeout: 2)))
        #expect(sent["request_id"] as? String == identifier)
        #expect(sent["protocol_version"] as? Int == 1)
        #expect(sent["method"] as? String == "hello")
    }

    @Test("a peer that never answers hits the injected deadline")
    func silentPeerTimesOut() async throws {
        let peer = try ManagementSocketTestPeer(behavior: .silence)
        defer { peer.shutdown() }

        let transport = UnixSocketManagementTransport(socketPath: peer.path, limits: limits)

        await #expect(throws: ManagementTransportFailure.timedOut(after: .milliseconds(200))) {
            _ = try await transport.exchange(Data(#"{"a":1}"#.utf8), timeout: .milliseconds(200))
        }
    }
}
