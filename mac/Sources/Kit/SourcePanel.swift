import SwiftUI

/* ── SourcePanel ───────────────────────────────────────────────────────
   A Panel that knows how healthy its source is.

   **Every panel fed by the collector goes through here**, so the rule from the
   design system's conventions -- a coloured frame means *this block is the
   thing in trouble* -- is expressed exactly once, and a new panel cannot get it
   wrong by omission.

   Two things it always does: the meta ends in the StatusLamp, and the footer
   carries the pill and the note whenever health has either. Never set a
   `tone` on a data panel by hand; that is how the staleness rule starts
   drifting.
*/

struct SourcePanel<Content: View>: View {
    var env: (any SourceEnvelopeShape)?
    var feedDown: Bool
    var title: String?
    var icon: String? = nil
    /// The bitmap half of the same slot. See `Panel.glyph`.
    var glyph: PixelGlyphName? = nil
    /// Text notched at the right of the top rule, before the lamp.
    var meta: String? = nil
    var ticks: Bool = false
    var dense: Bool = false
    var flush: Bool = false
    /// Given the health, render the body. `h.dim` demotes a value; `h.hideDelta`
    /// removes anything asserting a change that did not happen in the window it
    /// implies.
    @ViewBuilder var render: (Health) -> Content

    var body: some View {
        let h = HealthRule.health(env, feedDown: feedDown)

        Panel(
            title: title,
            icon: icon,
            glyph: glyph,
            meta: AnyView(
                HStack(spacing: HT.s1) {
                    if let meta {
                        Text(meta)
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .lineLimit(1)
                    }
                    StatusLamp(level: h.lamp.level, of: h.lamp.of, tone: h.lamp.tone)
                }
            ),
            footer: (h.pill != nil || h.note != nil) ? AnyView(
                HStack(spacing: HT.cw) {
                    if let pill = h.pill {
                        StatusPill(text: pill, tone: h.pillTone)
                    }
                    if let note = h.note {
                        Text(note)
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            ) : nil,
            ticks: ticks,
            dense: dense,
            flush: flush,
            tone: h.panelTone
        ) {
            render(h)
        }
    }
}
