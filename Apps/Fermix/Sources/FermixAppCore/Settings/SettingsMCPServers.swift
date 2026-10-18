import Foundation

/// The inputs of the MCP server form a refusal can name (M74 §4.2).
public enum MCPFormField: Hashable, Sendable {
    case place
    case url
    case command
    case name
    case signIn
    case keyHeader
    case key
    case variables
    case headers
    case clientID
    case clientSecret
    case workingFolder
    /// What was pasted or typed into the URL or the command field: the
    /// daemon's `text` when it reads it, and the `draft_id` that holds what
    /// it carried.
    case paste

    /// The input a refusal's `details.field` names, which the daemon spells
    /// as the form's own parameter. `tool` is a switch on the tools page
    /// rather than an input of the form, so it names none here.
    public init?(wire field: String) {
        switch field {
        case "text", "draft_id": self = .paste
        case "transport": self = .place
        case "url": self = .url
        case "command_line": self = .command
        case "name": self = .name
        case "auth": self = .signIn
        case "key_header": self = .keyHeader
        case "env_names": self = .variables
        case "header_names": self = .headers
        case "oauth_client_id": self = .clientID
        case "cwd": self = .workingFolder
        default: return nil
        }
    }
}

/// A refusal the daemon gave a write, with the form input it is about where
/// it named one, so the form marks that input rather than raising an alert.
public struct MCPRefusal: Equatable, Sendable, Error {
    public let sentence: String
    public let field: MCPFormField?

    public init(sentence: String, field: MCPFormField?) {
        precondition(!sentence.isEmpty, "a refusal states why")
        self.sentence = sentence
        self.field = field
    }
}

/// One value typed into the form, with the `secret.set` id it is stored under
/// and the input it was typed in, which a refused store marks.
public struct MCPSecretValue: Equatable, Sendable {
    public let id: String
    public let value: String
    public let field: MCPFormField

    public init(id: String, value: String, field: MCPFormField) {
        precondition(!value.isEmpty, "a blank secret is never sent")
        self.id = id
        self.value = value
        self.field = field
    }
}

/// What an add left behind.
public enum MCPAddOutcome: Equatable, Sendable {
    /// The daemon refused the add, so nothing was written.
    case refused(MCPRefusal)
    /// The server exists. A value typed for it that could not be stored is
    /// the store's refusal, under the input it was typed in.
    case added(name: String, unstored: MCPRefusal?)
}

/// What a server switch left behind: the daemon's refusal, a step the owner
/// has to take on the server's detail, or nothing.
public enum MCPEnableOutcome: Equatable, Sendable {
    case refused(String)
    case configure(String)
    case done
}

/// The MCP servers the owner adds (M74 §6).
///
/// Every word on a server row is the daemon's; what lives here is which
/// method each control calls, in which order. Values never ride the
/// `mcp.servers.*` methods: each one is its own `secret.set`, once the server
/// that declares its name exists.
extension SettingsModel {

    /// Whether the daemon's `hello` lists this method, which is what draws
    /// the control that calls it.
    public func serves(_ method: ManagementMethod) -> Bool {
        servedMethods.contains(method)
    }

    // MARK: - Reads

    /// Reads the list where the daemon serves it. A daemon whose `hello` does
    /// not list `mcp.servers.list` leaves the tab as it was before it: the
    /// plugins that run as MCP servers, and nothing to add.
    public func refreshMCPServers() async {
        beginRead(\.mcpServers)
        do {
            let served = try await gateway.servedMethods()
            publish(served, to: \.servedMethods)
            guard served.contains(.mcpServersList) else {
                publish(.requiresNewerEngine, to: \.mcpServers)
                return
            }

            publish(.loaded(try await gateway.mcpServers()), to: \.mcpServers)
            noteServed()
        } catch {
            publish(.failure(error), to: \.mcpServers)
            noteRead(error, "mcp.servers.list")
        }
    }

    /// One server, by name, as the daemon last published it.
    public func mcpServer(named name: String) -> ManagementMCPServer? {
        precondition(!name.isEmpty, "an MCP server is looked up by name")

        return mcpServers.value?.servers.first { $0.name == name }
    }

    /// One server's row and its tools, which `mcp.servers.get` alone carries.
    public func readMCPServer(_ name: String) async {
        precondition(!name.isEmpty, "an MCP server is read by name")

        if mcpTools[name]?.value == nil { publish(.loading, to: \.mcpTools[name]) }
        do {
            let server = try await gateway.mcpServer(name: name).server
            keep(server)
            publish(.loaded(server.tools ?? []), to: \.mcpTools[name])
        } catch {
            publish(.failure(error), to: \.mcpTools[name])
            noteRead(error, "mcp.servers.get")
        }
    }

    /// What was typed or pasted into the add form, read by the daemon, which
    /// writes nothing. A refusal names the paste field.
    public func draftMCPServer(text: String) async -> Result<ManagementMCPDrafts, MCPRefusal> {
        precondition(!text.isEmpty, "a draft reads some text")

        do {
            return .success(try await gateway.draftMCPServer(text: text))
        } catch {
            noteReconcile(error)
            let field = ManagementMessage.details(of: error)?.field.flatMap(MCPFormField.init(wire:))
            return .failure(MCPRefusal(sentence: ManagementMessage.sentence(for: error), field: field))
        }
    }

    // MARK: - Writes

    /// Adds one server, stores each value typed for it, then follows the check
    /// that connects it: the one the add started, or, where the server waited
    /// for the values just stored, one started now.
    public func addMCPServer(
        _ spec: ManagementMCPServerSpec,
        values: [MCPSecretValue],
        on runner: JobRunner
    ) async -> MCPAddOutcome {
        let added: ManagementMCPServerAdded
        switch await serverWrite({ try await self.gateway.addMCPServer(spec) }) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let answer): added = answer
        }

        // Read again rather than appended: the list is the daemon's, in its
        // order, and an add can change whether another one fits.
        await refreshMCPServers()
        if let unstored = await store(values) { return .added(name: spec.name, unstored: unstored) }

        if let job = added.jobId {
            await start(runner) { try await self.gateway.job(id: job) }
        } else if !values.isEmpty {
            await startMCPCheck(name: spec.name, on: runner)
        }
        return .added(name: spec.name, unstored: nil)
    }

    /// Changes one server: the fields that changed, then each value replaced.
    /// A server that is on restarts with them, and a check follows it so the
    /// detail shows it connecting again.
    public func updateMCPServer(
        _ change: ManagementMCPServerChange,
        values: [MCPSecretValue],
        on runner: JobRunner
    ) async -> MCPRefusal? {
        guard !change.isEmpty || !values.isEmpty else { return nil }

        if !change.isEmpty {
            switch await serverWrite({ try await self.gateway.updateMCPServer(change) }) {
            case .failure(let refusal): return refusal
            case .success(let answer): keep(answer.server)
            }
        }
        if let unstored = await store(values) { return unstored }

        if mcpServer(named: change.name)?.enabled == true, serves(.mcpServersCheckStart) {
            await startMCPCheck(name: change.name, on: runner)
        }
        return nil
    }

    public func removeMCPServer(name: String) async -> String? {
        precondition(!name.isEmpty, "a removal names its server")

        if case .failure(let refusal) = await serverWrite({ try await self.gateway.removeMCPServer(name: name) }) {
            return refusal.sentence
        }
        await refreshMCPServers()
        return nil
    }

    /// The server's switch, both ways. One turned on that leaves a step for
    /// the owner opens the server's detail, as a plugin row's does (M74 §4.8).
    public func setMCPServerEnabled(_ isOn: Bool, name: String) async -> MCPEnableOutcome {
        precondition(!name.isEmpty, "a server switch names its server")

        let answer = await serverWrite {
            isOn ? try await self.gateway.enableMCPServer(name: name) : try await self.gateway.disableMCPServer(name: name)
        }
        switch answer {
        case .failure(let refusal):
            return .refused(refusal.sentence)
        case .success(let row):
            keep(row.server)
            return isOn && MCPServerProjection.needsTheOwner(row.server) ? .configure(name) : .done
        }
    }

    /// One tool's switch, then the tools read again: the write answers the
    /// row's counts, and only `mcp.servers.get` says which tool is on.
    public func setMCPTool(server: String, tool: String, enabled: Bool) async -> String? {
        let refused = await writeTool(server: server, tool: tool, enabled: enabled)
        await readMCPServer(server)
        return refused
    }

    /// Every tool one way: one `tool.set` per tool not already there, in the
    /// server's order, stopping at the first refusal, then one read.
    public func setAllMCPTools(server: String, enabled: Bool) async -> String? {
        let pending = (mcpTools[server]?.value ?? []).filter { $0.enabled != enabled }
        var refused: String?
        for tool in pending {
            refused = await writeTool(server: server, tool: tool.name, enabled: enabled)
            if refused != nil { break }
        }

        await readMCPServer(server)
        return refused
    }

    // MARK: - Sign-in

    /// A server's own sign-in, the browser hop a plugin's takes, under the
    /// provider `mcp:<name>`.
    public func startMCPSignIn(name: String, on runner: JobRunner) async -> String? {
        await startSignIn(provider: MCPSecretId.signInProvider(server: name), on: runner)
    }

    /// Forgets a server's sign-in, then reads its row again.
    public func logOutMCPServer(name: String) async -> String? {
        if let refused = await logOut(provider: MCPSecretId.signInProvider(server: name)) { return refused }

        await readMCPServer(name)
        return nil
    }

    /// A check or a server's own sign-in ended, so the rows it moved are read
    /// back. A plugin's sign-in is the plugin detail's to follow.
    public func mcpJobFinished(_ job: ManagementJob) async {
        guard job.status.isTerminal else { return }

        switch job.kind {
        case .mcpCheck:
            await refreshMCPServers()
        case .auth where signingInProvider?.hasPrefix(MCPSecretId.prefix) == true:
            await signInFinished()
            await refreshMCPServers()
        default:
            return
        }
    }

    // MARK: - One write

    /// Stores each value, one `secret.set` per value, in the form's order,
    /// stopping at the first refusal, which names the input it was typed in.
    private func store(_ values: [MCPSecretValue]) async -> MCPRefusal? {
        for value in values {
            if let sentence = await setSecret(id: value.id, value: value.value) {
                return MCPRefusal(sentence: sentence, field: value.field)
            }
        }

        return nil
    }

    private func writeTool(server: String, tool: String, enabled: Bool) async -> String? {
        switch await serverWrite({ try await self.gateway.setMCPTool(name: server, tool: tool, enabled: enabled) }) {
        case .failure(let refusal):
            return refusal.sentence
        case .success(let row):
            keep(row.server)
            return nil
        }
    }

    /// One MCP write, with the external-change gate every write passes. A
    /// refusal is the daemon's sentence and the form input its `field` names.
    private func serverWrite<Answer: Sendable>(
        _ request: @escaping () async throws -> Answer
    ) async -> Result<Answer, MCPRefusal> {
        guard !writesBlocked else {
            return .failure(MCPRefusal(sentence: ProductStrings[.settingsExternalChangeBody], field: nil))
        }

        do {
            return .success(try await request())
        } catch {
            let field = ManagementMessage.details(of: error)?.field.flatMap(MCPFormField.init(wire:))
            return .failure(MCPRefusal(sentence: refusal(error), field: field))
        }
    }

    /// Puts a row a write answered in place of the one of its name. A row the
    /// list does not hold yet waits for the list's own next read.
    private func keep(_ server: ManagementMCPServer) {
        guard let list = mcpServers.value,
              let index = list.servers.firstIndex(where: { $0.name == server.name })
        else { return }

        var servers = list.servers
        servers[index] = server
        publish(.loaded(ManagementMCPServerList(servers: servers, limits: list.limits, canAdd: list.canAdd)), to: \.mcpServers)
    }
}
