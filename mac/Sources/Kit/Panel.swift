import SwiftUI

/* ── Panel ─────────────────────────────────────────────────────────────
   A drawn frame with its title notched into the top rule:

     ┌─ SYSTEM ──────────────────────┐
     │ host ................ raspberrypi │
     └───────────────────────────────┘

   The frame is a stroked path rather than literal box-drawing characters,
   because characters cannot survive a fluid width. The notch is what sells it:
   the title sits ON the border line, exactly where `┌─ SYSTEM ─` would put it.
   Half of that row is above the frame, so a titled panel reserves eight points
   of its own box for it -- a component that painted outside its layout box is a
   component the grid above it cannot account for.

   **The rule is cut, not covered.** The head used to paint the ground opaque
   behind each label and sit on top of the line. That reads correctly on an
   opaque window and fails on this one: the ground is a wash over a blur of the
   desktop, so an opaque void at a 0.50 wash is a visibly darker patch -- three
   black boxes floating along the top of every panel. So the top rule is drawn
   with real gaps at the head items instead, and the labels carry no background
   at all. The gaps are measured off the items' own laid-out boxes, which is
   what keeps a title that ellipsises on a narrow panel from leaving a hole
   wider than the word left in it.

   **A `tone` means this block is the thing in trouble.** It is not decoration.
   A healthy panel gets no frame colour: the lamp in `meta` already reports
   health, and a wall of green frames makes a real red one invisible. Nothing
   sets this by hand -- `SourcePanel` derives it from `health()`.
*/

enum PanelVariant {
    /// The single rule. The default.
    case tty
    /// The ═ frame, for a block that outranks its neighbours.
    case double
    /// No frame; the title rule is the only structure.
    case bare
}

struct Panel<Content: View>: View {
    /// Notched into the top rule, uppercased.
    var title: String?
    /// Glyph before the title, on the same rule.
    var icon: String?
    /// The same slot, for a mark Departure Mono does not carry: a bitmap on
    /// the cell rather than a character borrowed from a system face. One or
    /// the other, never both.
    var glyph: PixelGlyphName?
    /// Notched into the right end of the top rule. Ends in the StatusLamp
    /// wherever `SourcePanel` built it.
    var meta: AnyView?
    /// Strip below a bottom rule.
    var footer: AnyView?
    var variant: PanelVariant = .tty
    /// Draw the four corner marks over the frame ends.
    var ticks: Bool = false
    /// Tighten body padding to half a cell.
    var dense: Bool = false
    /// Remove body padding, for tables and plates that self-inset.
    var flush: Bool = false
    var tone: Tone = .default
    /// Cyan frame, the tty selection colour.
    var selected: Bool = false
    @ViewBuilder var content: Content

    private var framed: Bool { variant != .bare }
    private var hasHead: Bool { title != nil || icon != nil || glyph != nil || meta != nil }

    private var bodyPadH: CGFloat {
        if flush || variant == .bare { return 0 }
        return dense ? HT.cw : HT.cw2
    }

    private var bodyPadBottom: CGFloat {
        if flush || variant == .bare { return 0 }
        return dense ? HT.s2 : HT.s3
    }

    /// The extra row a framed panel keeps above its body to clear the notch.
    /// An untitled one has nothing to clear, so it drops back to half a cell.
    ///
    /// A flush body clears the notch too: the head hangs 8px inside the frame,
    /// and the web got away with content under it only because its notch chips
    /// were opaque. Ours are transparent, so a table header starting at 0
    /// would print through the title -- the same word twice, offset by a row.
    private var bodyPadTop: CGFloat {
        if flush || variant == .bare { return framed && hasHead ? HT.s2 * 2 : 0 }
        if !hasHead { return HT.s2 }
        return dense ? HT.s2 : HT.s3
    }

    private var frameInk: Color {
        if let toned = tone.ink { return toned }        // in trouble outranks selected
        if selected { return HT.signal }
        if variant == .double { return HT.lineBright }
        // With corners called out, the frame between them drops back a step.
        return ticks ? HT.lineFaint : HT.line
    }

    private var titleInk: Color {
        tone.ink ?? (selected ? HT.signal : HT.inkBright)
    }

    /// The frame's own ring. A CSS border sits outside the padding box, so
    /// content starts *after* it; a stroked overlay in SwiftUI is drawn inside
    /// the frame and would sit on the first row of a flush body. Inset by the
    /// stroke so the two box models agree.
    private var borderInset: CGFloat {
        switch variant {
        case .tty: return 1
        case .double: return 3
        case .bare: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if variant == .bare, hasHead { bareHead }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, bodyPadH)
                .padding(.top, bodyPadTop)
                .padding(.bottom, bodyPadBottom)

            if let footer {
                Rectangle().fill(HT.line).frame(height: 1)
                footer
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, variant == .bare ? 0 : HT.cw2)
                    .padding(.top, HT.s1)
                    .padding(.bottom, variant == .bare ? 0 : HT.s1)
            }
        }
        .padding(borderInset)
        .background(Color.clear)
        // The head goes down first so the ring can read where it landed. That
        // puts the ring *over* the labels, which is safe precisely because the
        // gaps are cut from those labels' own boxes: there is no line under
        // them left to win a fight with.
        .overlay(alignment: .top) { notch }
        .overlayPreferenceValue(PanelHeadKey.self) { heads in
            GeometryReader { geo in
                ring(gaps: gaps(heads, in: geo))
            }
            .allowsHitTesting(false)
        }
        // The head stops here. Reading a preference does not consume it, and a
        // panel inside another panel's body would otherwise hand its own three
        // boxes to the panel outside it -- which would cut holes in *that*
        // frame's top rule, at the x of a title sitting forty points lower.
        .transformPreference(PanelHeadKey.self) { $0 = [] }
        .overlay { corners }
        // The half-row the notch straddles, reserved inside the panel's box.
        .padding(.top, framed && hasHead ? 8 : 0)
    }

    // MARK: - the frame

    /// Where the top rule stops, in the panel box's own coordinates.
    ///
    /// Resolved here rather than stored: an anchor is a promise about a box,
    /// and cashing it against the panel's geometry at draw time is what makes
    /// the gaps follow a relayout without a `@State` round trip -- which in a
    /// measure-then-draw loop is the difference between tracking a resize and
    /// flickering through one.
    private func gaps(_ heads: [Anchor<CGRect>],
                      in geo: GeometryProxy) -> [ClosedRange<CGFloat>] {
        heads.compactMap { head in
            let box = geo[head]
            guard box.width > 0, box.minX.isFinite, box.maxX.isFinite else { return nil }
            return box.minX...box.maxX
        }
    }

    @ViewBuilder
    private func ring(gaps: [ClosedRange<CGFloat>]) -> some View {
        switch variant {
        case .tty:
            PanelFrame(gaps: gaps).stroke(frameInk, lineWidth: 1)
        case .double:
            // `3px double` is a rule, a gap and a rule, each one pixel. Both
            // rules are inside the sixteen points the head occupies, so both
            // take the same holes.
            ZStack {
                PanelFrame(gaps: gaps).stroke(frameInk, lineWidth: 1)
                PanelFrame(gaps: gaps, inset: 2).stroke(frameInk, lineWidth: 1)
            }
        case .bare:
            EmptyView()
        }
    }

    @ViewBuilder
    private var corners: some View {
        if ticks, framed {
            PanelTicks().stroke(HT.lineBright, lineWidth: 1).allowsHitTesting(false)
        }
    }

    // MARK: - the head

    @ViewBuilder
    private var notch: some View {
        if framed, hasHead {
            // None of the three carries a background. The horizontal padding
            // is no longer a mask's bleed but the clear space the rule leaves
            // on either side of the glyphs -- `┌─ SYSTEM ─┐` -- and it is the
            // padded box, not the text, that each hole is cut from.
            HStack(spacing: HT.cw) {
                if let icon {
                    Text(icon)
                        .font(HT.body)
                        .foregroundStyle(HT.inkMid)
                        .padding(.horizontal, HT.s1)
                        .frame(height: HT.row)
                        .fixedSize()
                        .panelHead()
                }
                if let glyph {
                    PixelGlyph(name: glyph, color: HT.inkMid)
                        .padding(.horizontal, HT.s1)
                        .frame(height: HT.row)
                        .fixedSize()
                        .panelHead()
                }
                if let title {
                    Text(title.uppercased())
                        .font(HT.body)
                        .foregroundStyle(titleInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, HT.s1)
                        .frame(height: HT.row)
                        .panelHead()
                }
                Spacer(minLength: 0)
                if let meta {
                    // Never shrinks. The title is the only head child that
                    // does: the meta is the health readout, and a lamp with
                    // an ellipsis through it reports nothing.
                    meta
                        .font(HT.body)
                        .foregroundStyle(HT.inkDim)
                        .padding(.horizontal, HT.s1)
                        .frame(height: HT.row)
                        .fixedSize()
                        .panelHead()
                }
            }
            .padding(.horizontal, HT.cw)
            .frame(height: HT.row)
            .offset(y: -8)
        }
    }

    private var bareHead: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HT.cw) {
                if let icon {
                    Text(icon).font(HT.body).foregroundStyle(HT.inkMid).fixedSize()
                }
                if let glyph {
                    PixelGlyph(name: glyph, color: HT.inkMid).fixedSize()
                }
                if let title {
                    Text(title.uppercased())
                        .font(HT.body)
                        .foregroundStyle(titleInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if let meta {
                    meta.font(HT.body).foregroundStyle(HT.inkDim).fixedSize()
                }
            }
            .frame(height: HT.row)
            .padding(.bottom, HT.s1)

            Rectangle().fill(HT.line).frame(height: 1)
        }
        .padding(.bottom, HT.row)
    }
}

// MARK: - the head, measured

/// Where the head items landed, as anchors.
///
/// Anchors and not rects: the head is laid out in one overlay and the rule is
/// drawn in another, and the panel's own geometry is the only thing that can
/// put the two in the same coordinate space. A `.bounds` anchor is exactly that
/// deferral -- a box promised now and resolved later against a proxy -- so the
/// gaps are a function of the current layout rather than a copy of the last one.
private struct PanelHeadKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    /// Appended, not merged. Three separate holes, and a reduce that took the
    /// union would join the title to the meta across the whole top rule.
    static func reduce(value: inout [Anchor<CGRect>],
                       nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Report this head item's box as a hole in the panel's top rule.
    func panelHead() -> some View {
        anchorPreference(key: PanelHeadKey.self, value: .bounds) { [$0] }
    }
}

/// The panel's ring, with its top rule interrupted where the head sits.
///
/// A path rather than `strokeBorder`, because the interruption is the whole
/// point: the icon, the title and the meta float in real gaps in the line, the
/// way `┌─ SYSTEM ─┐` puts them there, and a label in a gap needs nothing
/// painted behind it. On a translucent window that is the difference between a
/// notch and a black box.
struct PanelFrame: Shape {
    /// Where the top rule stops and starts again, in this shape's own space.
    /// Empty draws a plain rectangle, which is what an untitled panel wants.
    var gaps: [ClosedRange<CGFloat>] = []
    /// The second ring of the `double` variant, two points in. Stated here
    /// rather than as a `.padding` on the view so both rings are drawn in one
    /// coordinate space and can read one set of gaps.
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Half a point, so a one-point stroke's centre lands on the border
        // pixel -- which is what `strokeBorder` was doing for a shape that
        // fills its frame, and the reason the ring did not move.
        let r = rect.insetBy(dx: inset + 0.5, dy: inset + 0.5)
        guard r.width > 0, r.height > 0 else { return Path() }

        var p = Path()
        // Left, bottom and right in one run. Only the top is ever cut.
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))

        // The top, as whatever is left between the holes. Sorted and carried
        // in one sweep, so overlapping gaps -- a meta that has run into a
        // title on a narrow panel -- merge instead of drawing a sliver of
        // rule between two labels.
        var x = r.minX
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = Swift.min(Swift.max(gap.lowerBound, r.minX), r.maxX)
            let hi = Swift.min(Swift.max(gap.upperBound, r.minX), r.maxX)
            if lo > x {
                p.move(to: CGPoint(x: x, y: r.minY))
                p.addLine(to: CGPoint(x: lo, y: r.minY))
            }
            x = Swift.max(x, hi)
        }
        if x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        return p
    }
}

/// The four corner marks.
///
/// Drawn rather than typed: a box-drawing glyph carries its own background and
/// would punch a hole in the border it is meant to reinforce, and its corner
/// would never land on the same pixel as the frame's.
struct PanelTicks: Shape {
    var arm: CGFloat = HT.cw

    func path(in rect: CGRect) -> Path {
        // The stroke is one pixel wide, so its centre sits on the border pixel.
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let a = min(arm, min(r.width, r.height) / 2)
        var p = Path()

        p.move(to: CGPoint(x: r.minX, y: r.minY + a))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + a, y: r.minY))

        p.move(to: CGPoint(x: r.maxX - a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + a))

        p.move(to: CGPoint(x: r.minX, y: r.maxY - a))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + a, y: r.maxY))

        p.move(to: CGPoint(x: r.maxX - a, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - a))

        return p
    }
}
