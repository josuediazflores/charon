import SwiftUI

/* ── SidebarView / RailStub ────────────────────────────────────────────
     HALFTONE
   > ◉ Overview            The active item is marked by a `>` in the gutter
     ⏻ Hardware            and inverse video, the way a TUI menu marks the
     ▤ CMO                 line the cursor is on.

   No fills, no edge bars. One column of gutter, then the label.

   The shell swaps the sidebar for RailStub when collapsed.
*/

/// What stands in a rail row's icon slot.
///
/// Two cases because the rail is set in two things at once: the glyphs
/// Departure Mono actually has are characters, and the five it does not have
/// are drawn as bitmaps at the same resolution rather than borrowed from a
/// system face. A row does not care which it got -- both land in the same
/// fourteen-point slot, in the row's current ink.
enum SidebarIcon {
    case text(String)
    case pixel(PixelGlyphName)
}

struct SidebarItemSpec: Identifiable {
    var id: String
    var icon: SidebarIcon
    var label: String
    var badge: String?

    init(id: String, icon: SidebarIcon, label: String, badge: String? = nil) {
        self.id = id
        self.icon = icon
        self.label = label
        self.badge = badge
    }
}

/// The rail's eight destinations, in the reference's literal order.
///
/// **Five of these are drawn, not typed.** ◉ ⏻ ▤ ✉ ⧉ are not in Departure Mono
/// and used to fall back to a system face, a pixel off the grid and at another
/// weight; they are `PixelGlyph` bitmaps now, which is the same shape at the
/// resolution the rest of the rail is set at. The web reference still has the
/// character version of the bug (App.tsx:44-48). ❯ ✦ ⌘ are in the face and stay
/// characters.
enum ConsoleNav {
    static let items: [SidebarItemSpec] = [
        SidebarItemSpec(id: "overview", icon: .pixel(.overview), label: "Overview"),
        SidebarItemSpec(id: "hardware", icon: .pixel(.hardware), label: "Hardware"),
        SidebarItemSpec(id: "cmo", icon: .pixel(.cmo), label: "CMO"),
        SidebarItemSpec(id: "mail", icon: .pixel(.mail), label: "Mail"),
        // Two overlapping shapes, which is what the canvas's two-bubble pixel
        // icon says in a rail this size.
        SidebarItemSpec(id: "messages", icon: .pixel(.messages), label: "Messages"),
        SidebarItemSpec(id: "chat", icon: .text("❯"), label: "Chat"),
        SidebarItemSpec(id: "jarvis", icon: .text("✦"), label: "Jarvis"),
        SidebarItemSpec(id: "settings", icon: .text("⌘"), label: "Settings"),
    ]

    static let ids: Set<String> = Set(items.map(\.id))

    static func label(_ id: String) -> String {
        items.first { $0.id == id }?.label ?? "Overview"
    }
}

struct SidebarView: View {
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
                PixelGlyph(name: .brand, color: HT.signal)
                    .frame(width: HT.cw2, alignment: .leading)
                Text(name.uppercased())
                    .font(HT.body)
                    .foregroundStyle(HT.inkBright)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let brandAside { brandAside }
            }
            .padding(.horizontal, HT.cw2)
            .frame(height: HT.row3)
            .overlay(alignment: .bottom) { Rectangle().fill(HT.line).frame(height: 1) }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        SidebarRow(item: item, active: item.id == active) {
                            onSelect(item.id)
                        }
                    }
                }
                .padding(.vertical, HT.row)
            }
            .frame(maxHeight: .infinity)

            if let footer {
                footer
                    .padding(.horizontal, HT.cw2)
                    .padding(.vertical, HT.s2)
                    .overlay(alignment: .top) { Rectangle().fill(HT.line).frame(height: 1) }
            }
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .overlay(alignment: .trailing) { Rectangle().fill(HT.line).frame(width: 1) }
    }
}

private struct SidebarRow: View {
    var item: SidebarItemSpec
    var active: Bool
    var select: () -> Void

    @State private var hovering = false

    private func ink(_ down: Bool) -> Color {
        if active { return HT.void }
        return (hovering || down) ? HT.inkBright : HT.inkMid
    }

    /// Held down, a row goes one plate past its hover. The active row keeps its
    /// cyan and steps that instead: its ink is the ground, and a surface under
    /// ground-coloured type would be a row that vanished for as long as it was
    /// being clicked.
    private func fill(_ down: Bool) -> Color {
        if active { return down ? HT.signalMid : HT.signal }
        if down { return HT.surface4 }
        return hovering ? HT.surface3 : Color.clear
    }

    var body: some View {
        Button(action: select) {
            Pressed { down in
            HStack(spacing: HT.cw) {
                // The cursor gutter. Always present, so labels never shift on
                // selection.
                Text(active ? ">" : " ")
                    .foregroundStyle(active ? HT.void : HT.signal)
                    .frame(width: HT.cw)
                // The icon slot. Leading rather than centred: a single 7pt
                // glyph centred in a 14pt box lands on a half cell, and the
                // column has to read straight down whichever kind of icon a
                // row got.
                Group {
                    switch item.icon {
                    case .text(let glyph): Text(glyph)
                    case .pixel(let glyph): PixelGlyph(name: glyph, color: ink(down))
                    }
                }
                .frame(width: HT.cw2, alignment: .leading)
                Text(item.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge = item.badge {
                    Text(badge).foregroundStyle(active ? HT.void : HT.inkFaint)
                }
            }
            .font(HT.body)
            .foregroundStyle(ink(down))
            .padding(.leading, HT.cw)
            .padding(.trailing, HT.cw2)
            .frame(height: HT.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill(down))
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(item.label))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// The rail, collapsed to a strip.
///
/// Four cells of ground at the far left, the brand mark in a cap the height of
/// the bar beside it, and under that the same `>` the rail's own active item
/// carries -- which is the whole of the affordance, because `>` already means
/// "this way" everywhere else in this console. Instant on click: a strip that
/// slid back out would be the one animation in the system.
struct RailStub: View {
    var onShow: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onShow) {
            Pressed { down in
            VStack(spacing: 0) {
                // The cap keeps the console's one horizontal rule unbroken:
                // the brand row and the top bar are both 48 tall and ruled off
                // underneath, so a strip without this would put a four-cell
                // notch in that line.
                PixelGlyph(name: .brand, color: HT.signal)
                    .frame(maxWidth: .infinity)
                    .frame(height: HT.row3)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(HT.line).frame(height: 1)
                    }
                Text(">")
                    .foregroundStyle(HT.signal)
                    .padding(.top, HT.row)
                Spacer(minLength: 0)
            }
            .font(HT.body)
            .frame(width: HT.cw4)
            .frame(maxHeight: .infinity)
            .background(down ? HT.surface4 : (hovering ? HT.surface3 : Color.clear))
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) { Rectangle().fill(HT.line).frame(width: 1) }
        .accessibilityLabel(Text("Show sidebar"))
        .help("Show sidebar (⌥⌘S)")
    }
}
