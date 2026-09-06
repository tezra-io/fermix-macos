import Foundation

/// What a daemon-reported gap is, as a closed set the app has copy for.
///
/// The wire carries a `detail_key` per readiness failure plus the standing
/// coexistence descriptor ids (M34 §3.2, §5.8). Both are parsed here, into one
/// vocabulary, so a row's wording is keyed on what the gap *is* and never on
/// the pane it happens to route to: five channel failures and the voice
/// companion collapse onto two panes, so a pane key cannot tell Telegram from
/// Slack.
///
/// A key this build has never seen is preserved rather than folded onto a
/// neighbour, exactly as every other wire vocabulary here behaves: it renders
/// under the component the daemon named, never under a stranger's sentence.
public enum AttentionDetail: Equatable, Sendable {
    case personalization
    case providerUnknown
    case providerMultiplePrimary
    case providerInvalidAuthMode
    /// One provider descriptor has no usable credential. Parameterised rather
    /// than enumerated: the descriptor set is the daemon's, and restating it in
    /// Swift is the field inventory M34 §7.7 forbids.
    case providerCredentials(provider: String)
    case channel(name: String)
    case voiceRealtime
    case restartPending
    case externalConfigChange
    case configUnreadable
    case legacyServiceUnit
    case secretACLRestricted
    case unrecognized(String)

    /// The wire keys with no parameter, so parsing and the coverage gate read
    /// the same table.
    public static let publishedKeys: [String: AttentionDetail] = [
        "personalization": .personalization,
        "provider:unknown_configured": .providerUnknown,
        "provider:multiple_primary": .providerMultiplePrimary,
        "provider:invalid_auth_mode": .providerInvalidAuthMode,
        "realtime:openai": .voiceRealtime,
        "restart_pending": .restartPending,
        "external_config_change": .externalConfigChange,
        "config_unreadable": .configUnreadable,
        "legacy_service_unit": .legacyServiceUnit,
        "secret_acl_restricted": .secretACLRestricted
    ]

    /// The two parameterised families, by their key prefix.
    public static let credentialsPrefix = "provider:missing_credentials:"
    public static let channelPrefix = "channel:"

    public init(detailKey: String) {
        if let known = Self.publishedKeys[detailKey] {
            self = known
            return
        }

        if detailKey.hasPrefix(Self.credentialsPrefix) {
            let provider = String(detailKey.dropFirst(Self.credentialsPrefix.count))
            self = provider.isEmpty ? .unrecognized(detailKey) : .providerCredentials(provider: provider)
            return
        }

        if detailKey.hasPrefix(Self.channelPrefix) {
            let name = String(detailKey.dropFirst(Self.channelPrefix.count))
            self = name.isEmpty ? .unrecognized(detailKey) : .channel(name: name)
            return
        }

        self = .unrecognized(detailKey)
    }

    /// The key this detail came from, so a row's identity is the daemon's own.
    public var wireKey: String {
        switch self {
        case .providerCredentials(let provider): return Self.credentialsPrefix + provider
        case .channel(let name): return Self.channelPrefix + name
        case .unrecognized(let value): return value
        default:
            guard let match = Self.publishedKeys.first(where: { $0.value == self })?.key else {
                preconditionFailure("\(self) has no published key")
            }
            return match
        }
    }
}

/// The product's own name for each wire identifier a gap can carry.
///
/// The daemon publishes ids (`openai_codex`, `whatsapp`) and, separately, the
/// names the product uses for them: a provider's `label` on `setup.state.get`,
/// and a channel section's `title` on `settings.sections`. A row that raised the
/// first letter of the id instead read `Connect Openai_codex` and `Whatsapp`,
/// which is the same defect the Channels pane already fixed by reading the
/// daemon's titles.
public struct AttentionNames: Equatable, Sendable {
    /// Nothing has been read yet, so every row shows the id the daemon wrote.
    public static let unread = AttentionNames(providers: [:], channels: [:])

    public let providers: [String: String]
    public let channels: [String: String]

    public init(providers: [String: String], channels: [String: String]) {
        self.providers = providers
        self.channels = channels
    }

    /// The two lookups the Providers and Channels panes already use.
    public init(state: ManagementSetupState, sections: [ManagementSettingsSection]) {
        self.providers = Dictionary(
            state.providers.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        self.channels = Dictionary(
            sections.compactMap { section in section.channelName.map { ($0, section.title) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The name, or the identifier exactly as the daemon wrote it. An id shown
    /// raw is visibly an id; an id with its first letter raised is a spelling
    /// the app invented and got wrong.
    public func provider(_ identifier: String) -> String {
        providers[identifier] ?? identifier
    }

    public func channel(_ identifier: String) -> String {
        channels[identifier] ?? identifier
    }
}

/// What an Attention row's one trailing action does.
///
/// Only actions this build performs are minted. Since decision D1 put settings
/// inside the primary window, a gap answered by a pane carries a deep link into
/// that pane: before it, those rows carried no action at all, because there was
/// no surface to send anyone to.
public enum AttentionAction: Equatable, Sendable {
    case restartDaemon
    case reloadSettings
    /// Opens the settings presentation at the pane that can clear this gap.
    case openSettings(SettingsPane)
    /// Opens the one sheet that prints the commands for a gap answered outside
    /// Fermix (M34 §15.2). The app runs nothing: the sheet says what to run and
    /// puts it on the pasteboard. It carries no payload because the commands
    /// are a fact about this Mac, which the presenter reads and this catalogue
    /// has no business knowing.
    case showInstructions
    /// Reveals the settings file in the Finder.
    case revealSettingsFile

    public var title: String {
        switch self {
        case .restartDaemon: return ProductStrings[.attentionActionRestart]
        case .reloadSettings: return ProductStrings[.attentionActionReload]
        case .openSettings(let pane):
            return String(format: ProductStrings[.settingsOpenPaneFormat], pane.title)
        case .showInstructions: return ProductStrings[.attentionActionShowInstructions]
        case .revealSettingsFile: return ProductStrings[.uninstallReveal]
        }
    }
}

/// One Attention row: what the gap is, in the app's own words, and at most one
/// thing to do about it.
public struct AttentionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let action: AttentionAction?

    public init(id: String, title: String, body: String, action: AttentionAction?) {
        precondition(!id.isEmpty, "an attention row needs an identifier")
        precondition(!title.isEmpty, "an attention row needs a title")

        self.id = id
        self.title = title
        self.body = body
        self.action = action
    }
}

/// The app's copy for every gap the daemon can report.
///
/// The daemon publishes the key; the wording is the app's, because the engine's
/// own sentences are command lines (`Run mix fermix.setup …`) that a native
/// window must never render.
public enum AttentionCatalogue {
    /// The row for a detail, with the daemon's own supporting text where the
    /// wire carries one (restart reasons, a legacy unit's path).
    public static func row(
        for detail: AttentionDetail,
        evidence: String? = nil,
        names: AttentionNames = .unread
    ) -> AttentionRow {
        AttentionRow(
            id: detail.wireKey,
            title: title(for: detail, names: names),
            body: body(for: detail, evidence: evidence),
            action: action(for: detail)
        )
    }

    public static func title(for detail: AttentionDetail, names: AttentionNames = .unread) -> String {
        switch detail {
        case .personalization: return ProductStrings[.attentionPersonalizationTitle]
        case .providerUnknown: return ProductStrings[.attentionProviderUnknownTitle]
        case .providerMultiplePrimary: return ProductStrings[.attentionProviderPrimaryTitle]
        case .providerInvalidAuthMode: return ProductStrings[.attentionProviderAuthModeTitle]
        case .providerCredentials(let provider):
            return String(
                format: ProductStrings[.attentionProviderCredentialsTitleFormat],
                names.provider(provider)
            )
        case .channel(let name):
            return String(format: ProductStrings[.attentionChannelTitleFormat], names.channel(name))
        case .voiceRealtime: return ProductStrings[.attentionVoiceTitle]
        case .restartPending: return ProductStrings[.attentionRestartTitle]
        case .externalConfigChange: return ProductStrings[.attentionExternalChangeTitle]
        case .configUnreadable: return ProductStrings[.attentionConfigUnreadableTitle]
        case .legacyServiceUnit: return ProductStrings[.attentionLegacyServiceTitle]
        case .secretACLRestricted: return ProductStrings[.attentionSecretACLTitle]
        case .unrecognized(let key): return key
        }
    }

    public static func body(for detail: AttentionDetail, evidence: String?) -> String {
        switch detail {
        case .personalization: return ProductStrings[.attentionPersonalizationBody]
        case .providerUnknown: return ProductStrings[.attentionProviderUnknownBody]
        case .providerMultiplePrimary: return ProductStrings[.attentionProviderPrimaryBody]
        case .providerInvalidAuthMode: return ProductStrings[.attentionProviderAuthModeBody]
        case .providerCredentials: return ProductStrings[.attentionProviderCredentialsBody]
        case .channel: return ProductStrings[.attentionChannelBody]
        case .voiceRealtime: return ProductStrings[.attentionVoiceBody]
        // The daemon owns the reason sentences; the app never composes its own
        // reason for a restart (M34 §5.10).
        case .restartPending: return evidence ?? ProductStrings[.attentionRestartBody]
        // One body per concept. The Settings banner and this row say the same
        // thing about the same file and offer the same action, and two bodies
        // for one state is two chances to describe it differently.
        case .externalConfigChange: return ProductStrings[.settingsExternalChangeBody]
        case .configUnreadable: return evidence ?? ProductStrings[.settingsConfigUnreadableBody]
        // The path is evidence, not the sentence: replacing the body with it left
        // the row saying nothing about what to do (M34 §15.2).
        case .legacyServiceUnit:
            guard let evidence else { return ProductStrings[.attentionLegacyServiceBody] }

            return ProductStrings.middot(ProductStrings[.attentionLegacyServiceBody], evidence)
        case .secretACLRestricted: return ProductStrings[.attentionSecretACLBody]
        case .unrecognized: return ProductStrings[.attentionUnrecognizedBody]
        }
    }

    /// The one action, where this build has one to offer.
    ///
    /// Every gap answered by a pane deep-links to it (decision D1). The three
    /// that are not answered by a pane keep no action: an unreadable settings
    /// file routes to Recovery through its own banner, and the two coexistence
    /// descriptors are answered outside Fermix, so their body says what to do.
    public static func action(for detail: AttentionDetail) -> AttentionAction? {
        switch detail {
        case .restartPending: return .restartDaemon
        case .externalConfigChange: return .reloadSettings
        case .personalization: return .openSettings(.personality)
        case .providerUnknown, .providerMultiplePrimary, .providerInvalidAuthMode, .providerCredentials:
            return .openSettings(.providers)
        case .channel: return .openSettings(.channels)
        case .voiceRealtime: return .openSettings(.voice)
        // Answered outside Fermix, so the row opens the sheet that prints the
        // commands rather than carrying none at all (M34 §15.2, §3.2).
        case .legacyServiceUnit: return .showInstructions
        // The remedy M34 §15.2 names for a key the keychain will not hand over
        // is `Replace…` on that provider's secret row, which rewrites the item
        // with an ACL this daemon can read.
        case .secretACLRestricted: return .openSettings(.providers)
        // The settings file is what has to be looked at, so the row opens it in
        // the Finder. The banner's own route into Recovery is unchanged.
        case .configUnreadable: return .revealSettingsFile
        case .unrecognized: return nil
        }
    }
}

/// A wire identifier read back as a word.
///
/// The last resort, for the one surface where the daemon publishes an id and no
/// name beside it: an OAuth client's provider. Never for a provider or a channel
/// a readiness failure names — those carry the product's own label on
/// `setup.state.get` and on the section index, and raising the first letter of
/// the id instead is what rendered `Connect Openai_codex`.
public enum WireIdentifier {
    public static func word(_ identifier: String) -> String {
        guard let first = identifier.first else { return identifier }

        return first.uppercased() + identifier.dropFirst()
    }
}
