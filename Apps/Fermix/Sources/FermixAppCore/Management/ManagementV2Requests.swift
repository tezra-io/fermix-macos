import Foundation

/// The parameter objects of the protocol v2 methods.
///
/// Each is a plain `Encodable` whose coding keys are the wire names, so an
/// optional field is omitted rather than sent as null and takes the daemon's
/// published default. The one exception is a settings value, where null is a
/// value with a meaning (forget the key) and is carried as
/// `ManagementSettingValue.absent`.

struct ManagementDetectParams: Encodable {
    let targets: [ManagementDetectTarget]
}

struct ManagementSectionParams: Encodable {
    let section: String
}

struct ManagementSettingsApplyParams: Encodable {
    let section: String
    let values: [String: ManagementSettingValue]
}

struct ManagementSecretSetParams: Encodable {
    let id: String
    /// The one parameter in the whole protocol that may carry a secret. It is
    /// never logged, never persisted by the app, and never put on the
    /// pasteboard.
    let value: String
}

struct ManagementSecretIdentifierParams: Encodable {
    let id: String
}

struct ManagementProviderParams: Encodable {
    let provider: String
}

struct ManagementModelListParams: Encodable {
    let provider: String
    let live: Bool
    let query: String?
    let cursor: String?
    let limit: Int?
}

struct ManagementJobParams: Encodable {
    let jobId: String

    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
    }
}

struct ManagementAuthImportParams: Encodable {
    let source: ManagementAuthImportSource
}

struct ManagementPluginNameParams: Encodable {
    let name: String
}

struct ManagementWorkspaceSelectParams: Encodable {
    let name: String
    let profile: String
    let workspaceId: String
    let label: String

    private enum CodingKeys: String, CodingKey {
        case name, profile, label
        case workspaceId = "workspace_id"
    }
}

struct ManagementOAuthClientParams: Encodable {
    let provider: String
    let clientId: String
    let redirectPort: Int?

    private enum CodingKeys: String, CodingKey {
        case provider
        case clientId = "client_id"
        case redirectPort = "redirect_port"
    }
}

struct ManagementPluginSettingParams: Encodable {
    let name: String
    let key: String
    let value: ManagementSettingValue
}

struct ManagementCapabilityInstallParams: Encodable {
    let target: ManagementCapabilityTarget
}
