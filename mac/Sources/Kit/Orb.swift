import AppKit
import SwiftUI

/* ── OrbView ───────────────────────────────────────────────────────────
        .;',wiog
      :;',wiogOLX
     ;',wiogOLXHWY
      ',wiogOLXHW
        ,wiogO

   Presence for an assistant, drawn on the character grid.

   The same orthographic sphere `GlobeView` renders, with a field instead of a
   map: three sinusoids and a noise term, sampled per cell and quantised to a
   ramp of letterforms. One flat colour throughout, so it survives being printed
   1-bit, and stepped at 8 to 12 frames rather than animated, because a terminal
   advances in increments.

   **It is not a status indicator.** It says something is there and roughly how
   hard it is working; it cannot say *what*, it stops dead under Reduce Motion,
   and it is hidden from assistive tech. Whatever it reports has to be a word on
   the page as well -- which is what `presence.word` is for on the Jarvis page.

   `activity` is a number rather than a state on purpose: a design system
   component has no business knowing what "queued" means. The caller maps its
   own states onto 0…1 and this file has no opinion about them.
*/

struct OrbView: View {
    /// Width in character cells. The height follows from the cell's own aspect,
    /// so the disc comes out round.
    var cols: Int = 14
    /// How agitated the surface is, 0 to 1.
    var activity: Double = 0
    var spin: Bool = true
    /// Seconds per full revolution at `activity: 0`. Higher activity turns it
    /// faster on its own, so this is the floor rather than the rate.
    var period: Double = 24
    /// One flat colour. Passed rather than derived from a tone: on the Jarvis
    /// page the orb is gold because it is Jarvis, not because anything is wrong,
    /// and the health vocabulary has no word for that.
    var ink: Color = HT.ink
    var label: String = "Assistant presence"

    @State private var phase: Double = 0
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Whether this window is on a screen at all. See `GlobeView` for why this
    /// is read from the environment rather than handed down.
    @Environment(\.consoleVisible) private var visible

    private var k: Double { Swift.min(1, Swift.max(0, activity)) }
    /// **An orb nobody can see does not turn.** Presence is something said to
    /// somebody looking; with the window off screen it is just arithmetic. The
    /// phase is kept, so the surface picks up where it left off.
    private var turning: Bool { spin && !reduceMotion && visible }

    /// The cell is 7x11 at the body size -- the em box, not the 16px layout row,
    /// because the art is set at `line-height: 1`. Computing it off 16 gives an
    /// egg.
    private var rows: Int { Swift.max(1, Int(((Double(cols) * 7) / 11).rounded())) }

    private var frame: [String] {
        OrbArt.render(cols: cols, rows: rows, phase: turning ? phase : 0, k: k)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(frame.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .font(HT.body)
                    .kerning(0)
                    .tracking(0)
                    .foregroundStyle(ink)
                    .fixedSize()
                    // The em box, not the cell's 16px row: any leading at all
                    // opens hairlines between the rows and the sphere comes
                    // apart into stripes.
                    .frame(width: CGFloat(cols) * HT.cw, height: 11, alignment: .leading)
            }
        }
        .fixedSize()
        // Stepped on its own clock rather than on a shared 8fps timer, because
        // the rate is part of the reading: faster when busier, and the frame
        // rate moves with the step, since a large step at a low rate reads as
        // stuttering rather than as speed.
        .task(id: "\(turning)/\(k)") {
            guard turning else { return }
            let fps = 8 + Int((k * 4).rounded())
            let step = (Double.pi * 2) / (period * Double(fps)) * (1 + k * 5)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0 / Double(fps)))
                if Task.isCancelled { return }
                phase = (phase + step).truncatingRemainder(dividingBy: .pi * 2)
            }
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

/// One frame of the orb, as rows of text. Pure, so the view above holds no
/// state but an angle.
enum OrbArt {

    /// The same density ramp `GlobeArt` draws Earth with, and deliberately the
    /// same one: the fine, uneven texture comes from the ramp being built of
    /// letterforms of differing weight rather than of the even block glyphs the
    /// rest of this system uses. An orb rendered in blocks reads as a chart.
    static let palette = Array(" .:;',wiogOLXHWYV@")

    /// Earth's tilt, kept for no astronomical reason at all: it is what stops
    /// the interference pattern reading as a flat spinning disc, because the
    /// bands cross the silhouette at an angle instead of running straight
    /// across it.
    private static let tilt = 23.4 * Double.pi / 180

    /// Sub-samples per cell, per axis. Two, where the globe uses six: that one
    /// samples a land mask whose coastlines crawl between cells, and this
    /// samples a smooth analytic field with no such detail to alias against.
    private static let ss = 2

    /// Below this much of a cell inside the disc, draw nothing. The limb
    /// otherwise paints stray characters through a sliver of a cell and the
    /// sphere grows a fringe.
    private static let edge = 0.35

    /// Cheap deterministic value noise.
    ///
    /// **No random anywhere in the draw path.** The same phase has to give the
    /// same frame, or the surface boils in place instead of turning.
    private static func hash3(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let n = sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453
        return n - n.rounded(.down)
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = x.rounded(.down)
        let yi = y.rounded(.down)
        let zi = z.rounded(.down)
        let xf = smooth(x - xi)
        let yf = smooth(y - yi)
        let zf = smooth(z - zi)
        var v = 0.0
        for i in 0..<8 {
            let dx = Double(i & 1)
            let dy = Double((i >> 1) & 1)
            let dz = Double((i >> 2) & 1)
            let w = (dx > 0 ? xf : 1 - xf) * (dy > 0 ? yf : 1 - yf) * (dz > 0 ? zf : 1 - zf)
            v += w * hash3(xi + dx, yi + dy, zi + dz)
        }
        return v
    }

    /// The surface. Three sinusoids crossing the sphere, plus a noise term that
    /// only really arrives with activity: the globe samples geography at this
    /// point and gets continents, and this evaluates a field and gets weather.
    private static func surface(_ x: Double, _ y: Double, _ z: Double,
                                _ t: Double, _ k: Double) -> Double {
        let a = sin(x * 6 + t * 1.7)
        let b = sin(y * 5 - t * 1.1)
        let c = sin((x + z) * 4 + t * 0.9)
        let n = noise(x * 2.2 + t * 0.35, y * 2.2, z * 2.2 - t * 0.2)
        return 0.5 + 0.5 * ((a + b + c) / 3) * (0.45 + k * 0.75) + (n - 0.5) * k * 0.9
    }

    static func render(cols: Int, rows: Int, phase: Double, k: Double) -> [String] {
        let cosL = cos(phase)
        let sinL = sin(phase)
        let cosT = cos(tilt)
        let sinT = sin(tilt)
        var out: [String] = []
        out.reserveCapacity(rows)

        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                var inside = 0
                var acc = 0.0

                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let x = ((Double(c) + (Double(sx) + 0.5) / Double(ss))
                                 / Double(cols)) * 2 - 1
                        let y = -(((Double(r) + (Double(sy) + 0.5) / Double(ss))
                                   / Double(rows)) * 2 - 1)
                        let d2 = x * x + y * y
                        if d2 > 1 { continue }
                        inside += 1

                        let z = (1 - d2).squareRoot()
                        // Tilt, then spin. Both are rotations of the sample
                        // point rather than of the field, which is why the
                        // silhouette never moves.
                        let ty = y * cosT - z * sinT
                        let tz = y * sinT + z * cosT
                        let rx = x * cosL + tz * sinL
                        let rz = -x * sinL + tz * cosL

                        var v = surface(rx, ty, rz, phase * 1.6, k)
                        // The limb falls off so the sphere ends rather than
                        // being cut out of the page with scissors.
                        v *= 0.35 + 0.65 * pow(z, 0.45)
                        acc += v
                    }
                }

                if Double(inside) / Double(ss * ss) < edge {
                    line.append(" ")
                    continue
                }

                let v = Swift.max(0, Swift.min(1, acc / Double(inside)))
                let idx = Int((v * Double(palette.count)).rounded(.down))
                line.append(palette[Swift.min(palette.count - 1, Swift.max(0, idx))])
            }
            out.append(line)
        }
        return out
    }
}
