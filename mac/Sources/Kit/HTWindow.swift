import SwiftUI

/* ── TitleBar / HTWindow ───────────────────────────────────────────────
   ┌ ASK.EXE ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ [_][□][×] ┐
   │ $ why did trundleworks rank first?          │
   └─────────────────────────────────────────────┘

   Window chrome. Frame something in it when it should read as a discrete
   running process rather than as a panel in a dashboard.

   **A box with nowhere to go is drawn, disabled.** Not hidden: which of the
   three controls is wired is a fact about where this window is -- on the CMO
   tab it has somewhere to grow into, on its own page it has somewhere to close
   to, and never both -- and a control that quietly vanished would make those
   two places look like two different windows.

   Named `HTWindow` because `Window` is SwiftUI's own scene type.
*/

struct TitleBar: View {
    /// Process name. Conventionally uppercase with an extension: `ASK.EXE`.
    var name: String
    /// The hatched drag handle between the name and the controls.
    var grip: Bool = true
    /// Absent leaves the box drawn and disabled.
    var onMinimize: (() -> Void)? = nil
    var onMaximize: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: HT.cw) {
            Text(name.uppercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize()

            if grip { WindowGrip() } else { Spacer(minLength: HT.cw2) }

            HStack(spacing: 2) {
                TitleBox(glyph: "_", label: "Minimize \(name)", action: onMinimize)
                TitleBox(glyph: "□", label: "Maximize \(name)", action: onMaximize)
                TitleBox(glyph: "×", label: "Close \(name)", close: true, action: onClose)
            }
            .fixedSize()
        }
        .padding(.leading, HT.cw)
        .padding(.trailing, HT.s1)
        .frame(height: HT.row2)
        .background(Color.clear)
        .overlay { Rectangle().strokeBorder(HT.inkDim, lineWidth: 1) }
    }
}

/// The hatching that fills the dead space in the bar. Drawn rather than typed:
/// a run of box glyphs would sit on the type baseline, and this is a texture on
/// the bar rather than a word in it.
private struct WindowGrip: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                         with: .color(HT.lineBright))
                y += 3
            }
        }
        .frame(height: 7)
        .frame(minWidth: HT.cw2, maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private struct TitleBox: View {
    var glyph: String
    var label: String
    /// Closing is the one of the three that hovers fault.
    var close: Bool = false
    var action: (() -> Void)?

    @State private var hovering = false

    private var enabled: Bool { action != nil }
    private var hot: Bool { hovering && enabled }

    private var ink: Color {
        if !enabled { return HT.inkFaint }
        return hot ? HT.void : HT.inkMid
    }

    private var fill: Color {
        guard hot else { return .clear }
        return close ? HT.fault : HT.inkBright
    }

    private var border: Color {
        if !enabled { return HT.line }
        if hot { return close ? HT.fault : HT.inkBright }
        return HT.inkDim
    }

    var body: some View {
        Button(action: { action?() }) {
            Text(glyph)
                .font(HT.body)
                .foregroundStyle(ink)
                .frame(width: HT.cw2, height: HT.cw2)
                .background(fill)
                .overlay { Rectangle().strokeBorder(border, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

/// A TitleBar with a framed body attached.
struct HTWindow<Content: View>: View {
    var name: String
    var grip: Bool = true
    var onMinimize: (() -> Void)? = nil
    var onMaximize: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// Remove body padding, for buffers and tables that self-inset.
    var flush: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(name: name, grip: grip,
                     onMinimize: onMinimize, onMaximize: onMaximize, onClose: onClose)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, flush ? 0 : HT.cw2)
                .padding(.vertical, flush ? 0 : HT.s2)
                .overlay {
                    // The frame with no top edge: the title bar's own bottom
                    // rule is the one between them, and two rules there would
                    // be two pixels where the design has one.
                    WindowBodyFrame().stroke(HT.inkDim, lineWidth: 1)
                }
        }
        .background(Color.clear)
    }
}

private struct WindowBodyFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
