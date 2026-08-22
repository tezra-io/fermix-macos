import Foundation

/// Home's narrow model.
///
/// It reads two management methods and owns two independent registrations. It
/// never mutates the background service itself: that is a journaled lifecycle
/// transaction, and `AppCoordinator` is the one place that runs one.
@MainActor
public final class HomeModel: ObservableObject {
    @Published public private(set) var snapshot: HomeSnapshot
    @Published public private(set) var loading = false

    private let gateway: any DaemonQuerying
    private let services: ServiceController
    private let coordinator: AppCoordinator
    private let updates: any UpdateChecking
    private let log = AppLog.logger(.app)

    public init(
        gateway: any DaemonQuerying,
        services: ServiceController,
        coordinator: AppCoordinator,
        updates: any UpdateChecking
    ) {
        self.gateway = gateway
        self.services = services
        self.coordinator = coordinator
        self.updates = updates
        self.snapshot = HomeSnapshot.unreachable(serviceEnabled: services.backgroundServiceEnabled)
    }

    /// Whether the GUI opens at login. Independent of the background service in
    /// both directions: two registrations, two consents.
    public var openAtLogin: Bool {
        services.status(.mainApp) == .enabled
    }

    public var backgroundServiceEnabled: Bool {
        services.backgroundServiceEnabled
    }

    public var transactionInFlight: Bool {
        coordinator.isRunningTransaction
    }

    public func refresh() async {
        loading = true
        defer { loading = false }

        let serviceEnabled = services.backgroundServiceEnabled
        let update = await updates.availability()

        do {
            let hello = try await gateway.negotiate()
            let overview = try await gateway.overview()
            snapshot = HomeSnapshot(
                hello: hello,
                overview: overview,
                serviceEnabled: serviceEnabled,
                update: update
            )
        } catch {
            log.error("home could not read the daemon: \(ManagementMessage.sentence(for: error), privacy: .public)")
            snapshot = HomeSnapshot.unreachable(serviceEnabled: serviceEnabled)
        }
    }

    // MARK: - Actions

    public func openSetup() {
        coordinator.perform(.setup)
    }

    public func runDoctor() {
        coordinator.perform(.runDoctor)
    }

    public func restartDaemon() {
        coordinator.perform(.restartDaemon)
    }

    /// Enable or disable the background service. The verb is never start or
    /// stop: registration is the durable state, and the transaction is
    /// journaled by the lifecycle coordinator.
    ///
    /// Home sets the state it wants rather than toggling, because a switch and
    /// a menu row can disagree about what "the other one" is while a
    /// transaction is in flight.
    public func setBackgroundService(_ enabled: Bool) {
        coordinator.setBackgroundService(enabled: enabled)
    }

    /// The GUI's own login registration. Turning it off never touches the
    /// daemon's.
    public func setOpenAtLogin(_ enabled: Bool) {
        do {
            try enabled ? services.enable(.mainApp) : services.disable(.mainApp)
        } catch {
            log.error("the GUI login item could not be changed: \(String(describing: error), privacy: .public)")
        }
        objectWillChange.send()
    }
}
