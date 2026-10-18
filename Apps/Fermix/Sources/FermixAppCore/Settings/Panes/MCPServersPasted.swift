import SwiftUI

/// One line a pasted server's row draws under its name. Every one is drawn
/// whole, wrapped and never cut short: a tick adds what these say (D5).
public enum MCPPastedLine: Equatable, Sendable {
    /// The command line that will run on this Mac, or the address that will
    /// be reached, as the daemon reads it.
    case target(String)
    /// `Runs <program>`, or the sentence for a program this Mac does not
    /// have, as the add form draws it under the command.
    case runs(String, resolved: Bool)
    /// Where the code runs and what leaves this Mac, in the daemon's words.
    case consent(String)
    /// The name is taken here, so the server is not added.
    case taken
}

/// One server of a paste that held several, as its page lists it. Addressed
/// by its place in the paste: one paste may name two servers alike.
public struct MCPPastedItem: Identifiable, Equatable, Sendable {
    public let index: Int
    public let draft: ManagementMCPDraft

    public var id: Int { index }

    /// Whether the paste carried a value for it, which its add stores.
    public var carriesValues: Bool { draft.draftId != nil }

    /// What the row draws under the name: the whole of what will run or be
    /// reached, the program it runs where the daemon knows it, and the consent
    /// line, so ticking never adds anything the page did not show.
    public func lines(taken: Bool) -> [MCPPastedLine] {
        var lines: [MCPPastedLine] = []
        switch draft.transport {
        case .http:
            lines.append(.target(draft.url ?? ""))
        case .stdio, .unrecognized:
            lines.append(.target(draft.commandLine ?? ""))
            if let sentence = draft.commandSentence {
                lines.append(.runs(sentence, resolved: draft.resolvedCommand != nil))
            }
        }
        lines.append(.consent(draft.consentSentence))
        if taken { lines.append(.taken) }

        return lines
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

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The page's one scroll, as on every list the settings draw: no
            // indicator, the soft edge says the list runs on (decision D4).
            // As tall as the servers are, up to what keeps the sheet inside
            // the default window.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .paneScrollEdges()
            .frame(maxHeight: MCPServerSheetMetrics.pastedListHeight)
            .fixedSize(horizontal: false, vertical: true)

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

    private func row(_ item: MCPPastedItem) -> some View {
        let taken = item.draft.conflict || added.contains(item.index)

        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            Toggle(item.draft.name, isOn: tick(item))
                .toggleStyle(.checkbox)
                .disabled(taken || adding)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(Array(item.lines(taken: taken).enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding(.leading, MCPServerSheetMetrics.pastedIndent)
        }
    }

    @ViewBuilder
    private func lineView(_ line: MCPPastedLine) -> some View {
        switch line {
        case .target(let target):
            Text(target)
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .runs(let sentence, let resolved):
            MCPFormNote(text: sentence, failed: !resolved)
        case .consent(let consent):
            MCPFormNote(text: consent)
        case .taken:
            MCPFormNote(text: ProductStrings[.mcpPastedTaken])
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
