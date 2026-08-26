import SwiftUI

/* ── Metric ────────────────────────────────────────────────────────────
   ads blocked today
   13,315
   31.0% of 43,003 queries

   A headline reading. **One per panel**: the moment there are two, the panel
   has no subject and neither number means anything.

   Three sizes and nothing between them, because there is nothing between them
   in the face -- 22, 33 and 44 are whole multiples of its 11px design size and
   everything else resamples.
*/

enum MetricSize {
    case compact  // 22 / 32
    case standard // 33 / 48
    case hero     // 44 / 64
}

struct Metric: View {
    /// What is being measured. Set lowercase.
    var label: String
    /// The reading itself, pre-formatted. This component does not round.
    var value: String
    /// Unit set smaller and dimmer on the value's baseline.
    var unit: String? = nil
    /// Right-aligned header slot: an IconButton or a StatusLamp.
    var aside: AnyView? = nil
    /// Row under the value.
    var footer: AnyView? = nil
    var tone: Tone = .default
    var size: MetricSize = .standard
    /// Demote the reading, because its source is stale.
    var dim: Bool = false
    /// Draw the reading as an inverse-video block. For the one number in a view
    /// that must be read before anything else.
    var inverse: Bool = false

    private var valueFont: Font {
        switch size {
        case .compact: return HT.lead
        case .standard: return HT.metric
        case .hero: return HT.hero
        }
    }

    private var valueLine: CGFloat {
        switch size {
        case .compact: return HT.lineLead
        case .standard: return HT.lineMetric
        case .hero: return HT.lineHero
        }
    }

    private var valueInk: Color { dim ? HT.inkDim : (tone.ink ?? HT.inkBright) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HT.cw) {
                Text(label.lowercased())
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let aside { aside.fixedSize() }
            }
            .frame(height: HT.row)

            HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(inverse ? HT.void : valueInk)
                    .lineLimit(1)
                    .minimumScaleFactor(1)
                if let unit {
                    Text(unit)
                        .font(HT.body)
                        .foregroundStyle(inverse ? HT.void : HT.inkDim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, inverse ? HT.cw : 0)
            .frame(height: valueLine, alignment: .leading)
            .background(inverse ? valueInk : Color.clear)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let footer {
                footer
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .frame(maxWidth: .infinity, minHeight: HT.row, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
