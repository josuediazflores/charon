import SwiftUI

/* ── Sparkline ─────────────────────────────────────────────────────────
   ▂▁▄▆▃▅█▆▂▁▄▇▅█

   A trend strip in eighth-block characters, one cell per point. Shape only: no
   axes, no labels, no gridlines. If the reader needs the values, this is the
   wrong component.

   **Fewer than two points renders nothing.** One reading is not a trend, and a
   single block sitting on its own reads as a bar chart of one.

   The panel that draws one removes it entirely when `health.hideDelta` is set
   -- not dimmed. A stale value dimmed still reads as "this was true a while
   ago", which is honest; a stale sparkline dimmed still reads as "here is what
   the last fortnight did", which is not.
*/

struct Sparkline: View {
    /// Oldest first.
    var data: [Int]
    var tone: Tone = .default
    /// Colour the final cell brighter, marking the current reading.
    var cap: Bool = false
    /// Description for assistive tech. Without it the strip is decorative.
    var label: String? = nil

    /// U+2581 to U+2588. Eight levels is all a text sparkline has, and
    /// pretending otherwise is what makes one look wrong.
    private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    private var glyphs: String {
        guard data.count >= 2 else { return "" }
        let lo = Double(data.min() ?? 0)
        let hi = Double(data.max() ?? 0)
        let span = (hi - lo) == 0 ? 1 : (hi - lo)
        return String(data.map { v in
            let t = Swift.min(1, Swift.max(0, (Double(v) - lo) / span))
            let step = Int((t * Double(Sparkline.blocks.count - 1)).rounded())
            return Sparkline.blocks[Swift.min(Sparkline.blocks.count - 1, step)]
        })
    }

    private var ink: Color { tone.ink ?? HT.inkMid }

    var body: some View {
        if data.count >= 2 {
            let run = glyphs
            let head = cap ? String(run.dropLast()) : run
            let tail = cap ? String(run.suffix(1)) : ""

            HStack(spacing: 0) {
                Text(head).foregroundStyle(ink)
                if cap { Text(tail).foregroundStyle(HT.inkBright) }
                Spacer(minLength: 0)
            }
            .font(HT.body)
            .kerning(0)
            .tracking(0)
            .lineLimit(1)
            .frame(height: HT.row)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label ?? ""))
            .accessibilityHidden(label == nil)
        }
    }
}
