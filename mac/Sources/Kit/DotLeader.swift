import SwiftUI

struct DotLeader: View {
    /// Left-hand key. Set lowercase, the way a fetch tool prints them.
    var label: String
    /// Right-hand reading.
    var value: String
    /// Tints the value, and only the value.
    var tone: Tone = .default
    /// Demote the value, because its source is stale. Wins over `tone`: the
    /// reference wraps the value in `Demoted`, whose ink is the inner span's.
    var dim: Bool = false
    /// Colour the key cyan, the neofetch convention. Inside an identity block
    /// only -- in a long readout list every line would then compete.
    var keyed: Bool = false
    /// The one step up that renders crisp in a bitmap face.
    var lead: Bool = false
    /// Slot after the value, for a StatusLamp or a SegBar.
    var after: AnyView? = nil
    /// Override the key's ink. Settings uses it to lift its row labels to
    /// bright over their dim notes; nil keeps the readout default.
    var labelInk: Color? = nil

    private var font: Font { lead ? FocusInk.heading(22) : FocusInk.body }
    private var valueInk: Color { dim ? HT.inkDim : (tone.ink ?? FocusInk.text) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(labelInk ?? (keyed ? FocusInk.sand : HT.inkMid))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueInk)
                .lineLimit(1)
                .truncationMode(.tail)

            if let after { after }
        }
        .font(font)
        .frame(minHeight: lead ? 32 : 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(value)"))
    }
}
