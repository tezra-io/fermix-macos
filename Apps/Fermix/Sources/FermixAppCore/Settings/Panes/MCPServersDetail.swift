import SwiftUI

/// The rows a server's detail draws, each only where it has something to say
/// (M74 §4.4): where it runs, what it said about itself, who it is signed in
/// as, its variables, and how many of its tools are on.
public enum MCPServerFact: Equatable, Sendable {
    case runsOn(String)
    /// The command line, and the program it runs once the daemon has found
    /// it on the login shell's PATH.
    case command(String, resolved: String?)
    case workingFolder(String)
    case server(String)
    case account(String, canSignOut: Bool)
    case variables([ManagementMCPSecretName])
    case tools(enabled: Int, total: Int)

    public static func facts(_ server: ManagementMCPServer, served: Set<ManagementMethod>) -> [MCPServerFact] {
        var facts: [MCPServerFact] = []

        switch server.transport {
        case .http: facts.append(.runsOn(server.location))
        case .stdio, .unrecognized: facts.append(.command(server.location, resolved: server.resolvedCommand))
        }
        if let cwd = server.cwd { facts.append(.workingFolder(cwd)) }
        // Kept by the daemon while the server is off or starting again, so it
        // is drawn whenever it is there.
        if let info = server.serverInfo, let identity = identity(info) { facts.append(.server(identity)) }
        if server.transport == .http, let account = account(server.auth) {
            let signOut = server.actions.contains(.signOut) && ManagementMCPAction.signOut.isServed(by: served)
            facts.append(.account(account, canSignOut: signOut))
        }
        if !server.env.isEmpty { facts.append(.variables(server.env)) }
        if server.toolCount > 0 { facts.append(.tools(enabled: server.toolsOn, total: server.toolCount)) }

        return facts
    }

    /// The server's own title, or its name where it published none, beside
    /// its version.
    static func identity(_ info: ManagementMCPServerInfo) -> String? {
        let named = info.title ?? info.name
        switch (named, info.version) {
        case (let named?, let version?): return ProductStrings.middot(named, version)
        case (let named?, nil): return named
        case (nil, let version?): return version
        case (nil, nil): return nil
        }
    }

    /// Who a remote server's sign-in belongs to, or how it is reached without
    /// one. A server that takes nothing has no Account row, and neither has an
    /// automatic one the server never asked to sign in.
    static func account(_ auth: ManagementMCPAuth) -> String? {
        switch auth.mode {
        case .none, .unrecognized: return nil
        case .header: return ProductStrings[.mcpSignInAPIKey]
        case .auto: break
        }

        switch auth.state {
        case .signedIn: return auth.accountLabel ?? auth.issuer.flatMap { URL(string: $0)?.host }
        case .signedOut: return ProductStrings[.mcpAccountSignedOut]
        case .expired: return ProductStrings[.mcpAccountExpired]
        case .notNeeded, .unrecognized: return nil
        }
    }
}

/// One server's detail, a page of the server sheet (M74 §4.3, §4.4).
///
/// The server is addressed by name and re-read on every render, so the page
/// follows the connection the list reports rather than the state it opened
/// on. A sign-in is waited for in place under the verb that started it, and
/// removing asks in the footer, never in a dialog.
struct MCPServerDetailPage: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let edit: (ManagementMCPServer) -> Void
    let tools: () -> Void
    let showLogs: () -> Void
    let done: () -> Void

    @State private var confirmingRemove = false
    @State private var removing = false
    @State private var refusal: String?
    /// Whether the last thing asked of this detail was its sign-in
    /// (`IntegrationSignInBlock.resolve`).
    @State private var signInAsked = false
    @State private var startingSignIn = false
    @State private var cancellingSignIn = false

    private var server: ManagementMCPServer? { model.mcpServer(named: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let server {
                heading(server)
                facts(server)
                verbs(server)
                signIn
            } else {
                Text(ProductStrings[.mcpGone])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }

            jobNotice
            footer
        }
    }

    // MARK: - Heading and facts

    private func heading(_ server: ManagementMCPServer) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            MCPServerTile(transport: server.transport)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)

                Text(server.statusSentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Spacer(minLength: Spacing.s)

            if MCPServerProjection.switchServed(model.servedMethods) {
                Toggle(server.name, isOn: Binding(get: { server.enabled }, set: { setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.integrationEnabled], server.name))
            }
        }
    }

    private func facts(_ server: ManagementMCPServer) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(MCPServerFact.facts(server, served: model.servedMethods).enumerated()), id: \.offset) { _, fact in
                factRow(fact)
            }
        }
    }

    @ViewBuilder
    private func factRow(_ fact: MCPServerFact) -> some View {
        switch fact {
        case .runsOn(let host):
            MCPLabeledRow(label: .mcpDetailRunsOn) { MCPFactValue(text: host) }
        case .command(let line, let resolved):
            MCPLabeledRow(label: .mcpFieldCommand) {
                VStack(alignment: .leading, spacing: 2) {
                    MCPFactValue(text: line)
                    if let resolved {
                        Text(resolved)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.faint.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        case .workingFolder(let folder):
            MCPLabeledRow(label: .mcpFieldWorkingFolder) { MCPFactValue(text: folder) }
        case .server(let identity):
            MCPLabeledRow(label: .mcpDetailServer) { MCPFactValue(text: identity) }
        case .account(let account, let canSignOut):
            MCPLabeledRow(label: .mcpDetailAccount) {
                HStack(spacing: Spacing.xs) {
                    MCPFactValue(text: account)
                    Spacer(minLength: Spacing.xs)
                    if canSignOut {
                        Button(ProductStrings[.mcpActionSignOut], action: signOut)
                            .buttonStyle(SecondaryButtonStyle(.row))
                            .disabled(busy)
                            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.mcpActionSignOut], name))
                    }
                }
            }
        case .variables(let variables):
            MCPLabeledRow(label: .mcpFieldVariables) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(variables, id: \.name) { variable in
                        HStack(spacing: Spacing.xs) {
                            Text(variable.name)
                                .foregroundStyle(Palette.ink.color)
                            Text(ProductStrings[variable.present ? .mcpStored : .mcpNotStored])
                                .foregroundStyle((variable.present ? Palette.secondary : Palette.warning).color)
                        }
                    }
                }
            }
        case .tools(let enabled, let total):
            MCPLabeledRow(label: .mcpDetailTools) {
                HStack(spacing: Spacing.xs) {
                    MCPFactValue(text: String(format: ProductStrings[.mcpDetailToolsCount], enabled, total))
                    Spacer(minLength: Spacing.xs)
                    // The tools page reads `mcp.servers.get`, the one method
                    // that carries them.
                    if model.serves(.mcpServersGet) {
                        Button(ProductStrings[.mcpDetailChoose], action: tools)
                            .buttonStyle(SecondaryButtonStyle(.row))
                            .accessibilityLabel(
                                ProductStrings.commaPair(ProductStrings[.mcpDetailChoose], ProductStrings[.mcpDetailTools])
                            )
                    }
                }
            }
        }
    }

    // MARK: - Verbs

    /// The daemon's verbs, titled by id, the one it leads with first and as
    /// the page's one primary action; then the app's own Edit and Show logs.
    private func verbs(_ server: ManagementMCPServer) -> some View {
        let leading = MCPServerProjection.leadingVerb(server, served: model.servedMethods)

        return IntegrationVerbFlow(spacing: Spacing.xs) {
            ForEach(MCPServerProjection.verbs(server, served: model.servedMethods), id: \.self) { action in
                if action == leading {
                    PrimaryAction(title(of: action), size: .row) { perform(action) }
                        .disabled(busy || runner.isRunning)
                } else {
                    Button(title(of: action)) { perform(action) }
                        .disabled(busy || runner.isRunning)
                        .accessibilityLabel(ProductStrings.commaPair(title(of: action), name))
                }
            }

            if model.serves(.mcpServersUpdate) {
                Button(ProductStrings[.mcpActionEdit]) { edit(server) }
                    .disabled(signInBlock == .waiting)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.mcpActionEdit], name))
            }

            Button(ProductStrings[.mcpActionLogs], action: showLogs)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.mcpActionLogs], name))
        }
        .buttonStyle(SecondaryButtonStyle(.row))
    }

    private func title(of action: ManagementMCPAction) -> String {
        guard let key = action.titleKey else {
            preconditionFailure("\(action.wireValue) has no title and draws no button")
        }

        return ProductStrings[key]
    }

    private func perform(_ action: ManagementMCPAction) {
        switch action {
        case .signIn:
            beginSignIn()
        case .check:
            signInAsked = false
            refusal = nil
            Task { await model.startMCPCheck(name: name, on: runner) }
        case .signOut, .enable, .disable, .unrecognized:
            preconditionFailure("\(action.wireValue) is not a verb the detail draws")
        }
    }

    // MARK: - Sign-in

    private var signInBlock: IntegrationSignInBlock {
        IntegrationSignInBlock.resolve(
            asked: signInAsked,
            starting: startingSignIn || model.startingSignIn,
            job: runner.job
        )
    }

    private var busy: Bool { startingSignIn || model.startingSignIn || cancellingSignIn || removing }

    @ViewBuilder
    private var signIn: some View {
        if signInBlock != .hidden {
            IntegrationSignInWait(
                label: name,
                block: signInBlock,
                busy: busy,
                warning: warning,
                runner: runner,
                cancel: cancelSignIn,
                open: { model.openSignIn(on: runner) },
                reopen: { model.reopenSignIn(on: runner) },
                retry: beginSignIn
            )
        }
    }

    private func beginSignIn() {
        guard !startingSignIn, !runner.isRunning else { return }

        startingSignIn = true
        signInAsked = true
        refusal = nil
        Task {
            defer { startingSignIn = false }
            refusal = await model.startMCPSignIn(name: name, on: runner)
        }
    }

    private func cancelSignIn() {
        guard runner.isRunning, !cancellingSignIn else { return }

        cancellingSignIn = true
        Task {
            await runner.cancelJob()
            cancellingSignIn = false
        }
    }

    private func signOut() {
        Task { refusal = await model.logOutMCPServer(name: name) }
    }

    private func setEnabled(_ isOn: Bool) {
        Task {
            if case .refused(let sentence) = await model.setMCPServerEnabled(isOn, name: name) {
                refusal = sentence
            }
        }
    }

    // MARK: - What is running, and the foot

    private var warning: String? { refusal ?? runner.failure ?? runner.browserFailure }

    /// A check's progress and anything that went wrong; a sign-in draws both
    /// itself, under the verb that started it.
    @ViewBuilder
    private var jobNotice: some View {
        if signInBlock == .hidden {
            if runner.isRunning, let phase = runner.phase {
                HStack(spacing: Spacing.s) {
                    ProgressView(value: runner.progress?.fraction).controlSize(.small)
                    Text(phase).fermixType(Typography.style(.calloutSmall))
                }
            }
            if let warning {
                Text(warning)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    /// `Remove server…` and `Done`; or, once removing is asked, the question
    /// itself in their place.
    @ViewBuilder
    private var footer: some View {
        if confirmingRemove {
            HStack(spacing: Spacing.s) {
                Text(String(format: ProductStrings[.mcpRemoveConfirm], name))
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(ProductStrings[.settingsSheetCancel]) { confirmingRemove = false }
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)

                PrimaryAction(ProductStrings[.mcpRemoveDo], size: .row, action: remove)
                    .disabled(removing)
            }
        } else {
            HStack(spacing: Spacing.s) {
                if model.serves(.mcpServersRemove) {
                    Button(ProductStrings[.mcpRemove]) { confirmingRemove = true }
                        .buttonStyle(SecondaryButtonStyle(.row))
                        .disabled(server == nil || busy || signInBlock == .waiting)
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.mcpRemove], name))
                }

                Spacer(minLength: 0)

                doneButton
            }
            .background { escapeKey }
        }
    }

    /// Done is the page's primary action unless a verb leads, and then that
    /// verb is: one ink capsule on the page at a time.
    @ViewBuilder
    private var doneButton: some View {
        if let server, MCPServerProjection.leadingVerb(server, served: model.servedMethods) != nil {
            Button(ProductStrings[.settingsSheetDone], action: done)
                .buttonStyle(SecondaryButtonStyle(.row))
                .disabled(signInBlock == .waiting)
        } else {
            PrimaryAction(ProductStrings[.settingsSheetDone], size: .row, action: done)
                .disabled(signInBlock == .waiting)
        }
    }

    /// Escape as a key the page answers whatever holds focus: a sign-in being
    /// waited for is cancelled, and otherwise the sheet closes (M34 §3.1).
    private var escapeKey: some View {
        Button(ProductStrings[.settingsSheetCancel]) {
            guard signInBlock == .waiting else {
                done()
                return
            }

            if !busy { cancelSignIn() }
        }
        .keyboardShortcut(.cancelAction)
        .hidden()
    }

    private func remove() {
        removing = true
        Task {
            let refused = await model.removeMCPServer(name: name)
            removing = false
            guard let refused else {
                done()
                return
            }

            confirmingRemove = false
            refusal = refused
        }
    }
}

/// A published value on the detail, in the value colour the integration
/// detail draws its values in.
struct MCPFactValue: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Palette.secondary.color)
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }
}
