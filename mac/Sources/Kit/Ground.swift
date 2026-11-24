import SwiftUI

/* The colour under everything, as five answers instead of one.
 *
 * The console was built on one ground -- a deep blue-gray -- and every other
 * colour in the system was chosen against it. This file is the seam that lets
 * that one ground move, and it draws the line at what has to move with it:
 * everything read *on* the paper, and nothing else.
 *
 * **A family, not a colour.** A ground is never a single fill: it is the wash,
 * the three raised surfaces a card, a chip and a lit row stand on, the three
 * rules that separate them, and the four inks that are read on top of them.
 * Change the wash on its own and the surfaces stop being one step, two steps and
 * three steps off it -- a panel would read as a patch rather than as a plane --
 * and the ink stops clearing the floor it was measured against. So a preset
 * states all eleven, and the eleven move together or not at all.
 *
 * **The ink is part of the family, and that is a reversal.** It used to be
 * global, on the theory that a preset which retinted the ink would be a theme
 * and a theme is a second design system to keep honest. One ramp cannot hold:
 * these washes are 12 luminance points apart before the window's own
 * transparency is counted, and a secondary label that clears the floor on void
 * black is unreadable on pine at a 0.50 wash. So each family carries its own
 * four, tinted to its hue and measured against its own void -- see the contract
 * over the ink block in `HT.swift`.
 *
 * **What still does not move.** The ANSI sixteen, the semantic tones and the
 * cyan that means selection are the same values under every family. Those are
 * the vocabulary this console prints in; the ground is the paper and the ink is
 * what the paper takes.
 *
 * **Two dialects, one family.** `HT` is the tty dialect and `M` is the mail
 * dialect, and each names these eleven colours differently -- `M.raised` is
 * `HT.surface3`, `M.line` is `HT.lineFaint`. Both read this file, so a family
 * cannot come out consistent on the console pages and wrong in the reader, and
 * a ramp measured for legibility here cannot be legible on only one of them.
 *
 * **Read through a cache, written once.** The tokens are computed properties
 * over `Ground.current`, so a switch is one struct assignment rather than a walk
 * over every call site. What that does NOT buy is a repaint: a view that reads
 * `HT.surface3` has no dependency SwiftUI can see, which is why the shell
 * re-identifies its content on the family -- see the `.id` in ConsoleShellView.
 */

/// One ground family, resolved. The wash, its three surfaces, its three rules
/// and its four inks.
///
/// The mask is the wash again, opaque, and is not a separate field: a mask that
/// could drift from the ground it is masking would be visible as a patch the
/// moment it did. `inkBright` is not a field either, for the opposite reason: it
/// is white, it is white on every family, and a per-family white would be four
/// off-whites nobody asked for.
struct GroundPalette {
    let void: Color
    let surface2: Color
    let surface3: Color
    let surface4: Color
    let lineFaint: Color
    let line: Color
    let lineBright: Color
    let ink: Color
    let inkMid: Color
    let inkDim: Color
    let inkFaint: Color

    /// Written in hex, because that is how the design system writes them and a
    /// preset is easier to check against a stylesheet than against a decimal.
    init(void: UInt32, surface2: UInt32, surface3: UInt32, surface4: UInt32,
         lineFaint: UInt32, line: UInt32, lineBright: UInt32,
         ink: UInt32, inkMid: UInt32, inkDim: UInt32, inkFaint: UInt32) {
        self.void = Color(hex: void)
        self.surface2 = Color(hex: surface2)
        self.surface3 = Color(hex: surface3)
        self.surface4 = Color(hex: surface4)
        self.lineFaint = Color(hex: lineFaint)
        self.line = Color(hex: line)
        self.lineBright = Color(hex: lineBright)
        self.ink = Color(hex: ink)
        self.inkMid = Color(hex: inkMid)
        self.inkDim = Color(hex: inkDim)
        self.inkFaint = Color(hex: inkFaint)
    }
}

/// The five grounds this console offers, and no sixth by way of a colour well.
///
/// Curated rather than free: every one of these was built as a ramp, with the
/// surfaces spaced far enough apart to separate under its own ink and close
/// enough not to read as boxes. A wheel would let somebody pick a ground the
/// figures cannot be read on -- there would be no ink solved for it -- and the
/// wash slider already owns the one axis where that trade is worth offering.
enum GroundFamily: String, CaseIterable, Identifiable {
    /// The console's own. Deep blue-gray, and what every other colour in the
    /// system was picked against.
    case blueGray
    /// The original: true black, before the ground took its blue.
    case voidBlack
    case graphite
    case plum
    case pine

    var id: String { rawValue }

    /// What the setting calls it. Lowercase, like every other answer on that
    /// page.
    var label: String {
        switch self {
        case .blueGray: return "blue gray"
        case .voidBlack: return "void black"
        case .graphite: return "graphite"
        case .plum: return "deep plum"
        case .pine: return "pine"
        }
    }

    /// The eleven, stated.
    ///
    /// The four inks are not eyeballed: each was solved for the smallest colour
    /// at that family's hue whose WCAG contrast on that family's **lightened**
    /// void clears the floor in the contract -- 7.0, 5.0, 3.8, 2.3 -- and the
    /// hexes below are what came back. Nudging one by hand is how a family ends
    /// up a tenth under the floor it is supposed to be the proof of; re-solve
    /// the ramp instead.
    var palette: GroundPalette {
        switch self {
        case .blueGray:
            return GroundPalette(void: 0x131722, surface2: 0x191e2b,
                                 surface3: 0x232a3a, surface4: 0x2e3648,
                                 lineFaint: 0x252b39, line: 0x3e4557,
                                 lineBright: 0x5a6379,
                                 ink: 0xbec1c7, inkMid: 0x9fa3ae,
                                 inkDim: 0x868d9e, inkFaint: 0x61697e)
        case .voidBlack:
            return GroundPalette(void: 0x000000, surface2: 0x0d0d0d,
                                 surface3: 0x1c1c1c, surface4: 0x2a2a2a,
                                 lineFaint: 0x232323, line: 0x3a3a3a,
                                 lineBright: 0x5c5c5c,
                                 ink: 0xa9a9a9, inkMid: 0x8e8e8e,
                                 inkDim: 0x7a7a7a, inkFaint: 0x585858)
        case .graphite:
            return GroundPalette(void: 0x171818, surface2: 0x1e1f1f,
                                 surface3: 0x242424, surface4: 0x2e2e2e,
                                 lineFaint: 0x262626, line: 0x404040,
                                 lineBright: 0x5e5e5e,
                                 ink: 0xc2c2c2, inkMid: 0xa4a4a4,
                                 inkDim: 0x8e8e8e, inkFaint: 0x6a6a6a)
        case .plum:
            return GroundPalette(void: 0x171320, surface2: 0x1e1929,
                                 surface3: 0x292338, surface4: 0x342d47,
                                 lineFaint: 0x2a2438, line: 0x443c58,
                                 lineBright: 0x655c7c,
                                 ink: 0xbfbdc5, inkMid: 0xa39eae,
                                 inkDim: 0x8f879f, inkFaint: 0x6c6380)
        case .pine:
            return GroundPalette(void: 0x101814, surface2: 0x16201b,
                                 surface3: 0x1f2b25, surface4: 0x283630,
                                 lineFaint: 0x22302a, line: 0x3a4c44,
                                 lineBright: 0x566e63,
                                 ink: 0xb9c2be, inkMid: 0x95a79e,
                                 inkDim: 0x789385, inkFaint: 0x556e61)
        }
    }

    /// The one out of the box.
    static let fallback: GroundFamily = .graphite

    /// The five names, in declaration order, for the listbox.
    static let labels: [String] = allCases.map(\.label)

    /// The family a name belongs to. The control can only hand back one of its
    /// own options, but this is nil-returning anyway: a listbox that grows a
    /// sixth name somebody forgot to add a case for should do nothing rather
    /// than land on the first one.
    static func named(_ label: String) -> GroundFamily? {
        allCases.first { $0.label == label }
    }

    /// What this Mac last chose, validated. Read here rather than only in
    /// `ConsoleSettings` so the cache below is right on the very first token
    /// read, whenever that happens relative to the settings object being built.
    static var stored: GroundFamily {
        GroundFamily(rawValue: UserDefaults.standard.string(forKey: "groundFamily") ?? "")
            ?? fallback
    }
}

/// The family in force, and its palette, cached.
///
/// `nonisolated(unsafe)` and not a lock: this is written from exactly one place
/// -- the settings object's `didSet`, on the main actor -- and read from view
/// bodies and from `NSColor`, which are on the main actor too.
enum Ground {

    private(set) nonisolated(unsafe) static var family: GroundFamily = GroundFamily.stored

    private(set) nonisolated(unsafe) static var current: GroundPalette = GroundFamily.stored.palette

    /// Switch the ground. Repainting what is already on screen is the shell's
    /// job, not this function's -- see `ConsoleShellView`.
    static func use(_ next: GroundFamily) {
        family = next
        current = next.palette
    }
}
