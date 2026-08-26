import SwiftUI

/* ── Listbox ───────────────────────────────────────────────────────────
     ┌──────────┐
     │ • medium │
     │   high   │
     └──────────┘
     [ medium ▼ ]

   **A listbox, because a system popup cannot be made to match this page.**

   The closed control styles into the dialect easily enough. The dropped list
   cannot: on macOS an `NSMenu` is drawn by the window server, in the system
   font, with its own rounded chrome and its own blue selection, and nothing a
   SwiftUI `Picker` or `Menu` accepts changes any of it. So the one control that
   opened into a different design language is a real listbox that opens into
   this one.

   What that costs is the keyboard a native control gives away, so it is rebuilt
   rather than dropped: arrow keys, Home and End, Enter and Space, Escape, and
   the selection marked with a glyph as well as with ink so it survives 1-bit.

   **It opens upward by default.** Its home is the composer at the bottom of the
   chat and jarvis pages, where a list dropping downward would be clipped by any
   short window -- which is most of them, since a transcript grows. Settings
   opens its rows downward, because there the button is at the top of a long
   page and the clipping is the other way round.
*/

struct Listbox: View {
    /// Announced, never drawn: the current value is the visible label.
    var label: String
    var value: String
    var options: [String]
    var disabled: Bool = false
    /// Drop the border and set the closed control in the ink a leader's value
    /// is set in. For a row that is already inside a frame.
    var quiet: Bool = false
    var caps: Bool = false
    var opensUp: Bool = true
    var onPick: (String) -> Void

    @State private var open = false
    @State private var cursor = 0
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var shown: String { caps ? value.uppercased() : value }

    private var ink: Color {
        if disabled { return HT.inkFaint }
        if open || hovering { return HT.inkBright }
        return quiet ? HT.ink : HT.inkMid
    }

    private var border: Color {
        if quiet { return .clear }
        if disabled { return HT.lineFaint }
        return (open || hovering) ? HT.lineBright : HT.line
    }

    var body: some View {
        button
            .overlay(alignment: opensUp ? .bottomLeading : .topLeading) {
                if open {
                    list
                        // Clear of the control by a quarter row, on the side it
                        // opened from.
                        .alignmentGuide(opensUp ? .bottom : .top) { d in
                            opensUp ? d[.top] - HT.s1 : d[.bottom] + HT.s1
                        }
                        .zIndex(20)
                }
            }
    }

    private var button: some View {
        Button(action: { if !disabled { toggle() } }) {
            HStack(spacing: HT.cw) {
                Text(shown).lineLimit(1)
                Text("▼").foregroundStyle(disabled ? HT.inkFaint : HT.inkFaint)
            }
            .font(HT.body)
            .foregroundStyle(ink)
            .padding(.leading, quiet ? 0 : HT.cw2)
            .padding(.trailing, quiet ? 0 : HT.cw)
            .frame(height: quiet ? HT.row : HT.row2)
            .overlay { Rectangle().strokeBorder(border, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focusable(!disabled)
        .focused($focused)
        .onHover { hovering = $0 }
        .disabled(disabled)
        .accessibilityLabel(Text("\(label): \(value)"))
        .onKeyPress(phases: .down) { press in key(press) }
        // Losing the caret closes it. A menu that outlived its own control
        // would be a list floating over a page nothing on screen explains.
        .onChange(of: focused) { _, has in if !has { open = false } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                ListboxRow(
                    text: caps ? option.uppercased() : option,
                    chosen: option == value,
                    under: index == cursor,
                    hover: { cursor = index },
                    pick: {
                        onPick(option)
                        open = false
                        focused = true
                    })
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        // Masked with a bright rule, because it sits over whatever the page was
        // drawing: the surface tints used elsewhere are a few percent of
        // luminance and would let the text behind show through a menu. This is
        // one of the places the ground is painted opaque on purpose.
        .background(HT.groundMask)
        .overlay { Rectangle().strokeBorder(HT.lineBright, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    private func toggle() {
        if open {
            open = false
        } else {
            cursor = Swift.max(0, options.firstIndex(of: value) ?? 0)
            open = true
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        guard open else {
            switch press.key {
            case .return, .space, .upArrow, .downArrow:
                toggle()
                return .handled
            default:
                return .ignored
            }
        }
        switch press.key {
        case .escape:
            open = false
            return .handled
        case .tab:
            open = false
            return .ignored
        case .return, .space:
            if options.indices.contains(cursor) { onPick(options[cursor]) }
            open = false
            return .handled
        case .downArrow:
            if !options.isEmpty { cursor = (cursor + 1) % options.count }
            return .handled
        case .upArrow:
            if !options.isEmpty { cursor = (cursor - 1 + options.count) % options.count }
            return .handled
        case .home:
            cursor = 0
            return .handled
        case .end:
            cursor = Swift.max(0, options.count - 1)
            return .handled
        default:
            return .ignored
        }
    }
}

private struct ListboxRow: View {
    var text: String
    var chosen: Bool
    /// The row under the cursor, keyboard or mouse -- one state for both, so
    /// arrowing and pointing cannot disagree about where you are.
    var under: Bool
    var hover: () -> Void
    var pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: HT.cw) {
                // The mark is a glyph in a reserved column, not a tint: the
                // chosen row has to be findable with the colour thrown away,
                // and a column that is always there means nothing shifts by a
                // cell when the choice moves.
                Text(chosen ? "•" : " ")
                    .frame(width: HT.cw, alignment: .leading)
                Text(text).lineLimit(1)
            }
            .font(HT.body)
            .foregroundStyle(under ? HT.inkBright : HT.ink)
            .padding(.leading, HT.cw)
            .padding(.trailing, HT.cw2)
            .frame(height: HT.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The list's own mask is under this; a row that is not lit adds
            // nothing to it.
            .background(under ? HT.surface3 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { if $0 { hover() } }
        .accessibilityLabel(Text(text))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}
