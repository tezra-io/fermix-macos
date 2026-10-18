import Foundation
import Testing

@testable import FermixAppCore

/// MCP servers the owner adds (M74): the rows the golden records decode to,
/// what the tab and the sheet draw from them, the add and edit form's rules,
/// and the order the model calls the daemon in. Nothing here touches a window
/// or the host.
@Suite("MCP servers")
@MainActor
struct MCPServersTests {

    // MARK: - Decoding the golden records

    @Test("the list record decodes every row, sorted by name, without tools")
    func listDecodes() throws {
        let list = try Self.list()

        #expect(list.servers.map(\.name) == ["filesystem", "github", "linear", "notes", "postgres"])
        #expect(list.limits.maxServers == 32)
        #expect(list.canAdd)
        #expect(list.servers.allSatisfy { $0.tools == nil }, "only mcp.servers.get carries tools")

        let filesystem = try Self.server("filesystem", in: list)
        #expect(filesystem.transport == .stdio)
        #expect(filesystem.status == .connected)
        #expect(filesystem.statusSentence == "Connected. 11 tools.")
        #expect(filesystem.location == "npx -y @modelcontextprotocol/server-filesystem /Users/owner/Documents")
        #expect(filesystem.resolvedCommand == "/opt/homebrew/bin/npx")
        #expect(filesystem.serverInfo?.title == nil)
        #expect(filesystem.serverInfo?.name == "secure-filesystem-server")
        #expect(filesystem.toolCount == 11 && filesystem.toolsOn == 11)

        let github = try Self.server("github", in: list)
        #expect(github.status == .needsSignIn)
        #expect(github.primaryAction == nil, "no stage 1 row leads with sign_in")
        #expect(github.actions == [.disable])
        #expect(github.auth.mode == .auto)
        #expect(github.auth.state == .signedOut)

        let linear = try Self.server("linear", in: list)
        #expect(linear.url == "https://mcp.linear.app/mcp")
        #expect(linear.location == "mcp.linear.app")
        #expect(linear.auth.mode == .header)
        #expect(linear.auth.keyHeader == "Authorization")
        #expect(linear.headers.isEmpty, "the key's own header is not among the others")
        #expect(linear.serverInfo?.title == "Linear")
        #expect(linear.toolCount == 23 && linear.toolsOn == 21)

        let notes = try Self.server("notes", in: list)
        #expect(!notes.enabled)
        #expect(notes.status == .off)
        #expect(notes.primaryAction == .enable)
        #expect(notes.origin == nil)
        #expect(notes.cwd == "/Users/owner/mcp/notes-server")
        #expect(notes.serverInfo?.version == "0.3.0", "what a server said survives it being turned off")

        let postgres = try Self.server("postgres", in: list)
        #expect(postgres.status == .failed)
        #expect(postgres.primaryAction == .check)
        #expect(postgres.lastError == postgres.statusSentence)
        #expect(postgres.resolvedCommand == nil)
        #expect(postgres.env == [ManagementMCPSecretName(name: "DATABASE_URI", present: true)])
    }

    @Test("every MCP answer the goldens publish decodes into its typed result")
    func answersDecode() throws {
        let row: ManagementMCPServerRow = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_get",
            as: ManagementMCPServerRow.self
        )
        let tools = try #require(row.server.tools)
        #expect(tools.count == 23)
        #expect(tools.filter(\.enabled).count == row.server.toolsOn)
        #expect(tools.contains { $0.title == nil } && tools.contains { $0.description == nil })

        let added: ManagementMCPServerAdded = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_add",
            as: ManagementMCPServerAdded.self
        )
        #expect(added.server.name == "fetch")
        #expect(added.jobId == "job:4Vb8nC")

        let waiting: ManagementMCPServerAdded = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_add_remote_key",
            as: ManagementMCPServerAdded.self
        )
        #expect(waiting.jobId == nil, "a server waiting for its key starts no check")
        #expect(waiting.server.auth.keyHeader == "CONTEXT7_API_KEY")
        #expect(waiting.server.statusSentence == "Waiting for the key.")

        let off: ManagementMCPServerRow = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_disable",
            as: ManagementMCPServerRow.self
        )
        #expect(off.server.serverInfo?.title == "Linear")

        let check: ManagementJob = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_check_start",
            as: ManagementJob.self
        )
        #expect(check.kind == .mcpCheck)
        #expect(check.budgetMs == 75_000)
        #expect(JobPhaseCopy.sentence(kind: check.kind, phase: check.phase ?? "") == ProductStrings[.jobPhaseConnecting])
        #expect(JobPhaseCopy.sentence(kind: .mcpCheck, phase: "listing") == ProductStrings[.jobPhaseListingTools])

        let removed: ManagementMCPServerRemoved = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_remove",
            as: ManagementMCPServerRemoved.self
        )
        #expect(removed == ManagementMCPServerRemoved(name: "notes", removed: true))
    }

    /// The open vocabularies keep a value this build does not know, so a newer
    /// daemon's row decodes rather than failing the whole list.
    @Test("an unknown status, action, transport or auth state is kept, not refused")
    func unknownVocabularyIsKept() throws {
        var row = try Self.rowJSON("linear")
        row["status"] = "paused"
        row["actions"] = ["rotate_key", "check"]
        row["primary_action"] = "rotate_key"
        row["transport"] = "websocket"
        row["auth"] = ["mode": "mtls", "state": "pending", "key_header": NSNull(), "account_label": NSNull(), "issuer": NSNull()]
        let server = try Self.decode(row)

        #expect(server.status == .unrecognized("paused"))
        #expect(server.actions == [.unrecognized("rotate_key"), .check])
        #expect(server.transport == .unrecognized("websocket"))
        #expect(server.auth.mode == .unrecognized("mtls"))
        #expect(server.auth.state == .unrecognized("pending"))
    }

    // MARK: - Row projection and the pill

    @Test("From plugins is the installed MCP plugins, and the pill counts both together")
    func pillCountsServersAndPlugins() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )
        let rows = IntegrationRowProjection.rows(catalog)
        let fromPlugins = rows.filter(IntegrationFilter.mcps.admits)
        let servers = try Self.list().servers

        #expect(!fromPlugins.isEmpty)
        #expect(fromPlugins.allSatisfy { $0.installed }, "an MCP plugin not yet installed is not one Fermix talks to")
        let counts = IntegrationRowProjection.counts(rows: rows, features: 3, servers: servers.count)
        #expect(counts[.mcps] == servers.count + fromPlugins.count)
    }

    @Test("the verb line draws published ids by the app's words, the leading one first")
    func verbsFollowTheIds() throws {
        let list = try Self.list()
        let served = try Self.served()

        // Turning a server on and off is its switch, so neither is a verb.
        #expect(MCPServerProjection.verbs(try Self.server("linear", in: list), served: served) == [.check])
        #expect(MCPServerProjection.leadingVerb(try Self.server("linear", in: list), served: served) == nil)
        #expect(MCPServerProjection.verbs(try Self.server("github", in: list), served: served).isEmpty)
        #expect(MCPServerProjection.verbs(try Self.server("notes", in: list), served: served).isEmpty)
        #expect(MCPServerProjection.leadingVerb(try Self.server("postgres", in: list), served: served) == .check)
    }

    /// A failed server with nothing to start offers only its switch: its
    /// sentence and the Edit control are the whole of what the detail shows.
    @Test("a failed row whose only action is disable has nothing to check")
    func failedWithNothingToStart() throws {
        var row = try Self.rowJSON("postgres")
        row["status_sentence"] = "It has no command to start. Add one in its settings."
        row["primary_action"] = NSNull()
        row["actions"] = ["disable"]
        let server = try Self.decode(row)

        #expect(MCPServerProjection.verbs(server, served: try Self.served()).isEmpty)
        #expect(MCPServerProjection.leadingVerb(server, served: try Self.served()) == nil)
    }

    @Test("an action id this build does not know draws no button")
    func unknownActionsDrawNothing() throws {
        var row = try Self.rowJSON("postgres")
        row["actions"] = ["rotate_key", "check", "disable"]
        row["primary_action"] = "rotate_key"
        let server = try Self.decode(row)

        #expect(MCPServerProjection.verbs(server, served: try Self.served()) == [.check])
        #expect(MCPServerProjection.leadingVerb(server, served: try Self.served()) == nil)
        #expect(ManagementMCPAction.unrecognized("rotate_key").titleKey == nil)
        #expect(ManagementMCPAction.unrecognized("rotate_key").method == nil)
    }

    /// Each control is drawn only where the daemon's `hello` lists the method
    /// it calls (M74 §5): an engine one step behind has the tab's rows but
    /// not, say, its check.
    @Test("a verb whose method the daemon does not list draws no button")
    func verbsFollowTheServedMethods() throws {
        let postgres = try Self.server("postgres", in: try Self.list())
        let withoutCheck = try Self.served().subtracting([.mcpServersCheckStart])

        #expect(MCPServerProjection.verbs(postgres, served: withoutCheck).isEmpty)
        #expect(MCPServerProjection.leadingVerb(postgres, served: withoutCheck) == nil)
        #expect(MCPServerProjection.switchServed(try Self.served()))
        #expect(!MCPServerProjection.switchServed(try Self.served().subtracting([.mcpServersDisable])))
        #expect(ManagementMCPAction.signIn.method == .authStart)
        #expect(ManagementMCPAction.signOut.method == .authLogout)
    }

    @Test("a switch turned on opens the detail where a sign-in or a value is left")
    func needsTheOwner() throws {
        let list = try Self.list()
        #expect(!MCPServerProjection.needsTheOwner(try Self.server("linear", in: list)))
        #expect(!MCPServerProjection.needsTheOwner(try Self.server("notes", in: list)))

        var row = try Self.rowJSON("filesystem")
        row["env"] = [["name": "GITHUB_TOKEN", "present": false]]
        #expect(MCPServerProjection.needsTheOwner(try Self.decode(row)))

        let waiting: ManagementMCPServerAdded = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_add_remote_key",
            as: ManagementMCPServerAdded.self
        )
        #expect(!MCPServerProjection.keyStored(waiting.server))
        #expect(MCPServerProjection.needsTheOwner(waiting.server))
    }

    @Test("the detail draws each fact only where it has something to say")
    func detailFacts() throws {
        let list = try Self.list()
        let served = try Self.served()

        #expect(MCPServerFact.facts(try Self.server("linear", in: list), served: served) == [
            .runsOn("mcp.linear.app"),
            .server(ProductStrings.middot("Linear", "1.4.2")),
            .account(ProductStrings[.mcpSignInAPIKey], canSignOut: false),
            .tools(enabled: 21, total: 23)
        ])
        // The server's own title is absent, so its name stands in.
        #expect(MCPServerFact.facts(try Self.server("filesystem", in: list), served: served) == [
            .command("npx -y @modelcontextprotocol/server-filesystem /Users/owner/Documents", resolved: "/opt/homebrew/bin/npx"),
            .server(ProductStrings.middot("secure-filesystem-server", "0.6.2")),
            .tools(enabled: 11, total: 11)
        ])
        #expect(MCPServerFact.facts(try Self.server("github", in: list), served: served) == [
            .runsOn("api.githubcopilot.com"),
            .account(ProductStrings[.mcpAccountSignedOut], canSignOut: false)
        ])
        // A program the daemon could not find has no line under its command.
        #expect(MCPServerFact.facts(try Self.server("postgres", in: list), served: served) == [
            .command("uvx postgres-mcp --access-mode=restricted", resolved: nil),
            .variables([ManagementMCPSecretName(name: "DATABASE_URI", present: true)])
        ])
        #expect(MCPServerFact.facts(try Self.server("notes", in: list), served: served) == [
            .command("node index.js", resolved: "/opt/homebrew/bin/node"),
            .workingFolder("/Users/owner/mcp/notes-server"),
            .server(ProductStrings.middot("Notes", "0.3.0")),
            .tools(enabled: 4, total: 4)
        ])
    }

    /// An automatic server the server never asked to sign in says nothing
    /// about an account, and a signed-in one names who it is.
    @Test("an automatic server has an Account row only once sign-in means something")
    func automaticAccount() throws {
        var row = try Self.rowJSON("github")
        row["auth"] = ["mode": "auto", "state": "not_needed", "key_header": NSNull(), "account_label": NSNull(), "issuer": NSNull()]
        #expect(MCPServerFact.facts(try Self.decode(row), served: try Self.served()) == [.runsOn("api.githubcopilot.com")])

        row["auth"] = ["mode": "auto", "state": "signed_in", "key_header": NSNull(), "account_label": "owner@example.com", "issuer": NSNull()]
        row["actions"] = ["sign_out", "disable"]
        #expect(MCPServerFact.facts(try Self.decode(row), served: try Self.served()).contains(
            .account("owner@example.com", canSignOut: true)
        ))
    }

    @Test("a tool's tag is read from its annotations")
    func toolTags() throws {
        let row: ManagementMCPServerRow = try FakeDaemonGateway.fixtureResult(
            named: "mcp_servers_get",
            as: ManagementMCPServerRow.self
        )
        let tools = try #require(row.server.tools)

        #expect(tools.first { $0.name == "list_issues" }?.tagKey == .mcpToolReadOnly)
        #expect(tools.first { $0.name == "delete_comment" }?.tagKey == .mcpToolDestructive)
        #expect(tools.first { $0.name == "create_issue" }?.tagKey == .mcpToolChanges)
        #expect(tools.first { $0.name == "list_users" }?.displayTitle == "list_users")
    }

    // MARK: - The one sheet's pages

    @Test("every page goes back where Escape and the chevron say, and an add turns by its outcome")
    func pageRouting() throws {
        #expect(MCPServerPage.add.back == nil)
        #expect(MCPServerPage.detail("linear").back == nil)
        #expect(MCPServerPage.tools("linear").back == .detail("linear"))
        #expect(MCPServerPage.edit("linear").back == .detail("linear"))
        #expect(MCPServerPage.pasted(try Self.drafts("mcp_servers_draft_pasted_config")).back == .add)

        let refusal = MCPRefusal(sentence: "A quotation mark is not closed.", field: .command)
        #expect(MCPServerPage.after(.refused(refusal)) == nil)
        #expect(MCPServerPage.after(.added(name: "fetch", unstored: nil)) == .detail("fetch"))
        #expect(MCPServerPage.after(.added(name: "fetch", unstored: refusal)) == .edit("fetch"))
    }

    // MARK: - The form

    @Test("a refusal lands under the input its field names, and at the foot where it names none")
    func refusalsMarkTheirField() throws {
        let fields: [String: MCPFormField] = [
            "transport": .place, "url": .url, "command_line": .command, "name": .name, "auth": .signIn,
            "key_header": .keyHeader, "env_names": .variables, "header_names": .headers,
            "oauth_client_id": .clientID, "cwd": .workingFolder
        ]
        for (wire, field) in fields {
            #expect(MCPFormField(wire: wire) == field, "\(wire)")
        }
        #expect(MCPFormField(wire: "tool") == nil, "a tool is a switch on its own page")
        #expect(MCPFormField(wire: "text") == .paste)
        #expect(MCPFormField(wire: "draft_id") == .paste)

        var form = MCPServerForm()
        form.refuse(MCPRefusal(sentence: "A server named linear is already added.", field: .name))
        #expect(form.errors == [.name: "A server named linear is already added."])
        #expect(form.refusal == nil)

        form.refuse(MCPRefusal(sentence: "The server refused the key.", field: nil))
        #expect(form.errors.isEmpty)
        #expect(form.refusal == "The server refused the key.")
    }

    @Test("Add sends names on the wire and every typed value under its mcp: id")
    func addSendsNamesAndValues() {
        var local = MCPServerForm()
        local.place = .local
        local.commandLine = " npx -y @modelcontextprotocol/server-github "
        local.name = "github-local"
        local.variables = [
            MCPFormEntry(name: "GITHUB_TOKEN", value: "ghp_example"),
            MCPFormEntry(name: "LOG", stored: true),
            MCPFormEntry(name: " ", value: "dropped")
        ]

        #expect(local.spec == .local(
            name: "github-local",
            commandLine: "npx -y @modelcontextprotocol/server-github",
            envNames: ["GITHUB_TOKEN", "LOG"]
        ))
        #expect(local.secrets == [
            MCPSecretValue(id: "mcp:github-local/env/GITHUB_TOKEN", value: "ghp_example", field: .variables)
        ], "a stored value left as dots sends nothing")

        var remote = MCPServerForm()
        remote.url = "https://mcp.example.com/mcp"
        remote.name = "example"
        remote.signIn = .apiKey
        remote.key = MCPFormEntry(value: "sk-example")
        remote.headers = [MCPFormEntry(name: "X-Team", value: "core")]

        #expect(remote.spec == .remote(
            name: "example",
            url: "https://mcp.example.com/mcp",
            auth: .header,
            keyHeader: "Authorization",
            headerNames: ["X-Team"]
        ), "the key's header is its own field, apart from the others")
        #expect(remote.secrets.map(\.id) == ["mcp:example/header/Authorization", "mcp:example/header/X-Team"])
        #expect(remote.secrets.map(\.field) == [.key, .headers])

        var automatic = MCPServerForm()
        automatic.url = "https://mcp.example.com/mcp"
        automatic.name = "example"
        automatic.clientID = "client-1"
        automatic.clientSecret = MCPFormEntry(value: "shh")
        #expect(automatic.spec.oauthClientId == "client-1")
        #expect(automatic.secrets == [MCPSecretValue(id: "mcp:example/client_secret", value: "shh", field: .clientSecret)])
    }

    @Test("a click with nothing to run, or no name, marks the field rather than sending")
    func missingFields() {
        var remote = MCPServerForm()
        remote.url = "  "
        #expect(remote.missingFields == [
            .url: ProductStrings[.mcpFieldURLMissing],
            .name: ProductStrings[.mcpFieldNameMissing]
        ])

        var local = MCPServerForm()
        local.place = .local
        local.name = "fetch"
        #expect(local.missingFields == [.command: ProductStrings[.mcpFieldCommandMissing]])
    }

    @Test("Edit opens filled, with the name fixed and stored values as dots")
    func editOpensFilled() throws {
        let list = try Self.list()
        let postgres = MCPServerForm(editing: try Self.server("postgres", in: list))

        #expect(postgres.place == .local)
        #expect(postgres.nameFixed)
        #expect(postgres.commandLine == "uvx postgres-mcp --access-mode=restricted")
        #expect(postgres.variables.map(\.name) == ["DATABASE_URI"])
        #expect(postgres.variables.allSatisfy { $0.showsStored })
        #expect(postgres.secrets.isEmpty)
        #expect(postgres.consent == "Runs on this Mac as a separate program, with your access.")

        let linear = MCPServerForm(editing: try Self.server("linear", in: list))
        #expect(linear.place == .remote)
        #expect(linear.url == "https://mcp.linear.app/mcp")
        #expect(linear.signIn == .apiKey)
        #expect(linear.keyHeader == "Authorization")
        #expect(linear.key.showsStored, "a key the daemon reads back is drawn as dots")
    }

    @Test("an edit sends only the fields that changed, a cleared one as null")
    func editSendsTheChange() throws {
        let list = try Self.list()
        let notesRow = try Self.server("notes", in: list)

        let untouched = MCPServerForm(editing: notesRow)
        #expect(untouched.change(from: notesRow).isEmpty)

        var notes = untouched
        notes.workingFolder = ""
        notes.variables.append(MCPFormEntry(name: "NOTES_TOKEN", value: "t"))
        let change = notes.change(from: notesRow)
        #expect(change.cwd == .clear)
        #expect(change.envNames == ["NOTES_TOKEN"])
        #expect(change.commandLine == nil)
        #expect(notes.secrets == [MCPSecretValue(id: "mcp:notes/env/NOTES_TOKEN", value: "t", field: .variables)])

        let linearRow = try Self.server("linear", in: list)
        var linear = MCPServerForm(editing: linearRow)
        linear.signIn = .automatic
        let remote = linear.change(from: linearRow)
        #expect(remote.auth == .auto)
        #expect(remote.keyHeader == nil, "a key header means nothing to an automatic sign-in")
        #expect(remote.url == nil)
    }

    // MARK: - Paste

    @Test("every draft the goldens publish decodes, each with its own draft id")
    func draftsDecode() throws {
        let names = try ManagementFixtures.load(.success, from: .management)
            .filter { try $0.string("method") == ManagementMethod.mcpServersDraft.rawValue }
            .map(\.name)
        #expect(names.count == 7)
        for name in names {
            let drafts = try Self.drafts(name)
            #expect(!drafts.drafts.isEmpty, "\(name) answers no draft")
        }

        let url = try #require(try Self.drafts("mcp_servers_draft_url").drafts.first)
        #expect(url.name == "linear" && url.transport == .http && url.auth == .auto)
        #expect(url.draftId == nil, "a URL carries no value")
        #expect(url.summary == "Remote, mcp.linear.app")

        let command = try #require(try Self.drafts("mcp_servers_draft_command").drafts.first)
        #expect(command.commandLine == "npx -y @modelcontextprotocol/server-filesystem /Users/owner/Documents", "a typed ~ comes back as the home folder")
        #expect(command.commandSentence == "Runs /opt/homebrew/bin/npx")

        let missing = try #require(try Self.drafts("mcp_servers_draft_command_not_found").drafts.first)
        #expect(missing.resolvedCommand == nil)
        #expect(missing.commandSentence == "Fermix could not find uvx on this Mac. Install uv or use the full path.")

        let pasted = try Self.drafts("mcp_servers_draft_pasted_config").drafts
        #expect(pasted.map(\.name) == ["sentry", "brave-search"])
        #expect(pasted.map(\.draftId) == [nil, "draft:7Qm2Xk9pLw4Rt8Vn"], "each draft names its own values")
        #expect(pasted[1].env == [ManagementMCPSecretName(name: "BRAVE_API_KEY", present: true)])

        let claude = try #require(try Self.drafts("mcp_servers_draft_claude_add").drafts.first)
        #expect(claude.auth == .header)
        #expect(claude.keyHeader == "CONTEXT7_API_KEY")
        #expect(claude.headers == [ManagementMCPSecretName(name: "CONTEXT7_API_KEY", present: true)], "the key's header is among the headers")
        #expect(claude.draftId == "draft:Lr5Vb9Xq2Mn6Hs3T")

        let codex = try Self.drafts("mcp_servers_draft_codex").drafts
        #expect(codex.map(\.name) == ["context7", "figma"], "a Codex block's servers come by name")
        #expect(codex[1].headers == [
            ManagementMCPSecretName(name: "Authorization", present: false),
            ManagementMCPSecretName(name: "X-Figma-Region", present: true)
        ])
    }

    @Test("a pasted claude mcp add line fills a remote form, its key stored and not asked for again")
    func pasteFillsARemoteForm() throws {
        var form = MCPServerForm()
        form.url = Self.claudeAdd
        let answer = try Self.drafts("mcp_servers_draft_claude_add")

        #expect(form.apply(answer, sent: form.target, pasted: true) == .filled)
        #expect(form.place == .remote)
        #expect(form.url == "https://mcp.context7.com/mcp")
        #expect(form.name == "context7")
        #expect(form.signIn == .apiKey)
        #expect(form.keyHeader == "CONTEXT7_API_KEY")
        #expect(form.key.showsStored)
        #expect(form.headers.isEmpty, "the key's header is the key's own field")
        #expect(form.consentLine == "Runs on mcp.context7.com. What you ask its tools is sent there.")
        #expect(form.spec == .remote(
            name: "context7",
            url: "https://mcp.context7.com/mcp",
            auth: .header,
            keyHeader: "CONTEXT7_API_KEY",
            draftId: "draft:Lr5Vb9Xq2Mn6Hs3T"
        ))
        #expect(form.secrets.isEmpty, "a value the paste carried rides its draft id, never secret.set")
    }

    @Test("a pasted command fills a local form as the daemon reads it, with the line under it")
    func pasteFillsALocalForm() throws {
        var form = MCPServerForm()
        form.url = "npx -y @modelcontextprotocol/server-filesystem ~/Documents"
        let answer = try Self.drafts("mcp_servers_draft_command")

        _ = form.apply(answer, sent: form.target, pasted: true)

        #expect(form.place == .local, "a command pasted into the URL field turns the form to On this Mac")
        #expect(form.url.isEmpty)
        #expect(form.commandLine == "npx -y @modelcontextprotocol/server-filesystem /Users/owner/Documents")
        #expect(form.name == "filesystem")
        #expect(form.commandSentence == "Runs /opt/homebrew/bin/npx")
        #expect(form.commandResolved)
        #expect(form.draftId == nil)

        form.commandLine += " /Users/owner/Desktop"
        #expect(form.commandSentence == nil, "the line is the daemon's word on the text it read, not on this one")
    }

    @Test("typed text is only read: the lines under it and a name, never where it runs or what the owner chose")
    func typingIsOnlyRead() throws {
        var form = MCPServerForm()
        form.place = .local
        form.commandLine = "uvx some-missing-tool"
        form.name = "mine"
        form.nameEdited = true
        form.variables = [MCPFormEntry(name: "TOKEN", value: "t")]

        _ = form.apply(try Self.drafts("mcp_servers_draft_command_not_found"), sent: form.target, pasted: false)
        #expect(form.name == "mine")
        #expect(form.commandSentence == "Fermix could not find uvx on this Mac. Install uv or use the full path.")
        #expect(!form.commandResolved)
        #expect(form.variables.map(\.name) == ["TOKEN"])

        var remote = MCPServerForm()
        remote.url = "uvx mcp-server-fetch"
        _ = remote.apply(try Self.drafts("mcp_servers_draft_command_uvx"), sent: remote.target, pasted: false)
        #expect(remote.place == .remote, "typing in the URL field never turns the form around")
        #expect(remote.name.isEmpty)
        #expect(remote.consentLine == nil)

        var named = MCPServerForm()
        named.url = "https://mcp.linear.app/mcp"
        named.signIn = .none
        _ = named.apply(try Self.drafts("mcp_servers_draft_url"), sent: named.target, pasted: false)
        #expect(named.name == "linear", "a name the owner has not typed is the daemon's")
        #expect(named.signIn == .none)
    }

    @Test("a paste of several servers turns to their page, each added with its own draft id")
    func severalServers() throws {
        var form = MCPServerForm()
        let codex = try Self.drafts("mcp_servers_draft_codex")
        form.commandLine = "[mcp_servers.figma]"
        form.place = .local

        #expect(form.apply(codex, sent: form.target, pasted: true) == .several(codex))
        #expect(form.apply(codex, sent: form.target, pasted: false) == .filled, "typing never turns the page")

        let items = MCPPastedItem.items(codex)
        #expect(items.map(\.draft.name) == ["context7", "figma"])
        #expect(MCPPastedItem.initiallyTicked(items) == [0, 1])
        #expect(ManagementMCPServerSpec.pasted(codex.drafts[0]) == .local(
            name: "context7",
            commandLine: "npx -y @upstash/context7-mcp",
            envNames: ["CONTEXT7_API_KEY"],
            draftId: "draft:Wd1Ky7Pc4Fg8Ja2E"
        ))
        #expect(ManagementMCPServerSpec.pasted(codex.drafts[1]) == .remote(
            name: "figma",
            url: "https://mcp.figma.com/mcp",
            auth: .header,
            keyHeader: "Authorization",
            headerNames: ["X-Figma-Region"],
            draftId: "draft:Zt6Nq3Re9Hb2Mv5U"
        ))
    }

    @Test("a refused paste marks the field it was pasted into, and leaves every other mark")
    func refusedPasteMarksItsField() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        let answer = await harness.model.draftMCPServer(text: "not a server")
        let refusal = MCPRefusal(
            sentence: "Paste a server's address, the command that starts it, or the settings a README or another app gives for it.",
            field: .paste
        )
        #expect(answer == .failure(refusal))

        var form = MCPServerForm()
        form.errors = [.name: ProductStrings[.mcpFieldNameMissing]]
        form.mark(refusal)
        #expect(form.errors == [.name: ProductStrings[.mcpFieldNameMissing], .url: refusal.sentence])

        form.place = .local
        form.refuse(MCPRefusal(sentence: "This paste has expired. Paste it again.", field: .paste))
        #expect(form.errors == [.command: "This paste has expired. Paste it again."])
    }

    @Test("an add whose paste expired is refused under the paste field")
    func expiredPaste() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        harness.gateway.v2Failures[.mcpServersAdd] = try ManagementRefusal.published("invalid_params_mcp_servers_add_draft_id")
        let spec = ManagementMCPServerSpec.pasted(try #require(try Self.drafts("mcp_servers_draft_claude_add").drafts.first))

        let outcome = await harness.model.addMCPServer(spec, values: [], on: harness.model.makeJobRunner())

        #expect(outcome == .refused(MCPRefusal(sentence: "This paste has expired. Paste it again.", field: .paste)))
        #expect(harness.gateway.mcpSpecs.map(\.draftId) == ["draft:Lr5Vb9Xq2Mn6Hs3T"])
    }

    @Test("the paste is offered only where the daemon's hello lists mcp.servers.draft")
    func pasteFollowsHello() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        #expect(harness.model.serves(.mcpServersDraft))

        let older = try SettingsFixture.gateway()
        older.hello = try Self.hello(without: [.mcpServersDraft])
        let olderHarness = try SettingsHarness(gateway: older)
        await olderHarness.model.refreshMCPServers()
        #expect(olderHarness.model.serves(.mcpServersList))
        #expect(!olderHarness.model.serves(.mcpServersDraft))
    }

    // MARK: - The model

    @Test("the list is read where the daemon's hello publishes it")
    func refreshReadsTheList() async throws {
        let harness = try Self.harness()

        await harness.model.refreshMCPServers()

        #expect(harness.model.mcpServers.value?.servers.count == 5)
        #expect(harness.model.serves(.mcpServersAdd))
    }

    @Test("a daemon whose hello has no MCP methods keeps the plugin pill, for this tab only")
    func olderEngineIsAState() async throws {
        let harness = try SettingsHarness()

        await harness.model.refreshMCPServers()

        #expect(harness.model.mcpServers == .requiresNewerEngine)
        #expect(!harness.model.requiresNewerEngine, "every other pane is still served")
        #expect(!harness.model.serves(.mcpServersAdd))
        #expect(!harness.gateway.calls.contains(.v2(.mcpServersList)), "the method is never asked of a daemon without it")
    }

    @Test("a refused add hands back the daemon's sentence under the field it named")
    func refusedAddNamesItsField() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        harness.gateway.v2Failures[.mcpServersAdd] = ManagementError.daemon(try Self.failure("invalid_params_mcp_server_field"))

        let outcome = await harness.model.addMCPServer(
            .local(name: "fetch", commandLine: "uvx \"mcp-server-fetch"),
            values: [MCPSecretValue(id: "mcp:fetch/env/TOKEN", value: "value", field: .variables)],
            on: harness.model.makeJobRunner()
        )

        #expect(outcome == .refused(MCPRefusal(sentence: "A quotation mark is not closed.", field: .command)))
        #expect(harness.gateway.storedSecrets.isEmpty, "nothing is stored for a server that was not added")
    }

    /// The order is the contract's: the add, so the server that declares the
    /// names exists; each value; then a check, because a server waiting for
    /// a value started none of its own.
    @Test("an add waiting for a value stores each one, then starts the check")
    func addWaitingForAValue() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        let runner = harness.model.makeJobRunner()

        let outcome = await harness.model.addMCPServer(
            .remote(name: "context7", url: "https://mcp.context7.com/mcp", auth: .header, keyHeader: "CONTEXT7_API_KEY"),
            values: [MCPSecretValue(id: "mcp:context7/header/CONTEXT7_API_KEY", value: "ctx-key", field: .key)],
            on: runner
        )
        await runner.drainPendingWork()

        #expect(outcome == .added(name: "context7", unstored: nil))
        #expect(harness.gateway.storedSecrets == [SecretWrite(id: "mcp:context7/header/CONTEXT7_API_KEY", value: "ctx-key")])
        let calls = harness.gateway.calls
        let added = try #require(calls.firstIndex(of: .v2(.mcpServersAdd)))
        let stored = try #require(calls.firstIndex(of: .v2(.secretSet)))
        let checked = try #require(calls.firstIndex(of: .v2(.mcpServersCheckStart)))
        #expect(added < stored && stored < checked)
    }

    @Test("an add that started its own check follows that job and starts no other")
    func addFollowsItsCheck() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        harness.gateway.jobScript = [try FakeDaemonGateway.fixtureResult(named: "job_get_mcp_check_completed", as: ManagementJob.self)]
        let runner = harness.model.makeJobRunner()

        let outcome = await harness.model.addMCPServer(
            .local(name: "fetch", commandLine: "uvx mcp-server-fetch"),
            values: [],
            on: runner
        )
        await runner.drainPendingWork()

        #expect(outcome == .added(name: "fetch", unstored: nil))
        #expect(harness.gateway.polledJobs.first == "job:4Vb8nC")
        #expect(!harness.gateway.calls.contains(.v2(.mcpServersCheckStart)))
        #expect(runner.job?.kind == .mcpCheck)
    }

    @Test("an add whose value is refused leaves the server added and says which input")
    func addWithARefusedValue() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        harness.gateway.v2Failures[.secretSet] = ManagementRefusal.daemon(.secretStoreFailed, "The secret store refused the write.")

        let outcome = await harness.model.addMCPServer(
            .remote(name: "context7", url: "https://mcp.context7.com/mcp", auth: .header, keyHeader: "CONTEXT7_API_KEY"),
            values: [MCPSecretValue(id: "mcp:context7/header/CONTEXT7_API_KEY", value: "ctx-key", field: .key)],
            on: harness.model.makeJobRunner()
        )

        guard case .added("context7", let unstored?) = outcome else {
            Issue.record("the add should stand with its value refused: \(outcome)")
            return
        }
        #expect(unstored.field == .key)
        #expect(!harness.gateway.calls.contains(.v2(.mcpServersCheckStart)))
    }

    @Test("an edit sends the change, then each value replaced, then checks a server that is on")
    func editSendsChangeThenValues() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()
        var change = ManagementMCPServerChange(name: "filesystem")
        change.commandLine = "npx -y @modelcontextprotocol/server-filesystem /Users/owner/Documents"

        let refused = await harness.model.updateMCPServer(
            change,
            values: [MCPSecretValue(id: "mcp:filesystem/env/TOKEN", value: "v", field: .variables)],
            on: harness.model.makeJobRunner()
        )

        #expect(refused == nil)
        #expect(harness.gateway.mcpChanges == [change])
        let calls = harness.gateway.calls
        let updated = try #require(calls.firstIndex(of: .v2(.mcpServersUpdate)))
        let stored = try #require(calls.firstIndex(of: .v2(.secretSet)))
        let checked = try #require(calls.firstIndex(of: .v2(.mcpServersCheckStart)))
        #expect(updated < stored && stored < checked)
    }

    @Test("an edit that changed nothing writes nothing")
    func editWithNothingWritesNothing() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        let refused = await harness.model.updateMCPServer(
            ManagementMCPServerChange(name: "filesystem"),
            values: [],
            on: harness.model.makeJobRunner()
        )

        #expect(refused == nil)
        #expect(!harness.gateway.calls.contains(.v2(.mcpServersUpdate)))
        #expect(!harness.gateway.calls.contains(.v2(.mcpServersCheckStart)))
    }

    @Test("a write the switch makes takes the answered row in place, keeping the daemon's order")
    func switchTakesTheRow() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        let outcome = await harness.model.setMCPServerEnabled(false, name: "linear")

        #expect(outcome == .done)
        #expect(harness.model.mcpServer(named: "linear")?.enabled == false)
        #expect(harness.model.mcpServers.value?.servers.map(\.name) == ["filesystem", "github", "linear", "notes", "postgres"])
    }

    @Test("a tool switch reads the tools again, which only mcp.servers.get carries")
    func toolSwitchReadsTheTools() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        let refused = await harness.model.setMCPTool(server: "linear", tool: "update_project", enabled: true)

        #expect(refused == nil)
        #expect(harness.gateway.mcpToolWrites == [MCPToolWrite(server: "linear", tool: "update_project", enabled: true)])
        #expect(harness.gateway.mcpReads == ["linear"])
        #expect(harness.model.mcpTools["linear"]?.value?.count == 23)
    }

    @Test("a removal reads the list again rather than guessing it")
    func removalReadsTheList() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        #expect(await harness.model.removeMCPServer(name: "notes") == nil)
        #expect(harness.gateway.calls.filter { $0 == .v2(.mcpServersList) }.count == 2)
    }

    @Test("a server's sign-in and sign-out are auth.start and auth.logout under mcp:<name>")
    func signInUsesTheServersProvider() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        _ = await harness.model.startMCPSignIn(name: "github", on: harness.model.makeJobRunner())
        _ = await harness.model.logOutMCPServer(name: "github")

        #expect(harness.gateway.signInProviders == ["mcp:github"])
        #expect(harness.gateway.signOutProviders == ["mcp:github"])
        #expect(harness.gateway.mcpReads == ["github"], "the row is read again after a sign-out")
    }

    @Test("a value stored for a server reads its row again")
    func storedValueReadsTheRow() async throws {
        let harness = try Self.harness()
        await harness.model.refreshMCPServers()

        #expect(await harness.model.setSecret(id: "mcp:postgres/env/DATABASE_URI", value: "postgres://") == nil)
        #expect(harness.gateway.calls.filter { $0 == .v2(.mcpServersList) }.count == 2)
    }

    // MARK: - The fixture home

    @Test("the fixture home answers the list from its machine, empty on the empty start")
    func fixtureListFollowsTheMachine() async throws {
        let golden = try await Self.fixtureList(FixtureMachine(daemonUp: true))
        #expect(golden.servers.map(\.name) == ["filesystem", "github", "linear", "notes", "postgres"])

        let empty = try await Self.fixtureList(FixtureMachine(daemonUp: true, mcpServersStartEmpty: true))
        #expect(empty.servers.isEmpty)
    }

    @Test("the fixture home reads a golden paste, refuses any other, and an add stores what the paste held")
    func fixtureReadsPastes() async throws {
        let client = try await Self.fixtureClient(FixtureMachine(daemonUp: true))

        let pasted = try await client.draftMCPServer(text: Self.claudeAdd)
        #expect(pasted.drafts.first?.draftId == "draft:Lr5Vb9Xq2Mn6Hs3T")
        await #expect(throws: ManagementError.self) { _ = try await client.draftMCPServer(text: "not a server") }

        let added = try await client.addMCPServer(.pasted(try #require(pasted.drafts.first)))
        #expect(added.server.name == "context7")
        #expect(added.server.auth.state == .signedIn, "the key the paste held is stored with the add")
        #expect(added.server.status == .starting)
        #expect(added.jobId == "job:4Vb8nC")
        #expect(try await client.mcpServers().servers.map(\.name).contains("context7"))
    }

    @Test("an add and a removal on the fixture home move its list")
    func fixtureWritesMoveTheList() async throws {
        let machine = FixtureMachine(daemonUp: true)
        let client = try await Self.fixtureClient(machine)

        let added = try await client.addMCPServer(.local(name: "fetch2", commandLine: "uvx mcp-server-fetch", envNames: ["TOKEN"]))
        #expect(added.server.name == "fetch2")
        #expect(added.server.env == [ManagementMCPSecretName(name: "TOKEN", present: false)])
        _ = try await client.setSecret(id: "mcp:fetch2/env/TOKEN", value: "v")
        _ = try await client.removeMCPServer(name: "notes")

        let list = try await client.mcpServers()
        #expect(list.servers.map(\.name) == ["fetch2", "filesystem", "github", "linear", "postgres"])
        #expect(list.servers.first?.env == [ManagementMCPSecretName(name: "TOKEN", present: true)])
    }

    // MARK: - Fixtures

    private static func harness() throws -> SettingsHarness {
        let gateway = try SettingsFixture.gateway()
        gateway.hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)

        return try SettingsHarness(gateway: gateway)
    }

    private static func served() throws -> Set<ManagementMethod> {
        let hello = try FakeDaemonGateway.fixtureResult(named: "hello", as: ManagementHello.self)

        return Set(hello.capabilities.methods.compactMap(ManagementMethod.init(rawValue:)))
    }

    /// The `claude mcp add` line the contract's golden reads.
    private static let claudeAdd =
        #"claude mcp add --transport http context7 https://mcp.context7.com/mcp --header "CONTEXT7_API_KEY: ctx7sk-4f1e9a2b""#

    private static func drafts(_ name: String) throws -> ManagementMCPDrafts {
        try FakeDaemonGateway.fixtureResult(named: name, as: ManagementMCPDrafts.self)
    }

    /// The golden hello, less some of its methods: an engine a step behind.
    private static func hello(without methods: Set<ManagementMethod>) throws -> ManagementHello {
        let fixture = try #require(try ManagementFixtures.load(.success, from: .management).first { $0.name == "hello" })
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        var capabilities = try #require(result["capabilities"] as? [String: Any])
        let listed = try #require(capabilities["methods"] as? [String])
        capabilities["methods"] = listed.filter { !methods.map(\.rawValue).contains($0) }
        capabilities["minimum_versions"] = nil
        result["capabilities"] = capabilities

        return try JSONDecoder().decode(ManagementHello.self, from: try JSONSerialization.data(withJSONObject: result))
    }

    private static func list() throws -> ManagementMCPServerList {
        try FakeDaemonGateway.fixtureResult(named: "mcp_servers_list", as: ManagementMCPServerList.self)
    }

    private static func server(_ name: String, in list: ManagementMCPServerList) throws -> ManagementMCPServer {
        try #require(list.servers.first { $0.name == name })
    }

    private static func decode(_ row: [String: Any]) throws -> ManagementMCPServer {
        try JSONDecoder().decode(ManagementMCPServer.self, from: try JSONSerialization.data(withJSONObject: row))
    }

    private static func failure(_ name: String) throws -> ManagementFailure {
        let fixture = try #require(try ManagementFixtures.load(.errors, from: .management).first { $0.name == name })
        let published = try #require(try fixture.object("response")["error"] as? [String: Any])

        return try JSONDecoder().decode(ManagementFailure.self, from: try ManagementFixtures.encode(published))
    }

    /// One golden row as JSON, to change a field a case is about.
    private static func rowJSON(_ name: String) throws -> [String: Any] {
        let fixture = try #require(
            try ManagementFixtures.load(.success, from: .management).first { $0.name == "mcp_servers_list" }
        )
        let result = try #require(try fixture.object("response")["result"] as? [String: Any])
        let servers = try #require(result["servers"] as? [[String: Any]])

        return try #require(servers.first { $0["name"] as? String == name })
    }

    private static func fixtureClient(_ machine: FixtureMachine) async throws -> ManagementClient {
        let client = try ManagementClient(
            transport: FixtureManagementTransport(machine: machine, readiness: .ready),
            contract: try ManagementContract.vendored()
        )
        _ = try await client.hello()

        return client
    }

    private static func fixtureList(_ machine: FixtureMachine) async throws -> ManagementMCPServerList {
        try await fixtureClient(machine).mcpServers()
    }
}
