import Foundation

/// The typed results of the secret, provider and computer-use methods.

/// What a secret write or clear did. `present` is the secret store's own
/// answer — a reference or a plaintext value sits at the key's path — and never
/// "the keychain holds an item", which is the distinction M34 §7.4 exists for.
public struct ManagementSecretState: Decodable, Equatable, Sendable {
    public let id: String
    public let present: Bool
    public let restart: ManagementRestartState
}

/// What choosing a primary provider did, including the changes the operator did
/// not type, in the daemon's sentences.
public struct ManagementPrimaryProviderResult: Decodable, Equatable, Sendable {
    public let restart: ManagementRestartState
    public let sideEffects: [String]

    private enum CodingKeys: String, CodingKey {
        case restart
        case sideEffects = "side_effects"
    }
}

public struct ManagementProviderModel: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
}

/// One page of models. `source` says whether the page came from the catalog or
/// from the provider: a live fetch that fails answers `unavailable` rather than
/// returning the catalog under a live label.
public struct ManagementProviderModels: Decodable, Equatable, Sendable {
    public let models: [ManagementProviderModel]
    public let cursor: String?
    public let source: ManagementModelSource
    public let truncated: Bool
}

/// The computer-use permission probe. Non-prompting: it reports what is granted
/// and never asks for it, which `computer_use.grant.start` does explicitly.
public struct ManagementComputerUsePermissions: Decodable, Equatable, Sendable {
    public let installed: Bool
    public let screenCapture: Bool
    public let inputControl: Bool
    public let probedAt: String?

    private enum CodingKeys: String, CodingKey {
        case installed
        case screenCapture = "screen_capture"
        case inputControl = "input_control"
        case probedAt = "probed_at"
    }
}
