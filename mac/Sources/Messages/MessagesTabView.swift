import AppKit
import SwiftUI

/* The messages tab: a bar, one pane or two, and the standing rule under both.
 *
 * **The second room inside the console's one exception.** Everything around it
 * -- the rail, the top bar, the scanline overlay -- is the tty dialect; inside
 * this view the mail dialect applies and nothing else in the window changes.
 * The tab is handed the shell's own model rather than minting one, so there is
 * a single poller against a single Pi however many tabs the rail grows.
 *
 * **One pane or two is measured, not guessed**, and at the same width the mail
 * tab measures it at: above 1000pt of content box the column stays beside the
 * conversation, below it the conversation is the whole page and the column
 * stands down.
 *
 * **The keymap lives here and nowhere else.** One handler, at the top, so two
 * views cannot race for the same key. Every binding stands down while a field
 * has focus -- a bare letter that did not check would eat the j out of a
 * sentence.
 *
 *     j / k          walk the column: the summaries, Charon, then the chats
 *     → / ←          the same walk
 *     r              put the caret in the open chat's field
 *     e              take charon's draft on the open chat, or ask for one ·
 *                    archive the open summary (a chat has no archive route in
 *                    protocol v1)
 *     u              mark the open chat or summary read
 *     esc            close the pane
 *
 * Inside a field the keys belong to the field: Enter sends, Shift+Enter is a
 * newline, and Esc empties the field and then hands the keys back here. Tab is
 * nobody's here any more -- it used to take charon's line and there is no line,
 * so it walks the window like it does everywhere else. See
 * `MessagesThreadView`.
 *
 * **The pinned conversation is polled here** rather than by the pane that draws
 * it, because the row in the column needs it too and two readers of one thread
 * would be two pollers against one record. It is polled while its pane is on
 * screen or a turn is in flight, and read once otherwise -- and not at all
 * once the Pi has answered 404, because the thread is minted by its first
 * message and asking for one that does not exist yet is a request that can
 * only ever fail.
 */

private let msgSplitMin: CGFloat = 1000

struct MessagesTabView: View {

    var model: MailModel
    /// The gear. The Messages panel lives on the Settings page like every other
    /// program's, so the door goes there rather than opening a sheet of its own.
    var openSettings: (() -> Void)?

    @State private var settings = ConsoleSettings.shared
    @State private var route: MessagesRoute?
    @State private var replyRequests = 0
    @State private var draftRequests = 0
    @FocusState private var keyboardHeld: Bool

    // ── the pinned conversation ──
    @State private var agent: ChatThread?
    @State private var agentMissing = false
    @State private var sending: String?
    @State private var sentBaseline: Int?
    @State private var sendFailed: String?
    /// Cleared here, and not yet replaced. Holds the poll off so a store that
    /// answers an unknown id with something else cannot resurrect it.
    @State private var cleared = false

    private var agentId: String { settings.messagesAgentThreadId }

    private var agentLive: Bool {
        guard let agent else { return false }
        return chatInFlight(queued: agent.queued, status: agent.status)
    }

    /// The last thing in the conversation is the agent's, and nobody is looking
    /// at it. The same dot a chat gets for the same reason.
    private var agentUnread: Bool {
        guard route != .agent, let last = agent?.turns.last else { return false }
        return last.role == .assistant
    }

    private var agentPreview: String {
        if let sending { return sending }
        if agentLive { return "answering…" }
        guard let last = agent?.turns.last else { return "ask about today's messages" }
        return last.text
    }

    private var agentWhen: String {
        MsgTime.when(agent?.turns.last?.at ?? agent?.updatedAt, now: model.now)
    }

    /// How many chats the Bridge is allowed to forward at all.
    /// The envelope lists at most list_max rows, so the count comes from the
    /// collector's own tally of conversations when it has one.
    private var allowlisted: Int {
        let listed = model.messageChats.filter(\.read).count
        return max(listed, model.messagesData?.counts.chats ?? 0)
    }

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= msgSplitMin

            VStack(spacing: 0) {
                appBar(split: split)
                Hairline()

                HStack(spacing: 0) {
                    if split || route == nil {
                        side
                            .frame(width: split ? 300 : nil)
                            .frame(maxWidth: split ? nil : .infinity)
                    }

                    if split { VHairline() }

                    if split || route != nil {
                        pane.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                Hairline()
                foot
            }
        }
        .background(Color.clear)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardHeld)
        .onKeyPress(phases: .down) { press in handle(press) }
        .task { keyboardHeld = true }
        .task(id: agentPollKey) { await watchAgent() }
        .onChange(of: model.textFocused) { _, typing in
            if !typing { keyboardHeld = true }
        }
    }

    // MARK: - the bar

    private func appBar(split: Bool) -> some View {
        HStack(spacing: 10) {
            Icon(name: .messages, size: 17).foregroundStyle(M.inkMid)

            Text("Messages")
                .font(Face.title)
                .tracking(0.22)
                .foregroundStyle(M.inkBright)

            Text(barCount)
                .font(Face.body)
                .foregroundStyle(M.inkDim)
                .lineLimit(1)

            Spacer(minLength: 8)

            // The way out of the open pane, and it is a different thing at each
            // width. Narrow, the pane is the whole page and the arrow is the
            // door. Split, the column is beside it and there is nothing to
            // close, so what stands here is the key that empties the pane.
            if route != nil {
                if split {
                    HStack(spacing: 3) {
                        Kbd(text: "esc")
                        Text("close").font(Face.body).foregroundStyle(M.inkDim)
                    }
                } else {
                    Button { route = nil } label: {
                        HStack(spacing: 6) {
                            Icon(name: .back, size: 16)
                            Text("Chats").font(Face.body)
                        }
                        .foregroundStyle(M.inkMid)
                        .padding(.leading, 8)
                        .padding(.trailing, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                            .strokeBorder(M.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the chats (esc)")
                    .accessibilityLabel("Back to the chats")
                }
            }

            if split || route == nil {
                IconKey(icon: .gear, label: "Settings", help: "Settings") {
                    openSettings?()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// The bar counts what the column lists, and the column lists Charon.
    private var barCount: String {
        guard let counts = model.messagesCounts else { return "no bridge report yet" }
        let n = counts.chats + 1
        let unread = model.messageChats.reduce(0) { $0 + model.unreadCount($1) }
            + (agentUnread ? 1 : 0)
        return "\(Fmt.num(n)) chat\(n == 1 ? "" : "s") · \(Fmt.num(unread)) unread"
    }

    // MARK: - the foot

    /// The standing rule, stated where the messages are: the allowlist is the
    /// whole of what leaves this Mac, and a text leaves only when he clicks.
    private var foot: some View {
        let bridge = model.messagesData?.bridge
        let reporting = bridge?.seenAt != nil && model.messagesEnv?.status != .dormant
        let age = bridge?.seenAt.map { Fmt.relTime($0, now: model.now) }

        return HStack(spacing: 0) {
            Text("\(allowlisted) chat\(allowlisted == 1 ? "" : "s") allowlisted · "
                 + "sends need your click · bridge ")
                .foregroundStyle(M.inkDim)
            Text(reporting ? "live" : "absent")
                .foregroundStyle(reporting ? M.accent : M.caution)
            if reporting, let age {
                Text(" " + age).foregroundStyle(M.inkDim)
            }
            Spacer(minLength: 0)
        }
        .font(Face.body)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - the panes

    private var side: some View {
        MessagesSideView(model: model,
                         settings: settings,
                         route: route,
                         agentUnread: agentUnread,
                         agentWhen: agentWhen,
                         agentPreview: agentPreview) { picked in
            route = picked
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch route {
        case .chat(let key):
            // The id is load-bearing, not hygiene: the thread holds a
            // half-written reply, and walking from one chat to another without
            // remounting would carry that draft into the next chat's save route.
            MessagesThreadView(chatKey: key, model: model,
                               replyRequests: replyRequests,
                               draftRequests: draftRequests)
                .id(key)
        case .agent:
            MessagesAgentView(model: model, doc: agent, missing: agentMissing,
                              sending: sending, failed: sendFailed,
                              allowlisted: allowlisted,
                              onSend: { text in Task { await fileToAgent(text) } },
                              onClear: { Task { await clearAgent() } })
        case nil:
            VStack {
                EmptyPane(glyph: .messages, line: "Select a chat",
                          why: model.messageChats.isEmpty ? nil : "j and k walk the column")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - the pinned conversation

    /// Fast while something is happening, slow otherwise, stopped while nobody
    /// is looking at the window, and stopped for good once the Pi has said
    /// there is no such thread.
    ///
    /// `agentMissing` is in the key because it is the thing that ends the poll
    /// and the thing that restarts it. The pinned conversation is minted
    /// lazily by its first message, so before that message there is nothing on
    /// the Pi to read and a poll against it was a 404 every five seconds for
    /// as long as the tab was open. Sending mints one and clears the flag,
    /// which is what brings the poll back.
    private var agentPollKey: String {
        "\(model.active)/\(route == .agent)/\(agentLive || sending != nil)"
            + "/\(agentId)/\(cleared)/\(agentMissing)"
    }

    private func watchAgent() async {
        guard model.active, !cleared, !agentMissing else { return }

        // Off screen this is read once and not again. The row in the column
        // needs something to draw, which is why it is read at all; the repeat
        // belongs to the pane that is actually open. A turn in flight counts
        // as open, because "answering…" is a claim that has to be able to stop
        // being true.
        guard route == .agent || agentLive || sending != nil else {
            if agent == nil { await loadAgent() }
            return
        }

        let fast = agentLive || sending != nil
        while !Task.isCancelled {
            await loadAgent()
            // 404. There is no thread yet, so there is nothing to poll for:
            // the pane draws its empty state and the next request is the one
            // the user's first message causes.
            if agentMissing { return }
            try? await Task.sleep(for: fast ? chatLivePoll : chatIdlePoll)
            if Task.isCancelled { return }
        }
    }

    private func loadAgent() async {
        guard !cleared else { return }
        do {
            let got = try await model.store.chatThread(id: agentId)
            if Task.isCancelled { return }
            agent = got
            agentMissing = (got == nil)
            // Drop the optimistic copy once the record's user-turn count has
            // grown past the baseline captured at send time -- not when it
            // merely contains some user turn, which an established thread
            // already does.
            if let got, let baseline = sentBaseline, userTurns(got) > baseline {
                sending = nil
                sentBaseline = nil
            }
        } catch is CancellationError {
            return
        } catch {
            // A transport failure is not a fact about the thread: the record
            // stays on screen and nobody is told the session is gone.
            if !Task.isCancelled { agentMissing = false }
        }
    }

    private func userTurns(_ d: ChatThread) -> Int {
        d.turns.reduce(0) { $0 + ($1.role == .user ? 1 : 0) }
    }

    /// File a turn, minting the thread on the way if there is not one yet.
    ///
    /// The first message carries `@messages`, which is what points the session
    /// at today's index, the summaries and the allowlisted bodies. Only the
    /// first, and only when he did not type it himself: a tag on every turn
    /// would be the app arguing with the conversation.
    private func fileToAgent(_ text: String) async {
        sendFailed = nil
        var body = text
        let fresh = (agent?.turns.isEmpty ?? true)
        if fresh, ChatTags.vocabulary.contains("messages"),
           !ChatTags.scan(text).contains(where: { $0.name == "messages" }) {
            body = "@messages " + text
        }

        var id = agentId
        if agent == nil || agentMissing || cleared {
            guard let minted = await model.store.chatNew(model: .sonnet) else {
                sendFailed = "not sent · the collector did not take it"
                return
            }
            id = minted
            settings.messagesAgentThreadId = minted
            cleared = false
            agentMissing = false
        }

        sentBaseline = agent.map(userTurns) ?? 0
        sending = body
        switch await model.store.chatSend(id: id, text: body) {
        case .ok:
            sendFailed = nil
        case .busy:
            sendFailed = "not sent · a turn is already in flight"
            sending = nil
            sentBaseline = nil
        case .failed:
            sendFailed = "not sent · the collector did not take it"
            sending = nil
            sentBaseline = nil
        }
        await loadAgent()
    }

    private func clearAgent() async {
        _ = await model.store.chatDelete(id: agentId)
        agent = nil
        agentMissing = true
        sending = nil
        sentBaseline = nil
        sendFailed = nil
        cleared = true
    }

    // MARK: - the keymap

    /// The column, in the order it is drawn, which is the order the walk moves
    /// in. Derived rather than held: the list decides the order, and reading
    /// its own array back is what keeps the keys agreeing with the screen.
    private var walk: [MessagesRoute] {
        var out: [MessagesRoute] = []
        out.append(.agent)
        out += model.messageChats.map { MessagesRoute.chat($0.chatKey) }
        return out
    }

    private func step(_ delta: Int) {
        let order = walk
        guard !order.isEmpty else { return }
        guard let here = route, let at = order.firstIndex(of: here) else {
            route = delta > 0 ? order.first : order.last
            return
        }
        let next = at + delta
        guard next >= 0, next < order.count else { return }
        route = order[next]
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.keysLive else { return .ignored }
        guard press.modifiers.isEmpty else { return .ignored }

        switch press.key {
        case .escape:
            guard route != nil else { return .ignored }
            route = nil
            return .handled
        case .rightArrow:
            step(1)
            return .handled
        case .leftArrow:
            step(-1)
            return .handled
        default:
            break
        }

        switch press.characters {
        case "j":
            step(1)
            return .handled
        case "k":
            step(-1)
            return .handled
        case "r":
            // The box is always open now, so this is the caret rather than the
            // door: r is where you go to start typing without reaching.
            guard case .chat = route else { return .ignored }
            replyRequests += 1
            return .handled
        case "e":
            // Two verbs on one key, because the two panes have one shape each
            // and neither has the other's. A chat has no archive route in
            // protocol v1; a summary has nothing to draft.
            switch route {
            case .chat:
                draftRequests += 1
                return .handled
            default:
                return .ignored
            }
        case "u":
            switch route {
            case .chat(let key):
                Task { await model.markChatRead(key) }
                return .handled
            default:
                return .ignored
            }
        default:
            return .ignored
        }
    }
}
