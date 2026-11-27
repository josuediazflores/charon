import SwiftUI

struct DestinationPicker: View {
    let items: [SidebarItemSpec]
    let current: String
    var select: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private func label(_ item: SidebarItemSpec) -> String {
        item.id == "jarvis" ? "Jarvis / Conversation" : item.label
    }

    private var matches: [SidebarItemSpec] {
        items.filter { query.isEmpty || label($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Find a destination", text: $query)
                .accessibilityLabel("Find a destination")
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = matches.first { select(first.id) } }
            if matches.isEmpty {
                Text("No matching destinations").foregroundStyle(.secondary).padding(8)
            } else {
                ForEach(matches) { item in
                    Button { select(item.id) } label: {
                        HStack {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(label(item))
                            Spacer()
                            if item.id == current { Image(systemName: "checkmark") }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12).frame(width: 245)
        .onAppear { query = ""; focused = true }
    }
}
