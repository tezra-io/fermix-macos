import Foundation

/// The one verb a provider row leads with (M34 §5.1, §4).
///
/// Detections change the verb and never add a row or a screen: a machine with
/// the Claude Code command line signed in shows `Use Claude Code sign-in` where
/// one without it shows `Add setup token`, and both are the same row.
public enum ProviderVerb: String, CaseIterable, Sendable {
    case signIn
    case importClaudeCode
    case importCodexCLI
    case addSetupToken
    case addKey
    /// Nothing to do: the provider is connected and primary.
    case none

    public var titleKey: ProductStringKey? {
        switch self {
        case .signIn: return .providerVerbSignIn
        case .importClaudeCode: return .providerVerbImportClaudeCode
        case .importCodexCLI: return .providerVerbImportCodexCLI
        case .addSetupToken: return .providerVerbAddSetupToken
        case .addKey: return .providerVerbAddKey
        case .none: return nil
        }
    }

    public var title: String? { titleKey.map { ProductStrings[$0] } }

    /// Whether this verb opens the key sheet, which cannot write anything until
    /// the daemon has named the slot the value belongs in.
    public var writesSecret: Bool { self == .addKey || self == .addSetupToken }
}

/// One provider row: what it is, where it stands, and the one thing to do.
public struct ProviderRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let status: String
    public let verb: ProviderVerb
    public let primary: Bool
    /// Whether the daemon reports this provider as usable. Only a configured
    /// provider may be made primary: offering it for one the daemon has no
    /// working credential for is a write it would refuse (M34 §5.1).
    public let configured: Bool
    /// Whether a credential sits at this provider's slot, which is what the
    /// detail page's secret row reads.
    public let presentKey: Bool
    /// The `secret.set` id this row's key sheet writes to, where the daemon has
    /// named one. Never minted from `id`: a provider id is not a secret id.
    public let secretID: String?

    /// The row reads as one sentence: the vendor, then where it stands.
    public var accessibilityLabel: String { ProductStrings.commaPair(label, status) }

    /// Whether the row's verb can be carried out right now. A verb that writes a
    /// secret waits for the slot the daemon publishes rather than guessing one,
    /// which is the same rule the channel row's enable switch follows.
    public var canPerform: Bool { !verb.writesSecret || secretID != nil }
}

/// One provider an API key can be typed for: which provider it is, what the
/// product calls it, and the `secret.set` slot the daemon named for it.
///
/// A target exists only once the slot is known, so the Add an API key sheet
/// cannot be opened over a provider it has nowhere to write to.
public struct ProviderKeyTarget: Identifiable, Equatable, Sendable {
    public let provider: String
    public let label: String
    public let secret: String

    public var id: String { provider }

    public init(provider: String, label: String, secret: String) {
        precondition(!provider.isEmpty, "a key target names its provider")
        precondition(!secret.isEmpty, "a key target names the slot it writes to")

        self.provider = provider
        self.label = label
        self.secret = secret
    }
}

/// Turning `setup.state.get.providers` into rows.
///
/// Every fact is the daemon's. What this owns is the wording of the six status
/// words M34 §5.1 publishes and which verb a row leads with, both of which are
/// app copy rather than engine copy.
public enum ProviderRowProjection {
    /// The provider each import source belongs to. This pairing is the
    /// contract's own: `setup.detect {claude_code}` exists to answer for
    /// Anthropic and `{codex_cli}` for ChatGPT, and nothing else can pair them.
    public static let importSources: [String: ManagementDetectTarget] = [
        anthropicProvider: .claudeCode,
        "openai_codex": .codexCLI
    ]

    /// Anthropic, which is the one provider whose doors are not the ones its
    /// `auth_modes` suggest.
    public static let anthropicProvider = "anthropic"

    /// Every provider `auth.start` will actually start a browser sign-in for.
    ///
    /// `auth_modes` is not that answer. Anthropic publishes `oauth` there and
    /// `auth.start` refuses it — the daemon has no loopback flow for it, and its
    /// two ways in are an adopted Claude Code sign-in and a setup token. A row
    /// that read the mode and offered `Sign in` earned `This provider has no
    /// browser sign-in.` on every click.
    public static let browserSignInProviders: Set<String> = ["openai_codex", "xai"]

    /// The auth mode that means a browser hop rather than a typed key.
    public static let oauthMode = "oauth"

    /// The auth mode that means a key the operator types.
    public static let apiKeyMode = "api_key"

    /// The auth mode of a provider that needs no credential at all.
    public static let noAuthMode = "none"

    /// The two vendors Connect your AI names outright (M34 §4). The assistant
    /// draws three rows and no more: these two, and the API key door beside
    /// them. Every other provider the daemon publishes is reachable through
    /// that door's picker and through the Providers pane.
    public static let assistantProviders = ["openai_codex", "anthropic"]

    /// Token states that mean the credential is there and no longer works.
    public static let staleTokenStates: Set<String> = ["expired", "invalid", "revoked"]

    /// The one `secret.set` id the app names outright. M34 §7.3 lists it among
    /// the ids the method takes, and §7.4 has the daemon write it through
    /// `Auth.Store` rather than a `SecretPaths` path — so unlike every other
    /// provider credential, no descriptor row carries it and it cannot be read
    /// off one.
    public static let anthropicSetupTokenID = "anthropic_setup_token"

    /// The section the daemon publishes for one provider's own rows. M34 §5.1:
    /// Providers is one pane over Primary plus one section per descriptor id.
    public static func sectionId(for provider: String) -> String {
        precondition(!provider.isEmpty, "a provider section is named after its provider")

        return ManagementSettingsSection.providerPrefix + provider
    }

    /// The provider whose own section leads the pane: the one `draws(.pane,
    /// primary:)` answers for (M34 §5.1).
    ///
    /// Nil where the daemon reports no primary, which is a fresh home: there is
    /// no model in use to put at the top of the pane yet.
    public static func paneProvider(in providers: [ManagementSetupProvider]) -> ManagementSetupProvider? {
        providers.first { draws(.pane, primary: $0.primary) }
    }

    /// Which surface draws one provider's own descriptor rows (M34 §5.1).
    ///
    /// The primary's are the pane's headline — the model in use, its reasoning
    /// effort, its fast mode — because reaching the one fact most visits come
    /// for through a row's `Details…` hid it. Every other provider's belong to
    /// its sub-page, which is what keeps the pane from becoming the longest
    /// scroll in the app.
    ///
    /// It is the primary's *whole* section rather than three rows chosen by
    /// name: which rows a provider publishes is the daemon's answer, and naming
    /// them here would be the field inventory M34 §7.7 forbids. One rule read
    /// by both surfaces, so no key can end up with a control on each.
    public static func draws(_ surface: ProviderRowsSurface, primary: Bool) -> Bool {
        switch surface {
        case .pane: return primary
        case .subPage: return !primary
        }
    }

    /// - Parameter descriptorRows: the rows of each provider's own section, by
    ///   provider id. It is where a provider's key slot comes from; a provider
    ///   whose section has not been read yet simply has no slot yet.
    public static func rows(
        providers: [ManagementSetupProvider],
        detections: ManagementDetections?,
        signingIn: String?,
        descriptorRows: [String: [ManagementSettingRow]],
        selectedAuthModes: [String: String] = [:]
    ) -> [ProviderRowModel] {
        providers.map { provider in
            let verb = verb(for: provider, detections: detections, selectedAuthMode: selectedAuthModes[provider.id])

            return ProviderRowModel(
                id: provider.id,
                label: provider.label,
                status: status(of: provider, signingIn: signingIn),
                verb: verb,
                primary: provider.primary,
                configured: provider.configured,
                presentKey: provider.presentKey,
                secretID: secretID(for: verb, rows: descriptorRows[provider.id] ?? [])
            )
        }
    }

    /// Connect your AI's two vendor rows, in the design's order.
    ///
    /// A vendor the daemon does not publish simply has no row: the assistant
    /// never invents a provider the engine has not named.
    public static func assistantRows(
        providers: [ManagementSetupProvider],
        detections: ManagementDetections?,
        signingIn: String?,
        descriptorRows: [String: [ManagementSettingRow]]
    ) -> [ProviderRowModel] {
        let published = rows(
            providers: providers,
            detections: detections,
            signingIn: signingIn,
            descriptorRows: descriptorRows
        )

        return assistantProviders.compactMap { named in published.first { $0.id == named } }
    }

    /// Every provider the operator may type a key for, in the daemon's order.
    ///
    /// A provider whose section has not been read yet has no slot yet, so it is
    /// left out rather than offered with nowhere to write.
    public static func keyTargets(
        providers: [ManagementSetupProvider],
        descriptorRows: [String: [ManagementSettingRow]]
    ) -> [ProviderKeyTarget] {
        providers.compactMap { provider in
            guard provider.authModes.contains(apiKeyMode) else { return nil }
            guard let secret = secretID(for: .addKey, rows: descriptorRows[provider.id] ?? []) else { return nil }

            return ProviderKeyTarget(provider: provider.id, label: provider.label, secret: secret)
        }
    }

    /// The `secret.set` id a row's key sheet writes to.
    ///
    /// A provider id is never a secret id: M34 §7.3 spells the ids as
    /// `SecretPaths` slots (`openai_api_key`), which `anthropic` and
    /// `openai_codex` are not. The slot is therefore read off the secret row the
    /// daemon published in that provider's own section, exactly as the model
    /// picker reads its listing off the row's shape. Anthropic's setup token is
    /// the one id no descriptor row can carry, and the contract names it.
    public static func secretID(for verb: ProviderVerb, rows: [ManagementSettingRow]) -> String? {
        switch verb {
        case .addSetupToken:
            return anthropicSetupTokenID
        case .addKey:
            return rows.first { $0.kind == .secret }?.key
        case .signIn, .importClaudeCode, .importCodexCLI, .none:
            return nil
        }
    }

    /// Replacing a connected account uses the same credential flows as its
    /// first connection, without signing out the current account first.
    public static func detailAuthVerbs(
        for provider: String,
        detections: ManagementDetections?,
        authMode: String? = nil
    ) -> [ProviderVerb] {
        precondition(!provider.isEmpty, "provider authentication actions name their provider")
        guard authMode != apiKeyMode else { return [] }

        var verbs: [ProviderVerb] = browserSignInProviders.contains(provider) ? [.signIn] : []
        if let source = importSources[provider], detections?.result(for: source)?.present == true {
            verbs.append(source == .claudeCode ? .importClaudeCode : .importCodexCLI)
        }
        if provider == anthropicProvider { verbs.append(.addSetupToken) }

        return verbs
    }

    /// The six status words of M34 §5.1, in the order they win.
    static func status(of provider: ManagementSetupProvider, signingIn: String?) -> String {
        if provider.id == signingIn { return ProductStrings[.providerStatusSigningIn] }

        if let token = provider.tokenState, staleTokenStates.contains(token) {
            return ProductStrings[.providerStatusReconnect]
        }

        if provider.primary, !provider.configured {
            return ProductStrings.middot(
                ProductStrings[.providerStatusPrimary], ProductStrings[.providerStatusNotConnected]
            )
        }

        if provider.primary {
            guard let model = provider.defaultModel, !model.isEmpty else {
                return ProductStrings[.providerStatusPrimary]
            }

            return ProductStrings.middot(ProductStrings[.providerStatusPrimary], model)
        }

        if provider.configured { return ProductStrings[.providerStatusConnected] }
        if provider.presentKey { return ProductStrings[.providerStatusKeyUnverified] }

        return ProductStrings[.providerStatusNotConnected]
    }

    /// The verb, which the detections move and nothing else does.
    static func verb(
        for provider: ManagementSetupProvider,
        detections: ManagementDetections?,
        selectedAuthMode: String? = nil
    ) -> ProviderVerb {
        // A provider that takes no credential has nothing to add. Ollama
        // answers on localhost, and the key verb on it was a button that could
        // never be pressed (M34 §5.1).
        if provider.authModes == [noAuthMode] { return .none }

        let tokenUsable = provider.tokenState.map { !staleTokenStates.contains($0) } ?? true
        // A provider the daemon already reports as working has nothing for the
        // list to do: `Replace…` and `Sign out` live on its own sub-page, which
        // is where everything belonging to one provider lives.
        if provider.configured, tokenUsable, provider.primary || provider.presentKey { return .none }
        if selectedAuthMode == apiKeyMode { return .addKey }

        if let source = importSources[provider.id], detections?.result(for: source)?.present == true {
            return source == .claudeCode ? .importClaudeCode : .importCodexCLI
        }

        // Before the sign-in branch, because Anthropic publishes `oauth` and has
        // no browser flow: its door is the setup token `secret.set` takes under
        // `anthropic_setup_token`, and the key door beside these rows takes its
        // API key.
        if provider.id == anthropicProvider { return .addSetupToken }
        if provider.authModes.contains(oauthMode) { return .signIn }

        return .addKey
    }
}

/// The two surfaces that can draw a provider's own descriptor rows.
public enum ProviderRowsSurface: String, CaseIterable, Equatable, Sendable {
    /// The Providers pane's first section.
    case pane
    /// The provider sub-page opened from a row's `Details…`.
    case subPage
}
