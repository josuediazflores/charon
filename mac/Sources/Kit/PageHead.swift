import SwiftUI

struct PageHead: View {
    var title: String
    /// One line of orientation. Say what the reader is looking at.
    var subtitle: String? = nil
    /// Controls that apply to the whole view.
    var actions: AnyView? = nil

    var titleSize: CGFloat = 38

    @State private var boxWidth: CGFloat = 0

    private var narrow: Bool { boxWidth > 0 && boxWidth <= HT.bpSm }

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(FocusInk.heading(narrow ? min(31, titleSize) : titleSize))
                .tracking(-1)
                .foregroundStyle(FocusInk.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(FocusInk.body)
                    .foregroundStyle(HT.inkMid)
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
