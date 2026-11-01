import Foundation

/// `home.provision.options` (M75 lean v1 §4.3, Always On setup §3.5): what the
/// cloud provider in use sells now, read live, for the choice of size and
/// place that Create server and Replace the server collect (`needs`
/// `choice`). The engine knows which provider is in use, so the app names
/// none. It is the one provisioner method left on the wire: every step on
/// the provider is `home.act`. It calls the provider inside the request, so
/// it waits longer than the usual call (`DefaultManagementTimeoutPolicy.cloud`).

// MARK: - What a provider sells

/// One location the options name, by the provider's own id.
public struct ManagementProvisionLocation: Decodable, Equatable, Sendable {
    public let id: String
    public let city: String
    public let country: String
}

/// One type in one location. The prices are monthly and gross, as decimal
/// strings in the account's currency, drawn as they are given;
/// `totalMonthly` adds the IPv4 address.
public struct ManagementProvisionOffer: Decodable, Equatable, Sendable {
    public let type: String
    public let description: String
    public let cores: Int
    public let memoryGb: Double
    public let diskGb: Int
    public let dedicated: Bool
    public let location: String
    public let monthly: String
    public let ipv4Monthly: String
    public let totalMonthly: String

    private enum CodingKeys: String, CodingKey {
        case type, description, cores, dedicated, location, monthly
        case memoryGb = "memory_gb"
        case diskGb = "disk_gb"
        case ipv4Monthly = "ipv4_monthly"
        case totalMonthly = "total_monthly"
    }
}

/// A type in a location: what the choice sends.
public struct ManagementProvisionPick: Codable, Equatable, Hashable, Sendable {
    public let type: String
    public let location: String

    public init(type: String, location: String) {
        precondition(!type.isEmpty, "a server is created of a type")
        precondition(!location.isEmpty, "a server is created in a location")
        self.type = type
        self.location = location
    }
}

/// `home.provision.options`: what a provider sells now, read live.
public struct ManagementProvisionOptions: Decodable, Equatable, Sendable {
    public let currency: String
    public let locations: [ManagementProvisionLocation]
    public let offers: [ManagementProvisionOffer]
    public let recommended: ManagementProvisionPick?
    public let moreRoom: ManagementProvisionPick?
    /// The recommendation, or that nothing is in stock.
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case currency, locations, offers, recommended, sentence
        case moreRoom = "more_room"
    }

    /// The offer a pick names, where the provider sells it.
    public func offer(_ pick: ManagementProvisionPick) -> ManagementProvisionOffer? {
        offers.first { $0.type == pick.type && $0.location == pick.location }
    }
}

// MARK: - The client

extension ManagementClient {
    /// What the provider in use sells now. The one place this call's params
    /// are written: it sends none.
    public func provisionOptions() async throws -> ManagementProvisionOptions {
        try await send(.homeProvisionOptions, params: ManagementEmptyParams(), as: ManagementProvisionOptions.self)
    }
}

// MARK: - The gateway

extension ManagementGateway {
    public func provisionOptions() async throws -> ManagementProvisionOptions {
        try await negotiated().provisionOptions()
    }
}
