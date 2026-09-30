import SwiftUI

/// How the detail column's width is shared between the body and the browser
/// pane beside it (plan §4.3, redlines decision 37), as one pure rule.
///
/// Each side has a floor, the pane has a width it prefers, and the body has a
/// width past which it only grows its margins. The column's width is given
/// out in that order: the pane's floor, the body's floor, the pane up to what
/// it prefers, the body up to its ceiling, and everything past that to the
/// page, the one thing in the column that can use it. So dragging the window
/// wider grows the page, and a small screen narrows the page before it
/// starves the chat (owner, 2026-09-28).
public enum PaneSplit {
    public struct Widths: Equatable, Sendable {
        public let body: Double
        public let pane: Double

        public init(body: Double, pane: Double) {
            self.body = body
            self.pane = pane
        }
    }

    /// The two widths for a column `available` points wide, the body held
    /// between its floor and its ceiling and the pane between its floor and
    /// the width it prefers, as far as the column allows. They always sum to
    /// the column.
    public static func widths(
        available: Double,
        body bodyWidths: ClosedRange<Double>,
        pane paneWidths: ClosedRange<Double>
    ) -> Widths {
        var pane = min(paneWidths.lowerBound, available)
        var body = available - pane

        let spare = max(0, body - bodyWidths.lowerBound)
        let preferred = min(spare, paneWidths.upperBound - paneWidths.lowerBound)
        pane += preferred
        body -= preferred

        let unusable = max(0, body - bodyWidths.upperBound)
        pane += unusable
        body -= unusable

        return Widths(body: body, pane: pane)
    }
}

/// The detail column drawn: the body then the pane, side by side at the
/// widths `PaneSplit` gives them, the full height of the column. A closed
/// pane draws nothing, and a view that draws nothing is no subview to a
/// layout, so the body then has the column to itself.
struct PaneSplitLayout: Layout {
    let body: ClosedRange<Double>
    let pane: ClosedRange<Double>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        precondition((1 ... 2).contains(subviews.count), "the split holds the body and, while it is open, the pane")

        guard subviews.count == 2 else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let widths = PaneSplit.widths(available: bounds.width, body: body, pane: pane)
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: widths.body, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + widths.body, y: bounds.minY),
            proposal: ProposedViewSize(width: widths.pane, height: bounds.height)
        )
    }
}
