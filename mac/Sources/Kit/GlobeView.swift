import SwiftUI
import AppKit

/* ── GlobeView ─────────────────────────────────────────────────────────
   An ASCII Earth for the identity slot of a Masthead.

   Orthographic, tilted 23.4°, drawn in a density ramp of letterforms and in
   **one flat colour**: land and sea separate by the weight of the characters
   themselves -- '@' against '.' -- so the globe still reads with the colour
   thrown away.

   It advances eight times a second, not sixty. A terminal globe should turn in
   visible increments, and this sits in a masthead on an always-on dashboard,
   so the cheap version is also the correct-looking one. It stops dead under
   Reduce Motion, which is one of exactly two things that move in this console.
*/

struct GlobeView: View {
    /// Width in character cells. The height follows from the cell's own aspect,
    /// so the disc comes out round.
    var cols: Int = 27
    /// Degrees of longitude at the centre. Used as the frozen position too.
    var longitude: Double = 0
    var spin: Bool = true
    /// Seconds per full revolution.
    var period: Double = 60
    /// Light it, fading the night side out. Off by default, as in the
    /// reference: at seventeen rows the terminator is a horizontal band across
    /// the disc and the bottom third goes empty.
    var shade: Bool = false
    var tone: Tone = .default
    var label: String = "Rotating globe"

    @State private var lon: Double = 0
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Whether this window is on a screen at all. Read from the environment
    /// rather than plumbed down: the art slot reaches `Masthead` as an opaque
    /// `AnyView`, and threading a flag through that seam would put a
    /// performance concern in four files that are pure composition.
    @Environment(\.consoleVisible) private var visible

    /// The cell is 7x11 at the body size; this is what makes the disc round.
    private var rows: Int { Swift.max(1, Int(((Double(cols) * 7) / 11).rounded())) }

    /// **A globe nobody can see does not turn.** Every step rebuilds the frame
    /// from scratch and then asks the console's grid to lay itself out around
    /// it, which is the difference between a minimised dashboard costing a
    /// fifth of a core and costing nothing. The angle is kept rather than
    /// reset, so coming back resumes instead of snapping to zero.
    private var turning: Bool { spin && !reduceMotion && visible }

    private var frame: [String] {
        GlobeArt.render(cols: cols, rows: rows, lonDeg: turning ? lon : longitude, shade: shade)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(frame.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .font(HT.body)
                    .kerning(0)
                    .tracking(0)
                    .foregroundStyle(tone.ink ?? HT.ink)
                    .fixedSize()
                    // The em box, not the cell's 16px row: any leading at all
                    // opens hairlines between the rows and the sphere comes
                    // apart into stripes.
                    .frame(width: CGFloat(cols) * HT.cw, height: 11, alignment: .leading)
            }
        }
        .fixedSize()
        .onAppear { lon = longitude }
        .onReceive(
            Timer.publish(every: 1.0 / 8.0, on: .main, in: .common).autoconnect()
        ) { _ in
            guard turning else { return }
            lon = (lon + 360 / (period * 8)).truncatingRemainder(dividingBy: 360)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

/// One frame of the globe, as rows of text. Pure, so the view above holds no
/// state but an angle.
enum GlobeArt {

    /// Density ramp, sparsest first.
    ///
    /// This is the character vocabulary adamsky/globe renders Earth with, and
    /// it is what makes the result look like that globe rather than a generic
    /// shaded ball: the fine, uneven texture comes from the ramp being built of
    /// letterforms of differing weight, not of the even block glyphs the rest
    /// of this system uses.
    static let palette = Array(" .:;',wiogOLXHWYV@")

    /// Where sea and land sit on the ramp in full daylight...
    private static let daySea = 1
    private static var dayLand: Int { palette.count - 1 }
    /// ...and on the night side. Land stays faintly drawn, so the dark limb
    /// still shows a coastline rather than going empty.
    private static let nightSea = 0
    private static let nightLand = 2

    /// Earth's axial tilt, so this reads as a sphere seen slightly from above
    /// rather than as a spinning circle.
    private static let tilt = 23.4 * Double.pi / 180

    /// Sub-samples per cell, per axis. A character cell covers several degrees,
    /// so sampling once lets one texture pixel decide a whole cell and makes
    /// coastlines crawl as it turns. Averaging gives each cell a land
    /// *fraction*, which lands between the sea and land ramp positions -- that
    /// is where the intermediate characters come from.
    private static let ss = 6

    /// Below this much of a cell inside the disc, draw nothing. The limb
    /// otherwise paints stray continents through a sliver of a cell.
    private static let edge = 0.3

    static func render(cols: Int, rows: Int, lonDeg: Double, shade: Bool) -> [String] {
        let lon0 = lonDeg * Double.pi / 180
        // The tilt is a file-scope constant, so its sine and cosine are two
        // numbers -- not four transcendental calls per sub-sample, which at
        // 27 columns is sixty-six thousand of them per frame. `OrbArt.render`
        // has always hoisted exactly these two; this is that, here.
        let cosTilt = cos(-tilt)
        let sinTilt = sin(-tilt)
        var out: [String] = []
        out.reserveCapacity(rows)

        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                var inside = 0
                var lum = 0.0
                var land = 0

                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let x = ((Double(c) + (Double(sx) + 0.5) / Double(ss)) / Double(cols)) * 2 - 1
                        let y = -(((Double(r) + (Double(sy) + 0.5) / Double(ss)) / Double(rows)) * 2 - 1)

                        let d2 = x * x + y * y
                        if d2 > 1 { continue }
                        inside += 1

                        let z = (1 - d2).squareRoot()

                        // Light straight overhead, as in the reference. The x5
                        // is what makes the terminator hard: most of the lit
                        // face saturates and the whole gradient is squeezed
                        // into a narrow band.
                        lum += Swift.max(0, Swift.min(1, 5 * y + 0.5))

                        let yt = y * cosTilt - z * sinTilt
                        let zt = y * sinTilt + z * cosTilt
                        let lat = asin(Swift.max(-1, Swift.min(1, yt)))
                        let lon = atan2(x, zt) + lon0
                        if LandMask.isLand(lat, lon) { land += 1 }
                    }
                }

                if Double(inside) / Double(ss * ss) < edge {
                    line.append(" ")
                    continue
                }

                let f = Double(land) / Double(inside)
                let day = Double(daySea) + Double(dayLand - daySea) * f
                // Unlit, the texture is drawn as-is. That is the reference's
                // default and the only thing that fills the whole disc at this
                // size.
                var idx = Int(day.rounded())
                if shade {
                    let l = lum / Double(inside)
                    let night = Double(nightSea) + Double(nightLand - nightSea) * f
                    idx = Int(((1 - l) * night + l * day).rounded())
                }
                line.append(palette[Swift.min(palette.count - 1, Swift.max(0, idx))])
            }
            out.append(line)
        }
        return out
    }
}
