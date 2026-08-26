import AppKit
import Foundation

/* The demo iMessage channel: the reference layout, as data.
 *
 * Six chats, one thread with a real transcript in it, three days of Charon and
 * the allowlist the Settings pane shows -- the same six names, the same six
 * previews, the same four allowlist rows. A fixture that drifted from that
 * layout would make it useless as the thing to check the build against.
 *
 * **Mutable and not persisted**, for `DemoChatStore`'s reason: demo mode has no
 * collector, so without somewhere to put a read mark, a draft or a send this
 * tab would be the one page in the console that cannot be tried. A relaunch is
 * a fresh demo.
 *
 * **Nothing here reaches Messages.app and nothing here reaches a network.** Of
 * everything in this app, a send that actually texted somebody from a fixture
 * is the one with consequences that cannot be taken back.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

@MainActor
final class DemoMessagesStore {

    /// How long the fixture pretends the session on the Pi takes to write a
    /// draft, and the Bridge to perform a send. Short next to the real thing: a
    /// demo is watched rather than left, and both states have to be genuinely
    /// on screen rather than a flash.
    ///
    /// A second and a half for the draft, which is the sparkle's `thinking`
    /// long enough to be read and short enough that the sentence arriving still
    /// feels like the answer to the press.
    private static let draftDelay: Duration = .milliseconds(1500)
    private static let sendDelay: Duration = .seconds(4)

    // The six chats, by key. Sixteen lowercase hex like the real thing, so the
    // route guards are exercised in demo rather than bypassed by it.
    static let nadia = "a1f3c07d5b2e9401"
    static let roommates = "b28e4f1097c3a5d6"
    static let garage = "c3d90a4e17b62f85"
    static let corin = "d4e17b0c962a3f58"
    static let jo = "e5f28c1da03b4697"
    static let courier = "f60a3d2eb14c5708"

    static let nadiaNumber = "+1 408 555 0142"

    /// How long the fixture pretends the Bridge takes to answer a `fetch`. A
    /// second, because the state the tile shows while it waits has to be real
    /// in a demo and a real one is three seconds of a Mac polling.
    private static let fetchDelay: Duration = .seconds(1)

    /// What the agent writes when somebody presses the sparkle on Nadia's
    /// thread. Not seeded: the board opens with nothing waiting, because the
    /// whole of the new flow is that a draft is a thing you ask for.
    static let draftText = "Yes, 6 works. Go ahead and grab the table, "
        + "I'll be there a few minutes early."

    private var chats: [MessageChatSummary]
    private var threads: [String: MessageThread]
    private var summaries: [String: MessageSummaryDoc]
    private var rows: [MessageSummaryRow]
    private var config: MessagesConfig
    private let openedAt: Date

    init(now: Date = Date()) {
        openedAt = now
        chats = DemoMessagesStore.seedChats(now: now)
        threads = DemoMessagesStore.seedThreads(now: now)
        let days = DemoMessagesStore.seedSummaries(now: now)
        summaries = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        rows = days.map(DemoMessagesStore.row)
        config = DemoMessagesStore.seedConfig()
    }

    // MARK: - reads

    /// The envelope's body. Counted off the chats rather than stated: a fixture
    /// whose header disagrees with its own list teaches the reader to distrust
    /// the counts, which is the one thing a dashboard cannot afford.
    func data(now: Date) -> MessagesData {
        MessagesData(
            bridge: MessagesBridge(
                seenAt: Fmt.stampNow(now.addingTimeInterval(-2)),
                fda: true,
                automation: true,
                helper: "0.14.1 · verified",
                cursor: 184_220,
                lastEventAt: Fmt.stampNow(now.addingTimeInterval(-2)),
                dropped: 31,
                error: nil),
            counts: MessagesCounts(
                chats: chats.count,
                unread: chats.reduce(0) { $0 + $1.unread },
                needsYou: chats.filter(\.needsYou).count,
                queued: 0),
            chats: chats,
            summaries: rows)
    }

    func thread(_ chatKey: String) -> MessageThread? { threads[chatKey] }

    func summary(_ date: String) -> MessageSummaryDoc? { summaries[date] }

    func chatList() -> [MessageChatSummary] { chats }

    func currentConfig() -> MessagesConfig { config }

    // MARK: - the attachments

    /// One demo attachment's bytes, or nil when the fixture is pretending the
    /// Pi does not hold them yet.
    ///
    /// Drawn rather than shipped. A real photograph in the repository would be
    /// somebody's photograph, and the two colours this makes are the two the
    /// tile is drawn against -- so the board shows a picture in a bubble
    /// without a single byte of anybody's camera roll being in the build.
    func attachment(_ key: String, n: Int) -> Data? {
        guard let held = attachmentRecord(key, n: n), held.stored, !held.missing
        else { return nil }
        return DemoMessagesStore.plate
    }

    /// Ask for one, and let it turn up a second later -- which is the fixture
    /// standing in for the Bridge reading the want and pushing the file.
    func wantAttachment(_ key: String, n: Int) -> Bool {
        guard let held = attachmentRecord(key, n: n), !held.missing, !held.stored
        else { return true }
        Task { [weak self] in
            try? await Task.sleep(for: DemoMessagesStore.fetchDelay)
            self?.markStored(key, n: n)
        }
        return true
    }

    private func attachmentRecord(_ key: String, n: Int) -> MessageAttachment? {
        for thread in threads.values {
            guard let row = thread.messages.first(where: { $0.key == key }) else { continue }
            return row.attachments.first { $0.n == n }
        }
        return nil
    }

    private func markStored(_ key: String, n: Int) {
        for (chat, thread) in threads {
            guard let at = thread.messages.firstIndex(where: { $0.key == key })
            else { continue }
            var held = thread
            var row = held.messages[at]
            guard let which = row.attachments.firstIndex(where: { $0.n == n })
            else { return }
            row.attachments[which].stored = true
            held.messages[at] = row
            threads[chat] = held
            return
        }
    }

    /// A 320x240 plate in the two colours the tile is drawn against: the
    /// raised surface it sits on, and one rectangle of the accent this app
    /// already means "this went through" by.
    static let plate: Data? = {
        let size = NSSize(width: 320, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(M.raised).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(M.accent).setFill()
        NSRect(x: 56, y: 56, width: 208, height: 128).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }()

    // MARK: - writes

    func markRead(_ chatKey: String) -> Bool {
        guard let at = chats.firstIndex(where: { $0.chatKey == chatKey }) else { return true }
        chats[at].unread = 0
        return true
    }

    func saveDraft(_ chatKey: String, body: String) -> Bool {
        guard var held = threads[chatKey] else { return true }
        held.userDraft = MessageDraft(status: "ready", text: body, at: Fmt.stampNow())
        threads[chatKey] = held
        return true
    }

    /// Ask for a draft, and write one a second and a half later. The timer is
    /// the fixture standing in for the session on the Pi: it exists so the
    /// queued → ready walk the composer draws -- a dim sparkle, then a sentence
    /// in the field -- is real in a demo rather than mimed.
    func requestDraft(_ chatKey: String, instructions: String?) -> Bool {
        let asked = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (asked?.isEmpty ?? true) ? nil : asked

        guard var held = threads[chatKey] else { return true }
        held.draft = MessageDraft(status: "queued", instructions: ask,
                                  model: "claude-sonnet", at: Fmt.stampNow())
        threads[chatKey] = held

        Task { [weak self] in
            try? await Task.sleep(for: DemoMessagesStore.draftDelay)
            guard let self, var current = self.threads[chatKey] else { return }
            let text = ask.map { "\(DemoMessagesStore.draftText)\n\n[asked for: \($0)]" }
                ?? DemoMessagesStore.draftText
            current.draft = MessageDraft(status: "ready", text: text, instructions: ask,
                                         model: "claude-sonnet", at: Fmt.stampNow())
            self.threads[chatKey] = current
        }
        return true
    }

    /// File a send, and let the Bridge perform it a few seconds later.
    ///
    /// Returns the outbox id immediately, exactly as the collector does, so the
    /// thread's queued → sent walk is the same code path in both modes. The
    /// text lands in the transcript as an outbound run when it goes, which is
    /// what the real one does too: the Bridge sends it, `chat.db` gains a row,
    /// and the row comes back up as an event.
    func send(_ chatKey: String, body: String) -> String? {
        guard body.count <= MessageRoute.maxSendBody else { return nil }
        guard threads[chatKey] != nil else { return nil }
        // The collector refuses a chat whose policy is `off` (§7), and so does
        // the fixture: a demo that queued a send the real one would reject is a
        // demo of a bug.
        guard chats.first(where: { $0.chatKey == chatKey })?.policy == .confirm else {
            return nil
        }

        let id = DemoMessagesStore.mintHex()
        // Queued, and visible on the thread route the same second -- which is
        // the whole point of the field: the app has an outbox item to watch
        // before it has a message row to draw.
        threads[chatKey]?.outbox.append(
            MessageOutboxItem(id: id, status: "queued", body: body, at: Fmt.stampNow()))

        Task { [weak self] in
            try? await Task.sleep(for: DemoMessagesStore.sendDelay)
            guard let self, var current = self.threads[chatKey] else { return }
            // The Bridge performed it: `chat.db` gains a row, the row comes
            // back up as an event, and the outbox record names its guid. The
            // fixture mints one guid and derives the key from it exactly the
            // way both real sides do, so the app's own match is exercised
            // rather than bypassed.
            let guid = "p:0/\(DemoMessagesStore.mintHex().uppercased())"
            current.messages.append(MessageRecord(
                key: MsgKey.of(guid),
                chatKey: chatKey, isFromMe: true, text: body,
                createdAt: Fmt.stampNow(), service: "iMessage"))
            if let at = current.outbox.firstIndex(where: { $0.id == id }) {
                current.outbox[at].status = "sent"
                current.outbox[at].sentAt = Fmt.stampNow()
                current.outbox[at].guid = guid
            }
            self.threads[chatKey] = current
        }

        return id
    }

    func summaryRead(_ date: String) -> Bool {
        summaries[date]?.read = true
        if let at = rows.firstIndex(where: { $0.date == date }) { rows[at].read = true }
        return true
    }

    func summaryArchive(_ date: String) -> Bool {
        summaries[date]?.archived = true
        if let at = rows.firstIndex(where: { $0.date == date }) { rows[at].archived = true }
        return true
    }

    /// The allowlist, written whole and mirrored onto the chats the payload
    /// lists, so flipping a row in Settings changes the list and the foot on
    /// the Messages tab the way the real round trip would.
    func setConfig(_ next: MessagesConfig) -> Bool {
        config = MessagesConfig(updatedAt: Fmt.stampNow(), chats: next.chats)
        for (at, chat) in chats.enumerated() {
            guard let guid = chat.chatGuid, let entry = config.chats[guid] else { continue }
            chats[at].read = entry.read
            chats[at].policy = entry.send
        }
        return true
    }

    // MARK: - the fixture

    /// Sixteen lowercase hex, the shape every key in this system has.
    private static func mintHex() -> String {
        String((0..<16).map { _ in "0123456789abcdef".randomElement() ?? "0" })
    }

    private static func row(_ doc: MessageSummaryDoc) -> MessageSummaryRow {
        MessageSummaryRow(
            date: doc.date, status: doc.status, read: doc.read, archived: doc.archived,
            needsYouN: doc.needsYou.count,
            preview: doc.needsYou.first?.text ?? doc.noticed.first?.text, at: doc.at)
    }

    private static func seedChats(now: Date) -> [MessageChatSummary] {
        func ago(_ minutes: Double) -> String {
            Fmt.stampNow(now.addingTimeInterval(-minutes * 60))
        }

        return [
            MessageChatSummary(
                chatKey: nadia, chatGuid: "iMessage;-;+14085550142",
                chatIdentifier: nadiaNumber, name: "Nadia Sorin",
                service: "iMessage", participants: [nadiaNumber],
                policy: .confirm, read: true,
                lastAt: ago(3), lastPreview: "are we still on for 6? I can grab the table",
                lastSender: "Nadia Sorin", unread: 1, urgencyMax: 2, needsYou: true),
            MessageChatSummary(
                chatKey: roommates, chatGuid: "iMessage;+;chat829147305",
                chatIdentifier: nil, name: "Roommates", isGroup: true,
                service: "iMessage", participants: ["Theo", "Rae", "you"],
                policy: .confirm, read: true,
                lastAt: ago(25), lastPreview: "Theo: rent's in, utilities split posted",
                lastSender: "Theo", unread: 1, urgencyMax: 1, needsYou: false),
            MessageChatSummary(
                chatKey: garage, chatGuid: "SMS;-;+14155550188",
                chatIdentifier: "+1 415 555 0188", name: "Ridge Auto Service",
                service: "SMS", participants: ["+1 415 555 0188"],
                policy: .off, read: true,
                lastAt: ago(170),
                lastPreview: "Reminder: service Thu 8/27 9:30am. Reply C to confirm.",
                lastSender: "Ridge Auto Service", unread: 1, urgencyMax: 2, needsYou: true),
            MessageChatSummary(
                chatKey: corin, chatGuid: "iMessage;-;corin.blake@example.com",
                chatIdentifier: "corin.blake@example.com", name: "Corin Blake",
                service: "iMessage", participants: ["corin.blake@example.com"],
                policy: .off, read: false,
                lastAt: Fmt.stampNow(now.addingTimeInterval(-20 * 3600)),
                lastPreview: "lol ok send me the repo when it builds",
                lastSender: "Corin Blake", unread: 0, urgencyMax: 0, needsYou: false),
            MessageChatSummary(
                chatKey: jo, chatGuid: "iMessage;-;+16505550119",
                chatIdentifier: "+1 650 555 0119", name: "Jo Marsh",
                service: "iMessage", participants: ["+1 650 555 0119"],
                policy: .off, read: false,
                lastAt: Fmt.stampNow(now.addingTimeInterval(-2 * 86_400)),
                lastPreview: "Thanks again for the extra copies!",
                lastSender: "Jo Marsh", unread: 0, urgencyMax: 0, needsYou: false),
            MessageChatSummary(
                chatKey: courier, chatGuid: "SMS;-;28777", chatIdentifier: "28777",
                name: "Courier 28777", service: "SMS", participants: ["28777"],
                policy: .off, read: false,
                lastAt: Fmt.stampNow(now.addingTimeInterval(-2 * 86_400 - 3600)),
                lastPreview: "Your package is out for delivery",
                lastSender: "Courier 28777", unread: 0, urgencyMax: 0, needsYou: false),
        ]
    }

    /// Nadia's six runs, and one row apiece for the other five so no chat in
    /// the list opens onto nothing.
    private static func seedThreads(now: Date) -> [String: MessageThread] {
        func at(_ minutes: Double) -> String {
            Fmt.stampNow(now.addingTimeInterval(-minutes * 60))
        }
        // Stable rather than minted, so a demo relaunch draws the same
        // transcript and the read mark keeps pointing at the same row.
        func key(_ n: Int) -> String { String(format: "%016lx", 0x51a0_0000_0000 + n) }

        let all = seedChats(now: now)
        let chats = Dictionary(all.map { ($0.chatKey, $0) }, uniquingKeysWith: { a, _ in a })

        // The four tiles, on one conversation: a photograph the Pi already
        // holds, one it does not, a video, and a file Messages aged off the
        // Mac. All four states on one screen is the point -- a demo that only
        // showed the happy one would be a board nobody could check the other
        // three against.
        let nadiaRuns: [(Bool, String, Double, [MessageAttachment])] = [
            (false, "hey! dinner still on tonight?", 14, []),
            (true, "yes! 6 works", 12, []),
            (false, "ok cool. the place on weldon row or the new thai spot?", 11, []),
            (true, "thai. haven't tried it", 7, []),
            (false, "", 6.5, [
                MessageAttachment(n: 0, filename: "IMG_0412.heic",
                                  mimeType: "image/heic", totalBytes: 1_820_331,
                                  stored: true),
            ]),
            (false, "and one from last night", 5, [
                MessageAttachment(n: 0, filename: "IMG_0409.heic",
                                  mimeType: "image/heic", totalBytes: 1_884_000),
                MessageAttachment(n: 1, filename: "IMG_0412.mov",
                                  mimeType: "video/quicktime", totalBytes: 12_584_000),
                MessageAttachment(n: 2, filename: "IMG_0301.heic",
                                  mimeType: "image/heic", totalBytes: 2_100_000,
                                  missing: true),
            ]),
            (false, "same, heard it's good", 4, []),
            (false, "are we still on for 6? I can grab the table", 3, []),
        ]

        var out: [String: MessageThread] = [:]
        out[nadia] = MessageThread(
            chat: chats[nadia],
            messages: nadiaRuns.enumerated().map { index, run in
                MessageRecord(
                    key: key(index), chatKey: nadia,
                    sender: run.0 ? nil : nadiaNumber,
                    senderName: run.0 ? nil : "Nadia Sorin",
                    isFromMe: run.0, text: run.1, createdAt: at(run.2), service: "iMessage",
                    attachments: run.3,
                    ai: run.0 || index != nadiaRuns.count - 1
                        ? nil
                        : MessageAi(tags: ["plans"], urgency: 2, needsYou: true,
                                    summary: "wants a yes on dinner at 6"))
            },
            // No draft, and `userDraft` nil too: the thread opens idle in both
            // senses, with an empty field and a sparkle nobody has pressed.
            // `requestDraft` is what writes one, a second and a half later.
            draft: nil,
            userDraft: nil,
            // One send this box already made, reported and long since back in
            // the transcript above. Here for its shape: this is what the thread
            // route hands the app beside the messages, and it is what lets a
            // bubble drawn on Enter be recognised when the real row lands.
            outbox: [MessageOutboxItem(id: "0f4c19a7b3e28d65", status: "sent",
                                       body: "thai. haven't tried it",
                                       at: at(7), sentAt: at(7),
                                       guid: "p:0/9C1D-44A2", messageId: "184218")],
            readTo: key(6))

        for (index, chat) in all.enumerated() where chat.chatKey != nadia {
            out[chat.chatKey] = MessageThread(
                chat: chat,
                messages: [MessageRecord(
                    key: key(100 + index), chatKey: chat.chatKey,
                    sender: chat.chatIdentifier, senderName: chat.lastSender,
                    isFromMe: false, text: chat.lastPreview, createdAt: chat.lastAt,
                    service: chat.service)],
                readTo: chat.unread == 0 ? key(100 + index) : nil)
        }
        return out
    }

    private static func seedSummaries(now: Date) -> [MessageSummaryDoc] {
        func day(_ back: Int) -> String {
            let at = now.addingTimeInterval(-Double(back) * 86_400)
            let c = Calendar.current.dateComponents([.year, .month, .day], from: at)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        return [
            MessageSummaryDoc(
                date: day(0), status: "ok",
                needsYou: [
                    MessageSummaryLine("Nadia Sorin wants a yes on dinner at 6 and offered "
                                       + "to book the table. A draft is ready.",
                                       chatKey: nadia),
                    MessageSummaryLine("Ridge Auto Service needs a C to confirm "
                                       + "Thu 8/27 9:30.", chatKey: garage),
                ],
                noticed: [
                    MessageSummaryLine("Roommates: rent cleared, your share is posted.",
                                       chatKey: roommates),
                    MessageSummaryLine("A package is out for delivery.", chatKey: courier),
                ],
                quiet: [
                    MessageSummaryLine("Corin Blake and Jo Marsh: nothing needs you."),
                ],
                model: "claude-sonnet",
                at: Fmt.stampNow(now.addingTimeInterval(-2 * 60)),
                read: false),
            MessageSummaryDoc(
                date: day(1), status: "ok",
                noticed: [
                    MessageSummaryLine("Corin will wait for the repo; nothing needs you.",
                                       chatKey: corin),
                ],
                model: "claude-sonnet",
                at: Fmt.stampNow(now.addingTimeInterval(-86_400 + 3_000)),
                read: true),
            MessageSummaryDoc(
                date: day(2), status: "ok",
                noticed: [
                    MessageSummaryLine("Jo thanked you for the extra copies; a package "
                                       + "shipped.", chatKey: jo),
                ],
                model: "claude-sonnet",
                at: Fmt.stampNow(now.addingTimeInterval(-2 * 86_400 + 1_200)),
                read: true, archived: true),
        ]
    }

    /// The four rows the Settings board shows, in its own order.
    private static func seedConfig() -> MessagesConfig {
        MessagesConfig(updatedAt: Fmt.stampNow(), chats: [
            "iMessage;-;+14085550142": MessagesChatPolicy(read: true, send: .confirm,
                                                          name: "Nadia Sorin"),
            "iMessage;+;chat829147305": MessagesChatPolicy(read: true, send: .confirm,
                                                           name: "Roommates"),
            "SMS;-;+14155550188": MessagesChatPolicy(read: true, send: .off,
                                                     name: "Ridge Auto Service"),
            "iMessage;-;corin.blake@example.com": MessagesChatPolicy(
                read: false, send: .off, name: "Corin Blake"),
        ])
    }

    /// The pinned conversation, as a chat thread.
    ///
    /// It is a Chat thread with a fixed id and nothing else: the Messages tab
    /// draws it in the mail dialect, but what it is made of, what answers it
    /// and what route it lives on are the chat system's -- which is the whole
    /// of build decision 10 and the reason there is no second runner for it.
    static func agentThread(id: String, now: Date) -> ChatThread {
        func at(_ minutes: Double) -> String {
            Fmt.stampNow(now.addingTimeInterval(-minutes * 60))
        }
        return ChatThread(
            id: id, title: "messages", createdAt: at(2), updatedAt: at(0),
            model: .sonnet, effort: .high, status: .idle,
            turns: [
                ChatTurn(role: .user, text: "anything from nadia?", at: at(1)),
                ChatTurn(role: .assistant,
                         text: "She is asking for a yes on dinner at 6 and offered to book "
                             + "the table. I drafted a reply; it is waiting in her thread.",
                         at: at(1), model: .sonnet, elapsedS: 7),
                ChatTurn(role: .user, text: "send it", at: at(0)),
                ChatTurn(role: .assistant,
                         text: "Queued under Nadia's thread. It still needs your CONFIRM "
                             + "SEND there; I do not send on my own.",
                         at: at(0), model: .sonnet, elapsedS: 5),
            ])
    }
}
