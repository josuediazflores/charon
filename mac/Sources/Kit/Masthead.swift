import SwiftUI

struct MastheadRow: Identifiable {
    var key: String
    var value: String
    var tone: Tone

    var id: String { key }

    init(_ key: String, _ value: String, tone: Tone = .default) {
        self.key = key
        self.value = value
        self.tone = tone
    }
}

struct Masthead: View {
    var user: String
    var host: String
    var rows: [MastheadRow]
    var art: AnyView?
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(user)@\(host)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FocusInk.text)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16, alignment: .leading)],
                          alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.key.capitalized)
                                .font(.system(size: 12))
                                .foregroundStyle(HT.inkMid)
                            Text(row.value)
                                .font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .foregroundStyle(row.tone.ink ?? FocusInk.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if width > HT.bpSm, let art { art.fixedSize() }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
        .htMeasureWidth { width = $0 }
    }
}

struct MastheadStrip: View {
    var legend: String
    /// Tint the strip cyan.
    var signal: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: signal ? "checkmark.circle" : "info.circle")
            Text(legend)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(HT.inkMid)
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(legend))
    }
}
