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

/// The apps whose settings `mcp.servers.import.scan` reads, on an explicit
/// ask only (`mcpImportSource`). The daemon names each in `source_label`.
public enum ManagementMCPImportSource: ManagementVocabulary, Hashable {
    case claudeDesktop
    case claudeCode
    case cursor
    case vscode
    case windsurf
    case codex
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "claude_desktop": .claudeDesktop,
        "claude_code": .claudeCode,
        "cursor": .cursor,
        "vscode": .vscode,
        "windsurf": .windsurf,
        "codex": .codex
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

// MARK: - Drafts

/// One server a paste describes, as the add form takes it (`mcpServerDraft`).
/// Nothing is written: a draft is what the form fills from, and the values
/// the paste carried stay with the daemon under the draft's own id.
public struct ManagementMCPDraft: Decodable, Equatable, Sendable {
    public let name: String
    public let transport: ManagementMCPTransport
    public let url: String?
    /// The words that will run, a typed `~` written out as the home folder.
    public let commandLine: String?
    public let resolvedCommand: String?
    /// The line under the command: `Runs <program>`, or the sentence a row
    /// says of a program this Mac does not have. Null where the program is
    /// not known yet, and for a remote server.
    public let commandSentence: String?
    public let cwd: String?
    /// Every value the server declares; `present` where the paste carried it.
    public let env: [ManagementMCPSecretName]
    /// Every header the server declares, the key's own among them.
    public let headers: [ManagementMCPSecretName]
    public let auth: ManagementMCPAuthMode
    /// Which of `headers` carries the key.
    public let keyHeader: String?
    public let oauthClientId: String?
    public let consentSentence: String
    /// The draft in one line: `Remote, <host>`, or the program and its package.
    public let summary: String
    /// An MCP server here already has the name, or one that gives its tools
    /// the same names.
    public let conflict: Bool
    /// The values this draft carried, held by the daemon for an add. Null
    /// where it carried none.
    public let draftId: String?

    private enum CodingKeys: String, CodingKey {
        case name, transport, url, cwd, env, headers, auth, summary, conflict
        case commandLine = "command_line"
        case resolvedCommand = "resolved_command"
        case commandSentence = "command_sentence"
        case keyHeader = "key_header"
        case oauthClientId = "oauth_client_id"
        case consentSentence = "consent_sentence"
        case draftId = "draft_id"
    }
}

/// `mcp.servers.draft`: one draft or more, in the paste's order.
public struct ManagementMCPDrafts: Decodable, Equatable, Sendable {
    public let drafts: [ManagementMCPDraft]
}

// MARK: - Import

/// One server another app's settings on this Mac hold, as a draft of it
/// would read. Never a value: `secret_names` names the ones it declares.
public struct ManagementMCPImportCandidate: Decodable, Equatable, Sendable {
    public let source: ManagementMCPImportSource
    /// The daemon's name for the app, which heads the group it is listed in.
    public let sourceLabel: String
    public let name: String
    public let transport: ManagementMCPTransport
    public let summary: String
    public let commandLine: String?
    public let url: String?
    public let consentSentence: String
    public let resolvedCommand: String?
    public let commandSentence: String?
    public let secretNames: [String]
    /// The name, or its tools' names, is taken here.
    public let conflict: Bool

    private enum CodingKeys: String, CodingKey {
        case source, name, transport, summary, url, conflict
        case sourceLabel = "source_label"
        case commandLine = "command_line"
        case consentSentence = "consent_sentence"
        case resolvedCommand = "resolved_command"
        case commandSentence = "command_sentence"
        case secretNames = "secret_names"
    }
}

/// What a scan could not offer, in the daemon's words: a settings file it
/// could not read (`name` null), or one server it could not add as written.
public struct ManagementMCPImportSkipped: Decodable, Equatable, Sendable {
    public let source: ManagementMCPImportSource
    public let sourceLabel: String
    public let name: String?
    public let sentence: String

    private enum CodingKeys: String, CodingKey {
        case source, name, sentence
        case sourceLabel = "source_label"
    }
}

/// `mcp.servers.import.scan`.
public struct ManagementMCPImportScan: Decodable, Equatable, Sendable {
    public let candidates: [ManagementMCPImportCandidate]
    public let skipped: [ManagementMCPImportSkipped]
}

/// One server to import, by the app it was found in and the name the scan
/// offered it under.
public struct ManagementMCPImportPick: Codable, Equatable, Hashable, Sendable {
    public let source: ManagementMCPImportSource
    public let name: String

    public init(source: ManagementMCPImportSource, name: String) {
        self.source = source
        self.name = name
    }
}

/// One server an import did not add, with the daemon's sentence.
public struct ManagementMCPImportRefused: Decodable, Equatable, Sendable {
    public let source: ManagementMCPImportSource
    public let name: String
    public let sentence: String
}

/// `mcp.servers.import`: the new rows, and every server not added.
public struct ManagementMCPImported: Decodable, Equatable, Sendable {
    public let servers: [ManagementMCPServer]
    public let refused: [ManagementMCPImportRefused]
}

// MARK: - Writes

/// What `mcp.servers.add` takes: the name, the transport, and that
/// transport's fields. A field left nil is not sent, and an empty list is
/// sent as no list.
///
/// Values never ride here: each one follows in its own `secret.set` under
/// the `mcp:` family, once the server that declares its name exists, or
/// stays with the daemon under the `draft_id` of the paste that carried it.
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
    /// The paste whose values the add stores for the names it declares.
    public let draftId: String?

    /// A server on this Mac.
    public static func local(
        name: String,
        commandLine: String,
        cwd: String? = nil,
        envNames: [String] = [],
        draftId: String? = nil
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
            oauthClientId: nil,
            draftId: draftId
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
        oauthClientId: String? = nil,
        draftId: String? = nil
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
            oauthClientId: oauthClientId,
            draftId: draftId
        )
    }

    /// The add one pasted server makes as the paste gave it, its values held
    /// under its own draft id. The key's header is its own field, apart from
    /// the server's other headers.
    public static func pasted(_ draft: ManagementMCPDraft) -> Self {
        switch draft.transport {
        case .http:
            return .remote(
                name: draft.name,
                url: draft.url ?? "",
                auth: draft.auth,
                keyHeader: draft.keyHeader,
                headerNames: draft.headers.map(\.name).filter { $0 != draft.keyHeader },
                oauthClientId: draft.oauthClientId,
                draftId: draft.draftId
            )
        case .stdio, .unrecognized:
            return .local(
                name: draft.name,
                commandLine: draft.commandLine ?? "",
                cwd: draft.cwd,
                envNames: draft.env.map(\.name),
                draftId: draft.draftId
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, transport, cwd, url, auth
        case commandLine = "command_line"
        case envNames = "env_names"
        case keyHeader = "key_header"
        case headerNames = "header_names"
        case oauthClientId = "oauth_client_id"
        case draftId = "draft_id"
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

    /// The server a sign-in provider names, where it names one.
    public static func server(signingIn provider: String?) -> String? {
        guard let provider, provider.hasPrefix(prefix), !provider.contains("/") else { return nil }

        let server = String(provider.dropFirst(prefix.count))
        return server.isEmpty ? nil : server
    }
}
