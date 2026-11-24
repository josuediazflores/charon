import SwiftUI

/* The console's tokens, and the two primitives every component in this folder
 * is built out of -- ported from the design system's token sheet.
 *
 * This is the tty dialect. `M` in Theme.swift is the mail dialect and the two
 * are deliberately separate namespaces: mail rounds its corners, tints its
 * avatars and transitions its hovers, and none of that is allowed out here.
 * Every value below is one of the design system's own custom properties under
 * the name the CSS gives it, so a token that moves there moves in one place
 * here.
 *
 * THE CELL. Departure Mono's advance is exactly 7/11 of its size, so it lands
 * on whole pixels only at multiples of 11. Every type size in this system is
 * 11, 22, 33 or 44 and the cell is 7x16. That is why the two primitives at the
 * bottom of this file exist: a run of characters has to be counted in cells,
 * from the width actually available, and recounted when that width changes --
 * a background pattern of dots would drift off the grid the type sits on the
 * first time a panel was resized by a pixel.
 */

enum HT {

    // MARK: - the cell

    static let cw: CGFloat = 7
    static let row: CGFloat = 16
    static let cw2: CGFloat = 14
    static let cw3: CGFloat = 21
    static let cw4: CGFloat = 28
    static let row2: CGFloat = 32
    static let row3: CGFloat = 48

    static let s1: CGFloat = 4
    static let s2: CGFloat = 7
    static let s3: CGFloat = 14
    static let s4: CGFloat = 16
    static let s5: CGFloat = 21
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48

    // MARK: - ANSI 16
    // A real terminal palette. 0-7 base, 8-15 bright.

    static let c0 = Color(hex: 0x1c1c1c)
    static let c1 = Color(hex: 0xcc4436)
    static let c2 = Color(hex: 0x56a34b)
    static let c3 = Color(hex: 0xc9a227)
    static let c4 = Color(hex: 0x3f7fc4)
    static let c5 = Color(hex: 0x9a5fc4)
    static let c6 = Color(hex: 0x35a3a3)
    static let c7 = Color(hex: 0xa8a8a8)
    static let c8 = Color(hex: 0x4a4a4a)
    static let c9 = Color(hex: 0xff5f4f)
    static let c10 = Color(hex: 0x7ee07e)
    static let c11 = Color(hex: 0xffcc55)
    static let c12 = Color(hex: 0x6fb0ff)
    static let c13 = Color(hex: 0xc79fef)
    static let c14 = Color(hex: 0x5fdede)
    static let c15 = Color(hex: 0xffffff)

    /// The swatch rows a fetch tool prints: base on top, bright underneath.
    static let ansiBase: [Color] = [c0, c1, c2, c3, c4, c5, c6, c7]
    static let ansiBright: [Color] = [c8, c9, c10, c11, c12, c13, c14, c15]

    // MARK: - ground
    //
    // The selected ground over a blur of whatever is behind the window. `void` is
    // the colour; the window's own backdrop is the only thing that paints it --
    // once, at the wash the Console settings hold, behind every other view in
    // the app. `groundOpacity` below is where that preference starts. Nothing
    // below that fills the ground a second time: a bar, a rail or a panel that
    // did would stack the wash into an opaque patch on a translucent window,
    // which is why the components in this folder ask for `Color.clear` where
    // they used to ask for the void.
    //
    // **These seven, and the four inks below, are the part of this file that is
    // a preference.** The ground family is chosen in Settings and the whole
    // ramp moves together -- wash, surfaces, rules and ink -- so they read the
    // cache in `Ground.swift` rather than stating a hex. The rest is fixed
    // under every family: the ANSI sixteen and the semantic tones are the
    // vocabulary, and only the paper and what it takes change.

    static var void: Color { Ground.current.void }
    static var surface2: Color { Ground.current.surface2 }
    static var surface3: Color { Ground.current.surface3 }
    static var surface4: Color { Ground.current.surface4 }

    /// Start opaque so the desktop cannot tint the dashboard's default graphite.
    static let groundOpacity: Double = 1

    /// The ground again, opaque, for the few places that paint it in order to
    /// **hide** what is behind them rather than to be a background: a menu over
    /// the page it opened on, a caption over a dither plate, a no-signal plate
    /// over camera static.
    ///
    /// **The line it draws.** An opaque void on a window washed at 0.50 is a
    /// visibly darker patch, so this is only correct where something is
    /// genuinely floating over live content and the patch is the point --
    /// where reading the label matters more than the window being one plane.
    /// A mask that merely sits *on the ground*, with nothing behind it but the
    /// page, is a black box for no return: the panel's notched title cuts real
    /// gaps in its own rule instead, and the table header frosts what passes
    /// under it. Neither one asks for this token any more, and a new caller
    /// that is not floating over content should not either.
    ///
    /// The ground itself, never a second value: a mask that could drift from
    /// what it is masking would show up as a patch the moment it did.
    static var groundMask: Color { Ground.current.void }

    // MARK: - ink
    //
    // **The contrast contract.** Every step of this ramp clears a stated floor
    // against the family it is printed on: ink 7.0:1, inkMid 5.0:1, inkDim
    // 3.8:1, inkFaint 2.3:1. That contract is what makes the ramp part of the
    // ground family rather than a global -- the five voids are not one paper.
    // White measures 17.9:1 on blue gray and 21.0:1 on void black, and once
    // the wash is counted the spread is 12.6:1 to 16.5:1, so a single grey
    // sitting at exactly 3.8:1 on void black arrives at 2.9:1 on blue gray.
    // One ramp for five grounds means four of them are wrong.
    //
    // **Measured against a lightened void, not the real one.** Contrast is a
    // ratio between two opaque colours and this window is not opaque: the wash
    // can sit at 0.50 over somebody's bright desktop, which lifts the effective
    // background and eats the margin. So each ramp was solved against its void
    // blended 88/12 toward white. That buys 28-42% more ratio than the floor
    // asks for whenever the window is actually opaque, and it is why the ink
    // reads at 0.50 rather than only in the screenshot.
    //
    // The ramp order is the other half of the contract: bright > ink > mid >
    // dim > faint, with dim genuinely dimmer than mid. Legible was the goal,
    // not flat -- a ramp whose every step reads the same is a hierarchy nobody
    // can use, and raising `inkFaint` until it matched `inkMid` would have
    // passed the floor and failed the design.
    //
    // (This block used to document the opposite: `inkDim` and `inkFaint`
    // measured 2.02:1 and 1.36:1 and were used as text anyway, because the web
    // reference does. That call is revoked -- the reference's bug is not worth
    // porting, and it was the lighter grounds at a 0.50 wash that proved it.)

    static var ink: Color { Ground.current.ink }
    static let inkBright = c15
    static var inkMid: Color { Ground.current.inkMid }
    static var inkDim: Color { Ground.current.inkDim }
    static var inkFaint: Color { Ground.current.inkFaint }

    // MARK: - rules
    //
    // Part of the ground family: a rule is a step off the surface it separates,
    // so it moves with the surfaces or stops separating them.

    static var lineFaint: Color { Ground.current.lineFaint }
    static var line: Color { Ground.current.line }
    static var lineBright: Color { Ground.current.lineBright }

    // MARK: - semantic

    static let nominal = c10
    static let caution = c11
    static let fault = c9
    /// Stays the ANSI grey it always was, and does **not** follow `inkDim` up
    /// the new ink ramp even though it used to share a value with it. A standby
    /// lamp is a tone in a row of tones -- it is read against nominal, caution
    /// and fault, not as running text -- so it belongs with its four siblings
    /// above, all of which are ANSI constants under every family.
    static let standby = c8
    /// Selection. Cyan says "this one" and nothing else.
    static let signal = c14
    static let signalMid = c6
    static let signalDim = Color(hex: 0x1f5f5f)
    /// The shell prompt is green, because it always is.
    static let prompt = c10
    /// Focus is inverse video; this is the ring for controls that cannot invert.
    static let focus = c12

    // MARK: - type

    static var body: Font { Face.at(11) }
    static var lead: Font { Face.at(22) }
    static var metric: Font { Face.at(33) }
    static var hero: Font { Face.at(44) }

    /// The line box for each of the four sizes.
    static let lineBody: CGFloat = 16
    static let lineLead: CGFloat = 32
    static let lineMetric: CGFloat = 48
    static let lineHero: CGFloat = 64

    // MARK: - motion

    /// The cursor's square wave. One half-period; the block is on for one and
    /// off for the next.
    static let blinkHalf: TimeInterval = 0.530

    // MARK: - breakpoints
    //
    // Measured on the CONTENT box, never on the window. A console pane 700pt
    // wide inside a 1600pt window is a narrow console, and the reference's own
    // media queries are on a container that is the same width as the pane.

    static let bpMd: CGFloat = 1100
    static let bpSm: CGFloat = 720
}

// MARK: - tone

extension Tone {
    /// The colour this tone paints, or nil for "leave the ink alone".
    var ink: Color? {
        switch self {
        case .default: return nil
        case .nominal: return HT.nominal
        case .caution: return HT.caution
        case .fault: return HT.fault
        case .standby: return HT.standby
        case .signal: return HT.signal
        }
    }

    /// The colour with a fallback, for the many places a tone recolours one
    /// span and the default is whatever that span already was.
    func ink(or fallback: Color) -> Color { ink ?? fallback }

    /// Per-tone glyph. Distinct shapes, so the states separate with the colour
    /// thrown away -- which is the whole of rule 5.
    var pillGlyph: String {
        switch self {
        case .default: return "·"
        case .nominal: return "+"
        case .caution: return "!"
        case .fault: return "×"
        case .standby: return "-"
        case .signal: return "›"
        }
    }
}

// MARK: - the character run

/// A run of one glyph, counted in cells from the width actually available.
///
/// The dots in a leader, the ─ in a rule and the ─ under a masthead's name are
/// all this. They are characters, not a repeating background: in a monospace
/// system the glyphs land on the cell grid on their own, and a run made of the
/// same glyph the rest of the line is made of is the difference between a
/// terminal and a stylesheet imitating one.
///
/// The count is `floor(width / 7)` and it is recomputed whenever the width
/// changes, which is what a `GeometryReader` is for and the only thing it is
/// used for here.
struct GlyphRun: View {
    var glyph: String = "."
    var color: Color = HT.inkFaint
    var font: Font = HT.body
    var advance: CGFloat = HT.cw
    var height: CGFloat = HT.row
    /// Ceiling on the count. The masthead's own runs are written in the
    /// reference as a fixed forty dots and a fixed underline, clipped by
    /// overflow -- so they are still counted from the width and simply stop
    /// where the reference stops.
    var limit: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let fit = max(0, Int((geo.size.width / advance).rounded(.down)))
            let n = min(fit, limit ?? fit)
            Text(String(repeating: glyph, count: n))
                .font(font)
                .kerning(0)
                .tracking(0)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - the leader row

/// One row with a single elastic character run in it.
///
/// This is `DotLeader`'s flexbox, spelled out: the fields before the run keep
/// their own width (capped at a fraction of the row), the fields after it keep
/// theirs, and the run takes exactly what is left over. When the row runs out
/// of space the **dots collapse first** -- down to two cells -- and only then
/// does a value start to truncate, which is the post-diff narrow-width
/// behaviour build decision 7 pins.
///
/// Subview order is `[lead…, run, trail…]` with `runIndex` naming the run.
struct RunRow: Layout {
    var spacing: CGFloat = HT.cw
    var runIndex: Int = 1
    var runMin: CGFloat = HT.cw2
    /// Cap on everything before the run, as a fraction of the row. Nil for none.
    var leadFraction: CGFloat? = 0.6

    private struct Plan {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var height: CGFloat
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> Plan {
        let n = subviews.count
        var widths = [CGFloat](repeating: 0, count: n)
        var heights = [CGFloat](repeating: HT.row, count: n)

        for i in 0..<n where i != runIndex {
            let s = subviews[i].sizeThatFits(.unspecified)
            widths[i] = s.width
            heights[i] = s.height
        }

        let gaps = spacing * CGFloat(max(0, n - 1))
        let avail = max(0, width - gaps)

        var lead: CGFloat = 0
        for i in 0..<runIndex { lead += widths[i] }
        if let f = leadFraction, runIndex > 0, lead > width * f {
            // The overflow comes off the last field before the run: that is the
            // one wearing the ellipsis.
            let over = lead - width * f
            widths[runIndex - 1] = max(0, widths[runIndex - 1] - over)
            lead = width * f
        }

        var trail: CGFloat = 0
        if runIndex + 1 < n { for i in (runIndex + 1)..<n { trail += widths[i] } }

        var run = avail - lead - trail
        if run < runMin {
            // Dots before values: take the shortfall off the trailing fields,
            // last one first, and only then off the lead.
            var deficit = runMin - run
            var i = n - 1
            while i > runIndex, deficit > 0 {
                let take = min(widths[i], deficit)
                widths[i] -= take
                trail -= take
                deficit -= take
                i -= 1
            }
            var j = runIndex - 1
            while j >= 0, deficit > 0 {
                let take = min(widths[j], deficit)
                widths[j] -= take
                lead -= take
                deficit -= take
                j -= 1
            }
            run = max(0, avail - lead - trail)
        }
        widths[runIndex] = run

        let tallest = heights.max() ?? HT.row
        return Plan(widths: widths, heights: heights, height: max(HT.row, tallest))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let n = subviews.count
        guard n > 0 else { return .zero }

        guard let w = proposal.width, w > 0, w.isFinite else {
            var total = spacing * CGFloat(n - 1) + runMin
            var h = HT.row
            for i in 0..<n where i != runIndex {
                let s = subviews[i].sizeThatFits(.unspecified)
                total += s.width
                h = max(h, s.height)
            }
            return CGSize(width: total, height: h)
        }
        return CGSize(width: w, height: plan(subviews, width: w).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let p = plan(subviews, width: bounds.width)
        var x = bounds.minX
        for i in 0..<n {
            let w = p.widths[i]
            let h = i == runIndex ? bounds.height : min(p.heights[i], bounds.height)
            subviews[i].place(
                at: CGPoint(x: x, y: bounds.minY + (bounds.height - h) / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: w, height: h))
            x += w + spacing
        }
    }
}

// MARK: - a ceiling on a width

/// CSS `max-width`, which SwiftUI's `frame(maxWidth:)` is not.
///
/// That one takes everything it is offered up to the cap, which is right for a
/// column and wrong for a card: a two-word message would be drawn as a 62-cell
/// block with two words in it. This proposes the cap to the child and reports
/// back whatever the child actually wanted, so a short line is a short card and a
/// long one wraps at the ceiling.
struct MaxWidth: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = Swift.min(proposal.width ?? limit, limit)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: Swift.min(bounds.width, limit),
                                       height: bounds.height))
    }
}

// MARK: - measuring

private struct HTWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HTHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Report this view's own width. The breakpoints in this system are on the
    /// content box, so a component that needs one measures itself rather than
    /// asking anybody about the window.
    func htMeasureWidth(_ sink: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HTWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HTWidthKey.self) { sink($0) }
    }

    /// Report this view's own height.
    ///
    /// For the one shape in this console a CSS `max-height` describes and a
    /// SwiftUI frame does not: a scrollport that is as tall as its contents
    /// until it hits a ceiling. A `ScrollView` answers a height proposal by
    /// taking whatever it is given, so the buffer measures its own contents and
    /// states a definite height rather than leaving the grid above it to guess.
    func htMeasureHeight(_ sink: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HTHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HTHeightKey.self) { sink($0) }
    }

    /// Demote a value the way a stale panel has to. `Demoted` in the reference;
    /// a modifier here, because in SwiftUI it is one colour and not a wrapper.
    @ViewBuilder
    func htDemoted(_ dim: Bool) -> some View {
        if dim { foregroundStyle(HT.inkDim) } else { self }
    }

    /// Shared page margins for the console scroller and standalone chat pages.
    func htConsolePad(narrow: Bool) -> some View {
        padding(.vertical, narrow ? 18 : 26)
            .padding(.horizontal, narrow ? 18 : 32)
    }
}

/// The reference's own wrapper, kept so a port of a panel reads like the panel
/// it was ported from.
struct Demoted<Content: View>: View {
    var dim: Bool
    @ViewBuilder var content: Content
    var body: some View { content.htDemoted(dim) }
}

// MARK: - the checker band

/// Eight pixels of checkerboard, in 4px cells.
///
/// The design system draws it with a conic gradient tiled at 8x8, which puts
/// the top-right and bottom-left quadrant of each tile in ink -- so at this
/// height the band is one row of 4px squares against one row of gaps.
struct CheckerBand: View {
    var color: Color = HT.inkFaint
    var height: CGFloat = 8

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let cell: CGFloat = 4
            let cols = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for r in 0..<max(0, rows) {
                for c in 0..<max(0, cols) where (r + c) % 2 == 1 {
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                    width: cell, height: cell)),
                        with: .color(color))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - is anybody looking

/* Whether this window is on screen at all.
 *
 * **Occlusion, and deliberately nothing else.** The shell already stands the
 * telemetry poll down when the app is merely not frontmost, on the grounds
 * that a console nobody is reading does not need re-reading. The two moving
 * things in this system cannot borrow that rule: a dashboard is a thing you
 * glance at from the app you are actually working in, and a globe that froze
 * whenever Charon lost focus would be a stopped clock exactly where somebody
 * is looking at it. So this is the narrower fact -- the window is minimised,
 * or another window is over it, and there is no picture of it anywhere on any
 * screen -- and nothing that reads it changes what anyone can see.
 *
 * Defaults to true, so a view that finds itself outside the console shell
 * (a preview, a panel lifted into another window) animates rather than sits
 * there dead.
 */
private struct ConsoleVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var consoleVisible: Bool {
        get { self[ConsoleVisibleKey.self] }
        set { self[ConsoleVisibleKey.self] = newValue }
    }
}
