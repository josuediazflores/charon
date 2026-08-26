import SwiftUI

/* ── SegSlider ─────────────────────────────────────────────────────────
   [████████░░░░░░░░░░░░] 38%

   SegBar with a hand on it. The same run of block characters against light
   shade, the same cell grid, the same readout in the same place -- the one
   difference is that this one is aimed at as well as read, so the run is the
   control rather than a picture of a number.

   **Twenty cells, not a meter's ten.** A reading only has to be legible; a
   track has to be landed on, and ten cells over a range is a coarse thing to
   point at. The cells are still exactly one character wide, so the track is
   `20 x 7` points and the pointer maps onto it by arithmetic rather than by
   measurement.

   **The track is not the value.** The cells are how the value is drawn, and
   `grain` is how fine it may be -- a click lands on a hundredth and the run
   rounds it to the nearest cell, which is what keeps the number under the
   pointer a whole percent instead of a half of one.

   Focus is the brackets going cyan, the way the command field's rule does, and
   the system's own ring is off: a blue halo around a run of block glyphs is
   the one thing on this page drawn by something other than this design system.
*/

struct SegSlider: View {
    /// Announced, never drawn -- the row this sits in carries the visible name.
    var label: String
    var value: Double
    var range: ClosedRange<Double> = 0...1
    /// Cells in the track. Each is exactly one character wide.
    var segments: Int = 20
    /// One arrow press, in value units.
    var step: Double = 0.05
    /// The finest value a drag or a click may land on, in value units. Zero
    /// leaves the track continuous.
    var grain: Double = 0
    /// Reading after the track. Nil prints the position in the range.
    var readout: String? = nil
    var fill: SegBarFill = .block
    var disabled: Bool = false
    /// Handed the new value, already snapped and clamped, and only when it is
    /// actually a different one.
    var onChange: (Double) -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    private var span: Double {
        Swift.max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
    }

    private var ratio: Double {
        Swift.min(1, Swift.max(0, (value - range.lowerBound) / span))
    }

    private var lit: Int { Int((ratio * Double(segments)).rounded()) }
    private var trackWidth: CGFloat { CGFloat(segments) * HT.cw }
    private var reading: String { readout ?? "\(Int((ratio * 100).rounded()))%" }

    private var hot: Bool { (focused || hovering) && !disabled }
    private var onInk: Color { disabled ? HT.inkDim : (hot ? HT.inkBright : HT.ink) }
    private var bracketInk: Color {
        if disabled { return HT.inkFaint }
        return focused ? HT.signal : HT.inkFaint
    }

    var body: some View {
        HStack(spacing: HT.cw) {
            Text("[").foregroundStyle(bracketInk).fixedSize()
            track
            Text("]").foregroundStyle(bracketInk).fixedSize()
            Text(reading)
                .foregroundStyle(disabled ? HT.inkDim : HT.ink)
                .fixedSize()
        }
        .font(HT.body)
        .lineLimit(1)
        .frame(height: HT.row)
        .focusable(!disabled)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in key(press) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(reading))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(value + step)
            case .decrement: commit(value - step)
            @unknown default: break
            }
        }
    }

    /// The run itself, and the whole of the hit area: the brackets and the
    /// reading beside it are labels, and a click on either of them would put
    /// the value somewhere nobody pointed at.
    private var track: some View {
        HStack(spacing: 0) {
            Text(String(repeating: fill.on, count: lit))
                .foregroundStyle(onInk)
            Text(String(repeating: fill.off, count: Swift.max(0, segments - lit)))
                .foregroundStyle(HT.inkFaint)
        }
        .kerning(0)
        .tracking(0)
        .fixedSize()
        .frame(width: trackWidth, height: HT.row, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Zero minimum, so the press that never moves is a click. Dragging
        // past either end is clamped rather than ignored, which is how the
        // extremes are reachable without landing on a single pixel.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { seek($0.location.x) }
                .onEnded { seek($0.location.x) }
        )
    }

    private func seek(_ x: CGFloat) {
        guard !disabled else { return }
        // Clicking takes the caret as well as the value: the arrows are half
        // this control, and a track you have just pointed at is the one you
        // expect them to move.
        focused = true
        let f = Swift.min(1, Swift.max(0, Double(x / trackWidth)))
        commit(range.lowerBound + f * span)
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard !disabled else { return .ignored }
        switch press.key {
        case .leftArrow:
            commit(value - step)
            return .handled
        case .rightArrow:
            commit(value + step)
            return .handled
        case .home:
            commit(range.lowerBound)
            return .handled
        case .end:
            commit(range.upperBound)
            return .handled
        default:
            return .ignored
        }
    }

    /// Snap, clamp, and report only a move. The guard is what keeps a drag
    /// across one cell from writing the same number sixty times a second.
    private func commit(_ raw: Double) {
        let next = Swift.min(range.upperBound, Swift.max(range.lowerBound, snap(raw)))
        guard next != value else { return }
        onChange(next)
    }

    private func snap(_ v: Double) -> Double {
        guard grain > 0 else { return v }
        return (v / grain).rounded() * grain
    }
}
