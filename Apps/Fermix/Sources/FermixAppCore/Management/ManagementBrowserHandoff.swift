import Foundation

/// The browser sign-in and session hand-off methods (M75 §10), modelled so the
/// catalog is the contract's. No surface of this app calls them yet: a
/// hand-off is started on the desktop by the owner, and the Mac app draws
/// none of it.

// MARK: - Results

/// `browser.signin.open`: Chrome open on the owner profile at the address.
public struct ManagementBrowserSignInOpened: Decodable, Equatable, Sendable {
    public let sentence: String
}

/// One site of a hand-off, and how many of its cookies went.
public struct ManagementBrowserHandoffSite: Decodable, Equatable, Sendable {
    public let site: String
    public let cookies: Int
}

/// `browser.handoff.send`: what the primary stored, and until when.
public struct ManagementBrowserHandoffSent: Decodable, Equatable, Sendable {
    public let handoffId: String
    public let sites: [ManagementBrowserHandoffSite]
    public let cookiesSent: Int
    public let cookiesStored: Int
    public let expiresAt: String
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case sites, sentence
        case handoffId = "handoff_id"
        case cookiesSent = "cookies_sent"
        case cookiesStored = "cookies_stored"
        case expiresAt = "expires_at"
    }
}

/// One hand-off the primary stores: never a cookie's name or value.
public struct ManagementBrowserHandoff: Decodable, Equatable, Sendable {
    public let handoffId: String
    public let from: String
    public let sites: [String]
    public let cookies: Int
    public let storedAt: String
    public let expiresAt: String
    public let expired: Bool

    private enum CodingKeys: String, CodingKey {
        case from, sites, cookies, expired
        case handoffId = "handoff_id"
        case storedAt = "stored_at"
        case expiresAt = "expires_at"
    }
}

/// `browser.handoffs.list`.
public struct ManagementBrowserHandoffList: Decodable, Equatable, Sendable {
    public let handoffs: [ManagementBrowserHandoff]
    public let sentence: String
}

/// `browser.handoffs.wipe`: the sites wiped (null for every hand-off) and, on
/// the primary, how many cookies went (null on a desktop).
public struct ManagementBrowserHandoffsWiped: Decodable, Equatable, Sendable {
    public let sites: [String]?
    public let cookies: Int?
    public let sentence: String
}

// MARK: - What a call sends

struct ManagementBrowserSignInParams: Encodable {
    let url: String
}

struct ManagementBrowserHandoffParams: Encodable {
    let sites: [String]
    let expiresSeconds: Int?
    let allowIdentityProvider: Bool?

    private enum CodingKeys: String, CodingKey {
        case sites
        case expiresSeconds = "expires_s"
        case allowIdentityProvider = "allow_identity_provider"
    }
}

struct ManagementBrowserWipeParams: Encodable {
    /// Absent wipes every hand-off.
    let sites: [String]?
}

// MARK: - The client

extension ManagementClient {
    public func openBrowserSignIn(url: String) async throws -> ManagementBrowserSignInOpened {
        try await send(
            .browserSigninOpen,
            params: ManagementBrowserSignInParams(url: try requireText(url, field: "url")),
            as: ManagementBrowserSignInOpened.self
        )
    }

    public func sendBrowserHandoff(
        sites: [String],
        expiresSeconds: Int? = nil,
        allowIdentityProvider: Bool? = nil
    ) async throws -> ManagementBrowserHandoffSent {
        guard !sites.isEmpty else { throw ManagementError.invalidParameter(.empty(field: "sites")) }

        return try await send(
            .browserHandoffSend,
            params: ManagementBrowserHandoffParams(
                sites: sites,
                expiresSeconds: expiresSeconds,
                allowIdentityProvider: allowIdentityProvider
            ),
            as: ManagementBrowserHandoffSent.self
        )
    }

    public func browserHandoffs() async throws -> ManagementBrowserHandoffList {
        try await send(.browserHandoffsList, params: ManagementEmptyParams(), as: ManagementBrowserHandoffList.self)
    }

    /// Wipes the hand-offs of the sites named, or every one where none is.
    public func wipeBrowserHandoffs(sites: [String]? = nil) async throws -> ManagementBrowserHandoffsWiped {
        try await send(
            .browserHandoffsWipe,
            params: ManagementBrowserWipeParams(sites: sites),
            as: ManagementBrowserHandoffsWiped.self
        )
    }
}
