import AppKit
import CryptoKit
import SwiftUI

/* The Messages tab's own small parts: where it can be, what time it says, and
 * the four shapes the three boards are made of.
 *
 * **This tab lives in the mail dialect** -- cards, radii, avatars, `Face`, `M`
 * -- and not in the console's tty. That is the documented exception and this is
 * the second room inside it, which is why every piece here is a step off a
 * `MailKit` shape rather than a new idea: the disc is `Avatar`'s geometry with a
 * sparkle in it, the verb row is a borderless `IconKey`, the run is a `Card`'s
 * edge at a sentence's size.
 *
 * **Cyan is spent exactly where the mail app spends it**: the selected row's
 * rail, and the send button. Nothing else in this tab is allowed a hue.
 */

/// Where the tab is. `nil` is the empty pane, which only the narrow layout can
/// actually be in.
///
/// Not to be confused with `MessageRoute`, which guards the URLs.
enum MessagesRoute: Equatable {
    case chat(String)
    /// The pinned conversation with Charon. A place rather than an id: which
    /// thread it is, is a preference.
    case agent
}

// MARK: - time

/// What a row and a run say the clock is.
///
/// Today is a time, yesterday is a word, the last week is a weekday and
/// anything older is a date. The same ladder the Messages app itself climbs,
/// and the reason the list can be read without doing arithmetic.
enum MsgTime {

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    static func when(_ iso: String?, now: Date = Date()) -> String {
        guard let at = Fmt.date(iso) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(at) { return Fmt.hhmm(iso) }
        if cal.isDateInYesterday(at) { return "yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: at),
                                         to: cal.startOfDay(for: now)).day, days < 7 {
            return weekday.string(from: at)
        }
        return shortDate.string(from: at)
    }

    // ── the transcript's separators ──
    //
    // Three formatters of their own, pinned to `en_US_POSIX` with literal
    // patterns rather than to the locale's templates. Every other clock in this
    // app is the console's 24-hour `Fmt.hhmm`; these three are the one place a
    // person reads a transcript the way a phone draws one, and the board spells
    // the strings out: `Today 1:51 PM`, `Yesterday 9:12 AM`, `Tuesday 4:20 PM`,
    // `Aug 3, 2:15 PM`.

    private static let clock12: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let longWeekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// `1:51 PM`.
    static func clockWord(_ at: Date) -> String { clock12.string(from: at) }

    /// What stands in front of the clock on a separator that names a day:
    /// `Today`, `Yesterday`, a weekday inside the week, and a date with its own
    /// comma past it.
    static func dayLabel(_ at: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "Today" }
        if cal.isDateInYesterday(at) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: at),
                                         to: cal.startOfDay(for: now)).day,
           days < 7 {
            return longWeekday.string(from: at)
        }
        return monthDay.string(from: at) + ","
    }

    /// The same ladder in the summary list's own lowercase voice, off a
    /// `YYYY-MM-DD` rather than off a stamp: `today`, `yesterday`, `tue`.
    static func dayWord(_ date: String, now: Date = Date()) -> String {
        guard let at = day(date) else { return date }
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "today" }
        if cal.isDateInYesterday(at) { return "yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: at),
                                         to: cal.startOfDay(for: now)).day, days < 7 {
            return weekday.string(from: at).lowercased()
        }
        return shortDate.string(from: at).lowercased()
    }

    /// The same word with a capital, for the head of the document.
    static func dayTitle(_ date: String, now: Date = Date()) -> String {
        let word = dayWord(date, now: now)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// `Thursday 21 August` for the sub-line under it.
    static func longDay(_ date: String) -> String {
        guard let at = day(date) else { return date }
        return Fmt.longDate(at)
    }

    /// A local midnight from a `YYYY-MM-DD`. Built from the parts rather than
    /// parsed as an instant, which is UTC and names the wrong day every evening.
    static func day(_ date: String) -> Date? {
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// Whether two stamps fall on the same local day, for the transcript's rules.
    static func sameDay(_ a: String?, _ b: String?) -> Bool {
        guard let x = Fmt.date(a), let y = Fmt.date(b) else { return a == nil && b == nil }
        return Calendar.current.isDate(x, inSameDayAs: y)
    }
}

// MARK: - the mark

/// Charon's disc: `Avatar`'s geometry with a sparkle in it rather than
/// initials, because this is not a person.
///
/// One mark at four sizes -- the fold's header, a summary row, the pinned row,
/// and a run in the agent's transcript -- so the four places read as one thing
/// repeated rather than as four things.
struct SparkDisc: View {
    var side: CGFloat = 32
    var bright = false
    var dim = false

    var body: some View {
        Icon(name: .sparkle, size: side * 0.41)
            .foregroundStyle(dim ? M.inkDim : (bright ? M.inkBright : M.inkMid))
            .frame(width: side, height: side)
            .background(Circle().fill(M.raised))
            // The one addition over `Avatar`: a disc that is nearly the ground
            // needs an edge or it reads as a hole.
            .overlay(Circle().strokeBorder(M.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - the quiet verb

/// One verb under a thread head: a glyph, a lowercase word, no box.
///
/// There is nothing to press against here -- no walk, no toggle worth a frame
/// -- so `ActionKey`'s bordered cell would be three empty boxes around three
/// words. This is the treatment the app already gives text that is also a
/// control: dim ink that brightens under the cursor, and nothing else.
struct QuietAct: View {
    let icon: IconName
    let word: String
    var on = false
    var disabled = false
    var help: String?
    let action: () -> Void

    @State private var hover = false

    /// No plate to step and no edge to brighten, so the press is the one step
    /// this verb has left: past the ink it already brightens to under the
    /// cursor, to white.
    private func ink(_ down: Bool) -> Color {
        if disabled { return M.inkDim }
        if down { return M.inkBright }
        if on || hover { return M.ink }
        return M.inkDim
    }

    var body: some View {
        Button(action: action) {
            Pressed { down in
                HStack(spacing: 5) {
                    Icon(name: icon, size: 13)
                    Text(word)
                }
                .font(Face.body)
                .foregroundStyle(ink(down))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(HTPressStyle())
        .disabled(disabled)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .help(help ?? word)
        .accessibilityLabel(word)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The row those verbs stand in: flush left, ruled between the head above and
/// whatever is under it.
///
/// **Both rules, not one.** The row used to have a rule over it and nothing
/// under, so the transcript's scroll edge cut runs off directly beneath the
/// verb words -- a log that appeared to start in the middle of a sentence
/// wherever it happened to be scrolled to. The second rule is the floor those
/// runs pass behind.
struct QuietActs<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(spacing: 14) {
                content()
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
            .padding(.bottom, 9)
            Hairline()
        }
        .padding(.top, 9)
    }
}

// MARK: - the row

/// The list row every one of the three kinds is drawn in.
///
/// One anatomy, three fillings: the lead dot slot, a 32pt mark, a top line of
/// name, marks and time, and one preview line the row's own ellipsis cuts. A
/// summary and a chat are the same row with a different thing in the disc,
/// which is the whole reason the column reads as one list with a rule in it.
struct MessagesRow<Mark: View, Marks: View>: View {
    let name: String
    let preview: String
    let when: String
    var unread: Bool
    var selected: Bool
    var dim: Bool
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var marks: () -> Marks
    /// Reserved on every row whether or not it holds anything, so a row nobody
    /// is pointing at is exactly as wide as one they are.
    var act: AnyView?
    let open: () -> Void

    @State private var hover = false

    private var strong: Bool { unread && !dim }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if unread {
                            Circle()
                                .fill(dim ? M.inkMid : M.accent)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .frame(width: 12)
                    .padding(.top, 6)

                    mark()

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(name)
                                .font(Face.body)
                                .foregroundStyle(nameInk)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            marks()
                            Spacer(minLength: 4)
                            Text(when)
                                .font(Face.body)
                                .monospacedDigit()
                                .foregroundStyle(M.inkDim)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Text(preview)
                            .font(Face.body)
                            .foregroundStyle(previewInk)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                // One element, one label. See the note on `MailRow`: a label on
                // a container prepends itself to every element under it rather
                // than replacing them, and this row read its own sentence once
                // per leaf.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isButton)
            }
            .buttonStyle(.plain)

            Group { act }
                .frame(width: 26)
                .padding(.top, 10)
                .padding(.leading, 2)
                .padding(.trailing, 8)
                .opacity(hover ? 1 : 0)
                .animation(M.move, value: hover)
        }
        .background(
            RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .fill(selected ? M.raised : (hover ? M.surface : .clear))
        )
        // Cyan is selection in this console and it says nothing else; here it
        // is a rail rather than a wash, which leaves the send button the
        // loudest thing on the page. (Cyan, use 1 of 2.)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(M.select).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: M.r, style: .continuous))
        .animation(M.move, value: hover)
        .animation(M.move, value: selected)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    private var nameInk: Color {
        if dim { return strong ? M.inkMid : M.inkDim }
        return strong ? M.inkBright : M.inkMid
    }

    private var previewInk: Color {
        if dim { return M.inkDim }
        return strong ? M.ink : M.inkMid
    }

    private var spoken: String {
        var parts: [String] = []
        if unread { parts.append("unread") }
        parts.append(name)
        if !when.isEmpty { parts.append(when) }
        parts.append(preview)
        return parts.joined(separator: " · ")
    }
}

extension MessagesRow where Marks == EmptyView {
    init(name: String, preview: String, when: String, unread: Bool, selected: Bool,
         dim: Bool, @ViewBuilder mark: @escaping () -> Mark, act: AnyView? = nil,
         open: @escaping () -> Void) {
        self.init(name: name, preview: preview, when: when, unread: unread,
                  selected: selected, dim: dim, mark: mark, marks: { EmptyView() },
                  act: act, open: open)
    }
}

// MARK: - the transcript

/// What a bubble is made of. Four grounds, and the whole colour argument of
/// the log is in them.
///
/// Green is delivery in this console -- the foot says `live` in it and the
/// unread dot is drawn in it -- so a run that went through wears it and a run
/// that has not gone through yet does not. `failed` is not red: red means the
/// bridge is down, the state is already spelled out in words on the same row,
/// and a text that has to be pressed again has not earned a fault colour.
enum MsgTone {
    /// Theirs: the surface, with an edge.
    case inbound
    /// Yours, on a surface with no meaning attached -- the agent's own turns,
    /// which never travel and are never delivered.
    case mine
    /// Delivered: the accent at wash strength, and the ink one step up.
    case sent
    /// Not delivered: back to the raised surface, and the ink one step down.
    case failed

    var fill: Color {
        switch self {
        case .inbound: return M.surface
        case .mine, .failed: return M.raised
        // 22% of the accent over true black is `--m-raised`'s own lightness
        // carrying the accent's hue: the surface an outbound run already had,
        // plus the colour this app already means "this went through" by.
        case .sent: return M.accent.opacity(0.22)
        }
    }

    var ink: Color {
        switch self {
        case .inbound, .mine, .failed: return M.ink
        case .sent: return M.inkBright
        }
    }

    var edge: Color { self == .inbound ? M.line : .clear }
}

/// What happened to a run, beside the run: one dim word, and at most one word
/// you can press.
///
/// It stands in `.msg-when`'s own slot on the outer side of the bubble --
/// where this app already keeps one dim tabular span per outbound run -- so
/// this is not a new place for metadata, it is the place holding a different
/// fact. Under the bubble would have cost a line and invented a second
/// convention to pay for it.
struct MsgStatus: Equatable {
    /// `sending` · `sent` · `not delivered`.
    var word: String
    /// `undo` · `try again`, or nothing at all.
    var act: String?
}

/// The line itself. The act is the app's own treatment for text that is also a
/// control: no ground, no edge, mid ink, one step up under the cursor.
struct StatusLine: View {
    let status: MsgStatus
    var action: (() -> Void)?

    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(status.word)
                .font(Face.body)
                .foregroundStyle(M.inkDim)
            if let act = status.act {
                Text("·").font(Face.body).foregroundStyle(M.lineStrong)
                Button(action: { action?() }) {
                    Text(act)
                        .font(Face.body)
                        .foregroundStyle(hover ? M.inkBright : M.inkMid)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .animation(M.move, value: hover)
                .accessibilityLabel(act)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.bottom, 2)
    }
}

/// One run in a conversation.
///
/// Inbound on the left with the sender's small disc, outbound on the right in
/// the tone the send is currently worth -- which side of the pane it is on has
/// already said whose it is, so a border there would be saying it twice. The
/// clock is not here: it is in the separators between the groups, because a
/// time beside every line is a mail client's habit and a gap in time is the
/// only thing worth naming.
struct MsgRun<Lead: View>: View {
    let text: String
    /// The old per-run clock. Empty in the thread, which keeps its times in
    /// the separators; the pinned conversation still stamps every turn.
    var when: String = ""
    let outbound: Bool
    /// Nil takes the tone the side implies, which is what every caller that
    /// has nothing to say about delivery wants.
    var tone: MsgTone?
    /// How much of the log a run may NOT have, in points.
    ///
    /// The cap is stated as slack rather than as a width because that is the
    /// only way a bubble both hugs its sentence and wraps at a fraction of the
    /// log: a `frame(maxWidth:)` around a wrapping `Text` claims the whole
    /// width whatever is in it, and every run would come out the same size.
    /// The spacer's minimum is the cap, and the row's own flow does the rest.
    var slack: CGFloat = 160
    /// The accent dot the list draws at the head of an unread row, on the
    /// newest inbound run. One mark for one meaning, in two places.
    var unread = false
    /// What happened to this send, in the clock's old slot.
    var status: MsgStatus?
    var onStatusAct: (() -> Void)?
    @ViewBuilder var lead: () -> Lead
    /// Drawn inside the bubble, under the text.
    var tail: AnyView?
    /// An override for the bubble's ink; nil lets the tone decide. Dim for a
    /// stand-in -- a record that carried nothing at all -- so the words the
    /// sender did not write do not read as words the sender wrote.
    var textInk: Color? = nil

    private var shade: MsgTone { tone ?? (outbound ? .mine : .inbound) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if outbound {
                Spacer(minLength: max(24, slack))
                aside
                bubble
            } else {
                lead()
                bubble
                if unread {
                    Circle().fill(M.accent).frame(width: 7, height: 7)
                        .padding(.bottom, 8)
                        .accessibilityLabel("unread")
                }
                aside
                Spacer(minLength: max(24, slack))
            }
        }
        .frame(maxWidth: .infinity, alignment: outbound ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    /// The one slot on the outer side of a bubble, holding whichever of the
    /// two facts this run has: what happened to it, or when it was said.
    @ViewBuilder
    private var aside: some View {
        if let status {
            StatusLine(status: status, action: onStatusAct)
        } else if !when.isEmpty {
            Text(when)
                .font(Face.body)
                .monospacedDigit()
                .foregroundStyle(M.inkDim)
                .padding(.bottom, 2)
                .fixedSize()
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A bubble that holds only a photograph draws no line of text at
            // all. An empty `Text` is not nothing: it lays out its own line
            // box, and a picture with fourteen points of nothing over it reads
            // as a rendering fault rather than as a picture.
            if !text.isEmpty {
                Text(text)
                    .font(Face.body)
                    .foregroundStyle(textInk ?? shade.ink)
                    // The 16pt row, reached rather than declared: Departure
                    // Mono at 11pt lays out a 14pt line box, so 2 of leading
                    // makes the second line of a bubble land on the grid the
                    // rest of the app sits on.
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tail { tail.padding(.top, text.isEmpty ? 0 : 5) }
        }
        // 10 and 5 off the board, plus the 1pt its border occupies whether or
        // not this tone draws one: the box is 28pt tall on one line either way.
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
            .fill(shade.fill))
        .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
            .strokeBorder(shade.edge, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The disc's column, held open.
///
/// An outbound run has no disc, and an inbound one that is not last in its
/// group has not earned one, so both keep the gutter rather than closing it:
/// two consecutive runs that stepped sideways would read as two conversations.
struct MsgGutter: View {
    var body: some View { Color.clear.frame(width: 22, height: 1) }
}

extension MsgRun where Lead == MsgGutter {
    init(text: String, when: String = "", outbound: Bool, tone: MsgTone? = nil,
         slack: CGFloat = 160, unread: Bool = false, status: MsgStatus? = nil,
         onStatusAct: (() -> Void)? = nil, tail: AnyView? = nil,
         textInk: Color? = nil) {
        self.init(text: text, when: when, outbound: outbound, tone: tone,
                  slack: slack, unread: unread, status: status,
                  onStatusAct: onStatusAct, lead: { MsgGutter() }, tail: tail,
                  textInk: textInk)
    }
}

/// A gap in time, named. One centred dim line, no rule and no ground: a rule
/// across a transcript is a section break, and this is only a gap being named.
///
/// The first one sits at the head of the log and carries the day, so it does
/// not need the air a mid-stream one needs to read as a break rather than as a
/// caption on the run under it.
struct MsgSeparator: View {
    let word: String
    var first = false

    var body: some View {
        Text(word)
            .font(Face.body)
            .monospacedDigit()
            .foregroundStyle(M.inkDim)
            // The 16pt row again, stated rather than left to the face: the
            // separator is a line in the log and stands as tall as one.
            .frame(height: 16)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, first ? 0 : 9)
            .padding(.bottom, 5)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The way back to the bottom of a log you have scrolled up out of.
///
/// Anchored over the transcript on the right -- the side the send is on and
/// the side an outbound run is on, so the axis that means `now` is one axis.
/// Opaque, because there is no blur in this system and a translucent pill over
/// running text is unreadable.
struct NewMessagePill: View {
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("new message").font(Face.body).foregroundStyle(M.inkBright)
                Icon(name: .arrowDown, size: 12).foregroundStyle(M.inkMid)
            }
            // 12 off the board, plus the 1pt its border occupies.
            .padding(.horizontal, 13)
            .frame(height: 24)
            .background(Capsule().fill(hover ? M.high : M.raised))
            .overlay(Capsule().strokeBorder(M.lineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .help("Go to the newest message")
        .accessibilityLabel("new message")
    }
}

/// The head of a pane: a 22pt name, one dim line under it, and the verbs.
struct MsgHead<Acts: View>: View {
    let who: String
    let sub: String
    @ViewBuilder var acts: () -> Acts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(who)
                .font(Face.title)
                .foregroundStyle(M.inkBright)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sub)
                .font(Face.body)
                .foregroundStyle(M.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
            QuietActs { acts() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }
}

// MARK: - identity

/// The message key rule of §3, on this side of the wire.
///
/// The fourth implementation of one sentence -- the Bridge hashes in Swift,
/// `msglib` hashes in the pipeline, the collector hashes in Python -- and it is
/// here for one reader: a send the Bridge reported carries the GUID of the row
/// it became, and this is what turns that GUID into the key the transcript
/// files that row under. Only ever used to *recognise* a row the store already
/// holds, never to mint a name.
enum MsgKey {
    static func of(_ guid: String) -> String {
        SHA256.hash(data: Data(guid.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .lowercased()
    }
}

// MARK: - the composer

/// The line a text is typed into.
///
/// **Deliberately not `TextEditor`.** Enter has to send and Shift+Enter has to
/// be a newline, and SwiftUI's editor never sees either: the text system eats
/// the key first. AppKit already draws the distinction by name --
/// `insertNewline:` against `insertNewlineIgnoringFieldEditor:` -- so this is
/// an `NSTextView` answering three commands and nothing else. `PromptBox` is the
/// console dialect's version of the same idea; this one is the mail dialect's,
/// and it is smaller because it has no tags, no completion list and no
/// disabled state to draw.
///
/// **The box is not here.** The pill, the edge, the ground, the placeholder and
/// the discs are `MsgComposer`'s, so the field is only the run of text and the
/// height it needs. Every inset is the board's and stated there: 14pt in front
/// of the first character, and behind the last as many 26pt slots as that
/// composer holds open. What is here is 9pt over and under a 16pt row, and a
/// ceiling of five rows because that is where a text stops being a text.
/// An NSTextView that says when it gets or loses the keyboard. AppKit has no
/// delegate call for that (textDidBeginEditing waits for the first edit), and the
/// field needs the truth, not a guess.
final class MsgTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}

struct MsgField: NSViewRepresentable {

    /// The 16pt row every line of this app sits on.
    static let row: CGFloat = 16
    /// Five of them. Past this the field scrolls rather than grows.
    static let maxRows = 5

    @Binding var text: String
    /// The collector's own ceiling, enforced here so an over-long text is
    /// refused before it is filed rather than after.
    var maxLength: Int
    /// Two ways at once: the coordinator reports the caret arriving and
    /// leaving, and a caller that sets it true puts the caret in at the end.
    @Binding var focused: Bool
    /// How many rows the text currently occupies, capped at the ceiling.
    /// Reported back because the dock grows with it.
    @Binding var rows: Int
    var onSubmit: () -> Void
    /// Esc, offered to the caller first. Return true to swallow the key; false
    /// leaves the text view its own answer.
    var onCancel: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = MsgTextView()
        view.delegate = context.coordinator
        // The view tells the coordinator when it actually gains or loses the
        // keyboard. The binding is written from that, never the other way
        // round, so a stale binding can never take the keyboard away from a
        // field somebody is typing into.
        view.onFocus = { [weak coordinator = context.coordinator] live in
            coordinator?.liveChanged(live)
        }
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        // Grammar and Writing Tools each draw their own coloured underlines
        // through a field. Nothing may scribble on this one either.
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        if #available(macOS 15.1, *) { view.writingToolsBehavior = .none }
        view.drawsBackground = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.insertionPointColor = NSColor(M.accent)
        view.allowsUndo = true
        view.font = MsgField.face
        view.defaultParagraphStyle = MsgField.paragraph
        view.typingAttributes = MsgField.attributes

        // The wrapping half. Without it a text view in a scroller keeps the
        // width it was created at, which here is zero: every line wraps after
        // no characters at all.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        view.string = text
        MsgField.paint(view)

        let scroller = NSScrollView()
        scroller.documentView = view
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = false
        scroller.hasHorizontalScroller = false
        scroller.autohidesScrollers = true
        scroller.verticalScrollElasticity = .none
        return scroller
    }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        guard let view = scroller.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        // Conditional, and not out of tidiness: this runs on the update the
        // keystroke being typed caused, and rewriting the store on each of
        // those is reaching into the field while somebody is using it.
        if view.string != text {
            view.string = text
            MsgField.paint(view)
            // Setting `string` collapses the selection to the head of the
            // field, and every caller that writes from outside is handing this
            // field something to carry on from: charon's draft taken with tab,
            // an undone send coming back, a saved draft on the way in.
            view.setSelectedRange(NSRange(location: (view.string as NSString).length,
                                          length: 0))
        }
        context.coordinator.report(view)

        // Focus follows the binding only when the binding CHANGED, and only when
        // the change came from a caller (the r key, tab on a suggestion, an
        // undone send) rather than from this coordinator reporting what the
        // view already did. Reconciling on every update was the bug: a keystroke
        // re-renders the view while the binding still lags the real first
        // responder, and that lag read as a request to blur.
        let co = context.coordinator
        if co.wanted != focused {
            let mine = co.fromSelf
            co.wanted = focused
            co.fromSelf = false
            let live = view.window?.firstResponder === view
            if !mine, focused, !live {
                DispatchQueue.main.async {
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length,
                                                  length: 0))
                }
            } else if !mine, !focused, live {
                DispatchQueue.main.async { view.window?.makeFirstResponder(nil) }
            }
        }
    }

    // MARK: the grid

    private static var face: NSFont { Face.ns(11) }

    /// The 16pt row, stated: a text view left to its own leading puts the
    /// second line of a message off the grid every other element sits on.
    private static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = MsgField.row
        p.maximumLineHeight = MsgField.row
        return p
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: face, .foregroundColor: NSColor(M.inkBright), .paragraphStyle: paragraph]
    }

    /// Setting `string` drops every attribute in the field, so this puts the
    /// face, the ink and the row back.
    private static func paint(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        storage.setAttributes(attributes, range: whole)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MsgField

        init(_ parent: MsgField) { self.parent = parent }

        /// How tall the text is, in rows, handed back to SwiftUI. Deferred by
        /// one turn because it is read during a view update and writing a
        /// binding inside one is a state change nobody asked for.
        func report(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer
            else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let n = min(MsgField.maxRows,
                        max(1, Int((used / MsgField.row).rounded(.up))))
            guard n != parent.rows else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.rows = n }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if view.string.count > parent.maxLength {
                view.string = String(view.string.prefix(parent.maxLength))
                MsgField.paint(view)
            }
            parent.text = view.string
            report(view)
        }

        /// The last value of the focus binding this view acted on, and whether
        /// the write that changed it was ours. `nil` until the first update.
        var wanted: Bool?
        var fromSelf = false

        /// The view became or stopped being first responder. Written to the
        /// binding one turn later, marked as ours, so the update it causes only
        /// records it and never moves the keyboard again.
        func liveChanged(_ live: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.focused != live else { return }
                self.fromSelf = true
                self.wanted = live
                self.parent.focused = live
            }
        }

        /// Enter sends, Shift+Enter is a newline, and Esc is the caller's if the
        /// caller wants it. The other way round is a message box that needs a
        /// mouse to use, and this one is typed into.
        ///
        /// Tab is not answered here any more. It used to take charon's line,
        /// and there is no line: the ask is a control inside the field now, so
        /// the key goes back to the text view's own answer.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            // Escape arrives as one of these two depending on what else is
            // bound, so both are answered rather than one being guessed at.
            case #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSStandardKeyBindingResponding.complete(_:)):
                return parent.onCancel()
            default:
                // Shift+Return arrives as `insertNewlineIgnoringFieldEditor:`,
                // whose own default is to put a line break in. Answered by
                // letting the text view do exactly that.
                return false
            }
        }
    }
}

/// The send: a filled accent disc with a void arrow in it, inside the right
/// end of the line.
///
/// Absent while the field is empty -- there is nothing to send, so there is no
/// control -- and filled the moment there is a word in it. Filled rather than
/// outlined because this is not a request for confirmation: it is the send, and
/// it is allowed to look like the send.
///
/// No hover state. The disc is already at full accent and there is nowhere
/// brighter to go inside this palette, so hover would be decoration; the press
/// is the response that matters, and it is a step DOWN the ANSI ramp -- the
/// base green slot instead of the bright one -- which is how a terminal
/// palette darkens.
struct SendDisc: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(name: .arrowUp, size: 15, weight: 1.5)
                .foregroundStyle(M.ground)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(DiscPress())
        .help("Send")
        .accessibilityLabel("send")
    }
}

/// The 0.96 and the darker ground, on the instant a disc goes down.
///
/// One style for both discs in the right end of the field, because they are one
/// control repeated: the same 26pt circle, the same press. What they do not
/// share is the ground -- the send is the accent and the ask is the raised
/// surface -- so the two grounds are the parameters and the motion is not.
private struct DiscPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var stillness

    /// ANSI slot 2. The bright slot is the accent; one slot down is how this
    /// palette darkens.
    static let pressedGreen = Color(hex: 0x56a34b)

    var fill: Color = M.accent
    var down: Color = DiscPress.pressedGreen
    var edge: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(configuration.isPressed ? down : fill))
            .overlay(Circle().strokeBorder(edge, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !stillness ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The ask: charon's own mark on a quiet disc, inside the right end of the
/// line and one slot in from the send.
///
/// **It is not green.** The send is the one thing on this board that goes
/// somewhere and it is the one thing wearing the accent; this is a request for
/// a sentence, made on the same 26pt circle in the ink a control is drawn in.
/// The single exception is the dot in the ready state, which is the same 4pt
/// accent the list already puts at the head of a row that has something in it
/// nobody has read.
///
/// Three states and no spinner: `thinking` is a step DOWN the ramp with the
/// edge one step up, which is how this palette says a control is occupied
/// without moving anything.
struct DraftSpark: View {

    /// Idle, waiting on charon, or holding one nobody has taken yet.
    enum Phase { case idle, thinking, ready }

    let phase: Phase
    let action: () -> Void

    @State private var hover = false

    private var ink: Color {
        switch phase {
        case .thinking: return M.inkDim
        case .ready: return M.inkBright
        case .idle: return hover ? M.inkBright : M.inkMid
        }
    }

    /// A disc one step off the field's own surface needs an edge or it reads as
    /// a hole; while charon is writing it is the same edge one step up, which
    /// is the weight this app already draws a border that is live in.
    private var edge: Color { phase == .thinking ? M.lineStrong : M.line }

    var body: some View {
        Button(action: action) {
            Icon(name: .sparkle, size: 13)
                .foregroundStyle(ink)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(DiscPress(fill: M.raised, down: M.high, edge: edge))
        .overlay(alignment: .topTrailing) {
            if phase == .ready {
                Circle()
                    .fill(M.accent)
                    .frame(width: 4, height: 4)
                    .offset(x: -1, y: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hover = $0 }
        // Colour only, 120ms, which is the whole of what this control does.
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: phase)
        .help("Draft a reply (e)")
        .accessibilityLabel("draft a reply")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        switch phase {
        case .idle: return ""
        case .thinking: return "charon is writing"
        case .ready: return "a draft is waiting"
        }
    }
}

/// charon's older presence in the composer: one predictive line over the field.
///
/// **Nothing in the app draws this any more.** The ask moved inside the field,
/// where it is a control you press rather than a line standing over your text
/// whether or not you wanted one -- see `DraftSpark`. Kept because it is the
/// shape the boards were drawn in and it costs one struct to be able to put the
/// two side by side.
///
/// A phone keyboard's predictive bar, which is the one shape a person already
/// reads as "here is a thing you may take, or may ignore, and ignoring it costs
/// nothing". No ground and no edge, so it is not a second field standing over
/// the first.
///
/// Three inks, and the ranking is the argument: the mark and the key are dim
/// because they are the frame, the draft is mid because it is an offer, and the
/// words in the field under it are bright because they are the only thing on
/// the board that is yours. The draft starts on the same column your own text
/// does, so taking it with tab moves it up a line and not sideways; the sparkle
/// hangs a cell clear of that column, the way a bullet hangs.
struct SuggestionLine: View {
    let text: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(text)
                    .font(Face.body)
                    .foregroundStyle(hover ? M.inkBright : M.inkMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("tab to use")
                    .font(Face.body)
                    .foregroundStyle(hover ? M.inkMid : M.inkDim)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 33)
            .padding(.trailing, 18)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Icon(name: .sparkle, size: 12)
                    .foregroundStyle(hover ? M.inkMid : M.inkDim)
                    .padding(.leading, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(M.move, value: hover)
        .help("Use charon's draft (tab)")
        .accessibilityLabel("use charon's draft: \(text)")
    }
}

/// The field, the pill it sits in and the two discs inside its right end: one
/// object in every state, so the box you type into never moves under your hands.
///
/// Both slots are held whether or not a disc is standing in either, because a
/// placeholder that shifts when a control appears is the field moving -- and
/// the ask, which is there the whole time, would slide sideways on the first
/// character typed if the send's slot were only as wide as the send.
struct MsgComposer: View {
    @Binding var text: String
    let placeholder: String
    var maxLength: Int = 4000
    @Binding var focused: Bool
    let onSend: () -> Void
    /// Whether this conversation may be written to at all. False draws no disc
    /// and answers no Enter: a control that is on screen and does nothing is
    /// worse than one that is not there.
    var canSend = true
    /// charon's ask, and what it currently is. Nil where there is nobody to ask
    /// -- the pinned conversation, which is charon -- and the field then keeps
    /// its old single-slot right end.
    var draft: DraftSpark.Phase?
    var onDraft: () -> Void = {}
    var onCancel: () -> Bool = { false }

    /// One disc's side, the air in front of the slots, the gap between them and
    /// the inset off the pill's own edge.
    private static let disc: CGFloat = 26
    private static let air: CGFloat = 10
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 5

    @State private var rows = 1
    @Environment(\.accessibilityReduceMotion) private var stillness

    private var empty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the text ends short of: the send's slot, the air in front of it,
    /// the pill's inset -- and the ask's slot and the gap, where there is one.
    private var rightInset: CGFloat {
        let one = MsgComposer.disc + MsgComposer.air + MsgComposer.inset
        guard draft != nil else { return one }
        return one + MsgComposer.disc + MsgComposer.gap
    }

    /// The disc arriving and leaving: 0.9 to 1 over 120ms, and opacity alone
    /// where the system has been told not to move things.
    private var pop: AnyTransition {
        stillness ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MsgField(text: $text, maxLength: maxLength, focused: $focused,
                     rows: $rows, onSubmit: send, onCancel: onCancel)
                .frame(height: CGFloat(rows) * MsgField.row)
                // 14 off the board in front and the slots behind, plus the 1pt
                // the edge is drawn in: 36pt tall on one row, 100 on five, and
                // the text lands on the same column in both.
                .padding(.leading, 15)
                .padding(.trailing, rightInset)
                .padding(.vertical, 10)

            if text.isEmpty {
                Text(placeholder)
                    .font(Face.body)
                    .foregroundStyle(M.inkDim)
                    .lineLimit(1)
                    .padding(.leading, 15)
                    .frame(height: MsgField.row)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Capsule().fill(M.surface))
        // One weight for one meaning: `lineStrong` is already what this app
        // draws a border that is live in, so focus is that step and no glow.
        .overlay(Capsule().strokeBorder(focused ? M.lineStrong : M.line, lineWidth: 1))
        .animation(M.move, value: focused)
        // 5 off the field's own edge, and pinned to the bottom rather than the
        // top: the board only ever draws a one-line field, and on a five-line
        // one the send belongs beside the line being written.
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: MsgComposer.gap) {
                if let draft {
                    DraftSpark(phase: draft, action: onDraft)
                }
                // The send's slot, held open empty. The disc comes and goes
                // inside it, which is what keeps the ask beside it still.
                ZStack {
                    if !empty, canSend {
                        SendDisc(action: send).transition(pop)
                    }
                }
                .frame(width: MsgComposer.disc, height: MsgComposer.disc)
            }
            .padding(MsgComposer.inset)
        }
        .animation(.easeOut(duration: 0.12), value: empty)
    }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}
