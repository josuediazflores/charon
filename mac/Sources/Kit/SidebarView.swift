import SwiftUI

struct SidebarItemSpec: Identifiable {
    var id: String
    var symbol: String
    var label: String
    var badge: String?
}

enum ConsoleNav {
    static let items = [
        SidebarItemSpec(id: "overview", symbol: "house", label: "Overview"),
        SidebarItemSpec(id: "hardware", symbol: "cpu", label: "Hardware"),
        SidebarItemSpec(id: "cmo", symbol: "waveform.path.ecg", label: "CMO"),
        SidebarItemSpec(id: "mail", symbol: "envelope", label: "Mail"),
        SidebarItemSpec(id: "messages", symbol: "bubble.left", label: "Messages"),
        SidebarItemSpec(id: "chat", symbol: "bubble.left.and.bubble.right", label: "Chat"),
        SidebarItemSpec(id: "jarvis", symbol: "sparkles", label: "Jarvis"),
        SidebarItemSpec(id: "settings", symbol: "gearshape", label: "Settings"),
    ]

    static let overnight = SidebarItemSpec(id: "jarvis-overnight", symbol: "square.3.layers.3d", label: "Overnight tasks")
    static let destinations = items.flatMap { $0.id == "jarvis" ? [$0, overnight] : [$0] }
    static let ids: Set<String> = Set(destinations.map(\.id))

    static func label(_ id: String) -> String {
        destinations.first { $0.id == id }?.label ?? "Overview"
    }
}

extension EnvironmentValues {
    @Entry var workspaceScale: CGFloat = 1
}

struct SidebarView: View {
    // Wide enough for the three system window controls at their native spacing.
    static let collapsedWidth: CGFloat = 80

    @AppStorage("jarvisSidebarExpanded") private var jarvisExpanded = true
    @Environment(\.workspaceScale) private var scale
    let collapsed: Bool
    let onToggle: () -> Void
    var items: [SidebarItemSpec] = ConsoleNav.items
    var active: String
    var onSelect: (String) -> Void
    var footer: AnyView?

    var body: some View {
        GeometryReader { rail in
            let short = rail.size.height < 600
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 36)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .accessibilityHidden(true)

                Button(action: onToggle) {
                    HStack(spacing: 12 * scale) {
                        if !collapsed {
                            JarvisMark().frame(width: 46 * scale, height: 46 * scale)
                            Text("Jarvis").font(.system(size: 27 * scale, weight: .semibold)).fixedSize()
                            Spacer(minLength: 0)
                        }
                        Image(systemName: "sidebar.left")
                            .font(.system(size: collapsed ? 18 : 18 * scale))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, collapsed ? 0 : 30 * scale)
                    .padding(.trailing, collapsed ? 0 : 18 * scale)
                    .frame(maxWidth: .infinity)
                    .frame(height: short ? 52 : 108 * scale)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
                .help(collapsed ? "Expand sidebar (⌥⌘S)" : "Collapse sidebar (⌥⌘S)")

                ScrollView {
                    VStack(spacing: 2.5 * scale) {
                        ForEach(items) { item in
                            if item.id == "jarvis" {
                                if !collapsed {
                                    SidebarRow(item: item, active: !jarvisExpanded && (active == item.id || active == ConsoleNav.overnight.id),
                                               expanded: jarvisExpanded, short: short) { jarvisExpanded.toggle() }
                                }
                                if collapsed || jarvisExpanded {
                                    destination(.init(id: item.id, symbol: collapsed ? item.symbol : "bubble.left",
                                                      label: "Conversation"), short: short, nested: true)
                                    destination(ConsoleNav.overnight, short: short, nested: true)
                                }
                            } else {
                                destination(item, short: short)
                                    .padding(.top, item.id == "settings" ? (short ? 5 : 16 * scale) : 0)
                            }
                        }
                    }
                    .padding(.horizontal, collapsed ? 7 : 11 * scale)
                }
                .scrollIndicators(collapsed ? .hidden : .automatic)
                if let footer {
                    footer.font(.system(size: 17 * scale))
                        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                        .padding(.horizontal, collapsed ? 0 : 30 * scale)
                        .padding(.vertical, short ? 9 : 30 * scale)
                }
            }
        }
        .background(FocusInk.sidebar)
        .overlay(alignment: .trailing) {
            if Ground.shared.glass { Rectangle().fill(HT.lineFaint).frame(width: 1).allowsHitTesting(false) }
        }
    }
    private func destination(_ item: SidebarItemSpec, short: Bool, nested: Bool = false) -> some View {
        SidebarRow(item: item, active: active == item.id, iconsOnly: collapsed, nested: nested && !collapsed,
                   short: short) { onSelect(item.id) }
    }

}

private struct JarvisMark: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 46
            for row in -5...5 {
                for col in -5...5 {
                    let x = CGFloat(col) * 4.7 + (row.isMultiple(of: 2) ? 0 : 2.35)
                    let y = CGFloat(row) * 4.4
                    let r = hypot(x, y) / 23
                    guard r < 1 else { continue }
                    let diameter = (1 + 3.8 * (1 - r * r)) * (0.88 + 0.12 * cos(x + y))
                    let dot = CGRect(x: (23 + x - diameter / 2) * unit, y: (23 + y - diameter / 2) * unit,
                                     width: diameter * unit, height: diameter * unit)
                    context.fill(Path(ellipseIn: dot), with: .color(.white))
                }
            }
        }.accessibilityHidden(true)
    }
}

private struct SidebarRow: View {
    let item: SidebarItemSpec
    let active: Bool
    var expanded: Bool?
    var iconsOnly = false
    var nested = false
    let short: Bool
    let select: () -> Void
    @Environment(\.workspaceScale) private var scale
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: (scale <= 0.73 ? 10 : (nested ? 18 : 21)) * scale) {
                Image(systemName: item.symbol)
                    .font(.system(size: (nested ? 21 : 24) * scale, weight: .regular))
                    .frame(width: iconsOnly ? SidebarView.collapsedWidth - 14 : 28 * scale)
                    .foregroundStyle(Color(white: 0.84))
                if !iconsOnly {
                    Text(item.label).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    if let expanded {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13 * scale, weight: .medium))
                    }
                }
            }
            .foregroundStyle(.white)
            // Keep icons on the leading edge as the sidebar changes width.
            .padding(.leading, iconsOnly ? 0 : (nested ? 15 : 21) * scale)
            .padding(.trailing, iconsOnly ? 0 : (scale <= 0.73 ? 6 : 20) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: short ? 29 : (nested ? 44 : 47) * scale)
            .background(active ? Color.white.opacity(0.13) : (hovering ? Color.white.opacity(0.06) : .clear),
                        in: RoundedRectangle(cornerRadius: 9 * scale))
            .padding(.leading, nested ? (scale <= 0.73 ? 12 : 29) * scale : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityValue(expanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
