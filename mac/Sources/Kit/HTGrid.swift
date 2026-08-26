import SwiftUI

/* ── HTGrid / Cell ─────────────────────────────────────────────────────
   Twelve columns, a sixteen-point gutter, and panels that declare their own
   span -- so a view rearranges without touching the shell.

   **The breakpoints are measured on the content box.** A console pane 700pt
   wide inside a 1600pt window is a narrow console: the rail, the reader and
   the window chrome are all outside the box these panels live in, and a media
   query on the window would keep a four-column layout in a pane that cannot
   hold one. `Layout` gets the content width as its proposal, which is exactly
   the measurement wanted, so no ancestor has to publish anything.

     > 1100      span
     ≤ 1100      spanMd, defaulting to full width
     ≤  720      one column, every cell full width

   At 720 the reference collapses to a single track rather than to twelve
   spanned ones: twelve tracks hold eleven gutters open even when every cell
   spans all of them, and eleven gutters of 16pt is already wider than the
   whole console column on a narrow pane -- the grid cannot get narrower than
   its own gaps.
*/

struct CellSpanKey: LayoutValueKey {
    static let defaultValue: Int = 12
}

struct CellSpanMdKey: LayoutValueKey {
    static let defaultValue: Int? = nil
}

/// A cell in the console grid.
struct Cell<Content: View>: View {
    /// Columns to span above 1100, out of 12.
    var span: Int = 12
    /// Columns to span at 1100 and under. Defaults to full width.
    var spanMd: Int? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .layoutValue(key: CellSpanKey.self, value: span)
            .layoutValue(key: CellSpanMdKey.self, value: spanMd)
    }
}

struct HTGrid<Content: View>: View {
    /// Halve the gutter, for dense readout walls.
    var tight: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        ConsoleGridLayout(gap: tight ? HT.s2 : HT.row) { content }
    }
}

struct ConsoleGridLayout: Layout {
    var columns: Int = 12
    var gap: CGFloat = HT.row

    private struct RowPlan {
        var items: [(index: Int, width: CGFloat)]
        var height: CGFloat
    }

    private func span(_ subview: LayoutSubview, width: CGFloat) -> Int {
        if width <= HT.bpSm { return columns }
        if width <= HT.bpMd { return subview[CellSpanMdKey.self] ?? columns }
        return subview[CellSpanKey.self]
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> [RowPlan] {
        guard !subviews.isEmpty, columns > 0 else { return [] }
        let colWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)

        func boxWidth(_ n: Int) -> CGFloat {
            CGFloat(n) * colWidth + CGFloat(n - 1) * gap
        }

        var rows: [RowPlan] = []
        var i = 0
        while i < subviews.count {
            var used = 0
            var items: [(index: Int, width: CGFloat)] = []
            while i < subviews.count {
                let n = Swift.max(1, Swift.min(columns, span(subviews[i], width: width)))
                if !items.isEmpty, used + n > columns { break }
                items.append((index: i, width: Swift.max(0, boxWidth(n))))
                used += n
                i += 1
                if used >= columns { break }
            }
            let height = items.reduce(CGFloat(0)) { tallest, item in
                Swift.max(tallest,
                          subviews[item.index]
                              .sizeThatFits(ProposedViewSize(width: item.width, height: nil))
                              .height)
            }
            rows.append(RowPlan(items: items, height: height))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? HT.bpMd
        guard width.isFinite, width > 0 else { return .zero }
        let rows = plan(subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + gap * CGFloat(Swift.max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = plan(subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.width, height: row.height))
                x += item.width + gap
            }
            y += row.height + gap
        }
    }
}
