import SwiftUI

enum SegBarFill {
    case block, shade, bar, equals

    var on: String {
        switch self {
        case .block: return "█"
        case .shade: return "▓"
        case .bar: return "|"
        case .equals: return "="
        }
    }

    var off: String {
        switch self {
        case .block, .shade: return "░"
        case .bar: return "."
        case .equals: return "-"
        }
    }
}

struct SegBar: View {
    var value: Double
    var max: Double = 100
    /// Cells in the run. Each is exactly one character wide.
    var segments: Int = 10
    var tone: Tone = .default
    /// Mark a limit at this fraction of the scale. The cell there goes fault,
    /// so an over-range reading breaks the run visibly and not only in hue.
    var limit: Double? = nil
    var label: String? = nil
    /// Reading after the run. Nil renders the default percentage.
    var readout: String? = nil
    var showReadout: Bool = true
    var fill: SegBarFill = .block
    var brackets: Bool = false
    /// Stretch to fill the container, which pushes the readout to the far edge.
    var block: Bool = false

    private var ratio: Double {
        guard max != 0 else { return 0 }
        return Swift.min(1, Swift.max(0, value / max))
    }

    private var lit: Int { Int((ratio * Double(segments)).rounded()) }
    private var limitIndex: Int { limit.map { Int(($0 * Double(segments)).rounded()) } ?? -1 }
    private var onInk: Color { tone.ink ?? HT.ink }

    /// One span per contiguous run, so the limit cell can take its own colour
    /// without the bar becoming ten views.
    private var cells: [(id: Int, ink: Color, text: String)] {
        var out: [(id: Int, ink: Color, text: String)] = []
        for i in 0..<segments {
            let on = i < lit
            let ink: Color = i == limitIndex ? HT.fault : (on ? onInk : HT.inkFaint)
            let ch = on ? fill.on : fill.off
            if var last = out.last, last.ink == ink {
                last.text += ch
                out[out.count - 1] = last
            } else {
                out.append((id: out.count, ink: ink, text: ch))
            }
        }
        return out
    }

    var body: some View {
        HStack(spacing: HT.cw) {
            if let label {
                Text(label)
                    .foregroundStyle(HT.inkMid)
                    .fixedSize()
            }

            if fill == .block && limit == nil {
                GeometryReader { geometry in
                    Capsule().fill(HT.surface4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(onInk).frame(width: geometry.size.width * ratio)
                        }
                }
                .frame(width: block ? nil : CGFloat(segments) * HT.cw, height: brackets ? 6 : 4)
            } else {
                if brackets { Text("[").foregroundStyle(HT.inkFaint) }
                HStack(spacing: 0) {
                    ForEach(cells, id: \.id) { cell in
                        Text(cell.text).foregroundStyle(cell.ink)
                    }
                }
                .kerning(0)
                .tracking(0)
                .fixedSize()
                if brackets { Text("]").foregroundStyle(HT.inkFaint) }
                if block { Spacer(minLength: HT.cw) }
            }
            if showReadout {
                Text(readout ?? "\(Int((ratio * 100).rounded()))%")
                    .foregroundStyle(HT.ink)
                    .fixedSize()
            }
        }
        .font(HT.body)
        .lineLimit(1)
        .frame(maxWidth: block ? .infinity : nil, alignment: .leading)
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label ?? "meter"))
        .accessibilityValue(Text(readout ?? "\(Int((ratio * 100).rounded()))%"))
    }
}
