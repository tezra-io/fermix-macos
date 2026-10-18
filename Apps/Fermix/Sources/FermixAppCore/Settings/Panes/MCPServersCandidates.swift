import SwiftUI

/// One line a server offered to be added draws under its name, on the pasted
/// servers' page and on the import page. Every one is drawn whole, wrapped
/// and never cut short: a tick adds what these say (D5).
public enum MCPCandidateLine: Equatable, Sendable {
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
    /// The daemon's sentence for a server it did not add.
    case refused(String)

    /// What a server's row draws under its name: the whole of what will run
    /// or be reached, the program it runs where the daemon knows it, and the
    /// consent line, so ticking never adds anything the page did not show.
    public static func lines(
        transport: ManagementMCPTransport,
        url: String?,
        commandLine: String?,
        commandSentence: String?,
        resolved: Bool,
        consent: String
    ) -> [MCPCandidateLine] {
        var lines: [MCPCandidateLine] = []
        switch transport {
        case .http:
            lines.append(.target(url ?? ""))
        case .stdio, .unrecognized:
            lines.append(.target(commandLine ?? ""))
            if let commandSentence {
                lines.append(.runs(commandSentence, resolved: resolved))
            }
        }
        lines.append(.consent(consent))

        return lines
    }
}

/// One server offered to be added: its box, its name, and every line under
/// it, whole.
struct MCPCandidateRow: View {
    let name: String
    let isOn: Binding<Bool>
    let disabled: Bool
    let lines: [MCPCandidateLine]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Toggle(name, isOn: isOn)
                .toggleStyle(.checkbox)
                .disabled(disabled)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding(.leading, MCPServerSheetMetrics.pastedIndent)
        }
    }

    @ViewBuilder
    private func lineView(_ line: MCPCandidateLine) -> some View {
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
            MCPFormNote(text: ProductStrings[.mcpCandidateTaken])
        case .refused(let sentence):
            MCPFormNote(text: sentence, failed: true)
        }
    }
}

/// The servers a page offers, which is that page's one scroll: as tall as
/// they are, up to what keeps the sheet inside the default window, and then
/// scrolling rather than shortening a line.
struct MCPCandidateScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No indicator, as on every list the settings draw: the soft edge
        // says the list runs on (decision D4).
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .paneScrollEdges()
        .frame(maxHeight: MCPServerSheetMetrics.pastedListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
