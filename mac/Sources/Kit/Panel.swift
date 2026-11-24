import SwiftUI

enum PanelVariant {
    case tty, double, bare
}

struct Panel<Content: View>: View {
    var title: String?
    var icon: String?
    var glyph: PixelGlyphName?
    var meta: AnyView?
    var footer: AnyView?
    var variant: PanelVariant = .tty
    var ticks = false
    var dense = false
    var flush = false
    var tone: Tone = .default
    var selected = false
    @ViewBuilder var content: Content

    private var hasHeader: Bool { title != nil || icon != nil || glyph != nil || meta != nil }

    private var inset: CGFloat { variant == .bare ? 0 : (dense ? 10 : 18) }

    private var border: Color {
        if let ink = tone.ink { return ink }
        if selected { return FocusInk.sand }
        return ticks || variant == .double ? HT.line : FocusInk.cardLine
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                HStack(spacing: 8) {
                    if let icon { Text(icon).foregroundStyle(FocusInk.sand) }
                    if let glyph { PixelGlyph(name: glyph, color: FocusInk.sand) }
                    if let title {
                        Text(title).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tone.ink ?? FocusInk.text)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 4)
                    if let meta { meta.font(FocusInk.body).foregroundStyle(HT.inkMid) }
                }
                .padding(.horizontal, inset)
                .padding(.top, inset)
                .padding(.bottom, dense ? 6 : 12)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, flush ? 0 : inset)
                .padding(.top, hasHeader || flush ? 0 : inset)
                .padding(.bottom, flush ? 0 : inset)
            if let footer {
                Divider()
                footer.font(FocusInk.body).foregroundStyle(HT.inkMid)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.vertical, 8)
            }
        }
        if variant == .bare {
            card
        } else {
            card.focusCard(border: border, width: variant == .double ? 2 : 1)
        }
    }
}
