import SwiftUI

/* ── TopBar ────────────────────────────────────────────────────────────
   $ Search nodes, commits          ⌘K        DEMO  ⟳  ▲▲▲ LIVE

   The bar above the console. Command field on the left, feed state on the
   right. Forty-eight points tall and ruled off underneath, the same height as
   the rail's brand row, so the two make one line across the window.
*/

struct TopBar<Lead: View, Actions: View>: View {
    @ViewBuilder var lead: Lead
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: HT.cw2) {
            HStack(spacing: HT.cw2) { lead }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: HT.cw) { actions }
                .fixedSize()
        }
        .padding(.horizontal, HT.cw3)
        .frame(height: HT.row3)
        .background(Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(HT.line).frame(height: 1) }
    }
}
