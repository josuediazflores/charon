import Foundation

/* What this copy of the app is pointed at, and how it behaves.
 *
 * The three behaviour switches are constants in v1, set to the web's own
 * defaults. They are named and read from the views that obey them rather than
 * inlined, so the day they grow a control there is one place for it to land.
 */

enum AfterArchive: String {
    /// On to the next message. The last message in the inbox ends on the list
    /// under either answer, because there is nothing behind it to advance to.
    case next
    case inbox
}

enum ConsoleFeature: String, CaseIterable {
    case cmo, mail, messages, chat, jarvis
}

/* The console's own preferences, ported from `state/mailSettings.ts`'s
 * `charon-settings-v1` blob.
 *
 * **One object, observed.** Phase A read these as static computed properties,
 * which was right while nothing wrote them: the Settings tab was a placeholder
 * and every value was the web's own default. Now the page writes them, and a
 * static read is a value SwiftUI has no way to notice changing -- flipping the
 * scanlines would leave the overlay exactly where it was until something else
 * happened to repaint the shell.
 *
 * Defaults are applied per field, so a stored preference missing one still
 * answers for the rest. They live in `UserDefaults` on this Mac and never reach
 * the Pi, on purpose: a 900pt window on a laptop and a 2000pt one on the desk
 * want different answers to most of these, and a preference synced between them
 * would force one of the two to be wrong.
 */
@MainActor
@Observable
final class ConsoleSettings {

    /// One instance. These are facts about this copy of the app, and two
    /// objects reading the same defaults would be two answers to a question
    /// with one.
    static let shared = ConsoleSettings()

    // Store only opt-outs so existing installations and new features start enabled.
    private(set) var disabledFeatures: Set<ConsoleFeature> {
        didSet {
            UserDefaults.standard.set(disabledFeatures.map(\.rawValue).sorted(),
                                      forKey: "disabledFeatures")
        }
    }

    func isEnabled(_ feature: ConsoleFeature) -> Bool {
        !disabledFeatures.contains(feature)
    }

    func setEnabled(_ enabled: Bool, for feature: ConsoleFeature) {
        if enabled {
            disabledFeatures.remove(feature)
        } else {
            disabledFeatures.insert(feature)
        }
    }

    func isTabAvailable(_ id: String) -> Bool {
        if let feature = ConsoleFeature(rawValue: id) { return isEnabled(feature) }
        return ConsoleNav.ids.contains(id)
    }

    var availableTabs: [SidebarItemSpec] {
        ConsoleNav.items.filter { isTabAvailable($0.id) }
    }

    /// The rail steps aside while a mail message is open. On a narrow pane 200
    /// points of navigation is half the viewport; on a wide one it is 200
    /// points nobody misses, so the answer is a preference rather than a rule.
    var railCollapse: Bool { didSet { write("railCollapse", railCollapse) } }

    /// Whether line three of a mail row is drawn at all.
    var rowNote: Bool { didSet { write("rowNote", rowNote) } }

    /// Where a message's summary panel starts, once, per message.
    var summaryOpen: Bool { didSet { write("summaryOpen", summaryOpen) } }

    /// Where a message goes once it is filed.
    var afterArchive: AfterArchive {
        didSet { UserDefaults.standard.set(afterArchive.rawValue, forKey: "afterArchive") }
    }

    /// Where a cold start lands. Validated against the rail's own list on read,
    /// so a tab that has since been cut opens on Overview rather than nowhere.
    var landingTab: String {
        didSet { UserDefaults.standard.set(landingTab, forKey: "landingTab") }
    }

    /// Whether the CHARON block at the head of the Messages column is folded
    /// shut. Open out of the box: the summaries are the point of the tab, and
    /// a fold that started closed would hide the one thing nothing else says.
    var messagesCharonCollapsed: Bool {
        didSet { write("messagesCharonCollapsed", messagesCharonCollapsed) }
    }

    /// The id of the pinned Charon conversation.
    ///
    /// A preference rather than a constant because it names a record on the Pi:
    /// clearing the thread mints a new one, and the tab has to be able to point
    /// at it afterwards. Never empty -- an empty id would be a route to the
    /// whole chat list.
    var messagesAgentThreadId: String {
        didSet {
            UserDefaults.standard.set(messagesAgentThreadId, forKey: "messagesAgentThreadId")
        }
    }

    /// The CRT overlay. Off, because it costs contrast the ink ramp has already
    /// spent.
    var scanlines: Bool { didSet { write("scanlines", scanlines) } }

    /// How strongly the picture behind the window is printed. Zero is no
    /// picture at all.
    ///
    /// **Why this is a level and not a switch.** The picture stands where the
    /// desktop stands, and the first build of it leaned on that: the wash was
    /// already over the desktop, so surely it was enough over a picture too.
    /// It is not, and the reason is that the thing it replaces is *blurred*.
    /// What `underWindowBackground` puts behind this window has almost no local
    /// contrast left in it, and the ink ramp was measured against exactly that.
    /// A sharp picture is the opposite: it carries hard edges at full contrast
    /// straight under the type, and at the wash this console ships with, a lit
    /// forearm across the rail took the rail's own labels with it.
    ///
    /// So the strength is the reader's, on the same 0.05 track the wash uses,
    /// and it is deliberately not solved for them: where it lands is a matter
    /// of which picture, which ground and which window, and the honest control
    /// for a question with four inputs is the one you can watch while you move
    /// it.
    ///
    /// The default out of the box was picked by looking at it rather than
    /// derived. Under the ground this console ships on, the picture is plainly
    /// a picture at this level and nothing on the page has given up any
    /// contrast for it -- the rail still reads, the figures still read. Half
    /// again as much is where the top bar starts to compete.
    var backdrop: Double {
        didSet { UserDefaults.standard.set(backdrop, forKey: "backdrop") }
    }

    /// The floor and ceiling on that strength. Unlike the wash, this one has no
    /// floor worth defending: zero is not an illegible console, it is the
    /// console this app had before the picture, and it is what the bottom of
    /// the track is for.
    static let backdropRange: ClosedRange<Double> = 0.0...1.00

    /// How much of the blur behind the window the ground's wash leaves
    /// showing, as the wash's own opacity: 1.00 is an opaque console, and the
    /// floor is half of one.
    ///
    /// **There is a floor, and it is not zero.** Every line on this page is
    /// ink on the wash, and a wash thin enough to read the desktop through
    /// takes the figures with it -- so the range is stated once, here, and
    /// applied on read as well as by the control, because a preference written
    /// by hand is a preference this app still has to be legible under.
    var groundOpacity: Double {
        didSet { UserDefaults.standard.set(groundOpacity, forKey: "groundOpacity") }
    }

    /// The floor and ceiling on that wash.
    static let groundRange: ClosedRange<Double> = 0.50...1.00

    /// Which ground family the wash, the surfaces and the rules come out of,
    /// as a `GroundFamily` raw value. Held as a string rather than as the enum
    /// because that is what goes in and comes out of `UserDefaults`, and a
    /// preference written by an older -- or a newer -- build has to be readable
    /// as whatever it happens to say.
    ///
    /// The `didSet` is the only writer of the token cache in the whole app. The
    /// repaint is not here: this object knows what the ground is, and the shell
    /// is the only thing that knows what is currently drawn on it.
    var groundFamily: String {
        didSet {
            UserDefaults.standard.set(groundFamily, forKey: "groundFamily")
            Ground.use(GroundFamily(rawValue: groundFamily) ?? .fallback)
        }
    }

    /// The same answer, validated, for the control and for the window chrome.
    /// Reading this reads `groundFamily`, so a view that asks is a view that
    /// gets told when it moves.
    var ground: GroundFamily {
        GroundFamily(rawValue: groundFamily) ?? .fallback
    }

    /// What stands in the Overview masthead's identity slot, as a
    /// `MastheadArt` raw value. Held as a string for the same reason
    /// `groundFamily` is: that is what goes in and comes out of `UserDefaults`,
    /// and a preference written by an older -- or a newer -- build has to be
    /// readable as whatever it happens to say.
    ///
    /// **No repaint here.** The ground's `didSet` has to prime a token cache
    /// nothing observes; this is read straight out of the object by the view
    /// that draws the slot, so ordinary observation carries it and there is
    /// nothing to bump.
    var mastheadArt: String {
        didSet { UserDefaults.standard.set(mastheadArt, forKey: "mastheadArt") }
    }

    /// The same answer, validated, for the control and for the slot.
    var masthead: MastheadArt {
        MastheadArt(rawValue: mastheadArt) ?? .fallback
    }

    /// How wide that art is drawn, in character cells.
    ///
    /// Cells rather than points, because everything in the slot is set on the
    /// character grid: the ascii arts are rendered at exactly this many
    /// columns, and a picture is scaled to the same width so the two kinds of
    /// art are the same size at the same number.
    var mastheadCols: Int {
        didSet { UserDefaults.standard.set(mastheadCols, forKey: "mastheadCols") }
    }

    /// The floor and ceiling on that width.
    ///
    /// Fourteen is the narrowest an ascii sphere still reads as one -- it is
    /// nine rows -- and forty-two is where the art column plus the 52-cell
    /// identity column stops fitting in the 720 the masthead collapses at.
    static let mastheadColRange: ClosedRange<Int> = 14...42

    /// The imported picture's filename inside this app's Application Support
    /// container, or nil for none picked. A name, not a path -- see
    /// `MastheadImage`.
    var mastheadImageFile: String? {
        didSet {
            let d = UserDefaults.standard
            if let name = mastheadImageFile, !name.isEmpty {
                d.set(name, forKey: "mastheadImageFile")
            } else {
                d.removeObject(forKey: "mastheadImageFile")
            }
        }
    }

    private init() {
        let disabled = UserDefaults.standard.stringArray(forKey: "disabledFeatures") ?? []
        disabledFeatures = Set(disabled.compactMap(ConsoleFeature.init(rawValue:)))
        railCollapse = ConsoleSettings.flag("railCollapse", default: true)
        rowNote = ConsoleSettings.flag("rowNote", default: true)
        summaryOpen = ConsoleSettings.flag("summaryOpen", default: true)
        afterArchive = AfterArchive(
            rawValue: UserDefaults.standard.string(forKey: "afterArchive") ?? "") ?? .next
        let want = UserDefaults.standard.string(forKey: "landingTab") ?? "overview"
        landingTab = ConsoleNav.ids.contains(want) ? want : "overview"
        messagesCharonCollapsed = ConsoleSettings.flag("messagesCharonCollapsed",
                                                       default: false)
        let agent = UserDefaults.standard.string(forKey: "messagesAgentThreadId") ?? ""
        messagesAgentThreadId = agent.isEmpty ? "messages-agent" : agent
        scanlines = ConsoleSettings.flag("scanlines", default: false)
        backdrop = ConsoleSettings.level("backdrop", default: 0.60,
                                         in: ConsoleSettings.backdropRange)
        groundOpacity = ConsoleSettings.wash("groundOpacity", default: HT.groundOpacity)
        // Validated by the same reader the token cache initialises itself from,
        // so the two cannot disagree about what this Mac chose -- and a raw
        // value this build has no case for lands on the default here rather
        // than being written back out as itself.
        groundFamily = GroundFamily.stored.rawValue
        mastheadArt = MastheadArt.stored.rawValue
        mastheadCols = ConsoleSettings.cols("mastheadCols", default: 27)
        // Empty is nil: a preference written by hand as "" is nobody's picture.
        let picture = UserDefaults.standard.string(forKey: "mastheadImageFile")
        mastheadImageFile = (picture?.isEmpty ?? true) ? nil : picture
    }

    /// The validated landing tab, for a cold start.
    var landing: String {
        isTabAvailable(landingTab) ? landingTab : "overview"
    }

    private func write(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// `UserDefaults.bool` reads a missing key as false, which would make every
    /// default here false by accident. The presence of the key is the question.
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    /// The same question for the wash, and the clamp with it: `double` reads a
    /// A level read back inside its own range. Same shape as `wash` and
    /// separate from it because the two ranges are different facts: the wash
    /// has a floor that keeps the figures legible, and this one starts at the
    /// off position.
    private static func level(_ key: String, default fallback: Double,
                              in range: ClosedRange<Double>) -> Double {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, d.double(forKey: key)))
    }

    /// missing key as zero, and a zero here would be a window with nothing in
    /// it but blur.
    private static func wash(_ key: String, default fallback: Double) -> Double {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return fallback }
        return min(groundRange.upperBound, max(groundRange.lowerBound, d.double(forKey: key)))
    }

    /// And again for the art's width. Clamped on read as well as by the
    /// control: a hand-written 400 here is four hundred columns of ascii
    /// sphere rendered per frame, which is a preference this app has to
    /// survive rather than obey.
    private static func cols(_ key: String, default fallback: Int) -> Int {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return fallback }
        return min(mastheadColRange.upperBound,
                   max(mastheadColRange.lowerBound, d.integer(forKey: key)))
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case demo, live
    var id: String { rawValue }
    var label: String { self == .demo ? "Demo" : "Live" }
}

/// Address and mode live in preferences; the token never does -- see
/// `TokenStore`.
struct Connection {
    static let defaultBase = "http://100.64.0.2:8788"

    var mode: Mode
    var baseURL: String
    var token: String

    static func load() -> Connection {
        let d = UserDefaults.standard
        return Connection(
            mode: Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .demo,
            baseURL: d.string(forKey: "baseURL") ?? defaultBase,
            token: TokenStore.read()
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "mode")
        d.set(baseURL, forKey: "baseURL")
        TokenStore.write(token)
    }

    var url: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))
    }
}
