import SwiftUI

/* ── DotLeader ─────────────────────────────────────────────────────────
   uptime ........................ 42d 11h

   The signature readout, and the default for any key/value pair in this
   console -- reach for it before writing a two-column stack.

   The run is literal `.` characters, not a drawn pattern: in a monospace
   system the dots land on the cell grid on their own, and a run made of the
   same glyph the rest of the line is made of is the difference between a
   terminal and a stylesheet imitating one. `RunRow` counts them from the width
   the row actually got.
*/

struct DotLeader: View {
    /// Left-hand key. Set lowercase, the way a fetch tool prints them.
    var label: String
    /// Right-hand reading.
    var value: String
    /// Tints the value, and only the value.
    var tone: Tone = .default
    /// Demote the value, because its source is stale. Wins over `tone`: the
    /// reference wraps the value in `Demoted`, whose ink is the inner span's.
    var dim: Bool = false
    /// Colour the key cyan, the neofetch convention. Inside an identity block
    /// only -- in a long readout list every line would then compete.
    var keyed: Bool = false
    /// The one step up that renders crisp in a bitmap face.
    var lead: Bool = false
    /// Slot after the value, for a StatusLamp or a SegBar.
    var after: AnyView? = nil
    /// Override the key's ink. Settings uses it to lift its row labels to
    /// bright over their dim notes; nil keeps the readout default.
    var labelInk: Color? = nil

    private var font: Font { lead ? HT.lead : HT.body }
    private var advance: CGFloat { lead ? HT.cw2 : HT.cw }
    private var rowHeight: CGFloat { lead ? HT.lineLead : HT.lineBody }
    private var valueInk: Color { dim ? HT.inkDim : (tone.ink ?? HT.inkBright) }

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Text(label.lowercased())
                .font(font)
                .foregroundStyle(labelInk ?? (keyed ? HT.signal : HT.inkMid))
                .lineLimit(1)
                .truncationMode(.tail)

            GlyphRun(glyph: ".", color: HT.inkFaint,
                     font: font, advance: advance, height: rowHeight)

            Text(value)
                .font(font)
                .foregroundStyle(valueInk)
                .lineLimit(1)
                .truncationMode(.tail)

            if let after { after }
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(value)"))
    }
}
