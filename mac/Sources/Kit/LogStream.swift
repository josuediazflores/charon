import SwiftUI

/* ── LogStream ─────────────────────────────────────────────────────────
   jetson power rail ................................ PASS
   wheel encoder b .................................. FAULT

   The boot log. Each line is a leader with a fixed-width status field, so the
   right column reads down as a column even when the left labels vary.

   **The text is lowercased here**, exactly as the stylesheet does it. The
   Hardware view builds its lines in capitals (`THROTTLED · get_throttled 0x0`)
   and they land on screen in lower case; that round trip is deliberate in the
   reference and porting only half of it would change what the panel says.
*/

struct LogEntry: Identifiable {
    var id: String
    /// Optional leading timestamp, pre-formatted.
    var time: String?
    var text: String
    /// Right-hand status field: PASS, FAIL, 6/6 PASS.
    var state: String
    /// Tints the status field, and only the status field.
    var tone: Tone

    init(id: String = UUID().uuidString, time: String? = nil,
         text: String, state: String, tone: Tone = .default) {
        self.id = id
        self.time = time
        self.text = text
        self.state = state
        self.tone = tone
    }
}

struct LogStream: View {
    var entries: [LogEntry]
    /// Section banner above the lines.
    var banner: String? = nil
    /// Cap the height and give the block its own scroll.
    var maxHeight: CGFloat? = nil

    var body: some View {
        let lines = VStack(alignment: .leading, spacing: 0) {
            if let banner { LogBanner(text: banner) }
            ForEach(entries) { LogLine(entry: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let maxHeight {
            ScrollView(.vertical) { lines }
                .frame(maxHeight: maxHeight)
        } else {
            lines
        }
    }
}

private struct LogLine: View {
    var entry: LogEntry
    @State private var hovering = false

    var body: some View {
        RunRow(spacing: HT.cw,
               runIndex: entry.time == nil ? 1 : 2,
               runMin: HT.cw2,
               leadFraction: 0.62) {
            if let time = entry.time {
                Text(time)
                    .font(HT.body)
                    .foregroundStyle(HT.inkFaint)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(entry.text.lowercased())
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .lineLimit(1)
                .truncationMode(.tail)

            GlyphRun(glyph: ".", color: HT.inkFaint)

            Text(entry.state.uppercased())
                .font(HT.body)
                .foregroundStyle(entry.tone.ink ?? HT.inkBright)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .frame(height: HT.row)
        .background(hovering ? HT.surface2 : Color.clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.text), \(entry.state)"))
    }
}

/// ═══════════ BRING-UP ═══════════ — the section divider from a boot log.
private struct LogBanner: View {
    var text: String

    var body: some View {
        HStack(spacing: HT.cw) {
            GlyphRun(glyph: "═", color: HT.inkFaint)
            Text(text.uppercased())
                .font(HT.body)
                .foregroundStyle(HT.inkDim)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            GlyphRun(glyph: "═", color: HT.inkFaint)
        }
        .frame(height: HT.row)
    }
}
