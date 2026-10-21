import SwiftUI

extension ManagementMCPTool {
    /// The tag beside a tool's switch, from the server's own annotations. It
    /// informs; it decides nothing (M74 §4.5).
    public var tagKey: ProductStringKey {
        if readOnly { return .mcpToolReadOnly }
        if destructive { return .mcpToolDestructive }

        return .mcpToolChanges
    }

    /// The server's title for the tool, or its name where it published none.
    public var displayTitle: String { title ?? name }

    public func matches(_ query: String) -> Bool {
        IntegrationSearch.matches(query, title: displayTitle, summary: description)
    }
}

/// A server's tools, a page of the server sheet that owns its one scroll
/// (M74 §4.5; redlines §5.8: a long list is a page that owns its list).
///
/// The tools are `mcp.servers.get`'s, read when the page opens and after each
/// switch, since the list carries only their counts. One switch per tool: on
/// means the agent can find and use it, off hides it. Fermix asks before no
/// tool call, so the switch is the whole control.
struct MCPServerToolsPage: View {
    let name: String
    @ObservedObject var model: SettingsModel
    let back: () -> Void

    @State private var query = ""
    /// The daemon's refusal of a switch: under that tool's row, or at the
    /// head of the list for `Turn all on`, which is every row at once.
    @State private var refusal: (tool: String?, sentence: String)?
    @State private var writing = false

    private var read: SettingsReadState<[ManagementMCPTool]> { model.mcpTools[name] ?? .unread }

    private var tools: [ManagementMCPTool] { read.value ?? [] }

    private var visible: [ManagementMCPTool] { tools.filter { $0.matches(query) } }

    /// Turn all on while any is off, and off once every one is on.
    private var allOn: Bool { tools.allSatisfy(\.enabled) }

    /// Whether the daemon serves the switch at all.
    private var switchable: Bool { model.serves(.mcpServersToolSet) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                IntegrationPageHeader(title: ProductStrings[.mcpToolsTitle], parent: name, back: back)

                Spacer(minLength: Spacing.s)

                if switchable {
                    Button(ProductStrings[allOn ? .mcpToolsAllOff : .mcpToolsAllOn], action: setAll)
                        .buttonStyle(SecondaryButtonStyle(.row))
                        .disabled(writing || tools.isEmpty)
                }
            }

            SearchField(text: $query, prompt: ProductStrings[.mcpToolsSearch])

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if case .unavailable(let sentence) = read {
                        MCPFormNote(text: sentence, failed: true)
                    }
                    if let refusal, refusal.tool == nil {
                        MCPFormNote(text: refusal.sentence, failed: true)
                    }
                    ForEach(visible) { tool in
                        MCPToolRow(tool: tool, set: switchable ? { isOn in set(tool, isOn) } : nil)

                        if let refusal, refusal.tool == tool.name {
                            MCPFormNote(text: refusal.sentence, failed: true)
                        }
                    }
                }
            }
            // No indicator, as on every list the settings draw (decision D4);
            // the soft edge is what says the tools run on past it.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .paneScrollEdges()
            .frame(height: MCPServerSheetMetrics.toolsListHeight)
        }
        .background { escapeKey }
        .task { await model.readMCPServer(name) }
    }

    /// Escape goes back to the detail, as the chevron does.
    private var escapeKey: some View {
        Button(ProductStrings[.settingsSheetCancel], action: back)
            .keyboardShortcut(.cancelAction)
            .hidden()
    }

    private func set(_ tool: ManagementMCPTool, _ isOn: Bool) {
        Task {
            let refused = await model.setMCPTool(server: name, tool: tool.name, enabled: isOn)
            refusal = refused.map { (tool.name, $0) }
        }
    }

    private func setAll() {
        let target = !allOn
        writing = true
        Task {
            let refused = await model.setAllMCPTools(server: name, enabled: target)
            refusal = refused.map { (nil, $0) }
            writing = false
        }
    }
}

/// One tool: its title over its one-line description, the annotation tag, and
/// its switch, where the daemon serves it.
struct MCPToolRow: View {
    let tool: ManagementMCPTool
    let set: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayTitle)
                    .fermixType(Typography.style(.callout).weight(.medium))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)

                if let description = tool.description {
                    Text(description)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.s)

            Text(ProductStrings[tool.tagKey])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)

            if let set {
                Toggle(tool.displayTitle, isOn: Binding(get: { tool.enabled }, set: set))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(String(format: ProductStrings[.mcpToolUseFormat], tool.displayTitle))
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.trailing, Spacing.xxs)
    }
}
