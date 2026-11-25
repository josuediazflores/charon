import SwiftUI

struct SidebarItemSpec: Identifiable {
    var id: String
    var symbol: String
    var label: String
    var badge: String?
}

enum ConsoleNav {
    static let items = [
        SidebarItemSpec(id: "overview", symbol: "square.grid.2x2", label: "Overview"),
        SidebarItemSpec(id: "hardware", symbol: "cpu", label: "Hardware"),
        SidebarItemSpec(id: "cmo", symbol: "newspaper", label: "CMO"),
        SidebarItemSpec(id: "mail", symbol: "envelope", label: "Mail"),
        SidebarItemSpec(id: "messages", symbol: "bubble.left.and.bubble.right", label: "Messages"),
        SidebarItemSpec(id: "chat", symbol: "text.bubble", label: "Chat"),
        SidebarItemSpec(id: "jarvis", symbol: "sparkle", label: "Jarvis"),
        SidebarItemSpec(id: "settings", symbol: "gearshape", label: "Settings"),
    ]

    static let dailyBrief = SidebarItemSpec(id: "jarvis-brief", symbol: "sunrise", label: "Daily Brief")
    static let overnight = SidebarItemSpec(id: "jarvis-overnight", symbol: "moon", label: "Overnight tasks")
    static let destinations = items.flatMap { $0.id == "jarvis" ? [$0, dailyBrief, overnight] : [$0] }
    static let ids: Set<String> = Set(destinations.map(\.id))

    static func label(_ id: String) -> String {
        destinations.first { $0.id == id }?.label ?? "Overview"
    }
}

struct SidebarView: View {
    @AppStorage("jarvisSidebarExpanded") private var jarvisExpanded = true
    var name: String = "Halftone"
    /// Right side of the brand row, conventionally the hide-the-rail control.
    var brandAside: AnyView? = nil
    var items: [SidebarItemSpec] = ConsoleNav.items
    var active: String
    var onSelect: (String) -> Void
    /// Pinned block below the nav.
    var footer: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HT.cw) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 17)).foregroundStyle(FocusInk.sand)
                    .frame(width: HT.cw2, alignment: .leading)
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FocusInk.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let brandAside { brandAside }
            }
            .padding(.horizontal, HT.cw2)
            .frame(height: 56)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        if item.id == "jarvis" {
                            let sectionActive = active == item.id || active == ConsoleNav.dailyBrief.id || active == ConsoleNav.overnight.id
                            SidebarRow(item: item, active: sectionActive && !jarvisExpanded,
                                       expanded: jarvisExpanded) {
                                jarvisExpanded.toggle()
                            }
                            if jarvisExpanded {
                                SidebarRow(item: .init(id: item.id, symbol: "text.bubble", label: "Conversation"),
                                           active: active == item.id, nested: true) { onSelect(item.id) }
                                SidebarRow(item: ConsoleNav.dailyBrief, active: active == ConsoleNav.dailyBrief.id,
                                           nested: true) { onSelect(ConsoleNav.dailyBrief.id) }
                                SidebarRow(item: ConsoleNav.overnight, active: active == ConsoleNav.overnight.id,
                                           nested: true) { onSelect(ConsoleNav.overnight.id) }
                            }
                        } else {
                            SidebarRow(item: item, active: item.id == active) {
                                onSelect(item.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 9)
            }
            .frame(maxHeight: .infinity)

            if let footer {
                footer
                    .padding(.horizontal, HT.cw2)
                    .padding(.vertical, HT.s2)
            }
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .overlay(alignment: .trailing) { Rectangle().fill(FocusInk.cardLine).frame(width: 1) }
    }
}

private struct SidebarRow: View {
    var item: SidebarItemSpec
    var active: Bool
    var expanded: Bool? = nil
    var nested = false
    var select: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: select) {
            Pressed { down in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: nested ? 11 : 14))
                        .frame(width: 17)
                        .foregroundStyle(active || item.id == "jarvis" ? FocusInk.sand : HT.inkMid)
                    Text(item.label)
                        .font(.system(size: nested ? 12 : 13, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let badge = item.badge { Text(badge).font(.caption) }
                    if let expanded {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(active || hovering ? FocusInk.text : HT.inkMid)
                .padding(.horizontal, 10)
                .frame(height: nested ? 30 : 34)
                .background(down ? HT.surface4 : (active || hovering ? HT.surface3 : .clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: 8).strokeBorder(FocusInk.sand) }
                }
                .padding(.leading, nested ? 18 : 0)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(item.label))
        .accessibilityValue(Text(expanded.map { $0 ? "Expanded" : "Collapsed" } ?? ""))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct RailStub: View {
    var onShow: () -> Void

    var body: some View {
        VStack {
            Button(action: onShow) {
                Image(systemName: "sidebar.left").foregroundStyle(FocusInk.sand)
                    .frame(width: 38, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show sidebar")
            .help("Show sidebar (⌥⌘S)")
            Spacer()
        }
        .overlay(alignment: .trailing) { Rectangle().fill(FocusInk.cardLine).frame(width: 1) }
    }
}
