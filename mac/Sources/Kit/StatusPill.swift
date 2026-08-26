import SwiftUI

/* ── StatusPill ────────────────────────────────────────────────────────
   [+PASSING]  [!STALE 3M AGO]  [×FAILED]  [-NOT WIRED]

   Bracketed, not rounded. A terminal reports state in square brackets, and the
   bracket run gives every state the same visual weight regardless of word
   length, which a filled chip does not.

   The glyph is not decoration either: it is the non-colour channel, so the
   states stay apart when the console is printed one-bit.
*/

struct StatusPill: View {
    var text: String
    var tone: Tone = .default
    /// Hide the leading glyph. Only where the label alone is unambiguous.
    var glyph: Bool = true
    /// Drop the brackets.
    var bare: Bool = false
    /// Inverse video. At most one per view.
    var inverse: Bool = false

    /// A pill in a selected table row gives up its tone with the rest of the
    /// row: the design system voids exactly these against the signal ground,
    /// because a coloured chip on cyan is a chip nobody can read.
    @Environment(\.htRowSelected) private var rowSelected

    private var ink: Color {
        if rowSelected { return HT.void }
        return tone.ink ?? HT.inkMid
    }
    private var bracketInk: Color { rowSelected ? HT.void : HT.inkFaint }
    private var showBrackets: Bool { !bare && !inverse }

    var body: some View {
        HStack(spacing: 0) {
            if showBrackets {
                Text("[").foregroundStyle(bracketInk)
            }
            if glyph {
                Text(tone.pillGlyph)
                    .foregroundStyle(inverse ? HT.void : ink)
                    .padding(.trailing, 3)
            }
            Text(text.uppercased())
                .foregroundStyle(inverse ? HT.void : ink)
            if showBrackets {
                Text("]").foregroundStyle(bracketInk)
            }
        }
        .font(HT.body)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, inverse ? HT.cw : 0)
        .frame(height: HT.row)
        .background(inverse ? ink : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}
