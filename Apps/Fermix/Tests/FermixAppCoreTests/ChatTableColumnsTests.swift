import AppKit
import Testing

@testable import FermixAppCore

/// A table's columns follow the browser's automatic rule: natural widths
/// where they fit, and otherwise the widest give way first and wrap, down to
/// a floor, so every column shows in the reply.
@Suite("Table columns")
struct ChatTableColumnsTests {
    private static let gap = ChatMetrics.tableColumnGap
    private static let floor = ChatMetrics.tableColumnFloor

    private static func widths(_ natural: [Double], in available: Double) -> [Double] {
        ChatTableColumns.widths(natural: natural, available: available, gap: gap, floor: floor)
    }

    private static func total(_ widths: [Double]) -> Double {
        widths.reduce(0, +) + gap * Double(widths.count - 1)
    }

    @Test("a table that fits at its natural widths keeps them")
    func fits() {
        #expect(Self.widths([80, 200, 90], in: 696) == [80, 200, 90])
        #expect(Self.widths([300, 300], in: 624) == [300, 300])
    }

    /// The capture of 2026-10-16: a long Feel column pushed Price range past
    /// the panel's edge. Feel now wraps and the table fits the reply.
    @Test("a long prose column gives way and wraps, so the columns after it show")
    func longProseColumn() {
        let widths = Self.widths([108, 650, 85], in: 696)

        #expect(widths == [108, 455, 85])
        #expect(Self.total(widths) == 696)
    }

    @Test("the widest columns are brought down to the next widest in turn, and narrow ones keep their width")
    func waterFilling() {
        #expect(Self.widths([500, 300, 50], in: 448) == [175, 175, 50])
        #expect(Self.widths([500, 260, 60], in: 648) == [280, 260, 60])
        #expect(Self.widths([900], in: 600) == [600])
    }

    @Test("no column narrows below the floor, and floors wider than the reply are kept")
    func floors() {
        #expect(Self.widths([500, 500, 500], in: 400) == [Self.floor, Self.floor, Self.floor])
        #expect(Self.widths([500, 400, 60], in: 200) == [Self.floor, Self.floor, 60])
        #expect(Self.total(Self.widths([500, 400, 60], in: 200)) > 200)
        #expect(Self.widths([], in: 300).isEmpty)
    }

    /// A table spans the reply: each column's width becomes its share of
    /// the table's, so a narrower window narrows every column in step.
    @Test("each column's share is its width over the table's, and a table with no words shares evenly")
    func shares() {
        let shares = ChatTableColumns.shares(natural: [108, 650, 85], available: 696, gap: Self.gap, floor: Self.floor)

        #expect(shares.map { ($0 * 100).rounded() / 100 } == [16.67, 70.22, 13.12])
        #expect(abs(shares.reduce(0, +) - 100) < 0.001)
        #expect(ChatTableColumns.shares(natural: [0, 0], available: 696, gap: Self.gap, floor: Self.floor) == [50, 50])
    }
}
