import SwiftUI

/// The pages of the one MCP server sheet (M74 §4).
///
/// The sheet adds, connects, signs in, lists tools, edits and removes without
/// ever raising a second popup: each step is a page it turns to, with the
/// chevron back control, or a state drawn in place.
public enum MCPServerPage: Equatable, Sendable {
    case add
    case detail(String)
    case tools(String)
    case edit(String)

    /// Where the back control and Escape go. Nil closes the sheet: the add
    /// form and a server's detail are where it opens.
    public var back: MCPServerPage? {
        switch self {
        case .add, .detail: return nil
        case .tools(let name), .edit(let name): return .detail(name)
        }
    }

    /// Where the add form turns once it has sent: nowhere while the daemon
    /// refused the add, to the new server's detail, which shows it connecting,
    /// and to its edit where a value typed for it was refused, because the
    /// server exists now and the value is stored again from there.
    public static func after(_ outcome: MCPAddOutcome) -> MCPServerPage? {
        switch outcome {
        case .refused: return nil
        case .added(let name, nil): return .detail(name)
        case .added(let name, .some): return .edit(name)
        }
    }
}

/// What the Integrations pane presents the sheet for.
struct MCPSheetTarget: Identifiable, Equatable {
    let page: MCPServerPage

    init(_ page: MCPServerPage) {
        self.page = page
    }

    var id: String {
        switch page {
        case .add: return "add"
        case .detail(let name), .tools(let name), .edit(let name): return "server:\(name)"
        }
    }
}

/// The sheet's own geometry.
enum MCPServerSheetMetrics {
    /// The width of the integration detail, so the two sheets of the page are
    /// one size across (M74 §4.2).
    static let width: Double = SheetMetrics.pickerSize.width
    /// The tools page's list, the one scroll in the sheet: seven tool rows and
    /// the top of an eighth, so the cut row says the list goes on without a
    /// scroll indicator. The page stays well inside the default window.
    static let toolsListHeight: Double = 366
    /// The label column of the form and of the detail's facts: the widest
    /// label, `Working folder`, with room to spare.
    static let labelWidth: Double = 104
    /// The name column of a variable or header row.
    static let entryNameWidth: Double = 136
}

/// The MCP server sheet (M74 §4.2 to §4.6): one sheet, 520 points wide, sized
/// to the page it shows and never taller than the default window. It presents
/// nothing; every step is a page of it.
struct MCPServerSheet: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    let showLogs: () -> Void
    let dismiss: () -> Void

    @State private var page: MCPServerPage
    /// The add or edit form, held by the sheet so an add whose value was
    /// refused turns into the new server's edit with what was typed.
    @State private var form = MCPServerForm()

    init(
        opening: MCPServerPage,
        model: SettingsModel,
        runner: JobRunner,
        showLogs: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.runner = runner
        self.showLogs = showLogs
        self.dismiss = dismiss
        _page = State(initialValue: opening)
    }

    var body: some View {
        pageView
            .padding(WindowMetrics.contentPadding)
            .frame(width: MCPServerSheetMetrics.width)
            // Escape goes back a page, or closes the sheet from the page it
            // opened on (M74 §5). Pages with a Cancel of their own answer it
            // there first.
            .onExitCommand(perform: escape)
            .onChange(of: runner.job, initial: true) { _, job in
                guard let job, job.status.isTerminal else { return }

                Task { await model.mcpJobFinished(job) }
            }
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .add:
            MCPServerFormPage(
                mode: .add,
                form: $form,
                model: model,
                runner: runner,
                turn: { page = $0 },
                cancel: dismiss
            )
        case .edit(let name):
            MCPServerFormPage(
                mode: .edit(name),
                form: $form,
                model: model,
                runner: runner,
                turn: { page = $0 },
                cancel: { page = .detail(name) }
            )
        case .detail(let name):
            MCPServerDetailPage(
                name: name,
                model: model,
                runner: runner,
                edit: { server in
                    form = MCPServerForm(editing: server)
                    page = .edit(name)
                },
                tools: { page = .tools(name) },
                showLogs: showLogs,
                done: dismiss
            )
        case .tools(let name):
            MCPServerToolsPage(name: name, model: model, back: { page = .detail(name) })
        }
    }

    private func escape() {
        guard model.editingRow == nil else {
            model.revertEdit()
            return
        }
        guard let back = page.back else {
            dismiss()
            return
        }

        page = back
    }
}
