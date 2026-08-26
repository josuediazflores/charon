import SwiftUI

/* ── HTButton / IconButton ─────────────────────────────────────────────
   [ Ship build ]   < Run tests >   [ Halt ]

   Bracketed labels, inverse video on hover. `primary` is inverse at rest --
   the way a TUI marks the default action -- so there is never a question of
   which key Enter is bound to.

   Named `HTButton` because `Button` is SwiftUI's and `Kbd` is already the mail
   dialect's. The two dialects share a window and must not share a name.
*/

enum HTButtonVariant { case primary, secondary, ghost, quiet, danger }
enum HTButtonSize { case sm, md, lg }

// MARK: - the press

/* Nothing in this app used to change on mouse-down.
 *
 * `.plain` is SwiftUI's way of saying "draw nothing of your own", and it means
 * it: hover was the only state any control here had, so a click that landed on
 * a dead collector and a click that landed on nothing at all looked identical
 * for the whole round trip. A press is the one piece of feedback a program can
 * give instantly and always, because it is a fact about the mouse and not about
 * the network.
 *
 * It is a **colour and nothing else**, in both dialects. No scale, no shadow,
 * no ease: the tty dialect has one animation in it (the cursor's blink) and the
 * mail dialect fades colour over 120ms and moves nothing, so a button that
 * squashed under the pointer would be the one thing in the window that did.
 *
 * The mechanism is a `ButtonStyle`, which is the only place SwiftUI reports the
 * press at all, and it reports it *into the label* -- inside the button, not
 * around it. So the view that draws a control has to read it from the
 * environment rather than from a `@State` of its own, and `Pressed` below is
 * that read, written once instead of seven times.
 */

private struct HTPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the button this view is the label of is being held down.
    var htPressed: Bool {
        get { self[HTPressedKey.self] }
        set { self[HTPressedKey.self] = newValue }
    }
}

/// Reports the press and draws nothing. Everything visible is still the
/// control's own body, which is what keeps the two dialects from meeting here.
struct HTPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.htPressed, configuration.isPressed)
    }
}

/// The label side of that arrangement: hands the press to the content.
struct Pressed<Content: View>: View {
    @Environment(\.htPressed) private var pressed
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(pressed) }
}

struct HTButton: View {
    var title: String
    var variant: HTButtonVariant = .secondary
    var size: HTButtonSize = .md
    /// Glyph before the label.
    var icon: String? = nil
    /// Glyph after the label, for disclosure or direction.
    var iconAfter: String? = nil
    var block: Bool = false
    var caps: Bool = false
    /// `<` `>` instead of `[` `]`. Conventionally marks an action that
    /// navigates rather than commits.
    var angle: Bool = false
    var nobracket: Bool = false
    var disabled: Bool = false
    var action: () -> Void

    @State private var hovering = false

    private var height: CGFloat {
        switch size {
        case .sm: return HT.row
        case .md: return HT.row2
        case .lg: return HT.row3
        }
    }

    private var brackets: (String, String)? {
        if nobracket || variant == .quiet { return nil }
        return angle ? ("<", ">") : ("[", "]")
    }

    /// Held down, a control goes hot whether or not the pointer ever hovered
    /// it -- a key press and a click land the same way -- and a control that
    /// was hot already takes its fill one step down the ramp, so the click is
    /// visible on top of the hover rather than hidden under it.
    private func hot(_ down: Bool) -> Bool { (hovering || down) && !disabled }

    private func ink(_ down: Bool) -> Color {
        if disabled { return HT.inkFaint }
        let hot = hot(down)
        switch variant {
        case .primary: return HT.void
        case .secondary: return hot ? HT.void : HT.inkBright
        case .ghost: return hot ? HT.void : HT.inkMid
        case .quiet: return hot ? HT.inkBright : HT.inkDim
        case .danger: return hot ? HT.void : HT.fault
        }
    }

    private func fill(_ down: Bool) -> Color {
        if disabled { return .clear }
        let held = down && !disabled
        let hot = hot(down)
        switch variant {
        case .primary: return held ? HT.signalMid : HT.signal
        case .secondary: return held ? HT.inkMid : (hot ? HT.inkBright : .clear)
        case .ghost: return held ? HT.inkDim : (hot ? HT.inkMid : .clear)
        // The one variant with no fill of its own. It gets a plate rather than
        // a step, which is the rail's answer to the same question.
        case .quiet: return held ? HT.surface4 : .clear
        case .danger: return held ? HT.c1 : (hot ? HT.fault : .clear)
        }
    }

    private func border(_ down: Bool) -> Color {
        variant == .secondary ? (hot(down) ? HT.inkBright : HT.line) : .clear
    }

    private func bracketInk(_ down: Bool) -> Color {
        if disabled { return HT.inkFaint }
        switch variant {
        case .primary: return HT.void
        case .secondary, .ghost, .danger: return hot(down) ? HT.void : HT.inkFaint
        case .quiet: return .clear
        }
    }

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            Pressed { down in
                HStack(spacing: HT.cw) {
                    if let brackets { Text(brackets.0).foregroundStyle(bracketInk(down)) }
                    if let icon { Text(icon) }
                    Text(caps ? title.uppercased() : title)
                        .underline(variant == .quiet && hot(down))
                    if let iconAfter { Text(iconAfter) }
                    if let brackets { Text(brackets.1).foregroundStyle(bracketInk(down)) }
                }
                .font(HT.body)
                .foregroundStyle(ink(down))
                .lineLimit(1)
                .padding(.horizontal, size == .lg ? HT.cw2 : HT.cw)
                .frame(height: height)
                .frame(maxWidth: block ? .infinity : nil)
                .background(fill(down))
                .overlay { Rectangle().strokeBorder(border(down), lineWidth: 1) }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .disabled(disabled)
        .accessibilityLabel(Text(title))
    }
}

/// What stands in an icon button. The same two cases the rail's own slot has,
/// and for the same reason: a mark Departure Mono does not carry is drawn at
/// the face's own resolution rather than borrowed from a system one.
enum IconButtonIcon {
    case text(String)
    case pixel(PixelGlyphName)
}

/// A square control with no visible label. One cell wide -- at a single glyph
/// brackets would triple its width and read as a field the reader can type in.
struct IconButton: View {
    var icon: IconButtonIcon
    /// Required: the button has no visible text to name it.
    var label: String
    var size: HTButtonSize = .md
    /// Draw a border, for use outside a panel header.
    var bordered: Bool = false
    /// Cyan active state, for toggles.
    var on: Bool = false
    var disabled: Bool = false
    var action: () -> Void

    init(icon: String, label: String, size: HTButtonSize = .md, bordered: Bool = false,
         on: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = .text(icon)
        self.label = label
        self.size = size
        self.bordered = bordered
        self.on = on
        self.disabled = disabled
        self.action = action
    }

    init(glyph: PixelGlyphName, label: String, size: HTButtonSize = .md, bordered: Bool = false,
         on: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = .pixel(glyph)
        self.label = label
        self.size = size
        self.bordered = bordered
        self.on = on
        self.disabled = disabled
        self.action = action
    }

    @State private var hovering = false

    private var side: CGFloat { size == .sm ? HT.row : HT.row2 }
    private func hot(_ down: Bool) -> Bool { (hovering || down) && !disabled }

    private func ink(_ down: Bool) -> Color {
        if disabled { return HT.inkFaint }
        if on { return HT.void }
        return hot(down) ? HT.void : HT.inkMid
    }

    private func fill(_ down: Bool) -> Color {
        if disabled { return .clear }
        let held = down && !disabled
        if on { return held ? HT.signalMid : HT.signal }
        return held ? HT.inkDim : (hot(down) ? HT.inkMid : .clear)
    }

    private var border: Color {
        if on { return HT.signal }
        return bordered ? HT.line : .clear
    }

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            Pressed { down in
                Group {
                    switch icon {
                    case .text(let glyph): Text(glyph)
                    case .pixel(let glyph): PixelGlyph(name: glyph, color: ink(down))
                    }
                }
                .font(HT.body)
                .foregroundStyle(ink(down))
                .frame(width: side, height: side)
                .background(fill(down))
                .overlay { Rectangle().strokeBorder(border, lineWidth: 1) }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .disabled(disabled)
        .accessibilityLabel(Text(label))
    }
}
