import SwiftUI

/// One app the import page lists: the servers its settings hold, and what
/// the daemon could not offer from them, under the daemon's name for it.
public struct MCPImportGroup: Identifiable, Equatable, Sendable {
    public let source: ManagementMCPImportSource
    /// The daemon's `source_label`, the group's heading.
    public let label: String
    public let candidates: [ManagementMCPImportCandidate]
    public let skipped: [ManagementMCPImportSkipped]

    public var id: String { source.wireValue }

    /// Every app the scan names, in the order it first names it: the apps
    /// with servers to offer as the candidates come, then the apps that only
    /// have something skipped.
    public static func groups(_ scan: ManagementMCPImportScan) -> [MCPImportGroup] {
        var order: [ManagementMCPImportSource] = []
        var labels: [ManagementMCPImportSource: String] = [:]
        for (source, label) in scan.candidates.map({ ($0.source, $0.sourceLabel) }) + scan.skipped.map({ ($0.source, $0.sourceLabel) })
            where labels[source] == nil {
            order.append(source)
            labels[source] = label
        }

        return order.map { source in
            MCPImportGroup(
                source: source,
                label: labels[source] ?? "",
                candidates: scan.candidates.filter { $0.source == source },
                skipped: scan.skipped.filter { $0.source == source }
            )
        }
    }

    /// Every server ticked but the ones whose name is already taken here.
    public static func initiallyTicked(_ scan: ManagementMCPImportScan) -> Set<ManagementMCPImportPick> {
        Set(scan.candidates.filter { !$0.conflict }.map(\.pick))
    }
}

extension ManagementMCPImportCandidate {
    public var pick: ManagementMCPImportPick { ManagementMCPImportPick(source: source, name: name) }

    /// What the row draws under the name, whole (`MCPCandidateLine`), with
    /// `Already added` where the name is taken here and the daemon's sentence
    /// where an import did not add it.
    public func lines(taken: Bool, refused: String?) -> [MCPCandidateLine] {
        MCPCandidateLine.lines(
            transport: transport,
            url: url,
            commandLine: commandLine,
            commandSentence: commandSentence,
            resolved: resolvedCommand != nil,
            consent: consentSentence
        ) + (taken ? [.taken] : []) + (refused.map { [.refused($0)] } ?? [])
    }
}

/// Import from another app, a page of the server sheet (M74 §4.7).
///
/// The other apps' settings are read when this page opens and never before,
/// and never written. Each app is a group under the daemon's name for it;
/// each server shows the whole of what a tick adds, as the pasted servers'
/// page does; a server whose name is taken here is unticked and says so; and
/// what could not be offered is the daemon's sentence in its group. The ticked
/// servers are imported in one call, with the keys their settings held copied
/// into the Keychain.
struct MCPImportPage: View {
    @ObservedObject var model: SettingsModel
    /// Back to the add form.
    let back: () -> Void
    /// Closes the sheet: Cancel, and an import that added every server.
    let done: () -> Void

    @State private var scan: ManagementMCPImportScan?
    @State private var refusal: String?
    @State private var ticked: Set<ManagementMCPImportPick> = []
    /// The servers this page imported, which stay listed as added.
    @State private var added: Set<ManagementMCPImportPick> = []
    /// The servers an import did not add, with the daemon's sentence.
    @State private var refused: [ManagementMCPImportPick: String] = [:]
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            IntegrationPageHeader(title: ProductStrings[.mcpImportTitle], parent: ProductStrings[.mcpAddTitle], back: back)

            content

            if scan?.candidates.contains(where: { !$0.secretNames.isEmpty }) == true {
                MCPFormNote(text: ProductStrings[.mcpImportKeysFooter])
            }
            if let refusal {
                MCPFormNote(text: refusal, failed: true)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: done)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)

                PrimaryAction(String(format: ProductStrings[.mcpImportDo], ticked.count), size: .row, action: commit)
                    .disabled(ticked.isEmpty || importing)
            }
        }
        .task { await read() }
    }

    @ViewBuilder
    private var content: some View {
        if let scan {
            if scan.candidates.isEmpty && scan.skipped.isEmpty {
                MCPFormNote(text: ProductStrings[.mcpImportNone])
            } else {
                MCPCandidateScroll {
                    ForEach(MCPImportGroup.groups(scan)) { group in
                        groupView(group)
                    }
                }
            }
        } else if refusal == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: HitTarget.button)
                .accessibilityHidden(true)
        }
    }

    private func groupView(_ group: MCPImportGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(group.label)
                .fermixType(Typography.style(.callout).weight(.medium))
                .foregroundStyle(Palette.secondary.color)
                .accessibilityAddTraits(.isHeader)

            ForEach(group.candidates, id: \.pick) { candidate in
                let taken = candidate.conflict || added.contains(candidate.pick)
                MCPCandidateRow(
                    name: candidate.name,
                    isOn: tick(candidate.pick),
                    disabled: taken || importing,
                    lines: candidate.lines(taken: taken, refused: refused[candidate.pick])
                )
            }

            ForEach(Array(group.skipped.enumerated()), id: \.offset) { _, skipped in
                skippedView(skipped)
            }
        }
    }

    /// A server the daemon could not offer, by its name, or a whole settings
    /// file it could not read, as its sentence alone.
    @ViewBuilder
    private func skippedView(_ skipped: ManagementMCPImportSkipped) -> some View {
        if let name = skipped.name {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(name)
                    .foregroundStyle(Palette.secondary.color)
                MCPFormNote(text: skipped.sentence, failed: true)
                    .padding(.leading, MCPServerSheetMetrics.pastedIndent)
            }
        } else {
            MCPFormNote(text: skipped.sentence, failed: true)
        }
    }

    private func tick(_ pick: ManagementMCPImportPick) -> Binding<Bool> {
        Binding(
            get: { ticked.contains(pick) },
            set: { isOn in
                if isOn { ticked.insert(pick) } else { ticked.remove(pick) }
            }
        )
    }

    /// The other apps are read when the page opens, on the owner's ask and
    /// never before.
    private func read() async {
        switch await model.scanMCPImports() {
        case .success(let found):
            scan = found
            ticked = MCPImportGroup.initiallyTicked(found)
        case .failure(let refused):
            refusal = refused.sentence
        }
    }

    /// One import of every ticked server. Where every one was added the sheet
    /// closes onto the list, read again; a server not added keeps the page
    /// open with the daemon's sentence under it.
    private func commit() {
        let picks = (scan?.candidates ?? []).map(\.pick).filter(ticked.contains)
        importing = true
        refusal = nil
        Task {
            defer { importing = false }
            switch await model.importMCPServers(picks) {
            case .failure(let refused):
                refusal = refused.sentence
            case .success(let imported):
                let notAdded = Dictionary(
                    imported.refused.map { (ManagementMCPImportPick(source: $0.source, name: $0.name), $0.sentence) },
                    uniquingKeysWith: { first, _ in first }
                )
                refused = notAdded
                added.formUnion(picks.filter { notAdded[$0] == nil })
                ticked.subtract(picks)
                if notAdded.isEmpty { done() }
            }
        }
    }
}
