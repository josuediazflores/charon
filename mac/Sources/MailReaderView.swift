import AppKit
import SwiftUI

/* One message, and the reply to it.
 *
 * Ported from the web console's mail reader.
 *
 * **The body is text and is drawn as text.** No markdown renderer, no web
 * view, no HTML. It arrived from outside this system and is the only document
 * in the app that did; plain preformatted text is the honest treatment for it
 * and the one that cannot be talked into rendering something.
 *
 * **SEND is the only irreversible thing this app does.** So it is two clicks
 * with the recipient printed between them, and the recipient is printed rather
 * than typed: the collector computes who a reply goes to from the original's
 * own headers, and the address on screen is an echo of that decision rather
 * than an input into it. CONFIRM SEND is the one filled cyan in the whole app.
 *
 * **One instance per message, which the caller guarantees with `.id(key)`.**
 * Half the state here is a half-written reply, and a view that outlived a
 * navigation would carry one message's draft into another message's save
 * route. Rather than a reset that names nine fields and goes stale the first
 * time a tenth is added, the reader is simply a new reader for a new message.
 */

/// How long typing settles before the draft is saved. Long enough that a
/// sentence is one save rather than forty, short enough that closing the window
/// mid-thought loses nothing worth having.
private let saveAfter: Duration = .milliseconds(1500)

/// How often the open message is re-read while something on the Pi is working
/// on it.
private let workingPoll: Duration = .seconds(10)

/// Urgency, as a chip carrying its own word. The word is the channel that
/// prints; the border colour is the reinforcement, and only the top two get one
/// -- amber and red mean caution and fault everywhere in this console and are
/// not spent on a message that wants nothing.
private func readerUrgency(_ level: Int) -> (word: String, tone: Color?) {
    switch level {
    case 3: return ("needs today", M.fault)
    case 2: return ("this week", M.caution)
    case 1: return ("whenever", nil)
    default: return ("ignorable", nil)
    }
}

enum Doc: Equatable {
    case loading
    case missing
    case error(String)
    case ok(MailMessageFull)

    var msg: MailMessageFull? {
        if case .ok(let m) = self { return m }
        return nil
    }
}

struct MailReaderView: View {

    let messageKey: String
    let model: MailModel

    @State private var doc: Doc = .loading
    @State private var tick = 0

    // ── the reply ──
    @State private var reply = ""
    /// Exactly what this page last put in the field. Typing moves the field off
    /// it and nothing moves it back, so "untouched" keeps meaning what it says
    /// even after the debounced save has written his words to the Pi.
    @State private var filled: String?
    /// Whether the field has been filled from the Pi at all yet.
    @State private var opened = false
    /// The stamp on the session draft this page has already offered, which is
    /// its identity: the same draft arriving on every poll is not a new offer.
    @State private var seenDraft: String?
    /// A draft that landed while he was mid-sentence. Held rather than applied.
    /// Overwriting what somebody typed is the one thing this page must never do
    /// on its own, and a draft dropped in silence is the other.
    @State private var waiting: String?
    @State private var savedAt: (ok: Bool, at: String)?
    @State private var saveTask: Task<Void, Never>?

    // ── asking for a draft ──
    @State private var instructions = ""
    @State private var drafting = false
    @State private var draftRefused = false
    /// The draft's stamp when a new one was asked for, so an old ready draft
    /// cannot be mistaken for the answer to a question just asked.
    @State private var askedOver: String?

    // ── surfaces ──
    @State private var summaryOpen = ConsoleSettings.shared.summaryOpen
    /// Shut by default, which is the resting state of reading mail. Most
    /// messages are read and not answered, and an empty field standing open
    /// under every one of them is the page asserting the opposite.
    @State private var composing = false
    @State private var autoOpened: String?

    // ── archive ──
    @State private var archiving = false
    @State private var archiveRefused = false

    // ── sending ──
    @State private var confirming = false
    @State private var filing = false
    @State private var refused = false
    @State private var sentId: String?

    @State private var attachmentNote: String?

    private enum Field { case body, instructions }
    @FocusState private var focus: Field?

    /// The reader's own width, measured on the pane rather than the window.
    ///
    /// At the window's 720pt minimum with the rail pinned out this pane is
    /// about 520, and the action bar's five verbs plus the walk want 540 of it
    /// -- so the bar used to force the whole tab wider than the window it is
    /// in, carrying the app bar's controls, the walk arrows and the standing
    /// rule off the right edge with it. Nothing here is allowed a width it
    /// cannot have; below the step the bar takes a second row instead.
    @State private var width: CGFloat = 0

    private var tight: Bool { width > 0 && width < 700 }

    /// How much of the tab's standing rule sits under this pane. The scroll
    /// content clears it, so the last line of a message can never end up behind
    /// the sentence about who may click SEND.
    @Environment(\.mailFootHeight) private var footHeight: CGFloat

    // MARK: - body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch doc {
                case .loading: loadingState
                case .missing: missingState
                case .error(let why): errorState(why)
                case .ok(let msg): message(msg)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, max(28, footHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .htMeasureWidth { width = $0 }

        // Re-read on a tick, never re-blanked by one: the record is replaced
        // when the fetch lands rather than cleared when it starts, because
        // clearing it every ten seconds would be the polling loop eating the
        // body somebody is reading.
        .task(id: tick) { await load() }

        // The clock only runs while the Pi owes an answer: a message nobody is
        // working on is re-read never, and the telemetry feed is what notices
        // anything else about it.
        .task(id: working) {
            guard working else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: workingPoll)
                if Task.isCancelled { return }
                tick += 1
            }
        }

        .onChange(of: reply) { _, text in scheduleSave(text) }
        .onChange(of: focus) { _, now in model.textFocused = now != nil }
        .onChange(of: model.replyRequests) { _, _ in openCompose() }
        .onDisappear {
            saveTask?.cancel()
            model.textFocused = false
        }
    }

    // MARK: - the four doc states

    private var loadingState: some View {
        EmptyPane(glyph: .mail, line: "Reading message", why: messageKey)
    }

    private var missingState: some View {
        Card {
            Text("No message with this key")
                .font(Face.title)
                .foregroundStyle(M.inkBright)
                .fixedSize(horizontal: false, vertical: true)
            Note(text: "The Pi does not have \(messageKey). It may have been pruned, "
                 + "or the address may be from another mailbox.")
        }
    }

    private func errorState(_ why: String) -> some View {
        Card {
            Text("Message unreadable")
                .font(Face.title)
                .foregroundStyle(M.inkBright)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Flag(icon: .fault, word: "unreadable", tone: M.fault)
                Text(why).font(Face.body).foregroundStyle(M.inkDim)
            }
            .padding(.top, 10)
            Note(text: "The collector did not hand over this message. It may still be "
                 + "on the Pi.")
        }
    }

    // MARK: - the message

    @ViewBuilder
    private func message(_ msg: MailMessageFull) -> some View {
        card(msg)

        if archiveRefused {
            HStack(spacing: 8) {
                Flag(icon: .fault, word: "archive", tone: M.fault)
                Text("not filed · the collector did not take it")
                    .font(Face.body).foregroundStyle(M.inkDim)
            }
        }

        if let ai = msg.ai, summaryOpen {
            summary(ai)
        }

        bodyBlock(msg)

        if !msg.attachments.isEmpty { attachments(msg) }

        if composing {
            compose(msg)
        } else if draftLine(msg) != nil || sendWord(msg) != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let line = draftLine(msg) {
                    Button(action: openCompose) {
                        Text(line)
                            .font(Face.body)
                            .foregroundStyle(M.inkMid)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // Of everything on this page the outgoing state is the one thing
                // that may never be behind a click, because it is the only thing
                // here the reader cannot undo by looking again.
                sendLine(msg)
            }
        }
    }

    /// Subject, then who it is from, then the verbs. The three questions a
    /// reader asks, in that order.
    private func card(_ msg: MailMessageFull) -> some View {
        Card {
            Text(msg.subject)
                .font(Face.title)
                .lineSpacing(4)
                .foregroundStyle(M.inkBright)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                Avatar(who: msg.fromName ?? msg.fromAddr, large: true)

                VStack(alignment: .leading, spacing: 0) {
                    // Both truncate rather than wrap, and the name goes last:
                    // this row has to fit whatever the pane turns out to be.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(msg.fromName ?? msg.fromAddr ?? "unknown")
                            .font(Face.body)
                            .foregroundStyle(M.inkBright)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)
                        // The address beside the name and dim, never instead of
                        // it: a display name is whatever the sender typed, so
                        // the thing that identifies them stays on the line.
                        if let name = msg.fromName, !name.isEmpty, let addr = msg.fromAddr {
                            Text(addr)
                                .font(Face.body)
                                .foregroundStyle(M.inkDim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Chip(key: "from", value: sender(msg))
                            .help(sender(msg))
                        Chip(key: "to", value: msg.to ?? "not stated")
                            .help(msg.to ?? "not stated")
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Pushed to the far end and dim: a stamp is bookkeeping, and the
                // name is the line. It is also the first thing to give up room,
                // for the same reason -- no `fixedSize` on a row that has to
                // fit, and the lowest priority in it.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(msg.date != nil ? Fmt.stamp(msg.date) : "no date header")
                    Text(metaLine(msg))
                }
                .font(Face.body)
                .monospacedDigit()
                .foregroundStyle(M.inkDim)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            }
            .padding(.top, 12)

            verdict(msg)
            actions(msg)
        }
    }

    private func metaLine(_ msg: MailMessageFull) -> String {
        var parts: [String] = []
        if let date = msg.date { parts.append("\(Fmt.relTime(date)) ago") }
        if let size = msg.size { parts.append(Fmt.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    /// The sender, as one line: the name if the header carried one, and the
    /// address either way, because a display name is whatever the sender typed.
    private func sender(_ msg: MailMessageFull) -> String {
        if let name = msg.fromName, let addr = msg.fromAddr { return "\(name) <\(addr)>" }
        return msg.fromAddr ?? msg.fromName ?? "unknown"
    }

    @ViewBuilder
    private func verdict(_ msg: MailMessageFull) -> some View {
        // Null urgency on a failed record is "no verdict", not level 0.
        let urg = msg.ai?.urgency.map(readerUrgency)
        let tags = msg.ai?.tags ?? []

        if urg != nil || !tags.isEmpty {
            HStack(spacing: 6) {
                if let urg {
                    Chip(key: "urgency", value: urg.word, tone: urg.tone)
                }
                ForEach(tags, id: \.self) { Tag(text: $0) }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
    }

    /// The verbs. Icon over label, bordered, and the one that is on gets the
    /// filled ground. Not one of them is cyan: the only control in this app
    /// worth calling "this one" is CONFIRM SEND, and it is a long way down.
    private func actions(_ msg: MailMessageFull) -> some View {
        let walk = model.walk(from: messageKey)
        let gone = model.isArchived(msg.key)

        return VStack(spacing: 0) {
            Hairline()
                .padding(.top, 14)

            // **Two rows under 700, one over it.** The five verbs and the walk
            // want about 540 points between them and this pane can be 520, so
            // below the step the walk drops to a row of its own and the two
            // printed key caps beside it go with it: `k` and `j` are a reminder
            // of a binding that still works, and a reminder is the first thing
            // a narrow window can afford to lose. Right-aligned in both, so the
            // bar reads as one block that folded rather than as two bars.
            Group {
                if tight {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            verbs(msg, gone: gone)
                        }
                        if walk.position != nil {
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                walkBox(walk, caps: false)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        verbs(msg, gone: gone)
                        walkBox(walk, caps: true)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func verbs(_ msg: MailMessageFull, gone: Bool) -> some View {
        // A key that opens a surface is a key that closes it -- there is
        // no third state to get wrong.
        ActionKey(icon: .reply, label: "Reply", on: composing, help: "Reply (r)") {
            if composing { composing = false } else { openCompose() }
        }

        // Opens the panel on the way: the queued to ready walk needs
        // somewhere to land, and a draft that arrived into a shut panel
        // would be the Pi answering a question in a room nobody is in.
        ActionKey(icon: .pencil, label: "AI draft", disabled: draftWorking(msg)) {
            composing = true
            Task { await askForDraft(msg) }
        }

        // Off entirely where triage never ran: a toggle for a panel that
        // does not exist is a control that lies about what is here.
        ActionKey(icon: .sparkle, label: "Summary",
                  on: msg.ai != nil && summaryOpen,
                  disabled: msg.ai == nil) {
            summaryOpen.toggle()
        }

        ActionKey(icon: .archive, label: gone ? "Archived" : "Archive",
                  disabled: gone || archiving) {
            Task { await archiveAndAdvance(msg) }
        }

        // Fire and go: the optimistic store outlives this page, so a
        // refusal rolls the dot back on the list, which is the only
        // place the answer is visible anyway.
        ActionKey(icon: .unread, label: "Unread", disabled: gone) {
            Task { await model.markUnread(messageKey) }
            model.selection = nil
        }
    }

    /// Drawn only where the payload actually lists this key -- with no list
    /// there is no order to walk, and a pair of dead arrows would imply there
    /// is.
    @ViewBuilder
    private func walkBox(_ walk: MailModel.Walk, caps: Bool) -> some View {
        if let position = walk.position {
            HStack(spacing: 2) {
                IconKey(icon: .left, label: "newer message",
                        help: "newer message (k)", disabled: walk.prev == nil) {
                    if let prev = walk.prev { model.selection = prev }
                }
                Text(position)
                    .font(Face.body)
                    .monospacedDigit()
                    .foregroundStyle(M.inkDim)
                    .fixedSize()
                    .padding(.horizontal, 4)
                IconKey(icon: .right, label: "older message",
                        help: "older message (j)", disabled: walk.next == nil) {
                    if let next = walk.next { model.selection = next }
                }
            }
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                .strokeBorder(M.line, lineWidth: 1))
            .padding(.leading, 4)

            if caps {
                HStack(spacing: 3) { Kbd(text: "k"); Kbd(text: "j") }
                    .padding(.leading, 6)
            }
        }
    }

    // MARK: - what the session made of it

    /// Bordered, labelled, and above the body rather than inside it: this is
    /// the machine's reading of somebody else's words and it is never allowed
    /// to sit where the sender's own writing would.
    private func summary(_ ai: MailAiArtifact) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon(name: .sparkle, size: 14).foregroundStyle(M.accent)
                Text("SUMMARY")
                    .font(Face.body).tracking(1.1).foregroundStyle(M.inkMid)
                Spacer(minLength: 8)
                Text(ai.model ?? "model unstated")
                    .font(Face.body).foregroundStyle(M.inkDim).lineLimit(1)
                IconKey(icon: .down, label: "collapse the summary") { summaryOpen = false }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 10)

            Hairline()

            VStack(alignment: .leading, spacing: 6) {
                if ai.status == "failed" {
                    Text("Triage gave up on this message. Nothing below it is missing; "
                         + "there simply is no reading of it.")
                        .font(Face.body).foregroundStyle(M.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if ai.summary.isEmpty {
                    Text("No summary written.")
                        .font(Face.body).foregroundStyle(M.ink)
                } else {
                    ForEach(Array(ai.summary.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("·").foregroundStyle(M.inkDim)
                            Text(line).foregroundStyle(M.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Face.body)
                    }
                }

                Text("written by a session that read this message · not the sender's words")
                    .font(Face.body).foregroundStyle(M.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: M.rLg, style: .continuous).fill(M.surface))
        .overlay(RoundedRectangle(cornerRadius: M.rLg, style: .continuous)
            .strokeBorder(M.line, lineWidth: 1))
    }

    // MARK: - the message itself

    /// Preformatted, deliberately. Whatever is in here was written by somebody
    /// outside this system and is displayed, never interpreted.
    @ViewBuilder
    private func bodyBlock(_ msg: MailMessageFull) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if msg.bodyCached {
                Text(msg.body ?? "")
                    .font(Face.body)
                    .lineSpacing(7)
                    .foregroundStyle(M.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 2)
            } else {
                Note(text: "The poller kept no copy of this body. Messages over 5 MB "
                     + "are indexed and not stored.", top: 0)
            }

            if msg.bodyTruncated {
                Note(text: "body truncated at 64 KB · the whole message is on the Pi",
                     top: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachments(_ msg: MailMessageFull) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ATTACHED")
                    .font(Face.body).tracking(0.88).foregroundStyle(M.inkDim)

                ForEach(msg.attachments) { att in
                    Button {
                        Task { await save(att, from: msg) }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(name: .clip, size: 13).foregroundStyle(M.inkDim)
                            Text(att.name).font(Face.body).foregroundStyle(M.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text(Fmt.bytes(att.size))
                                .font(Face.body).monospacedDigit().foregroundStyle(M.inkDim)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(M.raised))
                        .overlay(Capsule(style: .continuous).strokeBorder(M.line, lineWidth: 1))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("\(att.name) · \(Fmt.bytes(att.size)) · \(att.ctype)")
                }
                Spacer(minLength: 0)
            }

            if let attachmentNote {
                Text(attachmentNote).font(Face.body).foregroundStyle(M.inkDim)
            }
        }
    }

    // MARK: - the reply

    private func compose(_ msg: MailMessageFull) -> some View {
        // Echoed, never sent. The collector computes the recipient from the
        // original's reply-to; this is the app reading that decision back so he
        // can see who is about to hear from him.
        let to = msg.replyTo ?? msg.fromAddr
        let subject = replySubject(msg.subject)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon(name: .reply, size: 14).foregroundStyle(M.inkMid)
                Text("REPLY").font(Face.body).tracking(1.1).foregroundStyle(M.inkMid)
                Spacer(minLength: 8)
                // Shutting it files nothing and drops nothing; the line that
                // replaces it says so.
                IconKey(icon: .close, label: "close the reply") { composing = false }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Hairline()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Chip(key: "to", value: to ?? "nobody this app can work out", wraps: true)
                    Text(subject)
                        .font(Face.body).foregroundStyle(M.inkDim).lineLimit(1)
                    Spacer(minLength: 0)
                }

                TextEditor(text: $reply)
                    .font(Face.body)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(M.inkBright)
                    .frame(minHeight: 176)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                        .fill(M.ground))
                    .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                        .strokeBorder(focus == .body ? M.focus : M.line, lineWidth: 1))
                    .focused($focus, equals: .body)
                    .accessibilityLabel("reply body")
                    .padding(.top, 10)

                Note(text: savedAt.map { $0.ok
                    ? "draft saved \($0.at)"
                    : "draft not saved · the collector did not take it" }
                    ?? "saved to the Pi a second after you stop typing")

                // A draft that arrived into a field with his own words in it.
                // Offered rather than applied, and offered rather than dropped:
                // he asked for it, and he is also the one who typed.
                if let held = waiting {
                    HStack(spacing: 8) {
                        Text("a session draft is ready and your own text is in the field")
                            .font(Face.body).foregroundStyle(M.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                        KeyButton("Use the draft") { fill(held) }
                        KeyButton("Keep mine", variant: .quiet) { waiting = nil }
                    }
                    .padding(.top, 10)
                }

                LabelledRule(text: "draft it")

                TextField("", text: $instructions, prompt: Text(
                    "instructions, optional: say no to the RFP, ask for their rate card")
                    .foregroundStyle(M.inkDim))
                    .textFieldStyle(.plain)
                    .font(Face.body)
                    .foregroundStyle(M.inkBright)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                        .fill(M.ground))
                    .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                        .strokeBorder(focus == .instructions ? M.focus : M.line, lineWidth: 1))
                    .focused($focus, equals: .instructions)
                    .accessibilityLabel("instructions for the draft")
                    // Enter files it, which keeps the field usable without
                    // reaching back up the page.
                    .onSubmit {
                        guard !draftWorking(msg) else { return }
                        Task { await askForDraft(msg) }
                    }
                    .padding(.top, 10)

                Note(text: "AI DRAFT above reads this line · Enter files it from here")

                if draftWorking(msg) {
                    HStack(spacing: 8) {
                        Flag(icon: .alert, word: "drafting", tone: M.caution)
                        Text("a session on the Pi is writing it · this page is watching")
                            .font(Face.body).foregroundStyle(M.inkDim)
                    }
                    .padding(.top, 10)
                }
                if draftRefused {
                    HStack(spacing: 8) {
                        Flag(icon: .fault, word: "draft", tone: M.fault)
                        Text("not filed · the collector did not take it")
                            .font(Face.body).foregroundStyle(M.inkDim)
                    }
                    .padding(.top, 10)
                }
                if !draftWorking(msg), msg.draft?.status == "failed" {
                    HStack(spacing: 8) {
                        Flag(icon: .fault, word: "draft", tone: M.fault)
                        Text(msg.draft?.error ?? "the session did not produce one")
                            .font(Face.body).foregroundStyle(M.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                }

                LabelledRule(text: "send it")

                sendControls(msg, to: to)
                sendLine(msg)
            }
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: M.rLg, style: .continuous).fill(M.surface))
        .overlay(RoundedRectangle(cornerRadius: M.rLg, style: .continuous)
            .strokeBorder(M.line, lineWidth: 1))
    }

    // MARK: - CONFIRM SEND
    //
    // Two steps, and the address printed on the second one. The first click
    // asks the question and files nothing; the second answers it -- and what is
    // on the button in between is the only thing worth checking: who this is
    // going to.

    @ViewBuilder
    private func sendControls(_ msg: MailMessageFull, to: String?) -> some View {
        if !confirming {
            HStack(spacing: 8) {
                KeyButton("Send", icon: .send,
                          disabled: to == nil || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filing) {
                    // No request. This click only asks the question.
                    confirming = true
                }
                Text(sendReason(to: to))
                    .font(Face.body).foregroundStyle(M.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("This leaves the Pi and cannot be taken back.")
                    .font(Face.body).foregroundStyle(M.inkDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    // The one filled cyan in the app. Of everything here this is
                    // the single control that does something the Pi cannot undo,
                    // so the recipient rides on its own face -- the last thing
                    // clicked is also the last thing read. (Cyan, use 2 of 2.)
                    KeyButton(variant: .send, icon: .send, action: { Task { await send(msg) } }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Confirm send")
                            Text(to ?? "")
                                .font(Face.body)
                                .opacity(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityLabel("Confirm send to \(to ?? "nobody")")

                    KeyButton("Cancel", variant: .quiet) { confirming = false }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: M.r, style: .continuous).fill(M.ground))
            .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .strokeBorder(M.lineStrong, lineWidth: 1))
            .padding(.top, 12)
        }
    }

    private func sendReason(to: String?) -> String {
        if to == nil { return "no reply address on this message" }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "nothing written yet"
        }
        return "one more click to confirm"
    }

    /// The send this page is watching: the one it filed, or the newest on
    /// record for a reply sent from somewhere else.
    private func record(_ msg: MailMessageFull) -> MailOutboxEntry? {
        if let sentId { return msg.outbox.first { $0.id == sentId } }
        return msg.outbox.last
    }

    /// The one word the send is currently worth, or nil when nothing has been
    /// tried. The word is the whole channel: no colour is spent on any state
    /// here, so a printed page still says which of them happened.
    private func sendWord(_ msg: MailMessageFull) -> String? {
        let rec = record(msg)
        if filing { return "QUEUEING" }
        if refused || rec?.status == .error { return "SEND FAILED" }
        if rec?.status == .sent { return "SENT \(Fmt.hhmm(rec?.sentAt))" }
        if sentId != nil || rec?.status == .queued { return "QUEUED" }
        return nil
    }

    private func sendWhy(_ msg: MailMessageFull) -> String? {
        let rec = record(msg)
        if refused { return "the collector did not take it" }
        if rec?.status == .error { return rec?.error ?? "the Pi could not send it" }
        if rec?.status == .sent { return rec?.smtpReply ?? "to \(rec?.to ?? "")" }
        if sendWord(msg) == "QUEUED" { return "waiting for the actions worker on the Pi" }
        return nil
    }

    @ViewBuilder
    private func sendLine(_ msg: MailMessageFull) -> some View {
        if let word = sendWord(msg) {
            let failed = refused || record(msg)?.status == .error
            HStack(spacing: 8) {
                Text(word)
                    .font(Face.body).tracking(0.44).foregroundStyle(M.inkBright)
                if let why = sendWhy(msg) {
                    Text("· " + why)
                        .font(Face.body).foregroundStyle(M.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failed {
                    // A retry is a new click and a new outbox record, never a
                    // resend of the old one: nothing here may ever be able to
                    // put two copies of the same email in somebody's inbox. It
                    // goes back to the confirm step with the text intact.
                    KeyButton("Retry") {
                        refused = false
                        sentId = nil
                        confirming = true
                        composing = true
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - derived reply state

    private func draftWorking(_ msg: MailMessageFull) -> Bool {
        drafting || msg.draft?.status == "queued"
    }

    /// Whether a reply to this message exists anywhere: his own words still in
    /// the field, his own draft on the Pi, or one a session wrote. The field is
    /// counted first and deliberately -- the debounced save is a second and a
    /// half behind him, and a panel closed inside that second must still report
    /// that something is in it.
    private func draftHeld(_ msg: MailMessageFull) -> Bool {
        if !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !(msg.userDraft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if msg.draft?.status == "ready",
           !(msg.draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// The line that stands where the compose area is not. Queued says so in
    /// the present tense, because a session on the Pi is writing it right now.
    private func draftLine(_ msg: MailMessageFull) -> String? {
        if draftWorking(msg) { return "a draft is being written..." }
        if draftHeld(msg) { return "a draft is waiting · open with REPLY" }
        return nil
    }

    /// `Re:` once, never twice.
    private func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    private var working: Bool {
        guard let msg = doc.msg else { return false }
        return draftWorking(msg)
            || filing
            || (sentId != nil && record(msg) == nil)
            || record(msg)?.status == .queued
    }

    // MARK: - acts

    private func load() async {
        do {
            let got = try await model.store.message(key: messageKey)
            guard let got else {
                doc = .missing
                return
            }
            doc = .ok(got)
            settle(got)
        } catch is CancellationError {
            return
        } catch {
            doc = .error(error.localizedDescription)
        }
    }

    /// Everything that has to happen the moment a fresh copy of the record
    /// lands. In the web these are four effects keyed on the record; here they
    /// are one call at the one place a record can change, which is the same
    /// thing said once.
    private func settle(_ msg: MailMessageFull) {
        // Reading it is what marks it read. The optimistic set is the guard as
        // well as the display: without it the poller's own minute of lag would
        // file a fresh read request on every ten-second poll of a message that
        // is already open.
        if msg.unread, !model.isRead(msg.key) {
            Task { await model.markRead(msg.key) }
        }

        // Handed over the moment the record can speak for itself: either the Pi
        // has taken the request, or a draft newer than the one that was there
        // when he asked has landed.
        if drafting, let written = msg.draft {
            if written.status == "queued" || written.at != askedOver { drafting = false }
        }

        // A request in flight opens the surface it is going to land on -- once
        // per request, by its stamp, rather than on every poll that still says
        // queued. He asked for this draft; a page that reopened the panel each
        // time he shut it would be arguing about a question he already answered.
        if msg.draft?.status == "queued" {
            let at = msg.draft?.at ?? "queued"
            if autoOpened != at {
                autoOpened = at
                composing = true
            }
        }

        applyDraft(msg)
    }

    /// The prefill rule.
    private func applyDraft(_ msg: MailMessageFull) {
        let draft = msg.draft
        let ready = (draft?.status == "ready" && !(draft?.text ?? "").isEmpty) ? draft?.text : nil

        // Opening it: his own draft if he has saved one, else a session draft
        // that is already written, else an empty field. Runs exactly once.
        if !opened {
            opened = true
            seenDraft = draft?.at
            let mine = msg.userDraft?.text
            if let mine, !mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fill(mine)
            } else if let ready {
                fill(ready)
            }
            return
        }

        // After that, only a session draft this page has not seen before. His
        // own copy is deliberately not consulted again: the save route wrote it
        // a second after he stopped typing, so preferring it forever would mean
        // AI DRAFT did nothing from the second keystroke onward.
        guard let ready else { return }
        let at = draft?.at
        guard at != seenDraft else { return }
        seenDraft = at
        if reply.isEmpty || reply == filled {
            fill(ready)
        } else {
            waiting = ready
        }
    }

    private func fill(_ text: String) {
        reply = text
        filled = text
        waiting = nil
        // The field is what the save watcher compares against, so it must not
        // file a save for text it put there itself.
        saveTask?.cancel()
    }

    private func scheduleSave(_ text: String) {
        guard case .ok = doc else { return }
        saveTask?.cancel()
        guard text != (filled ?? "") else { return }
        saveTask = Task {
            try? await Task.sleep(for: saveAfter)
            if Task.isCancelled { return }
            // `filled` is deliberately left alone. A save records what he wrote;
            // it does not make the field untouched again, or the next draft to
            // land would be free to write over words that had merely been filed.
            let ok = await model.store.saveDraft(key: messageKey, body: text)
            savedAt = (ok, Fmt.hhmm(Fmt.stampNow()))
        }
    }

    /// Open it and put him in it. The caret cannot be moved by the same update
    /// that mounts the box, so the focus follows the render that opening caused.
    private func openCompose() {
        composing = true
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            focus = .body
        }
    }

    private func askForDraft(_ msg: MailMessageFull) async {
        askedOver = msg.draft?.at
        drafting = true
        draftRefused = false
        let ok = await model.store.requestDraft(key: msg.key, instructions: instructions)
        if !ok {
            drafting = false
            draftRefused = true
            return
        }
        tick += 1
    }

    /// Out of the inbox, then wherever the setting says. Awaited rather than
    /// fired and forgotten, which is the one place this page differs from the
    /// list's archive control: the list stays on screen to report a refusal and
    /// this does not, so navigating first would mean a request the collector
    /// dropped left no trace anywhere.
    private func archiveAndAdvance(_ msg: MailMessageFull) async {
        archiving = true
        archiveRefused = false
        let ok = await model.archive(msg.key)
        archiving = false
        guard ok else {
            archiveRefused = true
            return
        }
        // The refusal above is checked first and is unconditional: nothing here
        // navigates on an archive the Pi would not take.
        if ConsoleSettings.shared.afterArchive == .inbox {
            model.selection = nil
        } else if let next = model.walk(from: messageKey).next {
            model.selection = next
        } else {
            model.selection = nil
        }
    }

    private func send(_ msg: MailMessageFull) async {
        // The strip goes the instant the second click lands, before the request:
        // a confirm still on screen while the post is in flight invites a third
        // click on a question already answered.
        confirming = false
        filing = true
        refused = false
        let id = await model.store.send(key: msg.key, body: reply)
        filing = false
        guard let id else {
            refused = true
            return
        }
        sentId = id
        tick += 1
    }

    private func save(_ att: MailAttachment, from msg: MailMessageFull) async {
        guard model.store.canDownloadAttachments else {
            attachmentNote = "demo mode · attachments live on the Pi and are not fetched here"
            return
        }
        do {
            let data = try await model.store.attachment(key: msg.key, n: att.n)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = att.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            attachmentNote = "saved \(att.name)"
        } catch {
            attachmentNote = "not saved · \(error.localizedDescription)"
        }
    }
}

// MARK: - shared furniture

/// A card: one step off the ground, hairlined, and rounded at the app's largest
/// radius.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: M.rLg, style: .continuous).fill(M.surface))
        .overlay(RoundedRectangle(cornerRadius: M.rLg, style: .continuous)
            .strokeBorder(M.line, lineWidth: 1))
    }
}

struct EmptyPane: View {
    let glyph: IconName
    let line: String
    var why: String?

    var body: some View {
        VStack(spacing: 10) {
            Icon(name: glyph, size: 30).foregroundStyle(M.lineStrong)
            Text(line).font(Face.body).foregroundStyle(M.inkDim)
            if let why {
                Text(why)
                    .font(Face.body).foregroundStyle(M.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }
}
