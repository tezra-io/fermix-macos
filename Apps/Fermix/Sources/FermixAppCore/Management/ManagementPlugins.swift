import Foundation

/// The typed results of the `plugins.*` methods.
///
/// Every word on a plugin row is the daemon's: the status sentence, the verb
/// labels, the consent sentence and the remote disclosure all come from the
/// manifest or the registry. The app arranges them and writes none of them.

public struct ManagementPluginSetting: Decodable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let value: String?
    public let required: Bool
}

/// One access profile the plugin's manifest publishes (M34 §5.6).
///
/// `write` is the daemon's, not a word the app parses out of the label: the
/// workspace sheet warns about a write-scoped profile before it is chosen, and
/// inferring that from a name would be the app deciding what a scope means.
public struct ManagementPluginAccessProfile: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let write: Bool
}

/// One workspace a discovery found. The list is the daemon's answer to
/// `plugins.workspaces.discover.start`, republished on the plugin row: a job
/// result is flat scalars only, so the rows themselves cannot ride on it.
public struct ManagementPluginWorkspace: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
}

public struct ManagementPlugin: Decodable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let version: String?
    /// How the plugin runs, or null for the http rail that runs inside Fermix.
    /// The daemon derives the consent sentence from it, so the app never maps
    /// the word itself.
    public let runtimeKind: ManagementPluginRuntimeKind?
    /// The credential kind, or null for a plugin that needs none.
    public let authKind: ManagementPluginAuthKind?
    public let installed: Bool
    public let enabled: Bool
    /// The status word behind the sentence, from `x-plugin-vocabulary.statuses`.
    /// It is carried so a support log and a filter can name the state; nothing
    /// drawn on the row is composed from it.
    public let status: String
    public let statusSentence: String
    /// Whether a credential is stored for this plugin. Never the credential.
    public let credentialPresent: Bool
    /// The sign-in family this plugin belongs to, which is what ties it to an
    /// entry in `oauth_clients`. Null for a plugin that signs in on its own or
    /// needs no credential at all.
    public let authProvider: String?
    /// The one verb the row leads with, where it has one. A word to paint,
    /// never a routing key.
    public let primaryVerb: String?
    /// Which method the leading verb runs. Null exactly when `primaryVerb` is,
    /// and the only thing the leading button dispatches on.
    public let primaryAction: ManagementPluginAction?
    public let verbs: [String]
    /// One action id per entry in `verbs`, in the same order. An empty list is
    /// a row with no verb buttons at all, not a row whose verbs are unknown.
    public let actions: [ManagementPluginAction]
    public let settings: [ManagementPluginSetting]
    public let accountLabel: String?
    /// What installing this plugin means, in the daemon's own words. Never
    /// absent: the contract requires it on every row, and a consent sheet that
    /// could omit the line is a consent sheet that can ask for nothing.
    public let consentSentence: String
    /// What leaves this machine, for a plugin that runs somewhere else.
    public let remoteDisclosure: String?
    /// The one-line description the page's row carries under the name. The
    /// manifest's, like every other word on the row.
    public let summary: String?
    /// The scopes the manifest offers, for a plugin that binds to a workspace.
    /// Empty on every plugin that does not.
    public let accessProfiles: [ManagementPluginAccessProfile]
    /// What the last discovery found. Empty until one has run.
    public let workspaces: [ManagementPluginWorkspace]
    /// The workspace this plugin is bound to, where it is bound to one.
    public let workspaceId: String?
    public let workspaceLabel: String?

    private enum CodingKeys: String, CodingKey {
        case name, title, version, installed, enabled, status, verbs, actions, settings, summary
        case workspaces
        case runtimeKind = "runtime_kind"
        case authKind = "auth_kind"
        case statusSentence = "status_sentence"
        case credentialPresent = "credential_present"
        case authProvider = "auth_provider"
        case primaryVerb = "primary_verb"
        case primaryAction = "primary_action"
        case accountLabel = "account_label"
        case consentSentence = "consent_sentence"
        case remoteDisclosure = "remote_disclosure"
        case accessProfiles = "access_profiles"
        case workspaceId = "workspace_id"
        case workspaceLabel = "workspace_label"
    }
}

/// An OAuth client the operator registered for a provider. The client secret is
/// never here: only its independent presence accompanies the public client ID.
public struct ManagementPluginOAuthClient: Decodable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let configured: Bool
    public let redirectPort: Int?
    public let clientId: String?
    /// Nil means an earlier protocol-2 engine did not publish this fact.
    public let secretPresent: Bool?

    public init(
        provider: String,
        configured: Bool,
        redirectPort: Int?,
        clientId: String? = nil,
        secretPresent: Bool? = nil
    ) {
        precondition(!provider.isEmpty, "an OAuth client names its provider")
        self.provider = provider
        self.configured = configured
        self.redirectPort = redirectPort
        self.clientId = clientId
        self.secretPresent = secretPresent
    }

    /// The provider, which is what a client is addressed by everywhere: the
    /// list, `plugins.oauth_client.set`, and the sheet the row opens.
    public var id: String { provider }

    private enum CodingKeys: String, CodingKey {
        case provider, configured
        case redirectPort = "redirect_port"
        case clientId = "client_id"
        case secretPresent = "secret_present"
    }
}

public struct ManagementPluginCatalog: Decodable, Equatable, Sendable {
    public let plugins: [ManagementPlugin]
    public let oauthClients: [ManagementPluginOAuthClient]

    private enum CodingKeys: String, CodingKey {
        case plugins
        case oauthClients = "oauth_clients"
    }
}

/// One plugin row, as every plugin verb answers.
public struct ManagementPluginRow: Decodable, Equatable, Sendable {
    public let plugin: ManagementPlugin
}

public struct ManagementPluginOAuthClientRow: Decodable, Equatable, Sendable {
    public let oauthClient: ManagementPluginOAuthClient

    private enum CodingKeys: String, CodingKey {
        case oauthClient = "oauth_client"
    }
}
