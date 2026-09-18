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

    @Test("the agent principal names the plist the bundle actually ships")
    func agentPlistNameComesFromTheConfiguration() throws {
        let configuration = try ProductConfiguration.decode(from: ProductFixture.json())

        #expect(LoginItemPrincipal.agent.plistName(configuration) == "io.tezra.FermixPet.agent.plist")
        #expect(LoginItemPrincipal.mainApp.plistName(configuration) == nil)
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
        return statuses[principal] ?? .notRegistered
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
