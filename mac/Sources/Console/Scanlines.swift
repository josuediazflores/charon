import SwiftUI

/* ── Scanlines ─────────────────────────────────────────────────────────
   The opt-in CRT overlay, ported from the design system's scanline layer:
   a repeating 180° gradient, one pixel of rgba(255,255,255,0.026) every three.

   **On the whole shell, not on a pane.** The rail, the bar and the console are
   all under it, which is what makes it a treatment of the console rather than
   a texture on one page.

   Three points is the cell row's own factor -- sixteen is not divisible by
   three, but the lines are far enough below the type's contrast that they read
   as glass rather than as a beat against it. Off by default: it costs contrast
   the ink ramp has already spent.
*/
struct Scanlines: View {
    /// Points of ink per period, and points of period.
    private let ink: CGFloat = 1
    private let period: CGFloat = 3

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: ink)),
                    with: .color(.white.opacity(0.026)))
                y += period
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
