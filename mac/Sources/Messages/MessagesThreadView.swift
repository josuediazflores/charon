import AppKit
import SwiftUI

/* One conversation, and the box at the bottom of it.
 *
 * **Enter sends what you typed, and that keystroke IS the click.** A text you
 * wrote yourself sends the way it does in every messaging app anybody has ever
 * used; there is no REPLY header, no recipient strip, no confirm step and no
 * second click. What replaces the two-step is five seconds on the other side of
 * it: the bubble appears the instant you press Enter, says `sending · undo`,
 * and nothing leaves this Mac until the five seconds are up. That is more
 * safety than a confirm bought, and it costs nothing on the ninety-nine sends
 * that were fine.
 *
 * **Nothing here is the act.** When the five seconds pass, the POST files an
 * outbox record on the Pi; Charon Bridge on this Mac picks it up and performs
 * it once through Messages.app, from the user's own number. No model is
 * anywhere in that path, and nothing retries on its own.
 *
 * **charon's draft is asked for, and it is never a prefill you did not ask
 * for.** The ask is a sparkle inside the right end of the field, one slot in
 * from the send: press it (or `e`) and charon writes one. It arrives IN the
 * field if the field is still empty, because you asked for it; if you started
 * typing while it was being written it waits behind a dot on the sparkle, and
 * the next press puts it in. At the moment it lands in the field it stops being
 * charon's and becomes yours -- Enter sends it like anything else you typed,
 * and nothing in the transcript says where the words came from. Esc clears it
 * like any other text.
 *
 * The keymap, which lives in `MessagesTabView` and is answered here:
 *
 *     j / k          walk the column
 *     r              put the caret in the field
 *     e              take charon's draft, or ask for one
 *     u              mark this chat read
 *     Enter          send what is in the field
 *     Shift+Enter    a newline
 *     esc            clear the field, then put a waiting draft away, then blur
 *                    it, then close the pane
 *
 * **One instance per chat, which the caller guarantees with `.id(key)`.** Half
 * the state here is a half-written text and a send that has not gone yet, and a
 * view that outlived a navigation would carry one chat's words into another
 * chat's outbox.
 */

/// How long typing settles before the draft is saved.
private let msgSaveAfter: Duration = .milliseconds(1500)

/// How often the open thread is re-read.
private let msgPoll: Duration = .seconds(10)

/// How often the thread is re-read while charon is writing, and how long that
/// is allowed to go on for.
///
/// The standing poll is ten seconds, which is a long time to sit under a dim
/// sparkle waiting for a sentence that is already written. This is the same
/// read at the pace of somebody watching for an answer, and it runs only inside
/// a window a person opened by pressing the thing.
private let msgDraftPoll: Duration = .seconds(2)
private let msgDraftWait: TimeInterval = 60

/// How far apart two runs have to be before the gap is worth naming.
private let msgSeparatorGap: TimeInterval = 15 * 60

struct MessagesThreadView: View {

    let chatKey: String
    let model: MailModel
    /// Bumped by the r key, watched here. The keymap lives in one place.
    let replyRequests: Int
    /// Bumped by the e key: the sparkle's other name.
    let draftRequests: Int

    @State private var thread: MessageThread?
    @State private var missing = false
    @State private var failure: String?
    @State private var tick = 0

    // ── the field ──
    @State private var reply = ""
    /// Exactly what this page last put in the field. Typing moves the field off
    /// it and nothing moves it back, so "untouched" keeps meaning what it says.
    @State private var filled: String?
    @State private var opened = false
    @State private var saveTask: Task<Void, Never>?
    @State private var typing = false

    // ── charon's draft ──
    /// A draft that has been taken, sent over or put away, held by its stamp so
    /// a newer one comes back.
    @State private var answeredDraft: String?
    /// When one was asked for, or nil when none is being waited on. The
    /// sparkle's `thinking` state, and the clock the wait is bounded by.
    @State private var askedAt: Date?
    @State private var draftTask: Task<Void, Never>?

    // ── the sends that have not landed ──
    private var pending: [MessageDeliveryRow] { model.messageDelivery.rows(for: chatKey) }

    // ── the log ──
    /// One photograph, held open over the pane. Here rather than in the tile
    /// because "as wide as the pane" is not a size a bubble can be: the log
    /// caps a run at two thirds of its width, which is the cap this steps out
    /// of for as long as somebody is looking.
    @State private var lifted: LiftedAttachment?
    /// Bumped whenever a photograph finishes arriving. Watched like
    /// `runs.count`, because a tile turning into a picture moves the bottom of
    /// the log exactly as much as a new bubble does.
    @State private var grew = 0
    @State private var atBottom = true
    @State private var newBelow = false
    @State private var lastRunCount = 0

    @Environment(\.accessibilityReduceMotion) private var stillness

    private var chat: MessageChatSummary? {
        thread?.chat ?? model.messageChats.first { $0.chatKey == chatKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            log
            dock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if let lifted {
                LiftedAttachmentView(lifted: lifted) { self.lifted = nil }
            }
        }
        .animation(.easeOut(duration: 0.16), value: lifted)
        .task(id: tick) { await load() }
        .task(id: "\(model.active)/\(tick)") { await watch() }
        .onChange(of: replyRequests) { _, _ in typing = true }
        .onChange(of: draftRequests) { _, _ in spark() }
        .onChange(of: reply) { _, text in scheduleSave(text) }
        .onChange(of: typing) { _, now in model.textFocused = now }
        .onDisappear {
            saveTask?.cancel()
            draftTask?.cancel()
            model.textFocused = false
        }
    }

    // MARK: - the head

    /// No `reply`. The box is always open, so a verb that opens it is a verb
    /// for a door that is not there; `archive` and `unread` are things you do
    /// to a thread and they stay, dim.
    private var head: some View {
        MsgHead(who: chat?.name ?? "…", sub: sub) {
            // Neither of these has a route in protocol v1: the collector serves
            // read and nothing else about a chat's state. They are drawn
            // because the pane has two verbs and said out loud in their help
            // rather than quietly doing nothing.
            QuietAct(icon: .archive, word: "archive", disabled: true,
                     help: "no archive route yet · v1 keeps every chat in the list") {}
            QuietAct(icon: .unread, word: "unread", disabled: true,
                     help: "no unread route yet · v1 only moves the mark forward") {}
        }
    }

    private var sub: String {
        guard let chat else { return "" }
        let handle = chat.handle
        return handle.isEmpty ? chat.service : "\(handle) · \(chat.service)"
    }

    // MARK: - the transcript

    private var log: some View {
        GeometryReader { geo in
            scrollback(width: geo.size.width)
        }
        .frame(maxHeight: .infinity)
    }

    /// The bottom of the buffer, by name, so the pill has somewhere to go.
    private static let foot = "msg-foot"

    private func scrollback(width: CGFloat) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if missing {
                        Text("the collector does not have this chat")
                            .font(Face.body).foregroundStyle(M.inkDim)
                    } else if let failure {
                        Text(failure).font(Face.body).foregroundStyle(M.inkDim)
                    }

                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, record in
                        if let word = separator(at: index) {
                            MsgSeparator(word: word, first: index == 0)
                        }
                        run(record, index: index, width: width)
                    }
                    // The one thing in this pane that moves on its own: a run
                    // that arrived. Nothing the keyboard does is in here.
                    .animation(.easeOut(duration: 0.16), value: runs.count)

                    // The sends this page is holding or has just made, under
                    // everything the store knows about. They are the newest
                    // thing in the conversation by definition.
                    ForEach(pending) { item in
                        optimistic(item, width: width)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 8)

                // The bottom of the buffer, outside the stack whose gap it
                // would otherwise take: the log's own 8pt is the last thing
                // under the newest run and nothing may be added to it.
                Color.clear.frame(height: 0).id(MessagesThreadView.foot)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The newest run is the one worth seeing, so the buffer rests on
            // its end rather than on its start.
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height
                    >= geo.contentSize.height - 8
            } action: { _, now in
                atBottom = now
                if now { newBelow = false }
            }
            .onChange(of: runs.count) { _, count in
                defer { lastRunCount = count }
                guard count > lastRunCount, lastRunCount > 0 else { return }
                // Caught up: follow. Reading back: say so and stay put -- a log
                // that jumps under somebody mid-sentence is worse than a pill.
                if atBottom {
                    scroller.scrollTo(MessagesThreadView.foot, anchor: .bottom)
                } else {
                    newBelow = true
                }
            }
            .onChange(of: pending.count) { _, _ in
                guard atBottom else { return }
                scroller.scrollTo(MessagesThreadView.foot, anchor: .bottom)
            }
            // A photograph that has just finished loading. No pill for this
            // one: nothing new was said, a line simply became a picture, and
            // somebody reading back does not want to be moved for it.
            //
            // Whether to follow is decided here and acted on a beat later, and
            // both halves of that are deliberate. This runs in the update that
            // set the image, before the three hundred points of layout it
            // causes -- so `atBottom` is still the answer from before the
            // picture, which is the answer that matters, and the scroll has to
            // wait for the height it is scrolling to.
            .onChange(of: grew) { _, _ in
                let follow = atBottom
                Task { @MainActor in
                    // Twice, because a thread of photographs settles in more
                    // than one pass: the first picture moves the ones under it
                    // and the lazy stack re-measures what that pushed off the
                    // screen. Two scrolls to the same place cost nothing and
                    // the second one is the one that lands.
                    for wait in [60, 260] {
                        try? await Task.sleep(for: .milliseconds(wait))
                        guard follow, !Task.isCancelled else { return }
                        scroller.scrollTo(MessagesThreadView.foot, anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if newBelow {
                    NewMessagePill {
                        newBelow = false
                        scroller.scrollTo(MessagesThreadView.foot, anchor: .bottom)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: newBelow)
        }
    }

    private var runs: [MessageRecord] { thread?.messages ?? [] }

    // MARK: the separators

    /// The line between two runs, or nil where the two are one conversation.
    ///
    /// Named at the head of the log and whenever a quarter of an hour has
    /// passed, which is the point at which two messages stop being one
    /// exchange. Under that the grouping already says everything a clock would.
    private func separator(at index: Int) -> String? {
        let here = Fmt.date(runs[index].createdAt)
        guard index > 0 else { return stampWord(here, withDay: true) }
        let before = Fmt.date(runs[index - 1].createdAt)
        guard let here, let before else { return nil }
        if !Calendar.current.isDate(before, inSameDayAs: here) {
            return stampWord(here, withDay: true)
        }
        guard here.timeIntervalSince(before) > msgSeparatorGap else { return nil }
        return stampWord(here, withDay: false)
    }

    /// `Today 1:51 PM`, `Yesterday 9:12 AM`, `Tuesday 4:20 PM`, `Aug 3, 2:15 PM`
    /// -- and the bare clock for a second break on a day already named.
    private func stampWord(_ at: Date?, withDay: Bool) -> String? {
        guard let at else { return nil }
        let clock = MsgTime.clockWord(at)
        guard withDay else { return clock }
        return MsgTime.dayLabel(at, now: model.now) + " " + clock
    }

    // MARK: the runs

    /// Whether the run at `index` is the last one of its group: the next run
    /// is on the other side, is under a separator, or there is no next run.
    private func closesGroup(_ index: Int) -> Bool {
        let next = index + 1
        guard next < runs.count else { return true }
        if runs[next].isFromMe != runs[index].isFromMe { return true }
        return separator(at: next) != nil
    }

    /// Whether the run at `index` opens a turn -- the run above it came from
    /// the other side. A run under a separator is not given it: the separator
    /// is already the break.
    private func opensTurn(_ index: Int) -> Bool {
        guard index > 0, separator(at: index) == nil else { return false }
        return runs[index - 1].isFromMe != runs[index].isFromMe
    }

    @ViewBuilder
    private func run(_ record: MessageRecord, index: Int, width: CGFloat) -> some View {
        let text = record.text ?? ""
        // A record with no text and nothing attached still happened, so it
        // still gets a bubble -- with the fact in it. An empty one was a hole
        // in the log that read as a rendering bug rather than as a message.
        let empty = text.isEmpty && record.attachments.isEmpty
        let body = empty ? "[no text]" : text
        // The disc goes on the LAST run of a group, so it sits beside the
        // newest thing that side said, and the gutter is held open for the
        // rest so two consecutive runs do not step sideways.
        let closes = closesGroup(index)

        MsgRun(text: body,
               outbound: record.isFromMe,
               tone: record.isFromMe ? .sent : .inbound,
               slack: slack(width, outbound: record.isFromMe),
               unread: !record.isFromMe && index == runs.count - 1
                   && (chat.map { model.unreadCount($0) > 0 } ?? false),
               lead: {
                   Group {
                       if closes, !record.isFromMe {
                           Avatar(who: record.senderName ?? chat?.name,
                                  dim: false, tight: true)
                               .frame(width: 22, height: 22)
                       } else {
                           MsgGutter()
                       }
                   }
               },
               // Under the words, inside the bubble. A photograph is part of
               // the message rather than a note about it, and a row that
               // carried nothing but a photograph is a bubble with only that
               // in it.
               tail: tiles(for: record),
               textInk: empty ? M.inkDim : nil)
            .padding(.top, opensTurn(index) ? 8 : 0)
            .transition(riseIn)
    }

    /// The tiles for one row, or nothing at all when it carried no files.
    private func tiles(for record: MessageRecord) -> AnyView? {
        guard !record.attachments.isEmpty else { return nil }
        return AnyView(AttachmentTiles(key: record.key,
                                       attachments: record.attachments,
                                       model: model,
                                       onLift: { lifted = $0 },
                                       onGrow: { grew += 1 }))
    }

    /// A send this page is holding, or has made and not yet seen come back.
    ///
    /// No transition on this one. Enter is a keystroke, and the whole point of
    /// drawing the bubble at once is that it is already there.
    @ViewBuilder
    private func optimistic(_ item: MessageDeliveryRow, width: CGFloat) -> some View {
        // The first of them opens a turn if the transcript's last run was
        // theirs; the rest are one group with each other.
        let first = pending.first?.id == item.id
        let after = runs.last.map { !$0.isFromMe } ?? false
        let action: String? = switch item.stage {
        case .holding: "undo"
        case .retryable where sendable && item.retryRequest != nil: "try again"
        default: nil
        }

        MsgRun(text: item.text,
               outbound: true,
               tone: [.refused, .retryable, .unknown].contains(item.stage) ? .failed : .sent,
               slack: slack(width, outbound: true),
               status: MsgStatus(word: item.stage.label, act: action),
               onStatusAct: { act(on: item) })
            .padding(.top, first && after ? 8 : 0)
    }

    /// 26% of the log held back from an inbound run and 34% from an outbound
    /// one, which is the boards' `max-width: 74%` and `66%` said as flow.
    private func slack(_ width: CGFloat, outbound: Bool) -> CGFloat {
        (width - 36) * (outbound ? 0.34 : 0.26)
    }

    /// A new run arriving: 160ms of ease-out and 4pt of rise, and opacity alone
    /// where the system has been told not to move things. Nothing else in this
    /// pane moves.
    private var riseIn: AnyTransition {
        stillness
            ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                          removal: .opacity)
    }

    // MARK: - the dock

    /// Always present, and the same three pixels of frame whatever it holds:
    /// one faint rule and 10pt, which is the least a band at the bottom of a
    /// pane can be and still be a band.
    private var dock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            MsgComposer(text: $reply,
                        placeholder: placeholder,
                        maxLength: MessageRoute.maxSendBody,
                        focused: $typing,
                        onSend: enter,
                        canSend: sendable,
                        draft: sparkPhase,
                        onDraft: spark,
                        onCancel: { escape() })
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }

    /// `iMessage` or `Text Message`, off the chat's own service. The same word
    /// the Messages app puts there, which is how a person knows which pipe a
    /// text is about to go down before they write it.
    private var placeholder: String {
        // A chat the allowlist has not opened for sending says so where the
        // prompt would be, rather than swallowing the keystroke in silence.
        guard sendable else { return "sending is off for this chat" }
        // The one other thing the empty field is ever used to say. It is the
        // whole of what `thinking` looks like in words, and it goes the moment
        // there is a character in the box.
        if askedAt != nil { return "charon is writing…" }
        return (chat?.service ?? "iMessage").lowercased() == "sms"
            ? "Text Message" : "iMessage"
    }

    // MARK: - charon's draft

    /// The draft on file, and the stamp that names it.
    private var draftOnFile: (text: String, stamp: String)? {
        guard let draft = thread?.draft, draft.status == "ready" else { return nil }
        guard let text = draft.text, !text.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return nil }
        return (text, draft.at ?? text)
    }

    /// One that has not been taken, sent over or put away yet.
    private var waitingDraft: (text: String, stamp: String)? {
        guard let held = draftOnFile, held.stamp != answeredDraft else { return nil }
        return held
    }

    /// What the sparkle is. Something waiting outranks something being waited
    /// for: a draft that landed while the field had words in it has already
    /// ended the wait, and the dot is the only thing left to say about it.
    private var sparkPhase: DraftSpark.Phase {
        if waitingDraft != nil { return .ready }
        if askedAt != nil { return .thinking }
        return .idle
    }

    /// The sparkle, and the `e` key. Take the one that is waiting, or ask for
    /// one; while one is being written this does nothing, which is what the dim
    /// sparkle is saying.
    private func spark() {
        if let waitingDraft {
            take(waitingDraft.text)
            return
        }
        guard askedAt == nil, thread != nil else { return }
        // Whatever is on file is old news the moment a new one is asked for.
        // Without this the wait would end on the draft it started with: one
        // already taken and answered would come straight back into the field
        // the first time the thread was re-read.
        answerDraft()
        askedAt = Date()
        draftTask?.cancel()
        draftTask = Task { await pursueDraft() }
    }

    /// Ask, then watch for the answer at a watched pace, and give up after a
    /// minute rather than sitting dim for the rest of the session.
    private func pursueDraft() async {
        // A refusal is an answer. Nothing is being written, so nothing is worth
        // waiting for and the sparkle says so at once rather than in a minute.
        guard await model.store.requestDraft(chatKey: chatKey, instructions: nil) else {
            askedAt = nil
            return
        }
        await load()
        let until = Date().addingTimeInterval(msgDraftWait)
        while !Task.isCancelled, askedAt != nil, Date() < until {
            try? await Task.sleep(for: msgDraftPoll)
            if Task.isCancelled { return }
            guard askedAt != nil else { return }
            await load()
        }
        if !Task.isCancelled { askedAt = nil }
    }

    /// A fresh copy of the thread, read for the one thing that was asked for.
    ///
    /// A draft this page asked for lands IN the field, because it was asked
    /// for: that is the whole of what the sparkle promises. What it may never
    /// do is land on top of words somebody typed while it was being written --
    /// those wait behind the dot, and one more press puts them in.
    private func absorbDraft() {
        guard askedAt != nil, let waitingDraft else { return }
        askedAt = nil
        guard reply.isEmpty else { return }
        take(waitingDraft.text)
    }

    /// Taking it. Instant, and no animation: it is one string arriving in a
    /// box, and a thing that slid would be the app performing the move rather
    /// than making it.
    private func take(_ text: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reply = text
            filled = text
        }
        saveTask?.cancel()
        askedAt = nil
        answerDraft()
        typing = true
    }

    /// The draft on file, answered. Held by its stamp, so the dot comes back
    /// the moment charon writes a newer one and not before: one the user has
    /// already taken, already sent over or already put away is not waiting any
    /// more, and offering it again would be the app repeating itself.
    private func answerDraft() {
        guard let held = draftOnFile else { return }
        answeredDraft = held.stamp
    }

    /// Esc, in the field. Empty the field, then put a waiting draft away, then
    /// give the keys back to the tab -- one thing per press, innermost first.
    private func escape() -> Bool {
        if !reply.isEmpty {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { reply = "" }
            filled = ""
            return true
        }
        if waitingDraft != nil {
            answerDraft()
            return true
        }
        typing = false
        return true
    }

    // MARK: - the send
    //
    // Enter files nothing. It puts the bubble on screen, empties the field and
    // starts a clock; the request goes when the clock runs out, and `undo`
    // takes the words back before it does.

    private func enter() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sendable else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reply = ""
            filled = ""
        }
        saveTask?.cancel()
        answerDraft()

        model.holdMessage(MessageSendRequest(chatKey: chatKey, body: text))
    }

    /// Whether this chat may be written to at all. `off` and unknown are the
    /// same refusal, here as on the Pi.
    private var sendable: Bool { chat?.policy == .confirm }

    private func act(on item: MessageDeliveryRow) {
        if let retry = item.retryRequest, sendable {
            model.holdMessage(retry)
        } else if model.undoMessage(item.id) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                reply = item.text
                filled = item.text
            }
            saveTask?.cancel()
            typing = true
        }
    }

    // MARK: - acts

    private func load() async {
        let source = model.store
        do {
            let got = try await source.thread(chatKey: chatKey, limit: MessageRoute.threadLimit, before: nil)
            guard !Task.isCancelled, source === model.store else { return }
            guard let got else {
                missing = true
                return
            }
            missing = false
            failure = nil
            thread = got
            settle(got)
        } catch is CancellationError {
            return
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Re-read on a cadence, and stand down while the window is not on screen.
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: msgPoll)
            if Task.isCancelled { return }
            guard model.active else { continue }
            await load()
        }
    }

    /// Everything that has to happen the moment a fresh copy lands.
    private func settle(_ got: MessageThread) {
        // Reading it is what marks it read. The optimistic set is the guard as
        // well as the display: without it the poller's own lag would file a
        // fresh read request on every poll of a chat that is already open.
        // The count comes off the list's summary (and the thread head when the
        // collector carries it); the thread's own chat object did not, which is
        // why an open chat kept its dot.
        let listed = model.messageChats.first { $0.chatKey == chatKey }
        let unread = max(listed?.unread ?? 0, got.chat?.unread ?? 0, self.chat?.unread ?? 0)
        if unread > 0, !model.readHereChats.contains(chatKey) {
            Task { await model.markChatRead(chatKey) }
        }
        openOnce(got)
        absorbDraft()
        model.reconcileDelivery(chatKey: chatKey, thread: got)
    }

    /// His own unsent words, once, on the way in. charon's draft is NOT put in
    /// the field here: one nobody asked for waits behind the sparkle's dot,
    /// which is what `waitingDraft` reads.
    private func openOnce(_ got: MessageThread) {
        guard !opened else { return }
        opened = true
        let mine = got.userDraft?.text
        guard let mine, !mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        reply = mine
        filled = mine
    }

    private func scheduleSave(_ text: String) {
        saveTask?.cancel()
        guard thread != nil, text != (filled ?? "") else { return }
        saveTask = Task {
            try? await Task.sleep(for: msgSaveAfter)
            if Task.isCancelled { return }
            _ = await model.store.saveDraft(chatKey: chatKey, body: text)
        }
    }
}
