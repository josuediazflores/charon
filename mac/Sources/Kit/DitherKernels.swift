import Foundation

/* ── Dithering core ────────────────────────────────────────────────────
   Pure functions, no view. Ported line for line from the design system's
   dither kernels, including the arithmetic:
   the noise grid and the luminance buffer are `Float` here because they are
   `Float32Array` there, and a plate rendered in Double would be a *different
   picture* -- one the reference never draws.

   Nothing in this file is random. The seed is fixed, so the same size renders
   the same plate on every machine and on every launch.
*/

/* `glow` is a Mac-side addition and is **not** in the web design system's
   kernels.ts. The other four are ports; this one was written for the chat
   landing, where the pane behind the composer wants a lit field rather than a
   lit object -- a wide lobe above the top edge, gone by the middle of the page,
   with a noise-clumped halo under it and a sparse floor of lone dots the rest
   of the way down. Adding it here rather than in the view keeps every field
   this console dithers in one file; a caller that wants it asks for it by name.
*/
enum DitherPattern { case sphere, ramp, noise, rings, glow }
enum DitherAlgorithm { case atkinson, floydSteinberg, bayer }

enum Dither {

    /// Deterministic PRNG. `Math.imul` is 32-bit wrapping multiply, which is
    /// what `&*` on UInt32 is.
    static func mulberry32(_ seed: UInt32) -> () -> Double {
        var a = seed
        return {
            a = a &+ 0x6d2b_79f5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// Smoothed value noise on an integer lattice. Cheap, seeded, and good
    /// enough to break up a gradient so the dither reads as texture rather
    /// than as concentric banding.
    static func valueNoise(_ seed: UInt32, _ cells: Int) -> (Double, Double) -> Double {
        let rand = mulberry32(seed)
        let size = cells + 1
        var grid = [Float](repeating: 0, count: size * size)
        for i in 0..<grid.count { grid[i] = Float(rand()) }

        func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

        return { x, y in
            let gx = Swift.min(Swift.max(x, 0), 0.999999) * Double(cells)
            let gy = Swift.min(Swift.max(y, 0), 0.999999) * Double(cells)
            let x0 = Int(gx.rounded(.down))
            let y0 = Int(gy.rounded(.down))
            let fx = smooth(gx - Double(x0))
            let fy = smooth(gy - Double(y0))
            let a = Double(grid[y0 * size + x0])
            let b = Double(grid[y0 * size + x0 + 1])
            let c = Double(grid[(y0 + 1) * size + x0])
            let d = Double(grid[(y0 + 1) * size + x0 + 1])
            return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy)
                + c * (1 - fx) * fy + d * fx * fy
        }
    }

    /// Render a generated luminance field into `lum` (0..255, row-major).
    static func paintField(_ lum: inout [Float], _ w: Int, _ h: Int,
                           _ pattern: DitherPattern, _ seed: UInt32) {
        let noise = valueNoise(seed, 8)
        let fine = valueNoise(seed &+ 1013, 24)

        for y in 0..<h {
            for x in 0..<w {
                let u = w == 1 ? 0.5 : Double(x) / Double(w - 1)
                let v = h == 1 ? 0.5 : Double(y) / Double(h - 1)
                var value: Double

                switch pattern {
                case .sphere:
                    // A lit sphere, offset up-left the way the reference orb is.
                    let dx = (u - 0.46) * 2
                    let dy = (v - 0.44) * 2
                    let d = (dx * dx + dy * dy).squareRoot()
                    let core = exp(-pow(d * 1.9, 2.2))
                    let halo = exp(-pow(d * 1.05, 1.5)) * 0.42
                    value = core + halo
                    // Turbulence, strongest in the mid-tones where dithering shows.
                    value += (noise(u, v) - 0.5) * 0.16 * (1 - abs(value - 0.5) * 1.4)
                    value += (fine(u, v) - 0.5) * 0.07
                case .ramp:
                    value = 1 - v
                    value += (fine(u, v) - 0.5) * 0.1
                case .rings:
                    let dx = u - 0.5
                    let dy = v - 0.5
                    let d = (dx * dx + dy * dy).squareRoot()
                    value = 0.5 + 0.5 * cos(d * 46)
                    value *= exp(-pow(d * 2.1, 2))
                    value += (noise(u, v) - 0.5) * 0.12
                case .noise:
                    value = noise(u, v) * 0.7 + fine(u, v) * 0.3
                case .glow:
                    // A wide lobe centred above the top edge and left of the
                    // middle: brightest at the top, gone by the vertical
                    // middle. The ambient is a faint wash along that top edge,
                    // tapering toward the corners.
                    let dx = (u - 0.40) * 1.55
                    let dy = (v + 0.22) * 2.9
                    let d = (dx * dx + dy * dy).squareRoot()
                    let core = exp(-pow(d * 1.75, 2.1))
                    let ambient = Swift.max(0, 1 - v * 3.0) * 0.055
                        * (1 - 0.5 * abs(u - 0.45) * 2)
                    value = core * 0.98 + ambient

                    // A second lobe under the first: far wider, far fainter,
                    // and multiplied by the noise so it clumps instead of
                    // resolving into a lattice.
                    //
                    // **Why it exists.** An ordered dither of a smooth field at
                    // a constant 6% is the same cell of every Bayer tile, which
                    // is graph paper and not a scatter. And without it the core
                    // is gone by v=0.25 -- the prompt would then sit on bare
                    // void under a band of texture rather than inside a glow,
                    // which is the one thing this field is about. Modulating by
                    // the noise breaks both: the field drifts between about 2%
                    // and 14% over the noise cells, so the tiles light in clumps
                    // with gaps between them. Both noise scales, because the
                    // coarse one alone resolves into contour arcs at this
                    // amplitude. Thinned toward the bottom, so only stragglers
                    // reach the floor.
                    let hx = (u - 0.42) * 0.95
                    let hy = (v - 0.05) * 1.30
                    let halo = exp(-pow((hx * hx + hy * hy).squareRoot() * 1.25, 2.0))
                    value += halo * 0.09
                        * (0.25 + 0.8 * noise(u, v) + 0.6 * fine(u, v))
                        * Swift.max(0.12, 1 - v * 1.0)

                    // Lone dots where the coarse noise crests, dying out
                    // downward, and rarer ones at the fine crests the rest of
                    // the way down.
                    value += Swift.max(0, noise(u, v) - 0.68) * 0.09
                        * Swift.max(0, 1 - v * 1.5)
                    value += Swift.max(0, fine(u, v) - 0.84) * 0.34 * (1 - v * 0.55)

                    // Turbulence, strongest in the mid-tones, gated so black
                    // stays black.
                    value += ((noise(u, v) - 0.5) * 0.15 * (1 - abs(value - 0.5) * 1.4)
                        + (fine(u, v) - 0.5) * 0.06) * Swift.min(1, value * 5)
                }

                lum[y * w + x] = Float(Swift.min(255, Swift.max(0, value * 255)))
            }
        }
    }

    /// Atkinson error diffusion, in place.
    ///
    /// The kernel pushes 1/8 of the error to six neighbours and **discards the
    /// remaining 2/8**. Losing that error is what blows highlights out to open
    /// white and crushes shadows to solid black, which is the look the original
    /// Macintosh had and the one this system is named for.
    ///
    ///          *   1/8  1/8
    ///    1/8  1/8  1/8
    ///         1/8
    static func atkinson(_ lum: inout [Float], _ w: Int, _ h: Int, _ threshold: Float = 128) {
        func push(_ x: Int, _ y: Int, _ err: Float, _ buf: inout [Float]) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            buf[y * w + x] += err
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = lum[i]
                let next: Float = old < threshold ? 0 : 255
                lum[i] = next
                let err = (old - next) / 8
                push(x + 1, y, err, &lum)
                push(x + 2, y, err, &lum)
                push(x - 1, y + 1, err, &lum)
                push(x, y + 1, err, &lum)
                push(x + 1, y + 1, err, &lum)
                push(x, y + 2, err, &lum)
            }
        }
    }

    /// Floyd-Steinberg. Retains all the error, so it holds mid-tone detail
    /// Atkinson throws away. For photographic sources.
    static func floydSteinberg(_ lum: inout [Float], _ w: Int, _ h: Int,
                               _ threshold: Float = 128) {
        func push(_ x: Int, _ y: Int, _ err: Float, _ buf: inout [Float]) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            buf[y * w + x] += err
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = lum[i]
                let next: Float = old < threshold ? 0 : 255
                lum[i] = next
                let err = old - next
                push(x + 1, y, err * 7 / 16, &lum)
                push(x - 1, y + 1, err * 3 / 16, &lum)
                push(x, y + 1, err * 5 / 16, &lum)
                push(x + 1, y + 1, err * 1 / 16, &lum)
            }
        }
    }

    /// Ordered 4x4 Bayer. Deterministic and tileable, so it is the only variant
    /// that holds still under motion.
    static func bayer(_ lum: inout [Float], _ w: Int, _ h: Int) {
        let m: [[Float]] = [
            [0, 8, 2, 10],
            [12, 4, 14, 6],
            [3, 11, 1, 9],
            [15, 7, 13, 5],
        ]
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let t = ((m[y & 3][x & 3] + 0.5) / 16) * 255
                lum[i] = lum[i] < t ? 0 : 255
            }
        }
    }

    static func apply(_ lum: inout [Float], _ w: Int, _ h: Int,
                      _ algorithm: DitherAlgorithm, _ threshold: Float) {
        switch algorithm {
        case .bayer: bayer(&lum, w, h)
        case .floydSteinberg: floydSteinberg(&lum, w, h, threshold)
        case .atkinson: atkinson(&lum, w, h, threshold)
        }
    }

    /// Brightness and contrast in luminance space, before the threshold.
    /// Contrast pivots around mid-grey; brightness is an additive shift.
    static func adjust(_ lum: inout [Float], _ brightness: Float, _ contrast: Float) {
        for i in 0..<lum.count {
            lum[i] = (lum[i] - 128) * contrast + 128 + brightness * 255
        }
    }
}
