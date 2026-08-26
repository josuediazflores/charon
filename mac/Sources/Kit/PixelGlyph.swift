import SwiftUI

/* ── PixelGlyph ────────────────────────────────────────────────────────
   ..#####..
   .#.....#.     A 7x7 bitmap drawn as 1pt squares, on the same cell the
   .#.###.#.     type sits on: 7 wide, 16 tall, one glyph per cell.
   .#.....#.
   ..#####..

   **Why this file exists.** The rail, the lamps and half a dozen buttons were
   set in characters Departure Mono does not have -- ◉ ⏻ ▤ ✉ ⧉ ◧ ⟳ ▸ ▾ ▴ ● ○ --
   so every one of them fell back to a system face: a different weight, drawn
   off the pixel grid, beside eleven-pixel bitmap type. The web reference has
   the same documented bug and the port kept it on parity grounds. Parity is
   not worth a smeared glyph in a rail of sharp ones, so the shapes are drawn
   here instead, at the resolution the face is drawn at.

   These are bitmaps, not icons. Integer coordinates only, one point per pixel,
   no strokes and no curves -- which is what makes them crisp at 2x and what
   keeps them in the same visual family as the characters beside them. A shape
   that cannot be said in forty-nine pixels does not belong in this rail.

   **Where it sits in the row.** The bitmap's top-left corner is (0, 4) in a
   16pt row: eleven-pixel Departure Mono puts its baseline at about y=11.5 and
   its caps run from roughly y=4, so a seven-tall glyph from y=4 to y=11 stands
   on the same band as the label beside it rather than floating over it.

   Decorative by construction: the thing a pixel glyph marks is always named in
   words somewhere in the same row, so the glyph itself is hidden from
   VoiceOver and the row carries the label.
*/

/// The bitmaps this console has. Adding one means adding seven strings below
/// and nothing else.
enum PixelGlyphName: String, CaseIterable {
    case overview, hardware, cmo, mail, messages, brand, refresh
    case caretRight, caretDown, caretUp
    case dot, ring
}

struct PixelGlyph: View {
    var name: PixelGlyphName
    var color: Color = HT.inkMid

    /// Where the 7x7 block starts inside the 16pt row. See the note above.
    private static let top: CGFloat = 4

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            let rows = PixelGlyph.bitmap(name)
            for (y, row) in rows.enumerated() {
                for (x, bit) in row.enumerated() where bit == "#" {
                    ctx.fill(
                        Path(CGRect(x: CGFloat(x), y: PixelGlyph.top + CGFloat(y),
                                    width: 1, height: 1)),
                        with: .color(color))
                }
            }
        }
        .frame(width: HT.cw, height: HT.row)
        .accessibilityHidden(true)
    }

    /// Seven rows of seven, '#' lit and '.' off. Written out rather than packed
    /// into bit masks so the shape is legible in the source it is drawn from --
    /// which is the only way a bitmap this small gets edited without a grid.
    static func bitmap(_ name: PixelGlyphName) -> [[Character]] {
        Array(art(name).map(Array.init))
    }

    private static func art(_ name: PixelGlyphName) -> [String] {
        switch name {

        // ◉ -- a ring with a filled core. Overview is everything at once.
        case .overview:
            return [".#####.",
                    "#.....#",
                    "#.###.#",
                    "#.###.#",
                    "#.###.#",
                    "#.....#",
                    ".#####."]

        // ⏻ -- the power mark, for the tab that reads the machines.
        case .hardware:
            return ["...#...",
                    ".#.#.#.",
                    "#..#..#",
                    "#..#..#",
                    "#.....#",
                    ".#...#.",
                    "..###.."]

        // ▤ -- a ruled document.
        case .cmo:
            return ["#######",
                    "#.....#",
                    "#######",
                    "#.....#",
                    "#######",
                    "#.....#",
                    "#######"]

        // ✉ -- an envelope, flap down.
        case .mail:
            return ["#######",
                    "##...##",
                    "#.#.#.#",
                    "#..#..#",
                    "#.....#",
                    "#.....#",
                    "#######"]

        // ⧉ -- two overlapping boxes, which is what the canvas's two-bubble
        // icon says at this size.
        case .messages:
            return ["#####..",
                    "#...#..",
                    "#.#####",
                    "#.#.#.#",
                    "#####.#",
                    "..#...#",
                    "..#####"]

        // ◧ -- the brand mark: a square half filled.
        case .brand:
            return ["#######",
                    "####..#",
                    "####..#",
                    "####..#",
                    "####..#",
                    "####..#",
                    "#######"]

        // ⟳ -- a circular arrow, open at the top right with a head on it.
        case .refresh:
            return ["..###.#",
                    ".#...##",
                    "#....##",
                    "#......",
                    "#......",
                    ".#...#.",
                    "..###.."]

        // ▸ ▾ ▴ -- disclosure and sort direction.
        case .caretRight:
            return [".......",
                    ".#.....",
                    ".##....",
                    ".###...",
                    ".##....",
                    ".#.....",
                    "......."]

        case .caretDown:
            return [".......",
                    ".......",
                    "#####..",
                    ".###...",
                    "..#....",
                    ".......",
                    "......."]

        case .caretUp:
            return [".......",
                    ".......",
                    "..#....",
                    ".###...",
                    "#####..",
                    ".......",
                    "......."]

        // ● ○ -- the lamp's pips and the unseen mark.
        case .dot:
            return [".......",
                    "..###..",
                    ".#####.",
                    ".#####.",
                    ".#####.",
                    "..###..",
                    "......."]

        case .ring:
            return [".......",
                    "..###..",
                    ".#...#.",
                    ".#...#.",
                    ".#...#.",
                    "..###..",
                    "......."]
        }
    }
}
