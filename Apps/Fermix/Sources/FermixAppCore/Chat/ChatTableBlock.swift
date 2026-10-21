import SwiftUI

extension ChatMetrics {
    /// Between two columns of a table.
    static let tableColumnGap: Double = Spacing.l
    /// Between two rows of a table, and either side of the hairline under
    /// its header.
    static let tableRowGap: Double = Spacing.xs
    /// The narrowest a column gives way to so the table fits the reply: about
    /// eight ems of the reply's face, room for a few words a line. Scaled
    /// with the type, as every size is.
    static let tableColumnFloor: Double = 8 * Typography.style(.body).size
}

/// A table in a reply, on a code block's soft panel (`ChatPanel`): its
/// header row in the reply's face at medium weight over a faint hairline, its
/// rows under it in the reply's own, every cell's inline markdown read, each
/// cell aligned as the delimiter row says. Its columns are sized by the
/// browser's automatic rule (`ChatTableColumns`): as wide as their widest
/// cell where the table fits the reply, and otherwise the widest give way
/// and their cells wrap, each row as tall as its tallest cell. Only a table
/// whose columns at their floor are still wider than the reply scrolls
/// sideways inside the panel (`ChatPanelScroll`). Copy takes it as text with
/// tabs (`ReplyTable.text`). It reads the reply's width from the surface, and
/// draws nothing where no surface hosts it, as a row does.
struct ChatTableBlock: View {
    /// The table, its words drawn.
    let table: ReplyTable

    @Environment(\.chatRows) private var chatRows
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var floor = ChatMetrics.tableColumnFloor

    var body: some View {
        if let chatRows {
            ChatPanel(label: ProductStrings[.chatTable], copying: table.text) {
                ChatPanelScroll {
                    ChatTableLayout(
                        alignments: table.alignments,
                        available: chatRows.columnWidth - 2 * ChatMetrics.codeInset,
                        floor: floor
                    ) {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { column, words in
                            cell(words, column: column, style: Typography.style(.body).weight(.medium))
                        }

                        Rectangle()
                            .fill(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
                            .frame(height: Stroke.hairline)
                            .layoutValue(key: ChatTableSpan.self, value: true)

                        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                            ForEach(Array(row.enumerated()), id: \.offset) { column, words in
                                cell(words, column: column, style: Typography.style(.body))
                            }
                        }
                    }
                    .padding(ChatMetrics.codeInset)
                }
            }
        }
    }

    private func cell(_ words: AttributedString, column: Int, style: TypeStyle) -> some View {
        Text(words)
            .fermixType(style)
            .foregroundStyle(Palette.ink.color)
            .multilineTextAlignment(alignment(of: column))
            .textSelection(.enabled)
    }

    private func alignment(of column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A table's columns' widths by the browser's automatic rule. A table that
/// fits the width it has at its columns' natural widths keeps them. One that
/// does not narrows its widest columns first, each brought down to the next
/// widest in turn, until it fits. No column narrows below the floor, and one
/// already narrower keeps its natural width; only when those alone are wider
/// than the width the table has does it keep them, and scroll.
enum ChatTableColumns {
    /// `natural` is each column's widest cell on one line, `available` the
    /// width the table has, and `gap` the room between two columns.
    static func widths(natural: [Double], available: Double, gap: Double, floor: Double) -> [Double] {
        let room = available - gap * Double(max(natural.count - 1, 0))
        let widest = natural.sorted(by: >)
        var rest = widest.reduce(0, +)
        var cap = 0.0
        for (rank, width) in widest.enumerated() {
            // The widest `rank + 1` columns share what the others leave.
            rest -= width
            let level = (room - rest) / Double(rank + 1)
            if level >= (rank + 1 < widest.count ? widest[rank + 1] : 0) {
                cap = level
                break
            }
        }

        return natural.map { min($0, max(cap, floor)) }
    }
}

/// Marks the one subview of a table's layout that takes a row of its own
/// across every column: the hairline under the header.
private struct ChatTableSpan: LayoutValueKey {
    static let defaultValue = false
}

/// A table's cells, in rows of as many as it has columns, laid out at the
/// widths `ChatTableColumns` gives: each cell's natural width read from its
/// ideal size, and each row as tall as its tallest cell at its column's
/// width. A cell sits at the top of its row, aligned in its column as the
/// column says.
struct ChatTableLayout: Layout {
    let alignments: [ReplyTableAlignment]
    /// The width the table has before it scrolls: the reply's, less the
    /// panel's inset either side.
    let available: Double
    let floor: Double

    /// The cells in their rows, and each column's natural width: what the
    /// subviews alone decide.
    struct Cache {
        let rows: [TableRow]
        let natural: [Double]
    }

    enum TableRow {
        case cells([Int])
        case span(Int)
    }

    func makeCache(subviews: Subviews) -> Cache {
        let rows = rows(of: subviews)
        var natural = Array(repeating: 0.0, count: alignments.count)
        for case .cells(let cells) in rows {
            for (column, index) in cells.enumerated() {
                natural[column] = max(natural[column], subviews[index].sizeThatFits(.unspecified).width)
            }
        }
        return Cache(rows: rows, natural: natural)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let measured = measured(subviews, cache: cache)
        let height = measured.heights.reduce(0, +) + ChatMetrics.tableRowGap * Double(max(measured.heights.count - 1, 0))
        return CGSize(width: measured.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let measured = measured(subviews, cache: cache)
        var y = bounds.minY
        for (row, height) in zip(cache.rows, measured.heights) {
            switch row {
            case .cells(let cells):
                var x = bounds.minX
                for (column, index) in cells.enumerated() {
                    let width = measured.widths[column]
                    let along = Self.along(alignments[column])
                    subviews[index].place(
                        at: CGPoint(x: x + width * along, y: y),
                        anchor: UnitPoint(x: along, y: 0),
                        proposal: ProposedViewSize(width: width, height: height)
                    )
                    x += width + ChatMetrics.tableColumnGap
                }
            case .span(let index):
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: measured.width, height: height))
            }
            y += height + ChatMetrics.tableRowGap
        }
    }

    /// The columns' widths, the table's, and each row's height.
    private func measured(_ subviews: Subviews, cache: Cache) -> (widths: [Double], width: Double, heights: [Double]) {
        let widths = ChatTableColumns.widths(natural: cache.natural, available: available, gap: ChatMetrics.tableColumnGap, floor: floor)
        let width = widths.reduce(0, +) + ChatMetrics.tableColumnGap * Double(max(widths.count - 1, 0))
        let heights = cache.rows.map { row -> Double in
            switch row {
            case .cells(let cells):
                return cells.enumerated()
                    .map { column, index in subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height }
                    .max() ?? 0
            case .span(let index):
                return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            }
        }
        return (widths, width, heights)
    }

    /// The cells in rows of as many as the table has columns, the spanning
    /// subview a row of its own.
    private func rows(of subviews: Subviews) -> [TableRow] {
        var rows: [TableRow] = []
        var cells: [Int] = []
        for index in subviews.indices {
            if subviews[index][ChatTableSpan.self] {
                rows.append(.span(index))
                continue
            }
            cells.append(index)
            if cells.count == alignments.count {
                rows.append(.cells(cells))
                cells = []
            }
        }
        if !cells.isEmpty { rows.append(.cells(cells)) }
        return rows
    }

    /// Where a cell sits across its column: at its start, its middle or its
    /// end.
    private static func along(_ alignment: ReplyTableAlignment) -> Double {
        switch alignment {
        case .leading: return 0
        case .center: return 0.5
        case .trailing: return 1
        }
    }
}
