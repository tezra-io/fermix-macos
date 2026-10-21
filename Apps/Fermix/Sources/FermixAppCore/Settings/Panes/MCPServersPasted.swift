import SwiftUI

/// One server of a paste that held several, as its page lists it. Addressed
/// by its place in the paste: one paste may name two servers alike.
public struct MCPPastedItem: Identifiable, Equatable, Sendable {
    public let index: Int
    public let draft: ManagementMCPDraft

    public var id: Int { index }

    /// Whether the paste carried a value for it, which its add stores.
    public var carriesValues: Bool { draft.draftId != nil }

    /// What the row draws under the name, whole (`MCPCandidateLine`).
    public func lines(taken: Bool) -> [MCPCandidateLine] {
        MCPCandidateLine.lines(
            transport: draft.transport,
            url: draft.url,
            commandLine: draft.commandLine,
            commandSentence: draft.commandSentence,
            resolved: draft.resolvedCommand != nil,
            consent: draft.consentSentence
        ) + (taken ? [.taken] : [])
    }

    public static func items(_ drafts: ManagementMCPDrafts) -> [MCPPastedItem] {
        drafts.drafts.enumerated().map { MCPPastedItem(index: $0.offset, draft: $0.element) }
    }

    /// Every server ticked but the ones whose name is already taken here.
    public static func initiallyTicked(_ items: [MCPPastedItem]) -> Set<Int> {
        Set(items.filter { !$0.draft.conflict }.map(\.index))
    }
}

/// The servers one paste held, a page of the server sheet (M74 §4.2).
///
/// Each server shows, under its name, the whole of what a tick adds: the
/// command line it runs or the address it reaches, the program the daemon
/// found for it, and its consent line, none of it cut short. Many servers
/// make the list scroll inside the page rather than shorten a line. Each
/// ticked server is added as the paste gave it, with its own draft id, so the
/// values the paste carried are stored with it and never asked for again. A
/// server whose name is taken here is unticked and says so.
struct MCPPastedServersPage: View {
    let drafts: ManagementMCPDrafts
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: JobRunner
    /// Back to the add form.
    let back: () -> Void
    /// Closes the sheet: Cancel, and every ticked server added.
    let done: () -> Void

    @State private var ticked: Set<Int>
    /// The servers this page has added, which stay listed as added.
    @State private var added: Set<Int> = []
    @State private var adding = false
    @State private var refusal: String?

    init(
        drafts: ManagementMCPDrafts,
        model: SettingsModel,
        runner: JobRunner,
        back: @escaping () -> Void,
        done: @escaping () -> Void
    ) {
        self.drafts = drafts
        self.model = model
        self.runner = runner
        self.back = back
        self.done = done
        _ticked = State(initialValue: MCPPastedItem.initiallyTicked(MCPPastedItem.items(drafts)))
    }

    private var items: [MCPPastedItem] { MCPPastedItem.items(drafts) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            IntegrationPageHeader(title: ProductStrings[.mcpPastedTitle], parent: ProductStrings[.mcpAddTitle], back: back)

            MCPCandidateScroll {
                ForEach(items) { item in
                    let taken = item.draft.conflict || added.contains(item.index)
                    MCPCandidateRow(
                        name: item.draft.name,
                        isOn: tick(item),
                        disabled: taken || adding,
                        lines: item.lines(taken: taken)
                    )
                }
            }

            if items.contains(where: \.carriesValues) {
                MCPFormNote(text: ProductStrings[.mcpPastedKeysFooter])
            }
            if let refusal {
                MCPFormNote(text: refusal, failed: true)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: done)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)

                PrimaryAction(String(format: ProductStrings[.mcpPastedAdd], ticked.count), size: .row, action: commit)
                    .disabled(ticked.isEmpty || adding)
            }
        }
    }

    private func tick(_ item: MCPPastedItem) -> Binding<Bool> {
        Binding(
            get: { ticked.contains(item.index) },
            set: { isOn in
                if isOn { ticked.insert(item.index) } else { ticked.remove(item.index) }
            }
        )
    }

    /// One add per ticked server, in the paste's order, stopping at the first
    /// refusal with the servers added before it kept and marked as added.
    private func commit() {
        adding = true
        refusal = nil
        Task {
            defer { adding = false }
            for item in items where ticked.contains(item.index) {
                if case .refused(let refused) = await model.addMCPServer(.pasted(item.draft), values: [], on: runner) {
                    refusal = refused.sentence
                    return
                }
                added.insert(item.index)
                ticked.remove(item.index)
            }

            done()
        }
    }
}
