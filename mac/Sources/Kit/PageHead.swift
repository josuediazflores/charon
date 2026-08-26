import SwiftUI

/* ── PageHead ──────────────────────────────────────────────────────────
   TUESDAY 18 AUGUST
   All sources reporting.

   Names this view. Distinct from `Masthead`, which names the system. The title
   is the one place the 22px step is used in the console.
*/

struct PageHead: View {
    var title: String
    /// One line of orientation. Say what the reader is looking at.
    var subtitle: String? = nil
    /// Controls that apply to the whole view.
    var actions: AnyView? = nil

    @State private var boxWidth: CGFloat = 0

    private var narrow: Bool { boxWidth > 0 && boxWidth <= HT.bpSm }

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(HT.lead)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: HT.lineLead, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if narrow {
                VStack(alignment: .leading, spacing: HT.s2) {
                    text
                    if let actions { HStack(spacing: HT.cw) { actions } }
                }
            } else {
                HStack(alignment: .top, spacing: HT.cw2) {
                    text
                    if let actions { HStack(spacing: HT.cw) { actions }.fixedSize() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .htMeasureWidth { boxWidth = $0 }
    }
}
