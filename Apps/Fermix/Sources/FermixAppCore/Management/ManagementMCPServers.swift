import Foundation

/// The typed results of the `mcp.servers.*` methods (M74 §5).
///
/// An operator server is one `[mcp.servers.<name>]` entry the daemon owns and
/// publishes. Every sentence on its row is the daemon's: the status line, the
/// consent line and the last error. The app arranges them, titles the
/// published action ids in its own words, and writes none of the state.

// MARK: - Vocabularies

/// Where a server's code runs: a program on this Mac or an endpoint at a URL.
public enum ManagementMCPTransport: ManagementVocabulary, Hashable {
    case stdio
    case http
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["stdio": .stdio, "http": .http]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a server stands (`x-mcp-server-vocabulary.statuses`). Published for
/// logs and support: the app draws `status_sentence` and switches on the
/// action ids, never on this.
public enum ManagementMCPStatus: ManagementVocabulary, Hashable {
    case off
    case needsSecret
    case needsSignIn
    case starting
    case connected
    case retrying
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "off": .off,
        "needs_secret": .needsSecret,
        "needs_sign_in": .needsSignIn,
        "starting": .starting,
        "connected": .connected,
        "retrying": .retrying,
        "failed": .failed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which method a server row's button runs (`mcpServerAction`). Edit and
/// remove are the app's own controls and never arrive here; an id this build
/// does not know draws no button rather than a guessed one.
public enum ManagementMCPAction: ManagementVocabulary, Hashable {
    case signIn
    case signOut
    case check
    case enable
    case disable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "sign_in": .signIn,
        "sign_out": .signOut,
        "check": .check,
        "enable": .enable,
        "disable": .disable
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// How a remote server is reached: OAuth when the server asks for it, a key
/// sent in a header, or nothing.
public enum ManagementMCPAuthMode: ManagementVocabulary, Hashable {
    case auto
    case header
    case none
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["auto": .auto, "header": .header, "none": .none]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a server's credential stands (`x-mcp-server-vocabulary.auth_states`).
/// An `auto` server is `not_needed` until the server itself asks to sign in.
public enum ManagementMCPAuthState: ManagementVocabulary, Hashable {
    case notNeeded
    case signedOut
    case signedIn
    case expired
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "not_needed": .notNeeded,
        "signed_out": .signedOut,
        "signed_in": .signedIn,
        "expired": .expired
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

// MARK: - The row

/// A named value a server declares: an environment variable or a header.
/// Never the value, only whether one is stored.
public struct ManagementMCPSecretName: Decodable, Equatable, Sendable, Hashable {
    public let name: String
    public let present: Bool

    public init(name: String, present: Bool) {
        self.name = name
        self.present = present
    }
}

public struct ManagementMCPAuth: Decodable, Equatable, Sendable {
    public let mode: ManagementMCPAuthMode
    public let state: ManagementMCPAuthState
    /// The header an API-key server sends its key in. `headers` on the row
    /// holds the others.
    public let keyHeader: String?
    /// Who a sign-in belongs to. Null until signed in.
    public let accountLabel: String?
    public let issuer: String?

    private enum CodingKeys: String, CodingKey {
        case mode, state, issuer
        case keyHeader = "key_header"
        case accountLabel = "account_label"
    }
}

/// A pre-registered OAuth client, for a server that registers nobody itself.
/// The secret is never here, only whether one is stored.
public struct ManagementMCPOAuthClient: Decodable, Equatable, Sendable {
    public let clientId: String?
    public let secretPresent: Bool

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case secretPresent = "secret_present"
    }
}

/// The server's own `serverInfo` from its last connection. Each field is the
/// server's to leave out.
public struct ManagementMCPServerInfo: Decodable, Equatable, Sendable {
    public let name: String?
    public let title: String?
    public let version: String?
}

/// One tool, with the server's own title and annotations. The annotations
/// inform; they decide nothing (D4).
public struct ManagementMCPTool: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let title: String?
    public let description: String?
    public let readOnly: Bool
    public let destructive: Bool
    /// False where the owner hid the tool from the agent.
    public let enabled: Bool

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, destructive, enabled
        case readOnly = "read_only"
    }
}

/// One operator server, as `mcpServerRow` publishes it.
public struct ManagementMCPServer: Decodable, Equatable, Sendable {
    /// The prefix of every tool name the agent learned from it, so it is also
    /// what the row is drawn by: the server's own title is `serverInfo`.
    public let name: String
    public let transport: ManagementMCPTransport
    public let enabled: Bool
    public let status: ManagementMCPStatus
    public let statusSentence: String
    /// The one action the row leads with, where it leads with one.
    public let primaryAction: ManagementMCPAction?
    public let actions: [ManagementMCPAction]
    /// Where the code runs and what leaves this Mac, in the daemon's words.
    public let consentSentence: String
    /// The host of a remote server, or a local server's command line as the
    /// daemon wrote it.
    public let location: String
    /// The endpoint, path included, of a remote server.
    public let url: String?
    /// The program a local command runs. Null where it was not found, and
    /// until the daemon has read the login shell's PATH.
    public let resolvedCommand: String?
    public let cwd: String?
    public let env: [ManagementMCPSecretName]
    /// The headers a remote server declares besides the key's own.
    public let headers: [ManagementMCPSecretName]
    public let auth: ManagementMCPAuth
    public let oauthClient: ManagementMCPOAuthClient
    /// What the server said about itself when it last connected, kept while
    /// it is off or starting again. Null before it first connected.
    public let serverInfo: ManagementMCPServerInfo?
    public let toolCount: Int
    public let toolsOn: Int
    /// Only `mcp.servers.get` carries the tools; `mcp.servers.list` and every
    /// write answer the counts alone.
    public let tools: [ManagementMCPTool]?
    public let lastError: String?
    /// `added`, `imported:<source>` or null for a hand-written entry. A label,
    /// never a behaviour.
    public let origin: String?

    private enum CodingKeys: String, CodingKey {
        case name, transport, enabled, status, actions, location, url, cwd, env, headers, auth
        case tools, origin
        case statusSentence = "status_sentence"
        case primaryAction = "primary_action"
        case consentSentence = "consent_sentence"
        case resolvedCommand = "resolved_command"
        case oauthClient = "oauth_client"
        case serverInfo = "server_info"
        case toolCount = "tool_count"
        case toolsOn = "tools_on"
        case lastError = "last_error"
    }
}

public struct ManagementMCPLimits: Decodable, Equatable, Sendable {
    public let maxServers: Int

    private enum CodingKeys: String, CodingKey {
        case maxServers = "max_servers"
    }
}

/// `mcp.servers.list`: the rows sorted by name, without their tools.
public struct ManagementMCPServerList: Decodable, Equatable, Sendable {
    public let servers: [ManagementMCPServer]
    public let limits: ManagementMCPLimits
    /// Whether one more server fits, which is what draws `Add server`.
    public let canAdd: Bool

    public init(servers: [ManagementMCPServer], limits: ManagementMCPLimits, canAdd: Bool) {
        self.servers = servers
        self.limits = limits
        self.canAdd = canAdd
    }

    private enum CodingKeys: String, CodingKey {
        case servers, limits
        case canAdd = "can_add"
    }
}

/// The one row `mcp.servers.get` and every single-server write answer with.
public struct ManagementMCPServerRow: Decodable, Equatable, Sendable {
    public let server: ManagementMCPServer
}

/// `mcp.servers.add`: the new row, and the `mcp_check` the add started. Null
/// where the server waits for a value and so did not start, or where no check
/// could start beside the jobs already running.
public struct ManagementMCPServerAdded: Decodable, Equatable, Sendable {
    public let server: ManagementMCPServer
    public let jobId: String?

    private enum CodingKeys: String, CodingKey {
        case server
        case jobId = "job_id"
    }
}

public struct ManagementMCPServerRemoved: Decodable, Equatable, Sendable {
    public let name: String
    public let removed: Bool
}

// MARK: - Writes

/// What `mcp.servers.add` takes: the name, the transport, and that
/// transport's fields. A field left nil is not sent, and an empty list is
/// sent as no list.
///
/// Values never ride here: each one follows in its own `secret.set` under
/// the `mcp:` family, once the server that declares its name exists.
public struct ManagementMCPServerSpec: Encodable, Equatable, Sendable {
    public let name: String
    public let transport: ManagementMCPTransport
    public let commandLine: String?
    public let cwd: String?
    public let envNames: [String]?
    public let url: String?
    public let auth: ManagementMCPAuthMode?
    public let keyHeader: String?
    public let headerNames: [String]?
    public let oauthClientId: String?

    /// A server on this Mac.
    public static func local(
        name: String,
        commandLine: String,
        cwd: String? = nil,
        envNames: [String] = []
    ) -> Self {
        Self(
            name: name,
            transport: .stdio,
            commandLine: commandLine,
            cwd: cwd,
            envNames: envNames.isEmpty ? nil : envNames,
            url: nil,
            auth: nil,
            keyHeader: nil,
            headerNames: nil,
            oauthClientId: nil
        )
    }

    /// A server at a URL. `keyHeader` names the header an API key is sent
    /// in; `headerNames` are the others.
    public static func remote(
        name: String,
        url: String,
        auth: ManagementMCPAuthMode,
        keyHeader: String? = nil,
        headerNames: [String] = [],
        oauthClientId: String? = nil
    ) -> Self {
        Self(
            name: name,
            transport: .http,
            commandLine: nil,
            cwd: nil,
            envNames: nil,
            url: url,
            auth: auth,
            keyHeader: keyHeader,
            headerNames: headerNames.isEmpty ? nil : headerNames,
            oauthClientId: oauthClientId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, transport, cwd, url, auth
        case commandLine = "command_line"
        case envNames = "env_names"
        case keyHeader = "key_header"
        case headerNames = "header_names"
        case oauthClientId = "oauth_client_id"
    }
}

/// A nullable field an update names: a new value, or null, which clears it.
public enum ManagementMCPClearable: Encodable, Equatable, Sendable {
    case set(String)
    case clear

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .set(let value): try container.encode(value)
        case .clear: try container.encodeNil()
        }
    }
}

/// What `mcp.servers.update` takes: the name, and only the fields that
/// changed. A field left nil is not sent and stays as it is; a list replaces
/// the one it names. The name and the transport never change.
public struct ManagementMCPServerChange: Encodable, Equatable, Sendable {
    public let name: String
    public var commandLine: String?
    public var cwd: ManagementMCPClearable?
    public var envNames: [String]?
    public var url: String?
    public var auth: ManagementMCPAuthMode?
    public var keyHeader: String?
    public var headerNames: [String]?
    public var oauthClientId: ManagementMCPClearable?

    public init(name: String) {
        self.name = name
    }

    /// Whether the change names no field, which is no write at all.
    public var isEmpty: Bool {
        commandLine == nil && cwd == nil && envNames == nil && url == nil && auth == nil
            && keyHeader == nil && headerNames == nil && oauthClientId == nil
    }

    private enum CodingKeys: String, CodingKey {
        case name, cwd, url, auth
        case commandLine = "command_line"
        case envNames = "env_names"
        case keyHeader = "key_header"
        case headerNames = "header_names"
        case oauthClientId = "oauth_client_id"
    }
}

/// The `mcp:` ids (PROTOCOL.md): the `secret.set` family of the values a
/// server declares, and the `auth.start` provider of a server's own sign-in.
/// Written once, beside the shapes that name them.
public enum MCPSecretId {
    public static let prefix = "mcp:"

    public static func env(server: String, name: String) -> String {
        precondition(!server.isEmpty && !name.isEmpty, "an MCP variable names its server and itself")
        return "\(prefix)\(server)/env/\(name)"
    }

    public static func header(server: String, name: String) -> String {
        precondition(!server.isEmpty && !name.isEmpty, "an MCP header names its server and itself")
        return "\(prefix)\(server)/header/\(name)"
    }

    public static func clientSecret(server: String) -> String {
        precondition(!server.isEmpty, "an MCP client secret names its server")
        return "\(prefix)\(server)/client_secret"
    }

    /// `mcp:<name>`, which `auth.start` and `auth.logout` take for a server's
    /// own sign-in, beside a plugin's `plugin:<name>`.
    public static func signInProvider(server: String) -> String {
        precondition(!server.isEmpty, "an MCP sign-in names its server")
        return prefix + server
    }
}
