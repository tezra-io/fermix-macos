import Foundation

/// The folders the server may read on this computer beyond its sandbox (M75):
/// each one the owner allowed on a card on the server, listed and removed here.
/// Answered by this computer's own engine and never forwarded, so they work
/// while the server is out of reach. A removal holds for the server's next
/// read.

/// One folder the server may read here, and when the owner allowed it.
public struct ManagementDeviceGrant: Decodable, Equatable, Sendable {
    public let path: String
    public let grantedAt: String

    private enum CodingKeys: String, CodingKey {
        case path
        case grantedAt = "granted_at"
    }
}

/// `device.grants.list`: the grants, oldest first, and the daemon's sentence.
public struct ManagementDeviceGrants: Decodable, Equatable, Sendable {
    public let grants: [ManagementDeviceGrant]
    public let sentence: String
}

/// `device.grants.remove`: the folder removed, the grants left, and the
/// daemon's sentence.
public struct ManagementDeviceGrantRemoved: Decodable, Equatable, Sendable {
    public let removed: String
    public let grants: [ManagementDeviceGrant]
    public let sentence: String
}

/// The folder a grant is removed for, as listed.
struct ManagementDeviceGrantParams: Encodable {
    let path: String
}

extension ManagementClient {
    public func deviceGrants() async throws -> ManagementDeviceGrants {
        try await send(.deviceGrantsList, params: ManagementEmptyParams(), as: ManagementDeviceGrants.self)
    }

    public func removeDeviceGrant(path: String) async throws -> ManagementDeviceGrantRemoved {
        try await send(
            .deviceGrantsRemove,
            params: ManagementDeviceGrantParams(path: try requireText(path, field: "path")),
            as: ManagementDeviceGrantRemoved.self
        )
    }
}

extension ManagementGateway {
    public func deviceGrants() async throws -> ManagementDeviceGrants {
        try await negotiated().deviceGrants()
    }

    public func removeDeviceGrant(path: String) async throws -> ManagementDeviceGrantRemoved {
        try await negotiated().removeDeviceGrant(path: path)
    }
}
