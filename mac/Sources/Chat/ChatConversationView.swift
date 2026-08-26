import AppKit
import SwiftUI

/* One conversation: the window, the scrollback, and the line you type into.
 *
 * Unchanged console -- no card, no corner, no surface tint. The list one route
 * back is the dialect; this is the tty, and `HALFTONE.CHAT` is a running process
 * with a title bar on it.
 */

struct ChatConversationView: View {

    var model: MailModel
    var id: String
    var navigate: (ChatRoute) -> Void

    @State private var doc: ChatThread?
    @State private var missing = false
    /// A message this window sent that the Pi has not confirmed yet. Held
    /// because losing what somebody typed is the one unforgivable failure here.
    @State private var sending: String?
    @State private var failed: String?
    /// How many user turns the record held when the in-flight message was sent.
    ///
    /// The optimistic copy clears when the record grows PAST this -- not when it
    /// merely contains some user turn, which every established thread already
    /// does. A count rather than a text match, so a re-sent identical message,
    /// or the collector's own strip() of what was typed, cannot clear the wrong
    /// one. The race is real: the collector is threaded, so a poll GET can
    /// return a pre-send record while the send POST is still open.
    @State private var sentBaseline: Int?

    private var live: Bool {
        guard let doc else { return false }
        return chatInFlight(queued: doc.queued, status: doc.status)
    }

    private var busy: Bool { sending != nil || live }

    /// Said out loud rather than left to be inferred from a greyed box. A
    /// disabled control with no stated reason is indistinguishable from a broken
    /// one.
    private var busyReason: String? {
        if missing { return "no session here" }
        if sending != nil { return "filing…" }
        if doc?.queued == true { return "queued · the runner has not picked this up yet" }
        if doc?.status == .running { return "answering · [stop] to give up on it" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            bar
            Rectangle().fill(HT.lineBright).frame(height: 1)

            // **The row that takes the slack.** Every other row on this page is
            // as tall as its line; this one is the buffer, and it is what turns
            // the leftover height of the pane into scrollback rather than into
            // black under the composer.
            HTWindow(name: "HALFTONE.CHAT", onClose: { navigate(.list) }, flush: true) {
                VStack(spacing: 0) {
                    if missing {
                        VStack(alignment: .leading, spacing: 0) {
                            ChatNote("this session is not on the pi.")
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: HT.row * 6, alignment: .topLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, HT.cw2)
                        .padding(.top, HT.row)
                    } else {
                        transcript
                    }

                    composer
                }
            }
            .frame(maxHeight: .infinity)

            // The web console prints a standing claim here ("runs on the pi ·
            // reads the box and the web · writes nothing here"). Removed at the
            // user's request 2026-08-19, and since the memory store landed on
            // 2026-08-25 it no longer holds unqualified: a session writes one
            // thing, its own memory, through bin/memory. The notes that do ship
            // carry that qualifier, and anything restored here would need it.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: pollKey) { await poll() }
    }

    // MARK: - the bar

    private var bar: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ChatTextButton(text: "◂ chat", ink: HT.inkBright) { navigate(.list) }
                Text(" / \(doc.map { chatUntitled($0.title) } ?? id)")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(doc.map { Fmt.stamp($0.updatedAt) } ?? "—")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - the scrollback

    /// Oldest turn at the top, the way a terminal fills, and the last line is
    /// always the most recent thing that happened -- which is why this scrolls to
    /// its end rather than to its start.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if (doc?.turns.isEmpty ?? true), sending == nil, !live {
                        ChatNote("nothing asked yet · this session reads this pi and the web, "
                                 + "and changes nothing but its own memory")
                    }

                    ForEach(Array((doc?.turns ?? []).enumerated()), id: \.offset) { _, turn in
                        if turn.role == .user {
                            ChatUserTurn(text: turn.text, at: turn.at)
                        } else {
                            ChatAssistantTurn(turn: turn)
                        }
                    }

                    // Before the record catches up, what this window typed is the
                    // only copy of it there is.
                    if let sending { ChatUserTurn(text: sending, at: nil) }

                    if live {
                        ChatStreaming(partial: doc?.partial ?? "",
                                      queued: doc?.queued ?? false)
                    }

                    // The runner's own reason, in the transcript rather than in a
                    // banner: it is a thing that happened at a point in the
                    // conversation, and the input is usable again underneath it.
                    if doc?.status == .error, !live {
                        ChatFail(pill: "×turn", message: doc?.error ?? "the session failed")
                    }

                    if let failed { ChatFail(pill: "×send", message: failed) }

                    // The blank last row. A real row rather than padding on the
                    // container: padding below the last line is padding scrolled
                    // past, which lands an answer's final line hard against the
                    // frame.
                    Color.clear.frame(height: HT.row).id("chat-end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HT.cw2)
                .padding(.top, HT.row)
            }
            // The floor, not the height: it binds only on a short window, where
            // the page overflowing is a better answer than a four-row letterbox.
            .frame(minHeight: CGFloat(chatRows) * HT.row, maxHeight: .infinity)
            // This scrollport and nothing else's: no smooth behaviour anywhere
            // near it, because a terminal repaints, it does not animate.
            .onChange(of: painted) { _, _ in proxy.scrollTo("chat-end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("chat-end", anchor: .bottom) }
        }
    }

    /// What the buffer currently says, as one string. The bottom line moves when
    /// a turn lands, when the partial grows, when a message is typed into it, and
    /// when a refusal comes back -- so those are what bring the end back into
    /// view.
    private var painted: String {
        [
            String(doc?.turns.count ?? 0),
            String(doc?.partial?.count ?? 0),
            doc?.status.rawValue ?? "",
            String(doc?.queued ?? false),
            sending ?? "",
            failed ?? "",
        ].joined(separator: "|")
    }

    // MARK: - the composer

    private var composer: some View {
        ChatComposer(
            busy: busy || missing,
            busyReason: busyReason,
            model: doc?.model ?? .sonnet,
            // Absent on the record means the runner's own `high`; the control
            // shows that truthfully rather than a blank.
            effort: doc?.effort ?? .high,
            // Only while there is something to stop. A control that is visible
            // and permanently disabled is a worse answer than one that is not
            // there.
            onStop: live ? { Task { await stop() } } : nil,
            onSend: { text in Task { await send(text) } },
            onModel: { m in Task { await changeModel(m) } },
            onEffort: { e in Task { await changeEffort(e) } },
            autoFocus: true)
    }

    // MARK: - reading

    /// Fast while something is happening, slow otherwise, and stopped entirely
    /// while nobody is looking at the window. The immediate read on the way back
    /// is what keeps the first thing on screen after a return current rather than
    /// up to five seconds old.
    private var pollKey: String { "\(model.active)/\(live || sending != nil)" }

    private func poll() async {
        guard model.active else { return }
        let fast = live || sending != nil
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: fast ? chatLivePoll : chatIdlePoll)
            if Task.isCancelled { return }
        }
    }

    private func load() async {
        do {
            let got = try await model.store.chatThread(id: id)
            if Task.isCancelled { return }
            doc = got
            missing = (got == nil)
            // Drop the optimistic copy once the record actually contains the
            // sent message -- i.e. its user-turn count has grown past the
            // baseline captured at send time. See `sentBaseline`.
            if let got, let baseline = sentBaseline, userTurns(got) > baseline {
                sending = nil
                sentBaseline = nil
            }
        } catch is CancellationError {
            return
        } catch {
            // A transport failure is not a fact about the thread: the record
            // stays on screen and the reader is not told the session is gone.
            if !Task.isCancelled { missing = false }
        }
    }

    private func userTurns(_ d: ChatThread) -> Int {
        d.turns.reduce(0) { $0 + ($1.role == .user ? 1 : 0) }
    }

    // MARK: - acting

    /// Every write lands the same way: say what went wrong if it did, then
    /// re-read. The record on the Pi is the one source of truth for what the
    /// conversation contains, so nothing here splices a copy in by hand.
    @discardableResult
    private func settle(_ result: WriteResult, _ what: String) async -> Bool {
        switch result {
        case .busy: failed = "\(what): a turn is already in flight"
        case .failed: failed = "\(what): the collector did not take it"
        case .ok: failed = nil
        }
        await load()
        return result == .ok
    }

    private func send(_ text: String) async {
        failed = nil
        sentBaseline = doc.map(userTurns) ?? 0
        sending = text
        let result = await model.store.chatSend(id: id, text: text)
        if await settle(result, "not sent") == false {
            sending = nil
            sentBaseline = nil
        }
    }

    private func stop() async {
        await settle(await model.store.chatStop(id: id), "not stopped")
    }

    /// Optimistic, and safe to be: a refusal restores the record's own value on
    /// the re-read a beat later, and the alternative is a toggle that does not
    /// move until the Pi answers.
    private func changeModel(_ m: ChatModelName) async {
        doc?.model = m
        await settle(await model.store.chatSetModel(id: id, model: m), "model unchanged")
    }

    private func changeEffort(_ e: JarvisEffort) async {
        doc?.effort = e
        await settle(await model.store.chatSetEffort(id: id, effort: e), "effort unchanged")
    }
}

// MARK: - the turns

/// The clock column every turn hangs off.
///
/// Five cells wide whether or not it has a time in it, which is what makes it a
/// column: the text beside it starts at the same offset on every row of the
/// buffer. Rendered blank for a turn that has no time yet -- the optimistic copy
/// of a message the Pi has not confirmed, and the streaming answer that has not
/// landed. A `--:--` there would be a stated unknown where the truth is "not
/// yet", and the pill beside it already says which.
private struct ChatWhen: View {
    var at: String?

    var body: some View {
        Group {
            if let at, !at.isEmpty {
                Text(Fmt.hhmm(at)).font(HT.body).foregroundStyle(HT.inkMid)
            } else {
                Color.clear
            }
        }
        .frame(width: HT.cw * 5, height: HT.row, alignment: .leading)
    }
}

/// One user turn, drawn as the command on a prompt line. The `Prompt` idiom
/// rather than the component: `Prompt` renders `operator@halftone:~$`, which is
/// right for a page announcing a command and wrong for the twelfth line of a
/// conversation. What carries over is the part that means something -- the green
/// sigil, the bright text, and the reader's own line breaks kept.
///
/// Attributed rather than plain for one reason: an `@cmo` in the composer and
/// the same `@cmo` two seconds later in the scrollback have to be the same
/// token. A tag that lost its surface the moment it was sent would read as a
/// thing the app had stopped recognising.
///
/// The box around a tag is drawn rather than attributed -- there is no border
/// attribute in either text system -- so the renderer is mounted here and only
/// here. It is on the message and not on the row: the clock and the `$` are
/// text too, and a renderer over the whole `HStack` would be asking them about
/// a mark they can never carry.
private struct ChatUserTurn: View {
    var text: String
    var at: String?

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw) {
            ChatWhen(at: at)
            Text("$").font(HT.body).foregroundStyle(HT.prompt).frame(height: HT.row)
            ChatTags.attributed(text)
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineSpacing(HT.row - 11)
                .textRenderer(TagBoxRenderer())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

/// What the session ran on the way to its answer, one dim line each.
///
/// Above the text because it is working-out rather than answer: the reader skims
/// it to see that the box was actually looked at, and reads the prose underneath.
/// The arrow is the non-colour channel.
struct ToolLines: View {
    var tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                Text("→ \(tool)")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineSpacing(HT.row - 11)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, HT.s2)
    }
}

/// The answer body, and **the one element in this console set in another face**.
///
/// Departure Mono's advance is 7/11 of its size, so it lands on whole pixels only
/// at 11, 22, 33 and 44 -- every size between resamples and there is no legible
/// middle step. That is fine for labels and readings, which are scanned. This is
/// four paragraphs somebody sits and reads, so it is the system monospace at
/// 13/18 -- and nothing else is: not the question, not the tool lines, not the
/// receipts, not one row of the session list.
///
/// **Plain text, and no markdown renderer.** Model output rendered as markup is
/// a surface, and this one has none. Tags included: an `@cmo` the session typed
/// back is a word in a sentence, not a pointer somebody aimed -- only what the
/// reader wrote is raised, on both surfaces they wrote it on.
struct AnswerBody: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(HT.ink)
            // 13pt of the system mono sets on about a 15pt line; three points of
            // lead puts it on the 18 the reference states.
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The streaming body, with the block on the end of it.
///
/// **The cursor is a character in the text rather than a view beside it, and it
/// has to be.** A block placed after a `Text` in a row forces that text to its
/// ideal width, which for a paragraph is its longest line -- so a streaming
/// answer would stop wrapping and run off the frame. Appended to the string it
/// wraps where the text wraps and lands exactly where the next character will.
///
/// A no-break space in the off half of the wave, not an empty string: the same
/// advance in a monospace face, so nothing reflows twice a second, and unlike a
/// plain space it survives at the end of a wrapped line.
struct StreamingBody: View {
    var text: String

    @State private var on = true
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        AnswerBody(text: text + (on ? "█" : "\u{00A0}"))
            .onReceive(
                Timer.publish(every: HT.blinkHalf, on: .main, in: .common).autoconnect()
            ) { _ in
                if reduceMotion { on = true } else { on.toggle() }
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            ) { _ in
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if reduceMotion { on = true }
            }
    }
}

/// The receipts under an answer. Ruled off above rather than merely spaced: it is
/// a different kind of statement from the answer over it.
struct TurnMeta<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HT.s1)
            .overlay(alignment: .top) { Rectangle().fill(HT.lineFaint).frame(height: 1) }
            .padding(.top, HT.s2)
    }
}

private struct ChatAssistantTurn: View {
    var turn: ChatTurn

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw) {
            ChatWhen(at: turn.at)
            VStack(alignment: .leading, spacing: 0) {
                if let tools = turn.tools, !tools.isEmpty { ToolLines(tools: tools) }
                if !turn.text.isEmpty { AnswerBody(text: turn.text) }
                TurnMeta {
                    Text(meta).font(HT.body).foregroundStyle(HT.inkMid)
                }
            }
            // Two more cells, so the answer's text column lands under the
            // message's text column rather than under its `$`.
            .padding(.leading, HT.cw2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }

    private var meta: String {
        let model = turn.model?.rawValue ?? "—"
        guard let elapsed = turn.elapsedS else { return model }
        return "\(model) · \(String(format: "%.1f", elapsed))s"
    }
}

/// The in-flight turn: whatever has been said so far, with a cursor on the end.
///
/// The cursor is the whole point of this element. A streaming answer and a
/// finished one are the same characters, and the block is what says the
/// difference -- so it is drawn for the queued state too, where there is no text
/// at all yet and the only honest thing on screen is "something is coming".
private struct ChatStreaming: View {
    var partial: String
    var queued: Bool

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw) {
            ChatWhen(at: nil)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                    StatusPill(text: queued ? "~queued" : "~running",
                               tone: .caution, glyph: false)
                    Text(queued ? "filed · waiting for the runner" : "answering")
                        .font(HT.body)
                        .foregroundStyle(HT.inkMid)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StreamingBody(text: partial)
            }
            .padding(.leading, HT.cw2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

/// A turn that did not become an answer, and a send the collector refused. In the
/// transcript rather than in a banner: both are things that happened at a point
/// in the conversation, and the composer under them is usable again.
private struct ChatFail: View {
    var pill: String
    var message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            StatusPill(text: pill, tone: .fault, glyph: false)
            Text(message)
                .font(HT.body)
                .foregroundStyle(HT.fault)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

// MARK: - the composer

/// Which of the two chats this composer is the composer of.
///
/// One box, two seats. The conversation's sits on the window's bottom edge
/// under a faint rule, says how many characters are in it, and carries a
/// `[stop]` while a turn is running. The landing's sits inside a card in the
/// middle of an empty pane, where a character count is a reading nobody asked
/// for and there is no turn to stop -- so the sentence is spent on what the
/// tags in the box will do, and the row it is on carries the dictation lamp
/// instead.
enum ChatComposerSeat {
    case window
    case card
}

/* The input line, and deliberately not `AskField`. That one is a single-line
   field capped at 2000 characters whose Return always submits, with no disabled
   state and nothing beside it. This needs two rows (Shift+Enter is a newline,
   because pasting a unit file into the box is the ordinary case here), a
   disabled state that says out loud why it is disabled, a STOP that appears only
   while there is something to stop, and two pickers.

   What is shared instead is the shape: a `$` sigil, a field reset to inherit
   everything, and a caret in the prompt's own green.

   **One box for both chat pages.** The landing is the same field, the same
   completion, the same two pickers and the same send -- so it is this view in
   its other seat rather than a second composer that would have to be kept in
   step with this one. See `ChatComposerSeat` for the three things that differ. */
struct ChatComposer: View {

    var busy: Bool
    var busyReason: String?
    var model: ChatModelName
    var effort: JarvisEffort
    var onStop: (() -> Void)?
    var onSend: (String) -> Void
    var onModel: (ChatModelName) -> Void
    var onEffort: (JarvisEffort) -> Void
    var autoFocus: Bool = false
    var seat: ChatComposerSeat = .window
    /// Bumped to put the caret back in the field. The landing's `n` is the one
    /// caller: on that page the field is the door, so the shortcut that used to
    /// mint a session opens it instead.
    var focusToken: Int = 0
    /// Whether the field has the caret. The landing needs it to tell a bare `n`
    /// pressed at the page from an `n` typed into the box; see `PromptBox`.
    var onCaret: ((Bool) -> Void)? = nil

    @State private var text = ""
    /// The tag list's state. Owned here rather than inside `PromptBox` for one
    /// reason: the popup has to be mounted somewhere it will not be clipped,
    /// and the field lives in a scroll view. See `tagList`.
    @State private var tags = CompletionModel()

    private var message: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HT.cw) {
                Text("$")
                    .font(HT.body)
                    .foregroundStyle(HT.prompt)
                    .frame(height: HT.row)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && !busy {
                        Text("ask about this pi")
                            .font(HT.body)
                            .foregroundStyle(HT.inkMid)
                            .frame(height: HT.row)
                            .allowsHitTesting(false)
                    }
                    PromptBox(text: $text, maxLength: chatTextMax, disabled: busy,
                              autoFocus: autoFocus, focusToken: focusToken,
                              highlight: { ChatTags.ranges(in: $0) },
                              completion: PromptCompletion(model: tags,
                                                           token: Self.offer),
                              onCaret: onCaret,
                              onSubmit: submit)
                        .accessibilityLabel(Text("Message the assistant"))
                }
                .frame(height: HT.row * 2)
                .overlay(alignment: .bottomLeading) { tagList }
            }

            controls
        }
        .padding(.horizontal, HT.cw2)
        .padding(.vertical, HT.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rule is the window seat's alone: it is what separates the composer
        // from the scrollback above it, and a card has an edge of its own.
        .overlay(alignment: .top) {
            if seat == .window { Rectangle().fill(HT.lineFaint).frame(height: 1) }
        }
    }

    // MARK: - the tag list

    /// What `ChatTags` says the caret is sitting in, as rows.
    ///
    /// The composer's whole half of the completion contract, and it is six
    /// lines because the vocabulary and the boundary rule both live in
    /// `ChatTags` -- this only turns one into the other. `static` so it holds
    /// nothing: it is a pure reading of a string, called from a text view's
    /// coordinator on a keystroke.
    ///
    /// **The `@` goes back on and a space follows.** What is *shown* is the
    /// bare word, because the sigil is noise in a list where every row has one;
    /// what is *typed* is the whole token, because that is what the runner
    /// reads. The trailing space is `PromptBox`' doing and it is deliberate on
    /// both sides of the wire: the runner's `\b` means `@cmojunk` is not a tag
    /// at all, so a completion that could leave the word unterminated would be
    /// a list that silently wrote a non-tag.
    private static func offer(_ text: String, _ caret: Int) -> PromptToken? {
        guard let partial = ChatTags.partial(in: text, at: caret) else { return nil }
        return PromptToken(
            range: partial.range,
            query: partial.prefix,
            rows: ChatTags.completions(prefix: partial.prefix).map {
                CompletionRow(glyph: $0.kind.glyph, name: $0.name,
                              hint: $0.hint, insert: "@\($0.name)")
            })
    }

    /// The list itself, hung off the `@` and opening upward.
    ///
    /// **Upward, and for `Listbox`' own reason**: this composer is the last row
    /// of the window and a list dropping downward from it would open into the
    /// window's bottom edge. **Here and not inside `PromptBox`** for the other
    /// half of the same argument: the field is an `NSTextView` in an
    /// `NSScrollView`, and a list mounted in there would be clipped by the
    /// 32-point box it was opened from. This route is handed the pane whole by
    /// `ConsoleShellView` and sits in no scroller at all, so nothing here clips
    /// it -- and the Jarvis composer, which is inside one, is out of the
    /// question for exactly that reason as well as for having no list.
    ///
    /// **The x tracks the token and the y does not, and that is the decision.**
    /// The list stands over the `@` it is completing, which is what the anchor
    /// is for. Its bottom sits a quarter row above the composer's own top rule
    /// -- `Listbox`' gap, measured off the control's edge the way `Listbox`
    /// measures it -- rather than off the line the token happens to be on. Two
    /// things fall out of that and both are wanted: on a message that has
    /// wrapped onto the field's second row the list still does not cover the
    /// first, and the faint rule this composer draws along its own top never
    /// lands across the list's bottom row. The published anchor's y is right
    /// and this caller has no use for it.
    ///
    /// The arithmetic is the composer's own numbers and nothing else's: the
    /// overlay's bottom edge starts at the field's, two rows down; back up two
    /// rows to the field's top, the vertical padding to the rule, and a quarter
    /// row clear of it.
    @ViewBuilder
    private var tagList: some View {
        if tags.open {
            CompletionList(model: tags, label: "Tags")
                .offset(x: tags.anchor.minX,
                        y: -(HT.row * 2 + HT.s2 + HT.s1))
                .zIndex(20)
        }
    }

    /// What the tags in the box will do, said in words.
    ///
    /// The raised token is a texture, and a texture is something a reader has to
    /// have been told the meaning of once. This is the telling: `→ cmo` in the
    /// `ToolLines` idiom, dim, in front of whatever the line was already saying.
    /// Named in the order typed, space-joined, so two tags read as two pointers
    /// rather than as one hyphenated word.
    private var status: String {
        let tags = ChatTags.names(in: text)
        guard let sentence = idle else {
            // The card's own line: the pointer alone, or nothing. A count of
            // characters is a reading, and the landing is a page with no
            // readings on it -- the one thing worth saying there is what the
            // tags in the box are going to do.
            return tags.isEmpty ? "" : "→ \(tags.joined(separator: " "))"
        }
        guard !tags.isEmpty else { return sentence }
        return "→ \(tags.joined(separator: " ")) · \(sentence)"
    }

    /// The sentence when nothing is in flight, or nil for "this seat has none".
    /// A reason always wins: a box that will not take a keystroke has to say why
    /// on both pages.
    private var idle: String? {
        if let busyReason { return busyReason }
        guard seat == .window else { return nil }
        return "\(text.count)/\(chatTextMax) · enter sends · shift+enter newline"
    }

    /// The row under the field: the count or the reason, then the settings, then
    /// the two acts. Right-aligned as a group because send is the thing being
    /// reached for and the reading eye should end on it.
    private var controls: some View {
        HStack(alignment: .center, spacing: HT.cw) {
            Text(status)
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The dictation lamp: a state, not a control. Standby says the
            // machinery is not wired rather than that it is off, which is the
            // truth -- there is no dictation on this Mac yet -- and a lamp says
            // that without offering a click that would do nothing.
            if seat == .card {
                StatusPill(text: "dictate", tone: .standby)
                    .accessibilityLabel(Text("Dictation: not wired"))
            }

            // Which model answers and how hard it thinks. Both are settings
            // rather than acts, and both are refused while a turn is in flight
            // because the runner has already read the record to build its argv.
            Listbox(label: "Model", value: model.rawValue,
                    options: ChatModelName.allCases.map(\.rawValue),
                    disabled: busy) { picked in
                onModel(ChatModelName(rawValue: picked) ?? .sonnet)
            }

            Listbox(label: "Effort", value: effort.rawValue,
                    options: JarvisEffort.allCases.map(\.rawValue),
                    disabled: busy) { picked in
                onEffort(JarvisEffort(rawValue: picked) ?? .high)
            }

            if let onStop {
                // Bracketed like every other text control here, and deliberately
                // not red: stopping is ordinary, and a red control beside a
                // running process reads as an alarm about the process.
                ChatTextButton(text: "[stop]", ink: HT.inkMid, hoverInk: HT.caution,
                               action: onStop)
            }

            sendButton
        }
        .padding(.top, HT.s1)
    }

    /// **The view's single cyan spend.** Cyan means "this one" and is spent once
    /// per view; here the one thing worth calling this one is the act that puts a
    /// message on the Pi. Everything else on this page is ink, green, amber or
    /// red.
    private var sendButton: some View {
        let enabled = !busy && !message.isEmpty
        return Button(action: submit) {
            Text("send")
                .font(HT.body)
                // Void on cyan, not ink: this is the one filled surface in the
                // view and the label has to survive it at 11px.
                .foregroundStyle(enabled ? HT.void : HT.inkDim)
                .padding(.horizontal, HT.cw2)
                .frame(height: HT.row2)
                // Disabled drops to an outline and dim ink, so the state has a
                // shape channel as well as a colour one.
                .background(enabled ? HT.signal : Color.clear)
                .overlay { Rectangle().strokeBorder(enabled ? HT.signal : HT.line, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }

    /// **The card keeps what was typed and the window does not**, and that is
    /// the optimism rule rather than an inconsistency. The conversation has a
    /// transcript to put the message into the instant it leaves the box, so the
    /// box can empty. The landing has nowhere to put it: it is minting a session
    /// and filing against it, either of which the collector can refuse, and a
    /// field that emptied first would have thrown the message away to draw a
    /// pill about not having sent it. It is cleared by the route changing, which
    /// only happens once the send has actually landed.
    private func submit() {
        guard !message.isEmpty, !busy else { return }
        let outgoing = message
        if seat == .window { text = "" }
        onSend(outgoing)
    }
}
