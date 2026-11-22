import SwiftUI

/* The left column: what Charon wrote, then who has written to you.
 *
 * **Two lists in one scroller with a rule between them, and the rows are the
 * same row on both sides of it.** A summary is a thing you open, so it is drawn
 * like the other things you open rather than as a card that sits there. The
 * only difference across the seam is what is in the 32pt disc: a sparkle above
 * it, a hashed avatar below.
 *
 * **The CHARON block folds.** The header line is the disclosure, which is the
 * console's own idiom moved into the mail exception -- the same two carets, the
 * same borderless button, the same hover that steps the ink one notch instead
 * of announcing a state. While it is shut the line says what is behind it, so
 * folding it away never costs the one number nothing else on this page carries.
 *
 * **Charon is pinned at the top of the chats as a chat**, because that is what
 * it is: a conversation you open, answer and come back to. Same row, same lead
 * dot, same disc as the summaries, and a pin where a chat shows its channel.
 */

struct MessagesSideView: View {

    let model: MailModel
    let showsAgent: Bool
    let route: MessagesRoute?
    let agentUnread: Bool
    let agentWhen: String
    let agentPreview: String
    let select: (MessagesRoute) -> Void

    var body: some View {
        let health = model.messagesHealth
        let chats = model.messageChats

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HealthStrip(health: health)

                counts(chats: chats)

                if showsAgent {
                    pinnedRow
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                    Hairline().padding(.horizontal, 8)
                }

                if chats.isEmpty {
                    empty(health: health)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(chats) { chat in
                            chatRow(chat, dim: health.dim)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 7)
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // MARK: - the chats

    private func counts(chats: [MessageChatSummary]) -> some View {
        // **The unread total, and no total of chats.** The number that used to
        // stand here counted the rows on screen, and the rows on screen are the
        // collector's capped page -- so on a busy account it read 51 while the
        // page head said the real figure and the footer said how many are
        // allowlisted, three numbers for one fact and two of them wrong. The
        // unread count is the one this line is actually for.
        let unread = chats.reduce(0) { $0 + model.unreadCount($1) } + (agentUnread ? 1 : 0)

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("chats").foregroundStyle(M.inkDim)
            Text("·").foregroundStyle(M.lineStrong)
            (Text(Fmt.num(unread)).foregroundStyle(M.inkMid)
                + Text(" unread").foregroundStyle(M.inkDim))
            Spacer(minLength: 0)
        }
        .font(Face.body)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var pinnedRow: some View {
        let selected = route == .agent
        return MessagesRow(
            name: "Charon",
            preview: agentPreview,
            when: agentWhen,
            unread: agentUnread,
            selected: selected,
            dim: false,
            mark: { SparkDisc(bright: selected) },
            marks: {
                Icon(name: .pin, size: 11)
                    .foregroundStyle(M.inkDim)
                    .help("pinned")
            },
            act: nil,
            open: { select(.agent) })
    }

    private func chatRow(_ chat: MessageChatSummary, dim: Bool) -> some View {
        let selected = route == .chat(chat.chatKey)
        let unread = model.unreadCount(chat)
        // A group says how many people are in it where a person says nothing:
        // the row has one name slot and a group's name is not a person's.
        let name = chat.isGroup && chat.participants.count > 0
            ? "\(chat.name) · \(chat.participants.count)"
            : chat.name

        return MessagesRow(
            name: name,
            preview: chat.lastPreview ?? "no messages yet",
            when: MsgTime.when(chat.lastAt, now: model.now),
            unread: unread > 0,
            selected: selected,
            dim: dim || (!chat.read && unread == 0),
            mark: { Avatar(who: chat.name, dim: dim || (!chat.read && unread == 0)) },
            marks: {
                Icon(name: chat.service.lowercased() == "sms" ? .sms : .messages, size: 11)
                    .foregroundStyle(M.inkDim)
                    .help(chat.service.lowercased() == "sms" ? "SMS" : "iMessage")
            },
            act: nil,
            open: { select(.chat(chat.chatKey)) })
    }

    /// The column's own empty state is a line, not a full pane: it stands where
    /// the rows would be, under a header that is already there.
    @ViewBuilder
    private func empty(health: Health) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.messagesEnv?.status == .dormant {
                Text("Not wired. Install Charon Bridge and allow a chat in Settings.")
                if let note = health.note { Text(note) }
            } else {
                Text("No chats yet. Nothing outside the allowlist ever leaves this Mac.")
            }
        }
        .font(Face.body)
        .foregroundStyle(M.inkDim)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }
}
