import Foundation
import Testing

@testable import FermixAppCore

private typealias E = CompanionEvents
private typealias M = CompanionMediaRows

/// The session over the real adapter on a fake line socket, as the session's
/// own cases build it, with its grants.
@MainActor
private struct Harness {
    let socket = FakeCompanionSocket()
    let scheduler = ManualDeadlineScheduler()
    let session: CompanionSession

    init() {
        session = CompanionSession(
            transport: CompanionSocketClient(lines: socket),
            socketPath: { "/tmp/fermix-test/companion.sock" },
            deadlines: scheduler
        )
    }

    var grants: MediaGrants { session.grants }

    func connected() {
        session.connect()
        socket.deliver(E.hello())
    }

    /// The connection drops and the next attempt completes its handshake.
    func reconnected() {
        socket.fail(.peerClosed)
        scheduler.fireAll()
        socket.deliver(E.hello())
    }

    /// The grants' lines on the wire, in order.
    func mediaLines() throws -> [NSDictionary] {
        try socket.sentObjects().filter { ($0["type"] as? String)?.hasPrefix("media_") == true }
    }

    /// Lets the uses started as tasks run until `condition` holds.
    func settle(until condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 1_000 {
            turns += 1
            await Task.yield()
        }
    }
}

private func wire(_ events: CompanionClientEvent...) throws -> [NSDictionary] {
    try events.map(wireObject(companion:))
}

/// The grant, app side (M66 decision 1): the count per ref of what uses a
/// granted file, one fetch for its first use, one release at zero and only for
/// what the engine granted, fetched again after every handshake, with no real
/// socket, clock or window.
@Suite("Media grants")
@MainActor
struct MediaGrantsTests {
    @Test("the first use fetches, its answer resolves every use waiting, and a later use takes it at once")
    func oneFetchResolvesEveryUse() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants

        let first = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }
        let second = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 2 }
        #expect(try harness.mediaLines() == wire(M.fetch(M.voice)))

        harness.socket.deliver(M.granted(M.voice))

        #expect(await first.value == .granted(M.grant(M.voice)))
        #expect(await second.value == .granted(M.grant(M.voice)))
        #expect(await grants.hold(M.voice.ref) == .granted(M.grant(M.voice)))
        #expect(grants.count(of: M.voice.ref) == 3)
        #expect(try harness.mediaLines() == wire(M.fetch(M.voice)))
    }

    @Test("the release goes out once, when the last use lets go, and the next use fetches again")
    func releaseAtZero() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let first = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }
        harness.socket.deliver(M.granted(M.picture))
        _ = await first.value
        _ = await grants.hold(M.picture.ref)

        grants.release(M.picture.ref)
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture)))

        grants.release(M.picture.ref)
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture), M.release(M.picture)))

        grants.release(M.picture.ref)
        let again = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture), M.release(M.picture), M.fetch(M.picture)))
        harness.socket.deliver(M.granted(M.picture))
        #expect(await again.value == .granted(M.grant(M.picture)))
    }

    @Test("a missing file answers missing, and what was never granted is never released")
    func missingIsNeverReleased() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let use = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }

        harness.socket.deliver(.mediaMissing(ref: M.voice.ref))

        #expect(await use.value == .missing)
        grants.release(M.voice.ref)
        #expect(try harness.mediaLines() == wire(M.fetch(M.voice)))
    }

    @Test("an error naming the ref answers failed, is never released, and is not the chat's error")
    func failedGrant() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let use = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }

        harness.socket.deliver(E.refusal("request_failed", ref: M.voice.ref))

        #expect(await use.value == .failed)
        grants.release(M.voice.ref)
        #expect(try harness.mediaLines() == wire(M.fetch(M.voice)))
        #expect(harness.session.model.lastError == nil)

        harness.socket.deliver(E.refusal("unsupported_profile"))
        #expect(harness.session.model.lastError == "The daemon reported: unsupported_profile")
    }

    @Test("a ref that is not 64 lowercase hex digits answers missing, is not counted and sends nothing")
    func badRefIsNeverUsed() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let upper = String(repeating: "A", count: 64)

        for ref in ["", "../../etc/passwd", upper, String(repeating: "a", count: 63)] {
            #expect(await grants.hold(ref) == .missing)
            #expect(grants.count(of: ref) == 0)
            grants.release(ref)
        }

        #expect(try harness.mediaLines().isEmpty)
    }

    @Test("after a reconnect every ref still counted is fetched again, its answer resolves the uses waiting and replaces the grant held")
    func reconnectFetchesAgain() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let voice = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }
        harness.socket.deliver(M.granted(M.voice))
        #expect(await voice.value == .granted(M.grant(M.voice)))
        let picture = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }

        harness.reconnected()

        #expect(
            try harness.mediaLines()
                == wire(M.fetch(M.voice), M.fetch(M.picture), M.fetch(M.voice), M.fetch(M.picture))
        )
        harness.socket.deliver(M.granted(M.picture))
        #expect(await picture.value == .granted(M.grant(M.picture)))

        harness.socket.deliver(M.granted(M.voice, at: "/Users/me/.fermix/companion/media/again.ogg"))
        #expect(await grants.hold(M.voice.ref) == .granted(M.grant(M.voice, at: "/Users/me/.fermix/companion/media/again.ogg")))

        grants.release(M.voice.ref)
        grants.release(M.voice.ref)
        #expect(try harness.mediaLines().last == wireObject(companion: M.release(M.voice)))
    }

    /// The engine lets go of a connection's grants when it closes, and keeps
    /// the file a minute after, so nothing is released into a new connection.
    @Test("a use let go while disconnected is not released, nor fetched after the next handshake")
    func releasedWhileAway() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let use = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }
        harness.socket.deliver(M.granted(M.voice))
        _ = await use.value

        harness.socket.fail(.peerClosed)
        grants.release(M.voice.ref)
        harness.scheduler.fireAll()
        harness.socket.deliver(E.hello())

        #expect(try harness.mediaLines() == wire(M.fetch(M.voice)))
    }

    @Test("a use asked for before the handshake waits for it, and is fetched after the catch-up read")
    func useWaitsForTheHandshake() async throws {
        let harness = Harness()
        harness.session.connect()
        let grants = harness.grants
        let use = Task { await grants.hold(M.voice.ref) }
        await harness.settle { grants.count(of: M.voice.ref) == 1 }
        #expect(try harness.mediaLines().isEmpty)

        harness.socket.deliver(E.hello())

        #expect(
            try harness.socket.sentObjects()
                == wire(.clientHello(protocolVersion: CompanionProtocol.version), newestPagePull, M.fetch(M.voice))
        )
        harness.socket.deliver(M.granted(M.voice))
        #expect(await use.value == .granted(M.grant(M.voice)))
    }

    @Test("a use cancelled while it waits answers failed; a grant that comes once nothing uses it is released at once")
    func cancelledUseAndALateGrant() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let use = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }

        use.cancel()
        #expect(await use.value == .failed)
        grants.release(M.picture.ref)
        #expect(grants.count(of: M.picture.ref) == 0)
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture)))

        harness.socket.deliver(M.granted(M.picture))
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture), M.release(M.picture)))
    }

    @Test("a use that comes while the first fetch is unanswered waits on it rather than fetching again")
    func noSecondFetchWhileOneIsOut() async throws {
        let harness = Harness()
        harness.connected()
        let grants = harness.grants
        let first = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }
        first.cancel()
        _ = await first.value
        grants.release(M.picture.ref)

        let second = Task { await grants.hold(M.picture.ref) }
        await harness.settle { grants.count(of: M.picture.ref) == 1 }
        harness.socket.deliver(M.granted(M.picture))

        #expect(await second.value == .granted(M.grant(M.picture)))
        #expect(try harness.mediaLines() == wire(M.fetch(M.picture)))
    }

    @Test("an answer for a ref this connection never asked for is not released")
    func unaskedAnswerIsIgnored() throws {
        let harness = Harness()
        harness.connected()

        harness.socket.deliver(M.granted(M.voice))

        #expect(try harness.mediaLines().isEmpty)
    }

    /// The fixture daemon's rows carry no bytes, so a fixture launch never
    /// waits on a file.
    @Test("the fixture daemon answers every fetch with a missing file")
    func fixtureGrantsNothing() async {
        let session = CompanionSession(
            transport: CompanionSocketClient(lines: FixtureCompanionTransport(timeline: .full)),
            socketPath: { "/fixture/companion.sock" },
            deadlines: ManualDeadlineScheduler()
        )
        session.connect()

        #expect(await session.grants.hold(M.voice.ref) == .missing)
        session.grants.release(M.voice.ref)
        #expect(session.grants.count(of: M.voice.ref) == 0)
    }
}
