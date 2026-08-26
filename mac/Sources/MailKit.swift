import SwiftUI

/* The mail app's own small parts, ported from `MailKit.tsx` and the control
 * rules in `mail.css`.
 *
 * Three button shapes, an avatar, and two pill shapes. Every one of them
 * animates background, border and text colour over 120ms and nothing else --
 * nothing in this app moves, grows, or eases into place.
 *
 * Every icon-only control carries an accessibility label. An icon with no
 * accessible name is a control only the sighted have.
 */

// MARK: - the avatar

/// The disc at the head of a row, and the one in the reader's header.
///
/// Decoration to a screen reader: the sender's own name is the next thing on
/// the line, and initials read out letter by letter would be the same fact
/// twice and worse the first time.
struct Avatar: View {
    let who: String?
    var large = false
    var dim = false
    /// No tracking. Departure Mono is a bitmap drawn on a fixed 7pt cell, so at
    /// 11pt the 0.22 lands the second capital off the cell and smears both of
    /// them. It is the same everywhere the app draws initials and belongs in
    /// the face rather than here; the transcript is the one place it is
    /// visible at 22pt, so the transcript is the one place that asks for it.
    var tight = false

    var body: some View {
        let side: CGFloat = large ? 38 : 32
        let hue = Fmt.senderHue(who)
        Text(Fmt.initials(who))
            .font(Face.body)
            .tracking(tight ? 0 : 0.22)
            .foregroundStyle(dim ? M.inkDim : Color(hue360: hue, s: M.avatarS, l: M.avatarFgL))
            .frame(width: side, height: side)
            .background(
                Circle().fill(dim ? M.raised : Color(hue360: hue, s: M.avatarS, l: M.avatarBgL))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - chips

/// A capsule with an uppercase micro-label inside it: the header field is the
/// key inside the pill rather than a column beside it.
struct Chip: View {
    let key: String
    let value: String
    /// Only the top two urgencies get a hue. Amber and red mean caution and
    /// fault everywhere in this console and are not spent on a message that
    /// wants nothing.
    var tone: Color?
    /// The compose panel's to-chip is the one chip in the app that may never
    /// truncate, so it wraps and gives up the pill radius instead.
    var wraps = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key.uppercased())
                .font(Face.body)
                .tracking(0.66)
                .foregroundStyle(M.inkDim)
                .fixedSize()
            Text(value)
                .font(Face.body)
                .foregroundStyle(tone ?? M.ink)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: wraps ? M.r : M.rPill, style: .continuous)
                .fill(M.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: wraps ? M.r : M.rPill, style: .continuous)
                .strokeBorder(tone ?? M.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key) \(value)")
    }
}

/// An allowlisted word from the triage worker. Chipped rather than coloured: a
/// tag is a category, and categories told apart by hue are exactly what this
/// system does not do.
struct Tag: View {
    let text: String
    var dim = false

    var body: some View {
        Text(text)
            .font(Face.body)
            .tracking(0.22)
            .foregroundStyle(dim ? M.inkDim : M.inkMid)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(M.raised))
            .fixedSize()
    }
}

/// A refusal, and the only two places a word gets a hue in the reader. Both
/// keep the word: the colour is the reinforcement.
struct Flag: View {
    let icon: IconName
    let word: String
    let tone: Color

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: icon, size: 12)
            Text(word.uppercased())
                .font(Face.body)
                .tracking(0.44)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .overlay(Capsule(style: .continuous).strokeBorder(tone, lineWidth: 1))
        .fixedSize()
    }
}

/// A printed binding. A shortcut nobody is told about is a shortcut nobody has.
struct Kbd: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Face.body)
            .foregroundStyle(M.inkDim)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(M.raised))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(M.line, lineWidth: 1))
            .accessibilityHidden(true)
            .fixedSize()
    }
}

// MARK: - controls

/// A key in the reader's action bar: an icon over a small label.
///
/// `on` is a toggle's state and is deliberately optional -- ARCHIVE and UNREAD
/// are acts and not toggles, and a control reporting "off" forever tells a
/// screen reader it is a switch.
struct ActionKey: View {
    let icon: IconName
    let label: String
    var on: Bool?
    var disabled = false
    var help: String?
    let action: () -> Void

    @State private var hover = false

    private var isOn: Bool { on == true }

    var body: some View {
        Button(action: action) {
            Pressed { down in
                VStack(spacing: 3) {
                    Icon(name: icon, size: 16)
                    Text(label)
                        .font(Face.body)
                        .tracking(0.33)
                        .lineLimit(1)
                }
                .frame(minWidth: 58)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 6)
                .foregroundStyle(ink(down))
                .background(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                    .fill(fill(down)))
                .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                    .strokeBorder(border(down), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: M.rSm, style: .continuous))
            }
        }
        .buttonStyle(HTPressStyle())
        .disabled(disabled)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .animation(M.move, value: isOn)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // The press, in this dialect: the plate steps one surface up from whatever
    // hover was showing, and the edge goes bright. Instant -- the animations
    // above are keyed on hover and on the toggle, so nothing eases into a state
    // that lasts as long as a finger is down.
    private func ink(_ down: Bool) -> Color {
        if disabled { return M.lineStrong }
        if isOn || hover || down { return M.inkBright }
        return M.inkMid
    }

    private func fill(_ down: Bool) -> Color {
        if disabled { return .clear }
        if down { return M.high }
        if isOn { return M.high }
        return hover ? M.raised : .clear
    }

    private func border(_ down: Bool) -> Color {
        if disabled { return M.line }
        if down { return M.inkBright }
        return (isOn || hover) ? M.lineStrong : M.line
    }
}

/// A bare glyph with a hit area: the row's archive control, the walk's arrows,
/// the summary's chevron, the gear at the end of the app bar.
struct IconKey: View {
    let icon: IconName
    let label: String
    var help: String?
    var disabled = false
    var tone: Color?
    var on: Bool?
    let action: () -> Void

    @State private var hover = false

    private var isOn: Bool { on == true }

    var body: some View {
        Button(action: action) {
            Pressed { down in
                Icon(name: icon, size: 14)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(ink(down))
                    .background(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                        .fill(fill(down)))
                    .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                        .strokeBorder(border(down), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: M.rSm, style: .continuous))
            }
        }
        .buttonStyle(HTPressStyle())
        .disabled(disabled)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    private func ink(_ down: Bool) -> Color {
        if disabled { return M.lineStrong }
        if let tone { return tone }
        if isOn || hover || down { return M.inkBright }
        return M.inkMid
    }

    private func fill(_ down: Bool) -> Color {
        if disabled { return .clear }
        if isOn || down { return M.high }
        return hover ? M.high : .clear
    }

    /// This one hovers straight to the top plate -- a bare glyph has no frame
    /// to raise -- so the plate has nowhere left to step and the edge carries
    /// the press on its own.
    private func border(_ down: Bool) -> Color {
        if disabled { return .clear }
        if down { return M.inkBright }
        return (isOn || hover) ? M.lineStrong : .clear
    }
}

enum KeyVariant {
    case standard
    /// No frame at all. For the controls that are a way out rather than an act
    /// -- close, cancel, keep mine.
    case quiet
    /// Cyan, filled, and the only one in the app.
    case send
}

/// The switch: a bordered button with a word on it.
struct KeyButton<Content: View>: View {
    var variant: KeyVariant = .standard
    var icon: IconName?
    var disabled = false
    var help: String?
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Pressed { down in
                HStack(spacing: 6) {
                    if let icon { Icon(name: icon, size: 14) }
                    content()
                }
                .font(Face.body)
                .foregroundStyle(ink(down))
                .padding(.horizontal, variant == .quiet ? 8 : 13)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                    .fill(fill(down)))
                .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                    .strokeBorder(border(down), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: M.rSm, style: .continuous))
            }
        }
        .buttonStyle(HTPressStyle())
        .disabled(disabled)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .ifLet(help) { view, text in view.help(text) }
    }

    private func ink(_ down: Bool) -> Color {
        // The one filled cyan in the app takes the ground as its ink, and does
        // not brighten under the cursor: it is already the loudest thing here.
        if variant == .send { return M.ground }
        if disabled { return M.lineStrong }
        return (hover || down) ? M.inkBright : M.inkMid
    }

    private func fill(_ down: Bool) -> Color {
        // Cyan is spent twice in this app and a shade of it would be a third
        // spend, so the send key alone carries its press on the edge.
        if variant == .send { return M.select }
        if disabled { return .clear }
        if down { return M.high }
        return hover ? M.raised : .clear
    }

    private func border(_ down: Bool) -> Color {
        if variant == .send { return down ? M.inkBright : M.select }
        if variant == .quiet { return down ? M.lineStrong : .clear }
        if disabled { return M.line }
        if down { return M.inkBright }
        return hover ? M.lineStrong : M.line
    }
}

extension KeyButton where Content == Text {
    init(_ title: String, variant: KeyVariant = .standard, icon: IconName? = nil,
         disabled: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.init(variant: variant, icon: icon, disabled: disabled, help: help,
                  action: action) { Text(title) }
    }
}

// MARK: - small helpers

extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?,
                                 @ViewBuilder transform: (Self, T) -> Content) -> some View {
        if let value { transform(self, value) } else { self }
    }
}

/// The rule with a word on it: "draft it", "send it".
struct LabelledRule: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text.uppercased())
                .font(Face.body)
                .tracking(1.1)
                .foregroundStyle(M.inkDim)
                .fixedSize()
            Hairline()
        }
        .padding(.top, 16)
    }
}

/// One dim line. The app's most common piece of furniture.
struct Note: View {
    let text: String
    var top: CGFloat = 8

    var body: some View {
        Text(text)
            .font(Face.body)
            .foregroundStyle(M.inkDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
    }
}
