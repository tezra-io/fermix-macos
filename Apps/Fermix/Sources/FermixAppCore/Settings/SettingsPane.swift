import Foundation

/// The four titled sections of the Settings sidebar (M34 §5).
///
/// The grouping is the app's, because M34 §7.7 makes pane grouping and titles
/// hand-built: the daemon names which pane a section belongs to and never how
/// the panes are arranged.
public enum SettingsPaneGroup: String, CaseIterable, Sendable {
    case assistant
    case connections
    case capabilities
    case system

    public var titleKey: ProductStringKey {
        switch self {
        case .assistant: return .settingsGroupAssistant
        case .connections: return .settingsGroupConnections
        case .capabilities: return .settingsGroupCapabilities
        case .system: return .settingsGroupSystem
        }
    }

    public var title: String { ProductStrings[titleKey] }

    /// The panes of this group, in the design's own order.
    public var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.group == self }
    }
}

/// The thirteen Settings panes (M34 §5, §3.4).
///
/// The raw value is the `fermix://settings/<pane>` slug **and** the wire value
/// `settings.sections` publishes, so the route family, the sidebar and the
/// daemon's section inventory speak one vocabulary rather than three that have
/// to be kept in step.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    // Assistant
    case providers
    case personality
    case memory

    // Connections
    case channels
    case integrations

    // Capabilities
    case voice
    case meetings
    case computer
    /// The pane is titled `Coding agents`; the slug the design publishes is
    /// `coding`, and the slug is what the wire and the route carry.
    case codingAgents = "coding"
    case search
    case images

    // System
    case sandbox
    case permissions

    public var id: String { rawValue }

    /// The route slug, which is also the wire value.
    public var slug: String { rawValue }

    public var group: SettingsPaneGroup {
        switch self {
        case .providers, .personality, .memory:
            return .assistant
        case .channels, .integrations:
            return .connections
        case .voice, .meetings, .computer, .codingAgents, .search, .images:
            return .capabilities
        case .sandbox, .permissions:
            return .system
        }
    }

    public var titleKey: ProductStringKey {
        switch self {
        case .providers: return .settingsPaneProviders
        case .personality: return .settingsPanePersonality
        case .memory: return .settingsPaneMemory
        case .channels: return .settingsPaneChannels
        case .integrations: return .settingsPaneIntegrations
        case .voice: return .settingsPaneVoice
        case .meetings: return .settingsPaneMeetings
        case .computer: return .settingsPaneComputer
        case .codingAgents: return .settingsPaneCodingAgents
        case .search: return .settingsPaneSearch
        case .images: return .settingsPaneImages
        case .sandbox: return .settingsPaneSandbox
        case .permissions: return .settingsPanePermissions
        }
    }

    public var title: String { ProductStrings[titleKey] }

    public var systemImage: String {
        switch self {
        case .providers: return "sparkles"
        case .personality: return "person.crop.circle"
        case .memory: return "brain"
        case .channels: return "bubble.left.and.bubble.right"
        case .integrations: return "puzzlepiece.extension"
        case .voice: return "waveform"
        case .meetings: return "video"
        case .computer: return "desktopcomputer"
        case .codingAgents: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        case .images: return "photo"
        case .sandbox: return "shield.lefthalf.filled"
        case .permissions: return "lock.shield"
        }
    }

    /// Words a person might type that are not in the pane's title. The daemon's
    /// row labels are searched too, so this covers only the vocabulary a pane
    /// answers to before its rows have been read.
    public var keywordsKey: ProductStringKey {
        switch self {
        case .providers: return .settingsKeywordsProviders
        case .personality: return .settingsKeywordsPersonality
        case .memory: return .settingsKeywordsMemory
        case .channels: return .settingsKeywordsChannels
        case .integrations: return .settingsKeywordsIntegrations
        case .voice: return .settingsKeywordsVoice
        case .meetings: return .settingsKeywordsMeetings
        case .computer: return .settingsKeywordsComputer
        case .codingAgents: return .settingsKeywordsCodingAgents
        case .search: return .settingsKeywordsSearch
        case .images: return .settingsKeywordsImages
        case .sandbox: return .settingsKeywordsSandbox
        case .permissions: return .settingsKeywordsPermissions
        }
    }

    public var keywords: [String] {
        ProductStrings[keywordsKey].split(separator: " ").map(String.init)
    }

    /// The same pane, in the wire vocabulary a section or a readiness failure
    /// names it with.
    public var wire: ManagementSettingsPane {
        guard let pane = ManagementSettingsPane.publishedValues[rawValue] else {
            preconditionFailure("\(rawValue) is not a published settings pane")
        }

        return pane
    }

    /// The pane a daemon-published value names, where this build knows it. A
    /// value from a newer engine has no pane here and is refused by the caller
    /// rather than folded onto a neighbour.
    public static func pane(for wire: ManagementSettingsPane) -> SettingsPane? {
        guard let value = ManagementSettingsPane.publishedValues.first(where: { $0.value == wire })?.key
        else { return nil }

        return SettingsPane(rawValue: value)
    }

    /// Whether this pane answers to the text typed in the sidebar's search
    /// field, before its rows are consulted.
    public func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }

        return title.lowercased().contains(needle) || keywords.contains { $0.contains(needle) }
    }
}
