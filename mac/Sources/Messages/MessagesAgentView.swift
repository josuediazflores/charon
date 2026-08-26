import SwiftUI

/* The pinned conversation with Charon.
 *
 * **It is a Chat thread and nothing else.** A fixed id, the chat routes, the
 * chat runner, the chat model -- build decision 10, and the reason there is no
 * second assistant in this app. What the Messages tab does is draw it in the
 * mail dialect, because a conversation about your texts belongs beside them
 * rather than in a terminal one tab over, and inject `@messages` on the first
 * turn so the session on the Pi opens the right files.
 *
 * **It reads and it does not write.** v1 gives the session today's index, the
 * summaries and the bodies of the allowlisted chats; it has no draft tool and
 * no send tool, and the note under the transcript says so until it does. Its
 * "send it" answer is a sentence about a draft that is already waiting in
 * somebody's thread, where a human still has to click CONFIRM SEND.
 *
 * **No two-step here, and there does not need to be one.** Nothing typed in
 * this box leaves the Mac's own tailnet, so the thing the mail exception exists
 * to slow down is not happening.
 */

struct MessagesAgentView: View {

    let model: MailModel
    let doc: ChatThread?
    let missing: Bool
    /// What this pane typed that the Pi has not confirmed yet. Held because
    /// losing what somebody typed is the one unforgivable failure here.
    let sending: String?
    let failed: String?
    let allowlisted: Int
    let onSend: (String) -> Void
    let onClear: () -> Void

    @State private var draft = ""
    @State private var typing = false

    private var live: Bool {
        guard let doc else { return false }
        return chatInFlight(queued: doc.queued, status: doc.status)
    }

    private var busy: Bool { sending != nil || live }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            log
            dock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: typing) { _, now in model.textFocused = now }
        .onDisappear { model.textFocused = false }
    }

    // MARK: - the head

    private var head: some View {
        MsgHead(who: "Charon",
                sub: "your agent · pinned · reads \(allowlisted) allowlisted "
                    + "chat\(allowlisted == 1 ? "" : "s")") {
            // Nothing to unpin to: v1 has one agent surface and this is it.
            // Drawn because the pane has two verbs, and said out loud in its
            // help rather than quietly doing nothing.
            QuietAct(icon: .pin, word: "unpin", disabled: true,
                     help: "the pinned thread is v1's only agent surface") {}
            QuietAct(icon: .close, word: "clear",
                     help: "delete this conversation on the Pi and start a new one",
                     action: onClear)
        }
    }

    // MARK: - the transcript

    private var log: some View {
        GeometryReader { geo in
            // The same 26% the thread holds back: one rule for how wide a
            // turn may get, wherever a turn is drawn.
            scrollback(slack: (geo.size.width - 36) * 0.26)
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollback(slack: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if (doc?.turns.isEmpty ?? true), sending == nil, !live {
                    Text("nothing asked yet")
                        .font(Face.body).foregroundStyle(M.inkDim)
                }

                ForEach(Array((doc?.turns ?? []).enumerated()), id: \.offset) { _, turn in
                    MsgRun(text: turn.text,
                           when: Fmt.hhmm(turn.at),
                           outbound: turn.role == .user,
                           slack: slack,
                           lead: { agentMark(turn.role == .user) })
                }

                // Before the record catches up, what this pane typed is the
                // only copy of it there is.
                if let sending {
                    MsgRun(text: sending, when: "", outbound: true, slack: slack)
                }

                if live {
                    MsgRun(text: streaming, when: "", outbound: false, slack: slack,
                           lead: { agentMark(false) })
                }

                if doc?.status == .error, !live {
                    Text(doc?.error ?? "the session failed")
                        .font(Face.body).foregroundStyle(M.fault)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failed {
                    Text(failed)
                        .font(Face.body).foregroundStyle(M.fault)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if missing, doc == nil, sending == nil {
                    Text("no session on the Pi yet · the first message opens one")
                        .font(Face.body).foregroundStyle(M.inkDim)
                }

                // The standing claim, in the transcript rather than in a
                // banner: it is what the whole channel is built on and it is
                // read where the reading happens.
                Text("charon reads only the chats you allowlisted · nothing here "
                     + "leaves this Mac")
                    .font(Face.body)
                    .foregroundStyle(M.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    /// The same mark the summaries and the pinned row carry, at the size a line
    /// of text is rather than the size a row is.
    @ViewBuilder
    private func agentMark(_ yours: Bool) -> some View {
        if yours {
            Color.clear.frame(width: 22, height: 1)
        } else {
            SparkDisc(side: 22)
        }
    }

    /// The answer as it is produced, with the block on the end of it. A queued
    /// turn has nothing to show yet and says which state it is in instead.
    private var streaming: String {
        let partial = doc?.partial ?? ""
        if doc?.queued == true, partial.isEmpty { return "queued…" }
        return partial.isEmpty ? "…" : partial
    }

    // MARK: - the composer

    /// The same pill and the same green disc the threads have, because the two
    /// composers are one control in two rooms and a person who has learned one
    /// of them has learned both. What is different is what is missing: no
    /// sparkle in the right end -- charon has no draft to offer about charon,
    /// so the field keeps its single slot -- and no five seconds, because
    /// nothing typed here leaves this Mac's tailnet.
    private var dock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            MsgComposer(text: $draft,
                        placeholder: "message charon",
                        maxLength: chatTextMax,
                        focused: $typing,
                        onSend: file,
                        onCancel: { escape() })
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }

    /// Esc: empty the field, then give the keys back to the tab.
    private func escape() -> Bool {
        if !draft.isEmpty {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { draft = "" }
            return true
        }
        typing = false
        return true
    }

    private var empty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func file() {
        guard !busy, !empty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        onSend(text)
    }
}
