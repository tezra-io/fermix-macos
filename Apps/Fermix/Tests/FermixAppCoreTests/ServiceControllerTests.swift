import Foundation
import Testing

@testable import FermixAppCore

/// The two login registrations, over an injected seam.
///
/// Nothing in this suite touches `SMAppService`: registering a real background
/// item would mutate the developer's account, so the production owner is
/// reached only through the protocol and never constructed here.
@Suite("Service controller")
struct ServiceControllerTests {
    private func controller(_ service: FakeLoginItemService) -> ServiceController {
        ServiceController(loginItems: service)
    }

    @Test("both principals default to unregistered on a fresh account")
    func freshAccountHasNothingRegistered() {
        let controller = controller(FakeLoginItemService())

        for principal in LoginItemPrincipal.allCases {
            #expect(controller.status(principal) == .notRegistered, "\(principal.rawValue)")
        }
    }

    @Test("registering one principal never registers the other")
    func principalsAreIndependent() throws {
        let service = FakeLoginItemService()
        let controller = controller(service)

        try controller.enable(.agent)

        #expect(controller.status(.agent) == .enabled)
        #expect(controller.status(.mainApp) == .notRegistered)
    }

    @Test("disabling one registration leaves the other exactly as it was")
    func disablingOneLeavesTheOther() throws {
        let service = FakeLoginItemService()
        let controller = controller(service)
        try controller.enable(.agent)
        try controller.enable(.mainApp)

        try controller.disable(.mainApp)

        #expect(controller.status(.mainApp) == .notRegistered)
        #expect(controller.status(.agent) == .enabled)
    }

    /// macOS can hold a registration in "waiting for approval": that is neither
    /// enabled nor a failure, and re-registering in a loop is exactly what M34
    /// forbids.
    @Test("an approval-pending registration is reported, not retried")
    func approvalPendingIsReported() throws {
        let service = FakeLoginItemService()
        service.nextStatus[.agent] = .requiresApproval
        let controller = controller(service)

        try controller.enable(.agent)

        #expect(controller.status(.agent) == .requiresApproval)
        #expect(service.registerCalls == [.agent])
    }

    /// A registration macOS cannot find is a broken install, not something to
    /// paper over by registering the other principal.
    @Test("an item macOS cannot find is reported as not found")
    func missingItemIsReported() throws {
        let service = FakeLoginItemService()
        service.nextStatus[.agent] = .notFound
        let controller = controller(service)

        try controller.enable(.agent)

        #expect(controller.status(.agent) == .notFound)
        #expect(controller.status(.mainApp) == .notRegistered)
    }

    @Test("a registration failure is raised rather than reported as success")
    func registrationFailuresAreLoud() {
        let service = FakeLoginItemService()
        service.registerError = ServiceControlError.registrationFailed(
            principal: .agent,
            underlying: "operation not permitted"
        )
        let controller = controller(service)

        #expect(throws: ServiceControlError.registrationFailed(principal: .agent, underlying: "operation not permitted")) {
            try controller.enable(.agent)
        }
        #expect(controller.status(.agent) == .notRegistered)
    }

    // MARK: - Asking for the background service

    @Test("a registration macOS allows is enabled, asked for once")
    func requestEnabled() {
        let service = FakeLoginItemService()

        #expect(controller(service).requestBackgroundService() == .enabled)
        #expect(service.registerCalls == [.agent])
    }

    /// A first registration macOS holds is the person not having answered
    /// yet, which is what a first install on a fresh account meets.
    @Test("a first registration macOS holds is awaiting the person's answer")
    func requestAwaitsApproval() {
        let service = FakeLoginItemService()
        service.nextStatus[.agent] = .requiresApproval

        #expect(controller(service).requestBackgroundService() == .awaitingApproval(.awaited))
        #expect(service.registerCalls == [.agent])
    }

    /// macOS reports one status for "not answered" and "switched off", and
    /// the only sign is that the item was already held before this attempt.
    @Test("an item already held before the attempt is one the person switched off")
    func requestFindsItSwitchedOff() {
        let service = FakeLoginItemService()
        service.preregister(.agent, as: .requiresApproval)
        service.nextStatus[.agent] = .requiresApproval

        #expect(controller(service).requestBackgroundService() == .awaitingApproval(.switchedOff))
    }

    /// The 0.2.1 case: macOS refuses to register a switched-off item
    /// ("Operation not permitted") and goes on holding it. The status read
    /// after the throw decides, so it is the same wait and not a failure.
    @Test("a refused registration of a switched-off item is still awaiting approval")
    func requestThrowsWhileHeld() {
        let service = FakeLoginItemService()
        service.preregister(.agent, as: .requiresApproval)
        service.registerError = ServiceControlError.registrationFailed(
            principal: .agent,
            underlying: "Operation not permitted"
        )

        #expect(controller(service).requestBackgroundService() == .awaitingApproval(.switchedOff))
        #expect(service.registerCalls == [.agent], "one register per request, never a retry")
    }

    @Test("a throw that leaves nothing held is refused, with what macOS said")
    func requestRefused() {
        let service = FakeLoginItemService()
        service.registerError = ServiceControlError.registrationFailed(
            principal: .agent,
            underlying: "Invalid signature"
        )

        #expect(controller(service).requestBackgroundService() == .refused(.notRegistered, underlying: "Invalid signature"))
    }

    @Test("a registration that leaves no item, or one macOS cannot find, is refused without an error")
    func requestFindsNoItem() {
        for missing in [ServiceRegistrationStatus.notRegistered, .notFound] {
            let service = FakeLoginItemService()
            service.nextStatus[.agent] = missing

            #expect(controller(service).requestBackgroundService() == .refused(missing, underlying: nil))
        }
    }

    /// The error code decides nothing: code 1 has causes other than the
    /// person's switch, and an item macOS reports enabled runs.
    @Test("a throw that leaves the item enabled is enabled")
    func requestThrowsWhileEnabled() {
        let service = FakeLoginItemService()
        service.preregister(.agent)
        service.registerError = ServiceControlError.registrationFailed(
            principal: .agent,
            underlying: "Operation not permitted"
        )

        #expect(controller(service).requestBackgroundService() == .enabled)
    }

    // MARK: - Waiting for the person

    @Test("the wait reads until the switch goes on, and never registers")
    func waitEndsOnApproval() async {
        let service = FakeLoginItemService()
        service.preregister(.agent, as: .requiresApproval)
        service.change(.agent, to: .enabled, onRead: 3)
        let reads = ScriptedApprovalReads()

        let status = await controller(service).awaitBackgroundApproval(readingOn: reads)

        #expect(status == .enabled)
        #expect(service.statusReads == 3, "a read as it starts, then one per scheduled moment")
        #expect(reads.count == 2)
        #expect(service.registerCalls.isEmpty)
    }

    @Test("an item removed while it was held ends the wait with its new status")
    func waitEndsOnRemoval() async {
        let service = FakeLoginItemService()
        service.preregister(.agent, as: .requiresApproval)
        service.change(.agent, to: .notRegistered, onRead: 2)

        let status = await controller(service).awaitBackgroundApproval(readingOn: ScriptedApprovalReads())

        #expect(status == .notRegistered)
    }

    @Test("a cancelled wait answers nothing and stops reading")
    func cancelledWaitAnswersNothing() async {
        let service = FakeLoginItemService()
        service.preregister(.agent, as: .requiresApproval)
        let reads = ScriptedApprovalReads()
        reads.cancelledOnCall = 2

        let status = await controller(service).awaitBackgroundApproval(readingOn: reads)

        #expect(status == nil)
        #expect(service.statusReads == 2)
        #expect(service.registerCalls.isEmpty)
    }

    /// The shipped schedule waits for the app to come to the front or the
    /// backstop, and a cancelled task ends it at once rather than after either.
    @Test("the shipped schedule ends as soon as its task is cancelled")
    func shippedScheduleHonoursCancellation() async {
        // Measured from inside the task, so a loaded runner that starts the
        // task late does not count: what must be short is the wait itself,
        // which a cancellation ends before the backstop would have.
        let outcome = Task { () async -> (Duration, Bool) in
            let started = ContinuousClock.now
            do {
                try await ReturnOrBackstop().nextRead()
                return (ContinuousClock.now - started, false)
            } catch is CancellationError {
                return (ContinuousClock.now - started, true)
            } catch {
                return (ContinuousClock.now - started, false)
            }
        }
        outcome.cancel()
        let (elapsed, cancelled) = await outcome.value

        #expect(cancelled, "the wait ended some other way than by its cancellation")
        #expect(elapsed < .seconds(ReturnOrBackstop.backstop))
    }

    @Test("Login Items opens through the one documented opener")
    func opensLoginItems() {
        let service = FakeLoginItemService()

        controller(service).openLoginItemsSettings()

        #expect(service.settingsOpened == 1)
    }

    @Test("the agent principal names the plist the bundle actually ships")
    func agentPlistNameComesFromTheConfiguration() throws {
        let configuration = try ProductConfiguration.decode(from: ProductFixture.json())

        #expect(LoginItemPrincipal.agent.plistName(configuration) == "io.tezra.FermixPet.agent.plist")
        #expect(LoginItemPrincipal.mainApp.plistName(configuration) == nil)
    }
}

/// The moments a held background item is read again, as a test decides them:
/// each returns at once, or throws the way a cancelled task does.
final class ScriptedApprovalReads: ApprovalReadSchedule, @unchecked Sendable {
    /// A wait no test ends is a failure, never a hang.
    static let limit = 1_000

    private let lock = NSLock()
    private var calls = 0

    /// The call that throws, as a cancelled wait does. Nil never throws.
    var cancelledOnCall: Int?
    /// Runs on every scheduled moment, for a test that moves a clock.
    var onRead: (() -> Void)?

    var count: Int { lock.withLock { calls } }

    func nextRead() async throws {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if let cancelledOnCall, call >= cancelledOnCall { throw CancellationError() }
        guard call < Self.limit else {
            Issue.record("the approval wait never ended")
            throw CancellationError()
        }

        onRead?()
    }
}

/// The seam's test double. It records calls and reports the status a test
/// chooses, so every branch of the controller runs without macOS.
final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    /// One mutation, in the order it happened. The two lists below answer "did
    /// it register", and this answers "in which order", which is the whole of
    /// the rebuild an enable performs.
    enum Mutation: Equatable {
        case register(LoginItemPrincipal)
        case unregister(LoginItemPrincipal)
    }

    private let lock = NSLock()
    private var statuses: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]

    var nextStatus: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    /// Whether `unregister` answers without throwing and leaves the item
    /// exactly where it was. macOS can do that, and the upgrade incident of
    /// 2026-09-17 is what it looks like when it does.
    var unregisterLeavesItRegistered = false

    private(set) var registerCalls: [LoginItemPrincipal] = []
    private(set) var unregisterCalls: [LoginItemPrincipal] = []
    private(set) var mutations: [Mutation] = []
    /// How many times System Settings was asked to open on Login Items.
    var settingsOpened: Int { lock.withLock { opened } }
    private var opened = 0
    /// The person flipping the switch in System Settings: after this many
    /// more reads of the principal, macOS reports the status given.
    private var pendingChange: (principal: LoginItemPrincipal, afterReads: Int, status: ServiceRegistrationStatus)?
    /// How many times macOS was asked for a status. Each real read is a slow
    /// XPC round trip, so a surface that redraws must not add to this.
    var statusReads: Int { lock.withLock { reads } }
    private var reads = 0

    /// Establishes a starting state without recording it: the call lists are
    /// about what the code under test did, not how the scenario was set up.
    ///
    /// - Parameter status: the state macOS reports for this principal. It is a
    ///   parameter because two of the four states no register or unregister call
    ///   can produce: `requiresApproval` is the operator's Login Items switch,
    ///   and `notFound` is macOS unable to find the item at all.
    func preregister(_ principal: LoginItemPrincipal, as status: ServiceRegistrationStatus = .enabled) {
        lock.lock()
        statuses[principal] = status
        lock.unlock()
    }

    func register(_ principal: LoginItemPrincipal) throws {
        lock.lock()
        defer { lock.unlock() }
        registerCalls.append(principal)
        mutations.append(.register(principal))
        if let registerError { throw registerError }
        statuses[principal] = nextStatus[principal] ?? .enabled
    }

    func unregister(_ principal: LoginItemPrincipal) throws {
        lock.lock()
        defer { lock.unlock() }
        unregisterCalls.append(principal)
        mutations.append(.unregister(principal))
        if let unregisterError { throw unregisterError }
        guard !unregisterLeavesItRegistered else { return }

        statuses[principal] = .notRegistered
    }

    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        if let change = pendingChange, change.principal == principal {
            if change.afterReads <= 1 {
                statuses[principal] = change.status
                pendingChange = nil
            } else {
                pendingChange = (principal, change.afterReads - 1, change.status)
            }
        }
        return statuses[principal] ?? .notRegistered
    }

    func openSettings() {
        lock.withLock { opened += 1 }
    }

    /// Scripts the person's answer in System Settings: the `reads`-th read of
    /// the principal from now reports `status`, and every one after it too.
    func change(_ principal: LoginItemPrincipal, to status: ServiceRegistrationStatus, onRead reads: Int) {
        lock.withLock { pendingChange = (principal, reads, status) }
    }
}

/// `--unregister-login-items`, which the cask runs from the copy it is about to
/// replace. It is the only thing that can withdraw a registration keyed on this
/// bundle, and on 2026-09-17 an upgrade left both the BTM item and the launchd
/// job behind with nothing in the log to say so.
@Suite("Login item withdrawal")
struct LoginItemWithdrawalTests {
    private func controller(_ loginItems: FakeLoginItemService) -> ServiceController {
        ServiceController(loginItems: loginItems)
    }

    @Test("withdrawing both registrations succeeds and says so")
    func withdrawalReportsEachPrincipal() {
        let loginItems = FakeLoginItemService()
        loginItems.preregister(.agent)
        loginItems.preregister(.mainApp)

        let withdrawal = LoginItemWithdrawal.run(services: controller(loginItems))

        #expect(withdrawal.succeeded)
        #expect(withdrawal.exitCode == 0)
        #expect(withdrawal.lines.count == LoginItemPrincipal.allCases.count)
        #expect(withdrawal.lines.allSatisfy { $0.sentence.contains("unregistered") })
        #expect(loginItems.unregisterCalls.sorted { $0.rawValue < $1.rawValue } == [.agent, .mainApp])
    }

    /// A registration that could not be withdrawn is the whole reason the verb
    /// exists, so it names the principal and the refusal and exits non-zero.
    @Test("a refused unregister is named and exits non-zero")
    func refusedUnregisterFails() {
        let loginItems = FakeLoginItemService()
        loginItems.preregister(.agent)
        loginItems.unregisterError = ServiceControlError.unregistrationFailed(
            principal: .agent,
            underlying: "operation not permitted"
        )

        let withdrawal = LoginItemWithdrawal.run(services: controller(loginItems))

        #expect(!withdrawal.succeeded)
        #expect(withdrawal.exitCode != 0)
        let failed = withdrawal.lines.filter { !$0.withdrawn }
        #expect(failed.count == 1)
        #expect(failed.first?.sentence.contains("agent") == true)
        #expect(failed.first?.sentence.contains("operation not permitted") == true)
    }

    /// `unregister` returning without throwing is not proof the item is gone.
    /// The registration this upgrade had to withdraw survived exactly that way,
    /// so macOS is read back and a surviving item is a refusal.
    @Test("a registration macOS still reports is a failure, not a success")
    func survivingRegistrationFails() {
        let loginItems = FakeLoginItemService()
        loginItems.preregister(.agent)
        loginItems.unregisterLeavesItRegistered = true

        let withdrawal = LoginItemWithdrawal.run(services: controller(loginItems))

        #expect(!withdrawal.succeeded)
        #expect(withdrawal.exitCode != 0)
        #expect(withdrawal.lines.contains { !$0.withdrawn && $0.sentence.contains("enabled") })
    }

    /// Nothing to withdraw is not a fault: the cask runs this on every upgrade,
    /// including for an account that never turned the background service on.
    @Test("an account with no registrations succeeds and states it")
    func nothingToWithdrawSucceeds() {
        let loginItems = FakeLoginItemService()

        let withdrawal = LoginItemWithdrawal.run(services: controller(loginItems))

        #expect(withdrawal.succeeded)
        #expect(withdrawal.exitCode == 0)
        #expect(loginItems.unregisterCalls.isEmpty)
        #expect(withdrawal.lines.allSatisfy { $0.sentence.contains("not registered") })
    }
}
