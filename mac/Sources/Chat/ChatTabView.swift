import SwiftUI

/* The chat assistant. A message typed here is filed by the collector, answered
   by a session running ON the Pi a minute later, and read back into the window
   as it is produced.

   **Two routes: the landing and the conversation.** The front used to be a list
   of sessions with `[+ new]` on it twice; it is a composer in the middle of a
   lit pane now, and the sessions are a section behind a chip under it. What
   moved is the door -- a session is minted around a question rather than before
   one -- and nothing else did: the cards, the sweep, the archive and every verb
   on them are the same view, one level down. See `ChatLandingView`.

   **The list is not a tty and the conversation still is.** That is the web's own
   split and its argument survives the port: the list drew each conversation with
   a `DotLeader`, the idiom for a key and a reading, and a conversation has no
   reading at the end of the walk -- so ten of them read as a systemd unit table.
   The cards keep one 6px corner and one surface step, and so does the box the
   landing wraps the composer in; the conversation one route over is unchanged
   console.

   **It is not the ask window and does not share its view.** They look alike and
   they are not the same thing: ask is one question answered once, out of a
   payload that arrives on the collector's clock, with a receipts line and a
   staleness test against the 6am run. This is a conversation with its own
   routes, a turn that streams, a stop button and a model toggle.

   **Nothing here is synchronous and the window never pretends otherwise.** The
   turn is filed, a path unit fires, and the answer arrives on a poll. The one
   optimism is the moment between pressing send and the collector confirming --
   and even that rolls back to a FAILED line rather than leaving a message on
   screen that no Pi ever received.
*/

/// How often the thread is re-read while something is happening to it. The
/// runner rewrites `partial` at most every 0.5s, so this is the rate at which
/// streaming text is actually visible; anything faster would be polling for
/// bytes that are not there yet.
let chatLivePoll: Duration = .seconds(1)

/// And how often when nothing is. Not zero: the runner can start a turn this
/// window did not file -- the web console, a re-fire of the path unit -- and a
/// window that stopped looking would sit on a finished conversation while the
/// next one streamed past it.
let chatIdlePoll: Duration = .seconds(5)

/// The collector's own ceiling on a message, stated here so the field stops at
/// it rather than letting the Pi reject something already typed.
let chatTextMax = 4000

/// The scrollback's **floor**, not its height, counted in rows because that is
/// the unit a terminal is measured in. Twelve is about the shortest exchange
/// that still reads as a conversation rather than as a field with something in
/// it.
let chatRows = 12

/// The column the tab runs in. 96 cells: wide enough that an answer quoting a
/// systemd unit line does not wrap mid-path, narrow enough that the frame still
/// reads as a window rather than as the page.
let chatMeasure: CGFloat = HT.cw * 96

/// The corner both cards in this tab round to: the session card in the list and
/// the card the landing wraps the composer in.
///
/// Mail's own radius step, so the two dialects round identically rather than
/// each inventing a curve. The one measurement in this tab that is not a
/// multiple of the cell.
let chatRadius: CGFloat = 6

/// Whether a thread is waiting on the runner or being answered by it.
///
/// `queued` and `running` are two different facts and either one means the same
/// thing to this view: the reader is not holding the conversation right now.
/// They are separate on the wire because they are written by different processes
/// -- the collector files the queue entry, the runner writes the status -- and
/// there is a real window between them in which no status has been written at
/// all. A view that read only `status` would draw that window as idle and hand
/// the input back mid-turn.
func chatInFlight(queued: Bool, status: ChatStatus) -> Bool {
    queued || status == .running
}

/// The non-colour channel for every thread state. A glyph and a word, so the
/// list survives being printed 1-bit -- and so the two in-flight states, which a
/// reader genuinely wants told apart, are told apart by their words rather than
/// by a shared amber.
struct ChatStateWord {
    var glyph: String
    var word: String
    var tone: Tone

    init(queued: Bool, status: ChatStatus) {
        // `~` rather than a dot, which is the glyph the transcript's own
        // `~queued` pill already uses for this state one route over.
        if queued {
            self = ChatStateWord(glyph: "~", word: "queued", tone: .caution)
        } else if status == .running {
            self = ChatStateWord(glyph: "›", word: "running", tone: .caution)
        } else if status == .error {
            self = ChatStateWord(glyph: "×", word: "failed", tone: .fault)
        } else {
            self = ChatStateWord(glyph: "", word: "idle", tone: .default)
        }
    }

    private init(glyph: String, word: String, tone: Tone) {
        self.glyph = glyph
        self.word = word
        self.tone = tone
    }
}

/// What a thread is called before anyone has typed into it. The collector stores
/// an empty title on purpose rather than inventing one, so the word for it
/// belongs here, in the view's own voice.
func chatUntitled(_ title: String) -> String { title.isEmpty ? "new session" : title }

// MARK: - the tab

enum ChatRoute: Equatable {
    case list
    /// Mint a session and go to it. A place rather than a thread, which is why
    /// it is a case and not an id.
    ///
    /// **Nothing on the landing navigates here any more**: minting an empty
    /// session was what `[+ new]` did, and the composer replaced it -- a session
    /// is minted around a question now. The case is kept because the route is
    /// still real: it is `#chat/new` on the web, it is the shape a restored
    /// window can arrive on, and it still does exactly what it always did.
    case fresh
    case thread(String)
}

struct ChatTabView: View {

    var model: MailModel

    /// The route, and only the route, is the tab's own. The web loses its
    /// `#chat/...` sub-route the moment another tab is opened, and so does this.
    @State private var route: ChatRoute = .list
    /// The pane's own width, for the padding step at 720. Measured on the pane
    /// rather than the window: the rail and the chrome are outside it.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        Group {
            switch route {
            case .list, .fresh:
                // **The landing takes the pane too, and for its own reason.**
                // The list this replaced wanted none of the slack and was
                // handed to a scroller as an ordinary console page. This one is
                // a box in the middle of a lit field: the plate is full-bleed
                // behind it and the column is centred in whatever is left, so
                // the page has to know how much there is. It owns its own
                // scrolling and its own margins -- same modifier, same numbers.
                ChatLandingView(model: model,
                                fresh: route == .fresh,
                                narrow: paneWidth > 0 && paneWidth <= HT.bpSm,
                                navigate: { route = $0 })

            case .thread(let id):
                // **The conversation takes the pane.** The window is the page
                // here, and the buffer is what turns the leftover height into
                // scrollback rather than into black under the composer -- which
                // is why this route is handed the pane whole rather than dropped
                // into a scroller that would let it grow instead.
                ChatConversationView(model: model, id: id, navigate: { route = $0 })
                    .frame(maxWidth: chatMeasure, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .htConsolePad(narrow: paneWidth > 0 && paneWidth <= HT.bpSm)
                    // Keyed to the conversation. The composer holds its draft in
                    // its own state and this element keeps the same position and
                    // type across a route change -- so without a key a half-typed
                    // message would follow the reader from one conversation into
                    // the next, sitting there loaded over a different thread, one
                    // Return away from filing itself against the wrong one.
                    .id(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .htMeasureWidth { paneWidth = $0 }
    }
}

// MARK: - the small parts

/// A bracketed word that does something. Every control on these two pages is one
/// of these: a text control in a row of text, ink rather than cyan, because the
/// accent is spent on the act that puts a message on the Pi.
struct ChatTextButton: View {
    var text: String
    var ink: Color = HT.ink
    var hoverInk: Color = HT.inkBright
    var label: String? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(HT.body)
                .foregroundStyle(hovering ? hoverInk : ink)
                .lineLimit(1)
                .fixedSize()
                .frame(height: HT.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label ?? text))
    }
}

/// A sentence about the page, never a control.
///
/// Set in `ink-mid` and not `ink-dim`: every demotion in this tab stops at the
/// contrast floor, because everything demoted here is a word rather than a rule.
/// The reference remaps its own `ht-dim` inside this tab for exactly this reason.
struct ChatNote: View {
    var text: String
    /// Set in the middle of the column rather than against its edge, and sized
    /// to the sentence rather than to the column -- so a mask drawn under it is
    /// the words' own box and not a band across the page. The landing wants
    /// both, because it is the one chat page with a picture behind the type;
    /// nothing else does.
    var centred: Bool = false

    init(_ text: String, centred: Bool = false) {
        self.text = text
        self.centred = centred
    }

    var body: some View {
        Text(text)
            .font(HT.body)
            .foregroundStyle(HT.inkMid)
            .multilineTextAlignment(centred ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: centred ? nil : .infinity, alignment: .leading)
    }
}
