import Foundation

/// The `home.provision.*` calls (M75 lean v1 §4.3): the cloud providers Fermix
/// creates the server on, a provider's token, what it sells, creating,
/// turning on, resetting and deleting the server Fermix made, and the record
/// of what it made.
///
/// Every provider is the engine's data: `home.provision.providers` names each
/// one and the words its token screen draws, so a provider the engine adds
/// needs nothing here. Each method is minimum version 2 and arrived inside
/// protocol 2, so the pane draws the provisioner only where `hello` lists all
/// seven (`ManagementMethod.homeProvisionMethods`); an engine without
/// `home.provision.providers` takes no `provider` and gets the update answer.
/// Create, power and delete start a `home_provision` job; connect, options
/// and resources call the provider in the request itself, so they wait
/// longer than the usual call (`DefaultManagementTimeoutPolicy.cloud`).

// MARK: - Vocabularies

/// Where the provisioner's record stands.
public enum ManagementProvisionState: ManagementVocabulary, Hashable {
    /// No token.
    case none
    case connected
    case creating
    /// The server exists and waits for its enrollment and move.
    case created
    case deleting
    /// Deleted outside Fermix.
    case gone
    /// The last create stopped: `failure` says why.
    case failed
    case unreadable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "none": .none,
        "connected": .connected,
        "creating": .creating,
        "created": .created,
        "deleting": .deleting,
        "gone": .gone,
        "failed": .failed,
        "unreadable": .unreadable
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Whether the provider takes the kept token.
public enum ManagementProvisionToken: ManagementVocabulary, Hashable {
    case none
    case accepted
    /// The provider stopped accepting it.
    case refused
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["none": .none, "accepted": .accepted, "refused": .refused]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where one thing Fermix created stands.
public enum ManagementProvisionStatus: ManagementVocabulary, Hashable {
    /// Written before the call that creates it.
    case requested
    case creating
    case created
    case deleting
    /// Deleted outside Fermix.
    case gone
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "requested": .requested,
        "creating": .creating,
        "created": .created,
        "deleting": .deleting,
        "gone": .gone
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What one thing Fermix created is.
public enum ManagementProvisionResourceKind: ManagementVocabulary, Hashable {
    case server
    case firewall
    case primaryIp
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "server": .server,
        "firewall": .firewall,
        "primary_ip": .primaryIp
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a replace of the server stands, from the desktop whose home lives on
/// it.
public enum ManagementProvisionReplaceState: ManagementVocabulary, Hashable {
    case creating
    /// The new server exists and waits for its enrollment and move.
    case waiting
    case moving
    /// The move is done; the old server is being deleted, once.
    case deleting
    case done
    case failed
    /// The new server is being deleted before the move.
    case cancelling
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "creating": .creating,
        "waiting": .waiting,
        "moving": .moving,
        "deleting": .deleting,
        "done": .done,
        "failed": .failed,
        "cancelling": .cancelling
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which server holds the home during a replace: the old one until the move
/// is done, then the new one.
public enum ManagementProvisionReplaceCurrent: ManagementVocabulary, Hashable {
    case old
    case new
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["old": .old, "new": .new]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// `home.provision.power`'s two actions: turn the server on, or reset it.
public enum ManagementProvisionPower: String, Encodable, CaseIterable, Sendable {
    case on
    case reset
}

// MARK: - The record

/// The server Fermix created, as its ledger last read it from the provider.
public struct ManagementProvisionServer: Decodable, Equatable, Sendable {
    public let name: String
    public let type: String
    /// A location id of the provider's own.
    public let location: String
    public let status: ManagementProvisionStatus
    /// The provider's status word as last read (`running`, `off` or another
    /// of its own); null before it was read.
    public let power: String?
    public let ipv4: String?
    public let createdAt: String?
    public let seenAt: String?

    private enum CodingKeys: String, CodingKey {
        case name, type, location, status, power, ipv4
        case createdAt = "created_at"
        case seenAt = "seen_at"
    }
}

/// Why the last create stopped, in the daemon's words. `reason` is a word the
/// app never switches on (`other` is a provider's own refusal); the sentence
/// is what it says.
public struct ManagementProvisionFailure: Decodable, Equatable, Sendable {
    public let reason: String
    public let sentence: String
    public let nextLocation: String?
    public let at: String

    private enum CodingKeys: String, CodingKey {
        case reason, sentence, at
        case nextLocation = "next_location"
    }
}

/// One thing Fermix created and its provider bills for until it is deleted.
public struct ManagementProvisionResource: Decodable, Equatable, Sendable {
    public let kind: ManagementProvisionResourceKind
    public let name: String?
    /// The provider's own id, opaque to Fermix; null until the provider
    /// answered with one. The app never sends it.
    public let id: String?
    public let status: ManagementProvisionStatus
    /// The old server's, while a replace keeps it.
    public let replaced: Bool
}

/// A replace of the server: where it stands, which server holds the home,
/// the old server's facts until it is deleted, and why it stopped.
public struct ManagementProvisionReplace: Decodable, Equatable, Sendable {
    public let state: ManagementProvisionReplaceState
    public let current: ManagementProvisionReplaceCurrent
    public let old: ManagementProvisionServer?
    public let failure: ManagementProvisionFailure?
}

/// `home.provision.connect` and `home.provision.resources`: what Fermix
/// created at a provider, from this computer's ledger of it. The token is
/// never answered.
public struct ManagementProvisionView: Decodable, Equatable, Sendable {
    /// The provider in use: the one Fermix created something on, else the one
    /// whose token was given last, else the first `home.provision.providers`
    /// lists; for `connect`, the one connected. Options and create name it.
    public let provider: String
    public let state: ManagementProvisionState
    public let token: ManagementProvisionToken
    public let server: ManagementProvisionServer?
    public let failure: ManagementProvisionFailure?
    /// While a replace is recorded, where it stands; `state` and `server` are
    /// then the new server's.
    public let replace: ManagementProvisionReplace?
    public let resources: [ManagementProvisionResource]
    public let sentence: String?
    /// `connect`: the project holds servers Fermix did not create.
    public let otherServers: Bool?
    /// `resources`: whether the provider was read just now; `sentence` says
    /// why not.
    public let checked: Bool?

    private enum CodingKeys: String, CodingKey {
        case provider, state, token, server, failure, replace, resources, sentence, checked
        case otherServers = "other_servers"
    }
}

// MARK: - The providers

/// One cloud provider Fermix creates the Always On server on, as
/// `home.provision.providers` lists it: what its token screen draws and what
/// Open console opens. A provider the engine adds is one more row, drawn the
/// same way.
public struct ManagementProvisionProvider: Decodable, Equatable, Hashable, Sendable {
    /// What connect, options and create take as `provider`.
    public let id: String
    /// How every sentence names it.
    public let name: String
    /// The token field's label.
    public let tokenLabel: String
    /// The "How to get one" steps.
    public let steps: [String]
    /// The provider's console, which `open_console` opens.
    public let consoleUrl: URL
    /// Its section of the Always On docs page.
    public let docsAnchor: String

    private enum CodingKeys: String, CodingKey {
        case id, name, steps
        case tokenLabel = "token_label"
        case consoleUrl = "console_url"
        case docsAnchor = "docs_anchor"
    }
}

/// `home.provision.providers`, in the order the app offers them.
public struct ManagementProvisionProviders: Decodable, Equatable, Sendable {
    public let providers: [ManagementProvisionProvider]
}

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

/// A type in a location: what Create server makes.
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

    /// A location's city, as the provider names it.
    public func city(_ location: String) -> String? {
        locations.first { $0.id == location }?.city
    }
}

// MARK: - What a call sends

/// The token for a provider, sent once and never kept here.
struct ManagementProvisionTokenParams: Encodable {
    let provider: String
    let token: String
}

/// The provider whose offers are read.
struct ManagementProvisionProviderParams: Encodable {
    let provider: String
}

/// The server to create, at the provider in use. `replace` is sent only as
/// true, from the desktop whose home lives on the server Fermix created.
struct ManagementProvisionCreateParams: Encodable {
    let provider: String
    let type: String
    let location: String
    let replace: Bool?
}

struct ManagementProvisionPowerParams: Encodable {
    let action: ManagementProvisionPower
}

extension ManagementMethod {
    /// The provisioner's methods: its screens are drawn only where the daemon
    /// lists every one, `home.provision.providers` among them, so an engine
    /// whose calls take no `provider` is never sent one.
    public static let homeProvisionMethods: Set<ManagementMethod> = [
        .homeProvisionProviders, .homeProvisionConnect, .homeProvisionOptions, .homeProvisionCreate,
        .homeProvisionPower, .homeProvisionResources, .homeProvisionDelete
    ]
}

// MARK: - The client

extension ManagementClient {
    /// Every provider Fermix creates the server on, in the order offered.
    public func provisionProviders() async throws -> ManagementProvisionProviders {
        try await send(.homeProvisionProviders, params: ManagementEmptyParams(), as: ManagementProvisionProviders.self)
    }

    /// Checks a token for one provider and keeps it on this computer only.
    public func provisionConnect(provider: String, token: String) async throws -> ManagementProvisionView {
        try await send(
            .homeProvisionConnect,
            params: ManagementProvisionTokenParams(
                provider: try requireText(provider, field: "provider"),
                token: try requireText(token, field: "token")
            ),
            as: ManagementProvisionView.self
        )
    }

    /// What one provider sells now.
    public func provisionOptions(provider: String) async throws -> ManagementProvisionOptions {
        try await send(
            .homeProvisionOptions,
            params: ManagementProvisionProviderParams(provider: try requireText(provider, field: "provider")),
            as: ManagementProvisionOptions.self
        )
    }

    /// Creates the server at a provider, or with `replace` a new one for the
    /// server the home lives on, as a `home_provision` job.
    public func provisionCreate(
        provider: String,
        _ pick: ManagementProvisionPick,
        replace: Bool = false
    ) async throws -> ManagementJob {
        try await send(
            .homeProvisionCreate,
            params: ManagementProvisionCreateParams(
                provider: try requireText(provider, field: "provider"),
                type: try requireText(pick.type, field: "type"),
                location: try requireText(pick.location, field: "location"),
                replace: replace ? true : nil
            ),
            as: ManagementJob.self
        )
    }

    public func provisionPower(_ action: ManagementProvisionPower) async throws -> ManagementJob {
        try await send(.homeProvisionPower, params: ManagementProvisionPowerParams(action: action), as: ManagementJob.self)
    }

    public func provisionResources() async throws -> ManagementProvisionView {
        try await send(.homeProvisionResources, params: ManagementEmptyParams(), as: ManagementProvisionView.self)
    }

    public func provisionDelete() async throws -> ManagementJob {
        try await send(.homeProvisionDelete, params: ManagementEmptyParams(), as: ManagementJob.self)
    }
}

// MARK: - The gateway

extension ManagementGateway {
    public func provisionProviders() async throws -> ManagementProvisionProviders {
        try await negotiated().provisionProviders()
    }

    public func provisionConnect(provider: String, token: String) async throws -> ManagementProvisionView {
        try await negotiated().provisionConnect(provider: provider, token: token)
    }

    public func provisionOptions(provider: String) async throws -> ManagementProvisionOptions {
        try await negotiated().provisionOptions(provider: provider)
    }

    public func provisionCreate(provider: String, _ pick: ManagementProvisionPick, replace: Bool) async throws -> ManagementJob {
        try await negotiated().provisionCreate(provider: provider, pick, replace: replace)
    }

    public func provisionPower(_ action: ManagementProvisionPower) async throws -> ManagementJob {
        try await negotiated().provisionPower(action)
    }

    public func provisionResources() async throws -> ManagementProvisionView {
        try await negotiated().provisionResources()
    }

    public func provisionDelete() async throws -> ManagementJob {
        try await negotiated().provisionDelete()
    }
}
