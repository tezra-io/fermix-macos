import Foundation

/// `home.act` (Always On setup §3.4): one Always On step, what the step's
/// `needs` collected, and the answer, which is the summary after the step and
/// the step's own result.

// MARK: - What a step sends

/// What an action's `needs` collected: a token (and the provider it is for,
/// where the summary lists more than one), the recovery passphrase (typed
/// once, or twice and compared here), or a size and place. Only the fields
/// given are sent. The token and the passphrase are withheld from every
/// print, so no log line or test failure carries either.
public struct ManagementHomeActInput: Encodable, Equatable, Sendable,
                                      CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let token: String?
    public let provider: String?
    public let recoveryPassphrase: String?
    public let type: String?
    public let location: String?

    public init(
        token: String? = nil,
        provider: String? = nil,
        recoveryPassphrase: String? = nil,
        type: String? = nil,
        location: String? = nil
    ) {
        precondition(token.map { !$0.isEmpty } ?? true, "a token is sent as text")
        precondition(recoveryPassphrase.map { !$0.isEmpty } ?? true, "a recovery passphrase is sent as text")
        precondition((type == nil) == (location == nil), "a size is sent with its place")
        self.token = token
        self.provider = provider
        self.recoveryPassphrase = recoveryPassphrase
        self.type = type
        self.location = location
    }

    /// Nothing was collected, so `home.act` is sent without `input`.
    var isEmpty: Bool {
        token == nil && provider == nil && recoveryPassphrase == nil && type == nil && location == nil
    }

    public var description: String {
        "ManagementHomeActInput(token: \(Self.shown(token)), provider: \(provider ?? "none"), "
            + "recovery_passphrase: \(Self.shown(recoveryPassphrase)), type: \(type ?? "none"), location: \(location ?? "none"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private static func shown(_ secret: String?) -> String {
        secret == nil ? "none" : "withheld"
    }

    private enum CodingKeys: String, CodingKey {
        case token, provider, type, location
        case recoveryPassphrase = "recovery_passphrase"
    }
}

// MARK: - The answer

/// `own_server`'s code for a server of the owner's own, answered once and
/// never again, with the command the server runs, which carries no code: the
/// server asks for the code as it first boots. The code is withheld from
/// every print.
public struct ManagementOwnServerCode: Decodable, Equatable, Sendable,
                                       CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let code: String
    public let expiresAt: String
    public let command: String

    public var description: String { "ManagementOwnServerCode(withheld, until \(expiresAt))" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private enum CodingKeys: String, CodingKey {
        case code, command
        case expiresAt = "expires_at"
    }
}

/// A step's own result, where it has one.
public enum ManagementHomeActResult: Decodable, Equatable, Sendable {
    /// `own_server`: the code, once.
    case ownServer(ManagementOwnServerCode)
    /// `move_now` and `try_again`: the move begun.
    case move(id: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.code) {
            self = .ownServer(try ManagementOwnServerCode(from: decoder))
            return
        }
        self = .move(id: try container.decode(String.self, forKey: .moveId))
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case moveId = "move_id"
    }
}

/// `home.act`: the summary after the step, which the app draws, and the
/// step's result.
public struct ManagementHomeActed: Decodable, Equatable, Sendable {
    public let summary: ManagementHomeSummary
    public let result: ManagementHomeActResult?
}
