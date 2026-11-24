import SwiftUI

/* ── StatusLamp ────────────────────────────────────────────────────────
   ▲▲△  ●●○○  ■■□

   A filled/hollow pip run. The level is carried by how many pips are filled,
   so the reading survives with no colour at all -- which is the point, and why
   the tone is reinforcement rather than the signal itself.
*/

enum LampGlyph {
    case triangle, dot, square

    /// Text shapes use the bundled mono face. Round indicators are drawn as circles.
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
    var glyph: LampGlyph = .dot
    var tone: Tone = .default
    /// Optional state label after the pips.
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
                    Circle()
                        .fill(i < lit ? litInk : .clear)
                        .overlay { Circle().strokeBorder(i < lit ? litInk : HT.inkFaint) }
                        .frame(width: 5, height: 5)
                        .padding(.leading, i == 0 ? 0 : 3)
                }
            }
            if let label {
                Text(label.capitalized)
                    .font(.system(size: 12))
                    .foregroundStyle(HT.inkMid)
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
