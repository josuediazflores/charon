import AppKit
import SwiftUI

/* ── TagBox ────────────────────────────────────────────────────────────
   $ ask @cmo what the watchlist is tracking
         ┌───┐
         │cmo│
         └───┘

   The box a raised token stands in, stated once for the two surfaces that
   have to draw it the same.

   **The `@` is in the string and not in the box.** A token that registers
   loses its sigil to look at and keeps it everywhere else -- see `sigilKern`
   at the bottom of this file, which is the whole of that trick and the only
   place either surface gets the number from.

   **It is drawn, not attributed.** Neither `NSAttributedString` nor SwiftUI's
   `AttributedString` has a border: a background colour is the only surface
   either text system will paint from an attribute, and a fill with no rule is
   the treatment this replaces. So the composer paints the box in an
   `NSLayoutManager` background pass and the transcript paints it in a
   `TextRenderer`, and this file is the thing that keeps those two from
   drifting -- one inset, one stroke width, one fill, one rule colour, and one
   rule for turning a run of glyphs into the rect around it.

   **The three points come off the box, not out of the string.** The design
   states `padding: 0 3px`, which in a browser opens an inline background
   three pixels either side of the run without moving a glyph. A hair space
   would have moved them, and in a monospace console a glyph pushed off the
   cell grid to make room for a border is the one thing this system does not
   do. So the rect is drawn wider than the run it belongs to, on both
   surfaces, and the text under it sits exactly where it sat before there was
   a box around it.

   **The box is the type's box, not the line's.** The two surfaces set on
   different leading -- 16 points of forced row in the composer, 11 points of
   face over 5 of lead in the transcript -- so a box as tall as the line would
   come out two different heights. Ascent and descent are one height under
   both: 14 points at 11, which is also why a box does not touch the row over
   it.
*/
enum TagBox {

    /// How far the box opens past the glyphs, each side. The design's
    /// `padding: 0 3px`.
    static let inset: CGFloat = 3

    /// One point of rule, which is what every other line in this console is.
    static let stroke: CGFloat = 1

    /// The step off the ground a chip stands on, and the rule that separates
    /// it from that ground. Both out of the ground family rather than stated
    /// as hexes: a box written in blue gray's own numbers would be a patch on
    /// the other four.
    static var fill: Color { HT.surface2 }
    static var line: Color { HT.line }

    /// The box around one fragment of a tag.
    ///
    /// A fragment and not a tag, because a tag that wrapped is two runs of
    /// glyphs in two places and each of them is a box -- neither caller ever
    /// asks this for a rect spanning a line break.
    ///
    /// `descent` is a magnitude, the way Core Text reports it and the opposite
    /// of the sign `NSFont.descender` carries. Y grows downward for both
    /// callers (a text view is flipped and a `GraphicsContext` is y-down), so
    /// this is the same arithmetic `Text.Layout.TypographicBounds.rect` does,
    /// opened by the inset.
    static func around(x: CGFloat, width: CGFloat, baseline: CGFloat,
                       ascent: CGFloat, descent: CGFloat) -> CGRect {
        CGRect(x: x - inset, y: baseline - ascent,
               width: width + inset * 2, height: ascent + descent)
    }

    /// The path a one-point stroke rides so it lands on one row of pixels.
    ///
    /// A stroke is centred on its path, so a rule drawn on the box's own edge
    /// straddles it and comes out two device pixels of half-ink at 1x. Half a
    /// point in is the whole of the fix, and it is the same half point in both
    /// drawing systems.
    static func rule(_ box: CGRect) -> CGRect {
        box.insetBy(dx: stroke / 2, dy: stroke / 2)
    }

    // MARK: - the hidden sigil

    /// What a registered tag's `@` is kerned by: minus its own advance.
    ///
    /// **Display only. The string never changes.** `@cmo` is what was typed,
    /// what is sent, what the record stores, and what a copy off either surface
    /// yields -- the runner's regex still finds its `@` and so does the scan in
    /// `ChatTags`. What changes is that once a token *is* a tag, its sigil is
    /// left out of the glyph pass and given no cell to stand in, so the name
    /// closes over it and the chip reads `cmo`. Nothing here calls
    /// `replaceCharacters` and nothing here is reached by a code path that
    /// could: this is one character's worth of drawing, declined.
    ///
    /// The un-hiding is not a second mechanism. Both surfaces paint from the
    /// string on every change, and a token that has stopped matching -- `@cmoj`
    /// on the next keystroke -- is simply not in the scan's answer any more, so
    /// it is painted as the plain text it is.
    ///
    /// **Measured off the face, never written as 7.** The cell is 7 because
    /// Departure Mono's advance is 7/11 of its size and this console is set at
    /// 11. A literal here would be a second statement of that fact, and the
    /// fallback to Menlo would falsify it on the first Mac the bundled font
    /// failed to register on.
    static func sigilKern(in font: NSFont) -> CGFloat { -advance(of: "@", in: font) }

    /// The body face's answer. For the transcript, which builds a SwiftUI `Text`
    /// and so has no `NSFont` of its own to ask -- 11 is the size a tag is set
    /// in on both surfaces, and `HT.body` is the same face at the same size.
    static var sigilKern: CGFloat { sigilKern(in: Face.ns(11)) }

    /// One character's advance in one face, straight off Core Text: the number
    /// the typesetter will lay the glyph out on, rather than one measured
    /// through a layout that would have to be built to ask.
    private static func advance(of ch: UnicodeScalar, in font: NSFont) -> CGFloat {
        var chars: [UniChar] = [UniChar(ch.value)]
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        let ct = font as CTFont
        guard CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, 1) else { return 0 }
        var advances = [CGSize.zero]
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyphs, &advances, 1)
        return advances[0].width
    }
}

// MARK: - the transcript's half

/// The mark a run of text carries to say it is a tag.
///
/// A `TextAttribute` and not an `AttributedString` key, because those are two
/// unrelated systems: `Text.Layout.Run` can only be asked about the first, and
/// the only way to put one on is `Text.customAttribute` -- which is why
/// `ChatTags.attributed` builds a `Text` by concatenation instead of returning
/// an attributed string.
///
/// Empty on purpose. There is one treatment and a run either wears it or does
/// not; a payload here would be a second thing that could disagree with
/// `TagBox`.
struct TagRun: TextAttribute {}

/// The mark on the one run inside a tag that is in the string and not on the
/// screen: the `@` of a token that registered.
///
/// It wears `TagRun` as well, because the box is the *tag's* geometry and this
/// is part of the tag -- see `TagBoxRenderer.boxes(in:)`. This second mark is
/// what says the difference between "in the chip" and "drawn".
///
/// **Why the clear ink on that run is not enough by itself.** Selected text is
/// drawn in the selection's own colour, which replaces the foreground the run
/// asked for -- so a `@` left in the glyph pass comes back the instant somebody
/// drags across the line, and, having no advance, comes back on top of the `c`
/// it is standing behind. The composer has the same problem in AppKit's words
/// and answers it the same way; see `htHiddenSigil` in PromptBox.swift.
struct HiddenSigil: TextAttribute {}

/// The transcript's painter: the box behind every run marked `TagRun`, then
/// every run.
///
/// **Two passes and not one.** A box is drawn three points wider than its run,
/// so painting box-then-glyphs run by run would let a tag late in a line lay
/// its fill over the tail of the glyph before it. Every box first, then every
/// glyph, and the overhang can only ever land on ground.
///
/// Wrapping is free here and that is the reason this is a `TextRenderer` at
/// all: `Text.Layout` is lines of runs, so a tag broken across a wrap arrives
/// on both lines and each side gets its own box, with no arithmetic about where
/// the break was.
struct TagBoxRenderer: TextRenderer {

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for box in TagBoxRenderer.boxes(in: line) {
                ctx.fill(Path(box), with: .color(TagBox.fill))
                ctx.stroke(Path(TagBox.rule(box)), with: .color(TagBox.line),
                           lineWidth: TagBox.stroke)
            }
        }
        for line in layout {
            // Every run but the hidden sigil, whose whole job is to hold a cell
            // open in the string and none on the screen. Skipped rather than
            // drawn in clear, because a selected run is not drawn in the colour
            // it asked for -- see `HiddenSigil`.
            for run in line where run[HiddenSigil.self] == nil { ctx.draw(run) }
        }
    }

    /// The boxes one line wants: one per unbroken span of runs marked `TagRun`.
    ///
    /// **A span and not a run, because a tag is more than one of them now.** Its
    /// `@` is its own run -- clear ink, minus its own advance -- so that the
    /// chip can read `cmo` while the string still says `@cmo`. That run is a
    /// six-point sliver sitting at the same origin as the name's box, so the
    /// union of the two *is* the name's box; boxing them one at a time would
    /// instead stroke a rule down the inside of the chip. The mark stays on the
    /// whole tag rather than on the name alone so that the geometry is the
    /// tag's, not a guess about which of its runs is the visible one.
    ///
    /// A span cannot run past the end of one tag: two tags can only ever be
    /// adjacent with something between them -- an `@` right after a word
    /// character is not a tag at all -- and anything between them is a run
    /// carrying no mark, which closes the span.
    private static func boxes(in line: Text.Layout.Line) -> [CGRect] {
        var out: [CGRect] = []
        var open: CGRect?
        for run in line {
            guard run[TagRun.self] != nil else {
                if let box = open { out.append(box) }
                open = nil
                continue
            }
            let bounds = run.typographicBounds
            let box = TagBox.around(x: bounds.origin.x, width: bounds.width,
                                    baseline: bounds.origin.y,
                                    ascent: bounds.ascent, descent: bounds.descent)
            open = open?.union(box) ?? box
        }
        if let box = open { out.append(box) }
        return out
    }
}
