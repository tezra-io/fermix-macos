import Foundation

/// What the app can say about an update.
///
/// Sparkle is M34 §6 work. Until it is wired, this build reports `unknown`
/// rather than "up to date": claiming an app is current when nothing has
/// checked is the kind of quiet untruth the update card exists to avoid.
public enum UpdateAvailability: Equatable, Sendable {
    case unknown
    case upToDate(lastCheckedAt: Date?)
    case available(version: String)
}

/// The update seam Home's card is wired to.
public protocol UpdateChecking: Sendable {
    func availability() async -> UpdateAvailability
}

/// The v1 checker. It has no updater behind it and says so.
public struct UnwiredUpdateChecker: UpdateChecking {
    public init() {}

    public func availability() async -> UpdateAvailability { .unknown }
}

/// Home, as data.
///
/// Every row here comes from `hello` and `overview.get`. There is no activity
/// database and nothing reads model-facing memory: Runtime carries
/// authoritative facts, Attention carries warnings with their one next action,
/// and a fact the daemon did not report simply has no row.
public struct HomeSnapshot: Equatable, Sendable {
    public let statusTitle: String
    public let statusTone: StatusTone
    public let uptime: String?
    /// The same fact the sentence above is built from, in seconds, for the
    /// surfaces that render it at a different resolution. One resolver, two
    /// renderings: Home's "for 3 days 4 hours" and the panel's "3 days".
    public let uptimeSeconds: Int?
    public let chips: [String]
    public let runtime: [StatusRowModel]
    public let attention: [StatusRowModel]
    public let setupComplete: Bool
    public let serviceEnabled: Bool
    public let update: UpdateAvailability

    public init(
        hello: ManagementHello?,
        overview: ManagementOverview?,
        serviceEnabled: Bool,
        update: UpdateAvailability,
        unreachable: Bool = false
    ) {
        let readiness = overview.map { OnboardingReadiness(overview: $0, daemonLive: true) }
        self.setupComplete = readiness?.canFinish ?? false
        self.serviceEnabled = serviceEnabled
        self.update = update
        self.uptimeSeconds = overview.flatMap { HomeSnapshot.uptimeSeconds($0) }
        self.uptime = overview.flatMap { HomeSnapshot.uptime($0) }
        self.chips = overview.map { HomeSnapshot.chips($0) } ?? []
        self.runtime = HomeSnapshot.runtimeRows(hello: hello, overview: overview)
        self.attention = HomeSnapshot.attentionRows(
            overview: overview,
            setupComplete: setupComplete,
            serviceEnabled: serviceEnabled
        )

        if unreachable {
            statusTitle = ProductStrings[.homeStatusUnreachable]
            statusTone = .fail
        } else if setupComplete {
            statusTitle = ProductStrings[.homeStatusRunning]
            statusTone = .pass
        } else {
            statusTitle = ProductStrings[.homeStatusSetupRequired]
            statusTone = .warn
        }
    }

    /// The daemon could not be reached at all. Home says so instead of drawing
    /// a hero that implies everything is fine.
    public static func unreachable(serviceEnabled: Bool) -> HomeSnapshot {
        HomeSnapshot(
            hello: nil,
            overview: nil,
            serviceEnabled: serviceEnabled,
            update: .unknown,
            unreachable: true
        )
    }

    public var runtimeEmpty: EmptyStateModel {
        EmptyStateModel(message: ProductStrings[.homeRuntimeEmpty])
    }

    public var attentionEmpty: EmptyStateModel {
        EmptyStateModel(message: ProductStrings[.homeAttentionEmpty])
    }

    /// M34 §4: the durable state is the registration, so the verb is enable or
    /// disable and never start or stop.
    public var serviceActionTitle: String {
        ProductStrings[serviceEnabled ? .serviceDisable : .serviceEnable]
    }

    public var updateSummary: String {
        switch update {
        case .unknown:
            return ProductStrings[.homeUpdateUnknown]
        case .upToDate:
            return ProductStrings[.homeUpdateCurrent]
        case .available(let version):
            return String(format: ProductStrings[.homeUpdateAvailableFormat], version)
        }
    }

    // MARK: - Hero

    /// The one place the daemon's reported uptime is resolved. A zero or absent
    /// value is no uptime at all rather than "just now": the daemon has not
    /// answered the question.
    private static func uptimeSeconds(_ overview: ManagementOverview) -> Int? {
        guard let milliseconds = overview.daemon.uptimeMs, milliseconds > 0 else { return nil }

        return milliseconds / 1000
    }

    private static func uptime(_ overview: ManagementOverview) -> String? {
        guard let seconds = uptimeSeconds(overview) else { return nil }

        return String(format: ProductStrings[.homeUptimeFormat], HumaneTime.uptime(seconds: seconds))
    }

    private static func chips(_ overview: ManagementOverview) -> [String] {
        var chips: [String] = []

        if let provider = overview.provider.active, !provider.isEmpty {
            let model = overview.provider.model
            chips.append(model.map { ProductStrings.middot(provider, $0) } ?? provider)
        }
        chips.append(contentsOf: overview.channels.filter(\.enabled).compactMap(\.name))

        return chips
    }

    // MARK: - Runtime

    private static func runtimeRows(
        hello: ManagementHello?,
        overview: ManagementOverview?
    ) -> [StatusRowModel] {
        guard let hello else { return [] }

        var rows = [
            StatusRowModel(
                id: "engine",
                title: ProductStrings[.homeRuntimeEngine],
                detail: hello.engine.productVersion,
                meta: hello.engine.architecture,
                systemImage: "cpu",
                tone: .neutral
            ),
            StatusRowModel(
                id: "protocol",
                title: ProductStrings[.homeRuntimeProtocol],
                detail: "v\(hello.protocolRange.currentVersion)",
                meta: "v\(hello.protocolRange.minimum)-v\(hello.protocolRange.maximum)",
                systemImage: "cable.connector",
                tone: .neutral
            )
        ]

        guard let overview else { return rows }

        if let uptime = uptime(overview) {
            rows.append(
                StatusRowModel(
                    id: "uptime",
                    title: ProductStrings[.homeRuntimeUptime],
                    detail: uptime,
                    meta: overview.daemon.pid,
                    systemImage: "clock",
                    tone: .neutral
                )
            )
        }

        rows.append(
            StatusRowModel(
                id: "provider",
                title: ProductStrings[.homeRuntimeProvider],
                detail: overview.provider.active ?? ProductStrings[.homeRuntimeNone],
                meta: overview.provider.model,
                systemImage: "sparkles",
                tone: .neutral
            )
        )
        rows.append(
            StatusRowModel(
                id: "channels",
                title: ProductStrings[.homeRuntimeChannels],
                detail: channelSummary(overview),
                meta: String(overview.channels.filter(\.enabled).count),
                systemImage: "bubble.left.and.bubble.right",
                tone: .neutral
            )
        )

        return rows
    }

    private static func channelSummary(_ overview: ManagementOverview) -> String {
        let enabled = overview.channels.filter(\.enabled).compactMap(\.name)
        guard !enabled.isEmpty else { return ProductStrings[.homeRuntimeNone] }

        return enabled.joined(separator: ", ")
    }

    // MARK: - Attention

    /// Warnings, each with the one next action. Order is deliberate: the thing
    /// that stops Fermix answering at all comes first.
    private static func attentionRows(
        overview: ManagementOverview?,
        setupComplete: Bool,
        serviceEnabled: Bool
    ) -> [StatusRowModel] {
        var rows: [StatusRowModel] = []

        if !setupComplete, overview != nil {
            rows.append(
                StatusRowModel(
                    id: "setup",
                    title: ProductStrings[.homeStatusSetupRequired],
                    detail: ProductStrings[.homeAttentionSetupRequired],
                    meta: nil,
                    systemImage: "slider.horizontal.3",
                    tone: .warn
                )
            )
        }

        if !serviceEnabled {
            rows.append(
                StatusRowModel(
                    id: "background_service",
                    title: ProductStrings[.homeAttentionServiceDisabledTitle],
                    detail: ProductStrings[.homeAttentionServiceDisabled],
                    meta: nil,
                    systemImage: "power",
                    tone: .warn
                )
            )
        }

        guard let overview else { return rows }

        if overview.health.restartRequired {
            rows.append(
                StatusRowModel(
                    id: "restart_required",
                    title: ProductStrings[.homeAttentionRestartRequiredTitle],
                    detail: ProductStrings[.homeAttentionRestartRequired],
                    meta: nil,
                    systemImage: "arrow.clockwise",
                    tone: .warn
                )
            )
        }

        rows.append(contentsOf: channelWarnings(overview))

        if overview.jobs.failedRecent > 0 {
            rows.append(
                StatusRowModel(
                    id: "jobs",
                    title: ProductStrings[.homeAttentionJobsTitle],
                    detail: ProductStrings[.homeAttentionJobs],
                    meta: String(overview.jobs.failedRecent),
                    systemImage: "calendar.badge.exclamationmark",
                    tone: .warn
                )
            )
        }

        return rows
    }

    /// A channel the operator turned off is a choice, not a warning. Only an
    /// enabled channel that is not answering earns a row.
    private static func channelWarnings(_ overview: ManagementOverview) -> [StatusRowModel] {
        overview.channels
            .filter { $0.enabled && $0.status != "ok" }
            .compactMap { channel in
                guard let name = channel.name else { return nil }

                return StatusRowModel(
                    id: "channel.\(name)",
                    title: name,
                    detail: ProductStrings[.homeAttentionChannel],
                    meta: channel.status,
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    tone: .warn
                )
            }
    }
}
