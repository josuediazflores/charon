import SwiftUI

/* ── StatusLamp ────────────────────────────────────────────────────────
   ▲▲△  ●●○○  ■■□

   A filled/hollow pip run. The level is carried by how many pips are filled,
   so the reading survives with no colour at all -- which is the point, and why
   the tone is reinforcement rather than the signal itself.
*/

enum LampGlyph {
    case triangle, dot, square

    /// The filled and hollow characters, for the two variants the face carries.
    ///
    /// `dot` has none, and that is the whole of the distinction: ▲△■□ are in
    /// Departure Mono and the round pair is not, so a dot run set as text would
    /// be two circles borrowed from whatever the system substitutes, at another
    /// weight and off the pixel grid the row beside it sits on. Its pips are
    /// `PixelGlyph` bitmaps instead. A glyph the face has is always better as a
    /// character than as a picture of one, and a glyph it lacks is the reverse.
    var run: (on: String, off: String)? {
        switch self {
        case .triangle: return ("▲", "△")
        case .square: return ("■", "□")
        case .dot: return nil
        }
    }
}

struct StatusLamp: View {
    var level: Int
    var of: Int = 3
    /// Triangles read as signal strength, dots as channel state.
    var glyph: LampGlyph = .triangle
    var tone: Tone = .default
    /// Short caps label after the pips.
    var label: String? = nil

    private var lit: Int { Swift.max(0, Swift.min(of, level)) }
    private var litInk: Color { tone.ink ?? HT.inkBright }

    var body: some View {
        HStack(spacing: 0) {
            if let run = glyph.run {
                Text(String(repeating: run.on, count: lit))
                    .foregroundStyle(litInk)
                Text(String(repeating: run.off, count: Swift.max(0, of - lit)))
                    .foregroundStyle(HT.inkFaint)
            } else {
                ForEach(0..<Swift.max(0, of), id: \.self) { i in
                    PixelGlyph(name: i < lit ? .dot : .ring,
                               color: i < lit ? litInk : HT.inkFaint)
                }
            }
            if let label {
                Text(label.uppercased())
                    .foregroundStyle(HT.inkDim)
                    .padding(.leading, HT.cw)
            }
        }
        .font(HT.body)
        .kerning(0)
        .tracking(0)
        .lineLimit(1)
        .fixedSize()
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label.map { "\($0), \(lit) of \(of)" } ?? "\(lit) of \(of)"))
    }
}
