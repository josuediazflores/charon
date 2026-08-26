import SwiftUI

/* ── Rule ──────────────────────────────────────────────────────────────
   ──────────────  ══════════════  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄  ··············
   ── storage ─────────────────────────────────────────────────────

   Dividers drawn in box-drawing characters rather than borders, so they sit on
   the cell grid and carry the same weight as the type around them.

   `checker` is the hard boundary mark: it separates sections that are
   unrelated, where a rule would imply continuity.
*/

enum RuleVariant {
    case solid, bright, double, dashed, dotted, checker

    var glyph: String {
        switch self {
        case .solid, .bright: return "─"
        case .double: return "═"
        case .dashed: return "┄"
        case .dotted: return "·"
        case .checker: return " "
        }
    }
}

struct Rule: View {
    var variant: RuleVariant = .solid
    /// Section legend set into the rule. Ignored when `variant` is `checker`.
    var label: String? = nil
    /// Colour a checker rule's cells, or a label, cyan.
    var signal: Bool = false
    /// Render as a vertical divider that stretches to its stack.
    var vertical: Bool = false

    private var ink: Color { variant == .bright ? HT.lineBright : HT.line }

    var body: some View {
        if vertical {
            Rectangle()
                .fill(HT.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        } else if variant == .checker {
            CheckerBand(color: signal ? HT.signalDim : HT.inkFaint)
        } else if let label {
            RunRow(spacing: HT.cw, runIndex: 2, runMin: 0, leadFraction: nil) {
                Text(String(repeating: variant.glyph, count: 2))
                    .font(HT.body)
                    .foregroundStyle(ink)
                    .fixedSize()
                Text(label.lowercased())
                    .font(HT.body)
                    .foregroundStyle(signal ? HT.signal : HT.inkMid)
                    .lineLimit(1)
                    .fixedSize()
                GlyphRun(glyph: variant.glyph, color: ink)
            }
            .frame(height: HT.row)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
        } else {
            GlyphRun(glyph: variant.glyph, color: ink)
        }
    }
}
