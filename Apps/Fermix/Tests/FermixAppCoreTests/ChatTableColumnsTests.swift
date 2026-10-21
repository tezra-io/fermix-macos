import AppKit
import SwiftUI
import Testing

@testable import FermixAppCore

/// A table's columns follow the browser's automatic rule: natural widths
/// where they fit, and otherwise the widest give way first and wrap, down to
/// a floor, so every column shows in the reply; only floors wider than the
/// reply scroll.
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

    @Test("no column narrows below the floor, and floors wider than the reply are kept and scroll")
    func floors() {
        #expect(Self.widths([500, 500, 500], in: 400) == [Self.floor, Self.floor, Self.floor])
        #expect(Self.widths([500, 400, 60], in: 200) == [Self.floor, Self.floor, 60])
        #expect(Self.total(Self.widths([500, 400, 60], in: 200)) > 200)
        #expect(Self.widths([], in: 300).isEmpty)
    }

    /// Measured through SwiftUI itself: the layout reads each cell's ideal
    /// width, and a cell in a column given way wraps onto more lines.
    @Test("the layout fits a table too wide for the reply by wrapping its widest column")
    @MainActor
    func layoutWraps() {
        let long = String(repeating: "Atmospheric lanes and steep climbs. ", count: 6)
        func size(_ available: Double) -> CGSize {
            let table = ChatTableLayout(alignments: [.leading, .leading, .trailing], available: available, floor: Self.floor) {
                Text("Alfama")
                Text(long)
                Text("€€")
            }
            return NSHostingView(rootView: table).fittingSize
        }
        let wide = size(4000)
        let narrow = size(500)

        #expect(narrow.width <= 500)
        #expect(narrow.height > wide.height)
        #expect(wide.width < 4000)
    }
}
