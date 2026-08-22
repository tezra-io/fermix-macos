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
    private let lock = NSLock()
    private var statuses: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]

    var nextStatus: [LoginItemPrincipal: ServiceRegistrationStatus] = [:]
    var registerError: (any Error)?
    var unregisterError: (any Error)?

    private(set) var registerCalls: [LoginItemPrincipal] = []
    private(set) var unregisterCalls: [LoginItemPrincipal] = []

    /// Establishes a starting state without recording it: the call lists are
    /// about what the code under test did, not how the scenario was set up.
    func preregister(_ principal: LoginItemPrincipal) {
        lock.lock()
        statuses[principal] = .enabled
        lock.unlock()
    }

    func register(_ principal: LoginItemPrincipal) throws {
        lock.lock()
        defer { lock.unlock() }
        registerCalls.append(principal)
        if let registerError { throw registerError }
        statuses[principal] = nextStatus[principal] ?? .enabled
    }

    func unregister(_ principal: LoginItemPrincipal) throws {
        lock.lock()
        defer { lock.unlock() }
        unregisterCalls.append(principal)
        if let unregisterError { throw unregisterError }
        statuses[principal] = .notRegistered
    }

    func status(_ principal: LoginItemPrincipal) -> ServiceRegistrationStatus {
        lock.lock()
        defer { lock.unlock() }
        return statuses[principal] ?? .notRegistered
    }
}
