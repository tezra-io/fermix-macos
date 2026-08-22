import Foundation

@testable import FermixAppCore

/// One assembled coordinator plus every double it runs against, wired to a
/// throwaway directory so the real account is never touched.
@MainActor
final class LifecycleHarness {
    let root: URL
    let location: BootstrapLocation
    let store: BootstrapStore
    let journal: LifecycleJournal
    let loginItems: FakeLoginItemService
    let plane: FakeDaemonControlPlane
    let process: FakeProcessLiveness
    let socket: FakePathPresence
    let web: FakeWebLiveness
    let sleeper: RecordingSleeper
    let coordinator: LifecycleCoordinator

    var socketPath: String { location.defaultFermixHome.appendingPathComponent("daemon.sock").path }

    init(registered: Bool, daemonRunning: Bool) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fermix-lifecycle-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        location = BootstrapLocation(homeDirectory: root)

        let home = location.defaultFermixHome
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        store = BootstrapStore(location: location)
        try store.save(fermixHome: home)

        journal = LifecycleJournal(location: location)
        loginItems = FakeLoginItemService()
        if registered {
            loginItems.preregister(.agent)
        }

        plane = FakeDaemonControlPlane()
        process = FakeProcessLiveness(running: daemonRunning)
        socket = FakePathPresence(present: daemonRunning)
        web = FakeWebLiveness()
        sleeper = RecordingSleeper()

        coordinator = LifecycleCoordinator(
            store: store,
            journal: journal,
            services: ServiceController(loginItems: loginItems),
            plane: { [plane] _ in plane },
            processes: process,
            paths: socket,
            web: web,
            sleeper: sleeper
        )
    }

    deinit {
        // The harness owns this directory exclusively: it is created under the
        // per-user temporary directory with a fresh UUID, and nothing else ever
        // writes there.
        let path = root.path
        guard path.contains("fermix-lifecycle-tests"), path.split(separator: "/").count >= 4 else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func removeBootstrap() throws {
        try store.remove()
    }
}

/// Records the control-plane calls a transaction makes, in order.
final class FakeDaemonControlPlane: DaemonControlPlane, @unchecked Sendable {
    enum Call: Equatable {
        case hello
        case prepare
        case commit(String)
        case cancel(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var helloCount = 0

    var helloPid = "4242"
    var helloPidAfterRestart: String?
    var origin = "http://127.0.0.1:4030"
    var leaseId = "lease-1"
    var helloFailure: (any Error)?
    var prepareFailure: (any Error)?
    var commitFailure: (any Error)?

    var calls: [Call] { lock.withLock { recorded } }

    func hello() async throws -> DaemonIdentity {
        let (pid, setupOrigin, failure) = lock.withLock { () -> (String, String, (any Error)?) in
            recorded.append(.hello)
            helloCount += 1
            let pid = helloCount > 1 ? (helloPidAfterRestart ?? helloPid) : helloPid
            return (pid, origin, helloFailure)
        }

        if let failure { throw failure }
        return DaemonIdentity(pid: pid, setupOrigin: setupOrigin, productVersion: "0.1.0")
    }

    func prepare() async throws -> ManagementLifecycleLease {
        let (lease, failure) = lock.withLock { () -> (String, (any Error)?) in
            recorded.append(.prepare)
            return (leaseId, prepareFailure)
        }

        if let failure { throw failure }
        return ManagementLifecycleLease(leaseId: lease, ttlMs: 30_000, expiresAt: Date().addingTimeInterval(30))
    }

    func commit(leaseId: String) async throws -> ManagementLifecycleOutcome {
        let failure = lock.withLock { () -> (any Error)? in
            recorded.append(.commit(leaseId))
            return commitFailure
        }

        if let failure { throw failure }
        return .committed
    }

    func cancel(leaseId: String) async throws -> ManagementLifecycleOutcome {
        lock.withLock { recorded.append(.cancel(leaseId)) }
        return .cancelled
    }
}

/// A process that stops answering after a chosen number of polls.
final class FakeProcessLiveness: ProcessLiveness, @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private var running: Bool

    var exitsAfterPolls = Int.max

    init(running: Bool) {
        self.running = running
    }

    func isRunning(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return false }
        polls += 1
        return polls <= exitsAfterPolls
    }
}

/// A path that appears (or disappears) after a chosen number of polls.
final class FakePathPresence: PathPresence, @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0

    var present: Bool
    var presentAfterPolls = 0
    var disappearsAfterPolls = Int.max

    init(present: Bool) {
        self.present = present
    }

    func exists(atPath path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        polls += 1
        if present {
            return polls <= disappearsAfterPolls
        }
        return polls > presentAfterPolls
    }
}

final class FakeWebLiveness: WebLiveness, @unchecked Sendable {
    private let lock = NSLock()
    private var origins: [String] = []

    var isLive = true

    var probedOrigins: [String] { lock.withLock { origins } }

    func isLive(origin: String) async -> Bool {
        lock.withLock {
            origins.append(origin)
            return isLive
        }
    }
}

/// Consumes the polling delays instantly and records them, so a bounded wait is
/// provable without spending its wall-clock time.
final class RecordingSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
    }
}
