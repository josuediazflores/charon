import SwiftUI

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
        .frame(height: 56)
        .background(Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(FocusInk.cardLine).frame(height: 1) }
    }
}
