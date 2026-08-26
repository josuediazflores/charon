import SwiftUI

/* ── Masthead ──────────────────────────────────────────────────────────
       ░▒▓██▓▒░        operator@halftone
     ░▒▓██████▓▒░      ───────────────────────────
    ░▓████████▓░       collector ..... up 4h 51m
   ▒▓██████████▓▒      nodes ......... 2 of 4 connected
    ░▓████████▓░       ████████████████

   The neofetch identity block: art on the left, a key/value dump on the right,
   and the ANSI swatch rows underneath. It is the one place the system states
   its own name, so it appears **once per view**.

   The art column goes at 720 and under, every kind of it: the arts `MastheadArt`
   puts in the slot are preformatted at a column count exactly like an art
   string, and at that width any of them is wider than the whole identity
   column. The measurement is of this block's own box, which is the console's
   content width -- never the window's.
*/

struct MastheadRow: Identifiable {
    var key: String
    var value: String
    var tone: Tone

    var id: String { key }

    init(_ key: String, _ value: String, tone: Tone = .default) {
        self.key = key
        self.value = value
        self.tone = tone
    }
}

struct Masthead: View {
    /// Account name, left of the `@`.
    var user: String = "operator"
    /// Machine name, right of the `@`.
    var host: String = "halftone"
    var rows: [MastheadRow] = []
    /// The identity slot. On Overview this is whatever `MastheadArt` the
    /// console's settings name; nil leaves the dump running full width, which
    /// is both what `none` means and what every art does under 720.
    var art: AnyView? = nil
    /// Show the ANSI swatch rows every fetch tool prints.
    var swatches: Bool = false
    var framed: Bool = false

    /// The system mark, in shade glyphs. The same subject the dither plate
    /// renders and the system is named for. Unused on Overview, which puts a
    /// turning Earth in the slot instead.
    static let halftoneArt = """
             ░▒▓███▓▒░
           ░▒▓███████▓▒░
          ░▓███████████▓░
         ▒▓█████████████▓▒
         ▒▓█████████████▓▒
          ░▓███████████▓░
           ░▒▓███████▓▒░
             ░▒▓███▓▒░
        """

    @State private var boxWidth: CGFloat = 0

    private var showArt: Bool { art != nil && boxWidth > HT.bpSm }
    private var keyWidth: Int { rows.reduce(0) { Swift.max($0, $1.key.count) } }

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw4) {
            if showArt, let art {
                art.fixedSize()
            }

            VStack(alignment: .leading, spacing: 0) {
                who
                GlyphRun(glyph: "─", color: HT.inkFaint,
                         limit: Swift.max(user.count + 1 + host.count, 24))

                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            RunRow(spacing: HT.cw, runIndex: 1,
                                   runMin: HT.cw2, leadFraction: 0.6) {
                                Text(row.key.padding(toLength: keyWidth,
                                                     withPad: " ", startingAt: 0))
                                    .font(HT.body)
                                    .foregroundStyle(HT.signal)
                                    .lineLimit(1)
                                GlyphRun(glyph: ".", color: HT.inkFaint, limit: 40)
                                Text(row.value)
                                    .font(HT.body)
                                    .foregroundStyle(row.tone.ink ?? HT.inkBright)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(height: HT.row)
                        }
                    }
                    .padding(.top, HT.row)
                }

                if swatches {
                    VStack(alignment: .leading, spacing: 0) {
                        swatchRow(HT.ansiBase)
                        swatchRow(HT.ansiBright)
                    }
                    .padding(.top, HT.row)
                    .accessibilityHidden(true)
                }
            }
            // Capped in characters, not points. A fetch block's leaders are
            // meant to be a few columns wide; letting them grow to the whole
            // console strands the values against the far edge.
            .frame(maxWidth: 52 * HT.cw, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, HT.s3)
        .padding(.horizontal, HT.cw2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
        .overlay { framed ? Rectangle().strokeBorder(HT.line, lineWidth: 1) : nil }
        .htMeasureWidth { boxWidth = $0 }
    }

    private var who: some View {
        (Text(user).foregroundStyle(HT.signal)
            + Text("@").foregroundStyle(HT.inkDim)
            + Text(host).foregroundStyle(HT.nominal))
            .font(HT.body)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: HT.row, alignment: .leading)
    }

    private func swatchRow(_ colors: [Color]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { pair in
                Rectangle().fill(pair.element).frame(width: HT.cw2, height: 8)
            }
        }
    }
}

/* ── MastheadStrip ─────────────────────────────────────────────────────
   ▨▨▨▨▨▨▨▨▨▨  L I V E  ▨▨▨▨▨▨▨▨▨▨

   Checker, legend, checker. The state banner at the foot of a view, and the
   only footer the console pages have -- there is no page footer, so a view
   ends here.
*/
struct MastheadStrip: View {
    var legend: String
    /// Tint the strip cyan.
    var signal: Bool = false

    var body: some View {
        HStack(spacing: HT.cw2) {
            CheckerBand(color: signal ? HT.signalDim : HT.inkFaint)
            Text(legend.uppercased())
                .font(HT.body)
                .tracking(1)
                .foregroundStyle(signal ? HT.signal : HT.inkBright)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            CheckerBand(color: signal ? HT.signalDim : HT.inkFaint)
        }
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(legend))
    }
}
