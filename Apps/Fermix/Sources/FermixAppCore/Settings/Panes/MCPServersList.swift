import SwiftUI

extension ManagementMCPAction {
    /// The app's own word for this action, or nil for an id this build does
    /// not know. An unknown id draws no button rather than a guessed one.
    public var titleKey: ProductStringKey? {
        switch self {
        case .signIn: return .mcpActionSignIn
        case .signOut: return .mcpActionSignOut
        case .check: return .mcpActionCheck
        case .enable: return .integrationEnable
        case .disable: return .integrationDisable
        case .unrecognized: return nil
        }
    }

    /// The method this action runs, which the daemon's `hello` has to list
    /// for its control to be drawn (PROTOCOL.md, `mcpServerAction`).
    public var method: ManagementMethod? {
        switch self {
        case .signIn: return .authStart
        case .signOut: return .authLogout
        case .check: return .mcpServersCheckStart
        case .enable: return .mcpServersEnable
        case .disable: return .mcpServersDisable
        case .unrecognized: return nil
        }
    }

    /// Whether the detail's verb line draws this action. Signing out sits on
    /// the Account row it acts on, and turning on and off is the switch, so
    /// each has one control rather than two.
    public var isVerb: Bool {
        switch self {
        case .signIn, .check: return true
        case .signOut, .enable, .disable, .unrecognized: return false
        }
    }

    /// Whether this daemon can run it: an id this build knows, whose method
    /// the daemon's `hello` lists.
    public func isServed(by served: Set<ManagementMethod>) -> Bool {
        method.map(served.contains) ?? false
    }
}

/// Turning `mcp.servers.list` and the plugin catalogue into the MCP servers
/// pill (M74 §4.1).
public enum MCPServerProjection {
    /// The verbs the detail's verb line draws: the daemon's ids it serves,
    /// the one it leads with first, and none this build has no word for.
    public static func verbs(_ server: ManagementMCPServer, served: Set<ManagementMethod>) -> [ManagementMCPAction] {
        let drawn = server.actions.filter { $0.isVerb && $0.isServed(by: served) }
        guard let leading = leadingVerb(server, served: served) else { return drawn }

        return [leading] + drawn.filter { $0 != leading }
    }

    /// The verb the daemon leads with, where it is one the verb line draws.
    /// A failed server whose only action is `disable` has nothing to check,
    /// so it leads with nothing.
    public static func leadingVerb(_ server: ManagementMCPServer, served: Set<ManagementMethod>) -> ManagementMCPAction? {
        guard let primary = server.primaryAction, primary.isVerb, primary.isServed(by: served),
              server.actions.contains(primary)
        else { return nil }

        return primary
    }

    /// Whether the switch can be drawn: it turns a server both ways.
    public static func switchServed(_ served: Set<ManagementMethod>) -> Bool {
        served.contains(.mcpServersEnable) && served.contains(.mcpServersDisable)
    }

    /// Whether a key a server sends in a header is stored. The row names no
    /// presence for it beside the other headers: its sign-in state is the
    /// daemon's word for it, signed in once the key is there.
    public static func keyStored(_ server: ManagementMCPServer) -> Bool {
        server.auth.mode != .header || server.auth.state == .signedIn
    }

    /// Whether a server just switched on is left waiting on the owner: a
    /// sign-in the daemon leads with, or a value it declares and has not got.
    /// Read from the published action and presence facts, never from `status`.
    public static func needsTheOwner(_ server: ManagementMCPServer) -> Bool {
        server.primaryAction == .signIn
            || server.env.contains { !$0.present }
            || server.headers.contains { !$0.present }
            || !keyStored(server)
    }

    /// The page's one search rule: the name and the line under it.
    public static func matches(_ server: ManagementMCPServer, query: String) -> Bool {
        IntegrationSearch.matches(query, title: server.name, summary: server.statusSentence)
    }

    /// The tile's symbol until server icons land (M74 §9): where the code runs.
    public static func symbol(for transport: ManagementMCPTransport) -> String {
        switch transport {
        case .http: return "globe"
        case .stdio, .unrecognized: return "terminal"
        }
    }

    public static func listId(_ server: ManagementMCPServer) -> String { "mcp:\(server.name)" }
}

/// One server the owner added: the plugin row's anatomy over the daemon's own
/// status sentence (M74 §4.1).
struct MCPServerListRow: View {
    let server: ManagementMCPServer
    /// The switch, where the daemon serves both of its methods.
    let setEnabled: ((ManagementMCPServer, Bool) -> Void)?
    let open: () -> Void

    var body: some View {
        IntegrationRowLayout(
            title: server.name,
            subtitle: server.statusSentence,
            accessibilityLabel: ProductStrings.commaPair(server.name, server.statusSentence),
            isOn: setEnabled.map { set in Binding(get: { server.enabled }, set: { set(server, $0) }) },
            open: open
        ) {
            MCPServerTile(transport: server.transport)
        }
    }
}

/// The 28-point tile a server is drawn with, on its row and on its detail.
struct MCPServerTile: View {
    let transport: ManagementMCPTransport

    var body: some View {
        VendorMarkView(symbol: MCPServerProjection.symbol(for: transport), size: IntegrationMetrics.tileSize)
    }
}

/// `Add server`, the header action the pill carries while the daemon says one
/// more fits (M74 §4.1). Importing from another app joins it as a pull-down
/// once the daemon publishes the import.
struct MCPAddServerAction: View {
    let add: () -> Void

    var body: some View {
        Button(ProductStrings[.integrationsMCPAdd], action: add)
            .buttonStyle(SecondaryButtonStyle(.row))
            .fixedSize()
    }
}

/// No server added yet: one line, and the way to add one beneath it.
struct MCPServersEmptyState: View {
    /// Where the daemon serves the add and one fits.
    let add: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProductStrings[.integrationsMCPEmpty])
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            if let add {
                MCPAddServerAction(add: add)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.s)
    }
}
