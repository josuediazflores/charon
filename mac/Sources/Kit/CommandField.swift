import SwiftUI

/* ── CommandField ──────────────────────────────────────────────────────
   $ Search nodes, commits                                          ⌘K

   A prompt you can type into. The sigil is not decoration: it tells the reader
   this field takes a command, not a search phrase.

   **Inert, on purpose** (build decision 4). ⌘K puts the caret in it and
   nothing else happens -- the reference searches nothing either, and porting
   the affordance without the behaviour is the faithful move. When search
   arrives it arrives in both programs at once.
*/

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
            Text("$")
                .font(HT.body)
                .foregroundStyle(focused ? HT.signal : HT.prompt)
                .fixedSize()

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(HT.body)
                        .foregroundStyle(HT.inkFaint)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(HT.body)
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
        .padding(.horizontal, HT.cw)
        .frame(height: HT.row2)
        .frame(maxWidth: block ? .infinity : 380)
        .background(Color.clear)
        .overlay {
            Rectangle().strokeBorder(focused ? HT.signal : HT.line, lineWidth: 1)
        }
        .onChange(of: focusToken) { focused = true }
        .accessibilityLabel(Text(placeholder))
    }
}

/// A printed key cap. Inverse video rather than a raised one: a bevel is a GUI
/// idiom and there is no light source in a terminal.
struct HTKbd: View {
    var key: String

    var body: some View {
        Text(key)
            .font(HT.body)
            .foregroundStyle(HT.inkMid)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(minWidth: HT.cw2, minHeight: HT.row)
            .background(HT.surface3)
            .accessibilityHidden(true)
    }
}
