import SwiftUI

/* The mail dialect's palette, geometry and face.
 *
 * Every value here is one of the console's own tokens from the design
 * system's token sheet, re-declared under the local name
 * `mail.css` gives it. Nothing in this app writes a colour anywhere else, which
 * is what keeps the palette from drifting by accident.
 *
 * The meanings hold:
 *   green   nominal, and the app's primary accent (unread, live)
 *   amber   caution      (stale, urgency 2)
 *   red     fault        (failed, urgency 3)
 *   cyan    selection    -- spent EXACTLY twice in the whole app: the selected
 *                           row's inset rail, and CONFIRM SEND.
 */

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

enum M {

    // MARK: - ground and surfaces
    // The console's deep blue-gray and its three raised surfaces. A card is one
    // step off the ground, a chip two, a selected row two and a rail.
    //
    // The ground is painted once, by the window's own backdrop, over a blur of
    // whatever is behind the window -- so the mail tab's panes hand it straight
    // through rather than filling it again. `ground` is still spent inside the
    // cards: a text well recessed into an opaque surface has to be a real
    // colour, or it would be the surface with a border drawn round it.
    //
    // **The preference in this file.** Which ground family these six -- and the
    // three inks below -- come out of is chosen in Settings, so they read
    // `Ground.current` rather than stating a hex: the same cache the console
    // dialect reads, under the local names `mail.css` gives them. A reader on
    // one ground and a console page on another would be two apps in one window,
    // and a reader whose ink was measured against a ground it is no longer
    // printed on would be the same mistake one layer down.

    static var ground: Color { Ground.current.void }       // --ht-void
    static var surface: Color { Ground.current.surface2 }  // --ht-surface-2
    static var raised: Color { Ground.current.surface3 }   // --ht-surface-3
    static var high: Color { Ground.current.surface4 }     // --ht-surface-4

    // MARK: - edges

    static var line: Color { Ground.current.lineFaint }  // --ht-line-faint
    static var lineStrong: Color { Ground.current.line }  // --ht-line

    // MARK: - ink
    //
    // The same three steps the console reads, under the mail names. `M.inkDim`
    // is the console's `inkDim` and not the ANSI grey it used to be spelled as:
    // it is running text in a reader, so it is held to the ramp's 3.8:1 floor
    // like every other reading colour. The contract is stated once, over the ink
    // block in `HT.swift`.

    static var ink: Color { Ground.current.ink }
    static let inkBright = Color(hex: 0xffffff)  // --ht-c15
    static var inkMid: Color { Ground.current.inkMid }
    static var inkDim: Color { Ground.current.inkDim }

    // MARK: - meaning

    static let accent = Color(hex: 0x7ee07e)   // --ht-nominal
    static let caution = Color(hex: 0xffcc55)  // --ht-caution
    static let fault = Color(hex: 0xff5f4f)    // --ht-fault
    /// Selection. Two call sites in the entire app and no more.
    static let select = Color(hex: 0x5fdede)   // --ht-signal
    /// The console's focus ring is blue and only ever means focus.
    static let focus = Color(hex: 0x6fb0ff)    // --ht-c12

    static let cautionWash = Color(hex: 0xffcc55).opacity(0.12)
    static let faultWash = Color(hex: 0xff5f4f).opacity(0.12)

    // MARK: - geometry
    // Three radii and a pill, and nothing between them.

    static let rSm: CGFloat = 6
    static let r: CGFloat = 10
    static let rLg: CGFloat = 12
    static let rPill: CGFloat = 999

    // MARK: - motion
    // Colour only, 120ms. Nothing in this app moves, grows or eases into place.

    static let move: Animation = .easeInOut(duration: 0.12)

    // MARK: - the avatar

    static let avatarS: Double = 0.16
    static let avatarBgL: Double = 0.23
    static let avatarFgL: Double = 0.76
}

/// The face, resolved once.
///
/// Departure Mono is a bitmap face whose advance is exactly 7/11 of its size,
/// so it lands on whole pixels only at multiples of 11 -- which is why this app
/// is set at 11 and 22 and nothing between, and why the sizes are fixed rather
/// than scaled by Dynamic Type. Menlo is the fallback if the bundled font
/// failed to register, so the app is still monospaced when it is not itself.
enum Face {
    static let name: String = {
        for candidate in ["DepartureMono-Regular", "Departure Mono", "DepartureMono"] {
            if NSFont(name: candidate, size: 11) != nil { return candidate }
        }
        return "Menlo"
    }()

    static let registered: Bool = name != "Menlo"

    /// 11px: everything.
    static var body: Font { .custom(name, fixedSize: 11) }
    /// 22px: a subject, and nothing else.
    static var title: Font { .custom(name, fixedSize: 22) }

    static func at(_ size: CGFloat) -> Font { .custom(name, fixedSize: size) }

    /// The same face, as AppKit reports it.
    ///
    /// Two text systems set this console and only one of them can be asked how
    /// wide a glyph is. `TagBox` asks -- a registered tag's `@` is pulled back
    /// by exactly its own advance -- and the composer's field is set from here
    /// too, so the measurement and the type it is measured off cannot come from
    /// two different resolutions of the same name.
    static func ns(_ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - hsl

extension Color {
    /// The avatar's only constructor. Hue in degrees, s and l as 0…1.
    init(hue360: Double, s: Double, l: Double) {
        let h = hue360.truncatingRemainder(dividingBy: 360) / 360
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch Int(h * 6) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: 1)
    }
}

// MARK: - small shared shapes

/// A hairline. The console draws rules as text weight, not as a border, so this
/// is one physical pixel wherever it lands.
struct Hairline: View {
    var color: Color = M.line
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

struct VHairline: View {
    var color: Color = M.line
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
    }
}
