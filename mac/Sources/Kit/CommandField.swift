import SwiftUI

struct CommandField: View {
    var placeholder: String = "Search"
    /// Bumped by the shell's ⌘K. Any change moves the caret into the field.
    var focusToken: Int = 0
    /// Keys printed on the right. Empty hides the cap.
    var keys: [String] = ["⌘K"]
    /// Drop the max width and fill the container.
    var block: Bool = false

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: HT.cw) {
            Image(systemName: "magnifyingglass")
                .font(FocusInk.body)
                .foregroundStyle(focused ? FocusInk.sand : HT.inkMid)
                .accessibilityHidden(true)
                .fixedSize()

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(FocusInk.body)
                        .foregroundStyle(HT.inkMid)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(FocusInk.body)
                    .foregroundStyle(HT.inkBright)
                    .focused($focused)
                    .focusEffectDisabled()
            }

            if !keys.isEmpty {
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { HTKbd(key: $0) }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .frame(height: HT.row2)
        .frame(maxWidth: block ? .infinity : 380)
        .background(HT.surface2, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? FocusInk.sand : FocusInk.cardLine, lineWidth: 1)
        }
        .onChange(of: focusToken) { focused = true }
        .accessibilityLabel(Text(placeholder))
    }
}

struct HTKbd: View {
    var key: String

    var body: some View {
        Text(key)
            .font(FocusInk.body)
            .foregroundStyle(HT.inkMid)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(minWidth: HT.cw2, minHeight: HT.row)
            .background(HT.surface3, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}
