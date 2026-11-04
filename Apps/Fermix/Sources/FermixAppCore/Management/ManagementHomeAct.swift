import Foundation

/// `home.act` (Always On setup §3.4): one Always On step, what the step's
/// `needs` collected, and the answer, which is the summary after the step and
/// the step's own result.

// MARK: - What a step sends

/// What an action's `needs` collected: the recovery passphrase, typed once,
/// or twice and compared here. It is withheld from every print, so no log
/// line or test failure carries it.
public struct ManagementHomeActInput: Encodable, Equatable, Sendable,
                                      CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let recoveryPassphrase: String

    public init(recoveryPassphrase: String) {
        precondition(!recoveryPassphrase.isEmpty, "a recovery passphrase is sent as text")
        self.recoveryPassphrase = recoveryPassphrase
    }

    public var description: String { "ManagementHomeActInput(recovery_passphrase: withheld)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private enum CodingKeys: String, CodingKey {
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
