import Foundation

/* The demo mailbox, ported from the web console's demo fixture.
 *
 * Eight messages, one per state the two views have to draw: something that
 * needs today, something already replied to, something with a reply queued,
 * something whose reply the far end refused, something the triage worker has
 * not reached, something triage gave up on, a newsletter that wants nothing,
 * and a notice with an attachment.
 *
 * **The rows are derived from the messages, not stated beside them.** That is
 * what the collector does -- it reads the header index and joins the ai, draft
 * and outbox records onto it -- so deriving them here means the list and the
 * reader physically cannot disagree in a demo, which is exactly the bug a
 * fixture would otherwise be very good at hiding.
 *
 * **Nothing here reaches a network.** Of everything in this app, a write that
 * touched a real mailbox from a fixture is the one with consequences that
 * cannot be taken back.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

@MainActor
final class DemoStore: MailStore {

    /// How long the fixture pretends each worker on the Pi takes. Short next to
    /// the real thing: a demo is watched rather than left, and both states have
    /// to be genuinely on screen rather than a flash.
    private static let draftDelay: Duration = .seconds(6)
    private static let sendDelay: Duration = .seconds(4)

    private var store: [String: MailMessageFull] = [:]
    /// The inbox order the collector lists in, newest first.
    private var order: [String] = []
    private let openedAt = Date()

    /// Conversations invented during this session, by id.
    ///
    /// Mutable and held here rather than in `DemoCmo`, which is stateless: demo
    /// mode has no collector and no poll, so without somewhere to put a
    /// question the ask window would be the one thing in this console that
    /// cannot be tried -- and the prompt is the whole feature. Nothing is
    /// persisted; a relaunch is a fresh demo.
    private var askStore: [String: CmoAskThread] = [:]

    /// The other two programs' fixtures, each holding its own mutable store for
    /// the same reason the ask threads are held here.
    private let chat: DemoChatStore
    private let jarvis: DemoJarvisStore
    private var intakePlans: [OvernightRun] = []
    private let msgs: DemoMessagesStore

    /// Which of the four demo payloads the console draws around the mailbox.
    /// `1` unless a preference says otherwise -- see `DemoMode.preference`.
    var demoMode: DemoMode = DemoMode.preference

    init() {
        chat = DemoChatStore(now: openedAt)
        jarvis = DemoJarvisStore(now: openedAt)
        msgs = DemoMessagesStore(now: openedAt)
        // The pinned conversation is a chat thread with a fixed id, so it is
        // put where every other chat thread lives rather than answered from a
        // second store the chat routes would know nothing about.
        chat.adopt(DemoMessagesStore.agentThread(
            id: ConsoleSettings.shared.messagesAgentThreadId, now: openedAt))
        let seeded = DemoStore.seed(now: openedAt)
        order = seeded.map(\.key)
        for m in seeded { store[m.key] = m }
        for t in DemoCmo.threads(now: openedAt) { askStore[t.id] = t }
    }

    // MARK: - reads

    func telemetry() async throws -> TelemetryPayload {
        let listed = order.compactMap { store[$0] }.filter(\.inInbox)
        let rows = listed.map(DemoStore.door)

        // Counted off the rows rather than stated. A fixture whose header
        // disagrees with its own list teaches the reader to distrust the
        // counts, which is the one thing a dashboard cannot afford.
        let counts = MailCounts(
            inbox: rows.count,
            unread: rows.filter(\.unread).count,
            urgent: rows.filter { $0.urgency == 3 }.count,
            triagePending: rows.filter { !$0.hasAi }.count,
            outboxQueued: rows.filter { $0.outboxStatus == .queued }.count
        )

        let data = MailData(counts: counts,
                            lastPollAt: Fmt.stampNow(Date().addingTimeInterval(-90)),
                            messages: rows)

        // The whole document, not only the mailbox. `DemoPayload` fixtures every
        // other source; this hands it the eight messages above and gets back the
        // envelope the current demo mode wants around them, so the console's
        // panels and the mail tab are looking at one payload in demo exactly as
        // they are in live.
        return DemoPayload.make(mode: demoMode, mail: data,
                                messages: msgs.data(now: Date()))
    }

    /// One demo message by key. The dining RFP answers for any key the demo did
    /// not invent: what a demo has to prove is the rendering, and there is one
    /// message here worth rendering.
    func message(key: String) async throws -> MailMessageFull? {
        if let held = store[key] { return held }
        guard let first = order.first, var fallback = store[first] else { return nil }
        fallback.key = key
        return fallback
    }

    // MARK: - writes
    //
    // The web demo answers `true` and changes nothing, because a browser reload
    // is a fresh fixture and the optimistic store is what draws the change.
    // Here the writes genuinely mutate: a window stays open for an hour, and a
    // pending entry the payload never agrees with would sit in the optimistic
    // set forever rather than being reconciled the way the real one is.

    func markRead(key: String) async -> Bool {
        guard var m = store[key] else { return true }
        m.unread = false
        store[key] = m
        return true
    }

    func markUnread(key: String) async -> Bool {
        guard var m = store[key] else { return true }
        m.unread = true
        store[key] = m
        return true
    }

    /// Out of the inbox, not deleted. The message stays on disk and stays
    /// readable by key; what changed is only that it is no longer filed in the
    /// inbox, which is exactly what the collector's archive does.
    func archive(key: String) async -> Bool {
        guard var m = store[key] else { return true }
        m.inInbox = false
        store[key] = m
        return true
    }

    /// Keep what was typed. The reader debounces, so this is called about once a
    /// sentence and its only job is to be there on the next read.
    func saveDraft(key: String, body: String) async -> Bool {
        guard var m = store[key] else { return true }
        m.userDraft = MailDraft(status: "ready", text: body, instructions: nil,
                                model: nil, error: nil, at: Fmt.stampNow())
        store[key] = m
        return true
    }

    /// Ask for a draft, and write one a few seconds later. The timer is the
    /// fixture standing in for the session on the Pi: it exists so the queued →
    /// ready transition the reader polls for is real in a demo.
    func requestDraft(key: String, instructions: String?) async -> Bool {
        let asked = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (asked?.isEmpty ?? true) ? nil : asked

        guard var m = store[key] else { return true }
        m.draft = MailDraft(status: "queued", text: nil, instructions: ask,
                            model: "claude-opus", error: nil, at: Fmt.stampNow())
        store[key] = m

        Task { [weak self] in
            try? await Task.sleep(for: DemoStore.draftDelay)
            guard let self, var current = self.store[key] else { return }
            let text = ask.map { "\(DemoStore.draftText)\n\n[asked for: \($0)]" }
                ?? DemoStore.draftText
            current.draft = MailDraft(status: "ready", text: text, instructions: ask,
                                      model: "claude-opus", error: nil, at: Fmt.stampNow())
            self.store[key] = current
        }

        return true
    }

    /// File a send, and let it leave a few seconds later.
    ///
    /// Returns the outbox id immediately, exactly as the collector does, so the
    /// reader's QUEUED → SENT walk is the same code path in both modes.
    func send(key: String, body: String) async -> String? {
        guard body.count <= MailRoute.maxSendBody else { return nil }
        guard var m = store[key] else { return nil }

        let at = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let id = String(format: "%04d-%02d-%02d-%02d%02d-%04x",
                        c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                        Int.random(in: 0..<0xffff))

        let record = MailOutboxEntry(
            id: id, key: key,
            to: m.replyTo ?? m.fromAddr ?? "nobody@example.com",
            subject: "Re: \(m.subject)",
            status: .queued, queuedAt: Fmt.stampNow(), sentAt: nil,
            smtpReply: nil, error: nil)

        // What went out stays in the field, which is what the real save route
        // leaves behind too.
        m.userDraft = MailDraft(status: "ready", text: body, instructions: nil,
                                model: nil, error: nil, at: Fmt.stampNow())
        m.outbox.append(record)
        store[key] = m

        Task { [weak self] in
            try? await Task.sleep(for: DemoStore.sendDelay)
            guard let self, var current = self.store[key] else { return }
            current.outbox = current.outbox.map { entry in
                guard entry.id == id else { return entry }
                var out = entry
                out.status = .sent
                out.sentAt = Fmt.stampNow()
                out.smtpReply = "250 2.0.0 OK"
                return out
            }
            self.store[key] = current
        }

        return id
    }

    // MARK: - attachments

    var canDownloadAttachments: Bool { false }

    func attachment(key: String, n: Int) async throws -> Data {
        throw MailError.demoOnly
    }

    // MARK: - messages
    //
    // Every write genuinely mutates, for the mailbox's reason: a window stays
    // open for an hour, and a pending entry the payload never agrees with would
    // sit in the optimistic set forever rather than being reconciled the way
    // the real one is.

    func thread(chatKey: String, limit: Int, before: String?) async throws -> MessageThread? {
        guard MessageRoute.isValidKey(chatKey) else { throw MailError.badKey }
        return msgs.thread(chatKey)
    }

    func markRead(chatKey: String) async -> Bool { msgs.markRead(chatKey) }

    func requestDraft(chatKey: String, instructions: String?) async -> Bool {
        msgs.requestDraft(chatKey, instructions: instructions)
    }

    func saveDraft(chatKey: String, body: String) async -> Bool {
        msgs.saveDraft(chatKey, body: body)
    }

    func send(_ intent: MessageSendRequest) async -> MessageSubmission {
        msgs.send(intent)
    }

    func summary(date: String) async throws -> MessageSummaryDoc? {
        guard MessageRoute.isValidDate(date) else { throw MailError.badKey }
        return msgs.summary(date)
    }

    func summaryRead(date: String) async -> Bool { msgs.summaryRead(date) }
    func summaryArchive(date: String) async -> Bool { msgs.summaryArchive(date) }

    /// The demo's own bytes: a drawn plate, not a photograph, so nothing in
    /// this build is anybody's camera roll. Nil for the tiles the fixture is
    /// holding back, which is what makes `fetch` a real state to look at.
    func attachmentData(key: String, n: Int) async -> Data? {
        guard MessageRoute.isValidKey(key), n >= 0, n < MessageRoute.maxAttachments
        else { return nil }
        return msgs.attachment(key, n: n)
    }

    func wantAttachment(key: String, n: Int) async -> Bool {
        guard MessageRoute.isValidKey(key), n >= 0, n < MessageRoute.maxAttachments
        else { return false }
        return msgs.wantAttachment(key, n: n)
    }

    func config() async throws -> MessagesConfig? { msgs.currentConfig() }
    func setConfig(_ config: MessagesConfig) async -> Bool { msgs.setConfig(config) }
    func chats() async -> [MessageChatSummary]? { msgs.chatList() }

    // MARK: - the cmo
    //
    // The curation routes answer yes and change nothing on purpose: the
    // dismissal list in the payload is a fixture, the optimistic overlay is
    // what draws the row dimmed, and a demo that also rewrote the fixture would
    // be testing the overlay against itself.
    //
    // `standby` is the one mode where the documents are missing rather than
    // present. That is the whole point of it -- a Pi with nothing on disk yet
    // is a real state and the four reader branches have to be lookable at.

    func cmoDismiss(_ entry: Dismissal) async -> Bool { true }
    func cmoRestore(_ entry: Dismissal) async -> Bool { true }

    /// Append one question and answer it on a timer.
    ///
    /// Returns the thread id immediately, exactly as the collector does, so the
    /// window's optimistic render is the same code path in both modes. The
    /// timer is the fixture standing in for the runner on the Pi: it is the one
    /// thing here that makes something happen later, and it exists so the
    /// thinking → idle transition the window polls for is real in a demo.
    func cmoAsk(question: String, thread: String?) async -> String? {
        let at = Fmt.stampNow()
        let turn = CmoAskTurn(role: .q, text: question, at: at)

        let doc: CmoAskThread
        if let thread, var held = askStore[thread] {
            held.updated = at
            held.status = .thinking
            held.turns.append(turn)
            doc = held
        } else {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: Date())
            let id = String(format: "%04d-%02d-%02d-%02d%02d-%04x",
                            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                            Int.random(in: 0..<0xffff))
            doc = CmoAskThread(id: id, created: at, updated: at, sessionId: nil,
                               status: .thinking, turns: [turn])
        }
        askStore[doc.id] = doc

        Task { [weak self] in
            try? await Task.sleep(for: DemoCmo.answerDelay)
            guard let self, var held = self.askStore[doc.id] else { return }
            let answeredAt = Fmt.stampNow()
            held.updated = answeredAt
            held.sessionId = held.sessionId ?? "demo-session"
            held.status = .idle
            held.turns.append(CmoAskTurn(
                role: .a, text: DemoCmo.answer, at: answeredAt,
                reads: ["briefings/\(DemoCmo.isoDay(Date())).md", "memory/leads.md"],
                durationS: 6))
            self.askStore[doc.id] = held
        }

        return doc.id
    }

    /// One demo thread by id. The answered one stands in for any id the demo
    /// did not invent, the same way the dossier answers for any slug: what a
    /// demo has to prove is the rendering, and there is one conversation here
    /// worth rendering.
    func cmoThread(id: String) async throws -> CmoAskThread? {
        if let held = askStore[id] { return held }
        var fallback = DemoCmo.answered(now: Date())
        fallback.id = id
        return fallback
    }

    func cmoBriefing(date: String) async throws -> String? {
        demoMode == .standby ? nil : DemoCmo.briefing
    }

    func cmoDossier(slug: String) async throws -> String? {
        demoMode == .standby ? nil : DemoCmo.dossier(now: Date())
    }

    func cmoDoc(slug: String) async throws -> String? {
        demoMode == .standby ? nil : DemoCmo.doc(now: Date())
    }

    // MARK: - chat and jarvis
    //
    // Two stores of their own, and stateful for `askStore`'s reason: demo mode
    // has no collector and no runner, so without somewhere to put a message
    // these two tabs would be the pages in this console that cannot be tried,
    // and the input is the whole feature. Both mint answers on a timer, which is
    // what makes the states the views poll for -- queued, running with a growing
    // partial, then idle with a turn -- real in a demo rather than described.
    //
    // Nil is never returned from a list here: it is the sentence about an
    // unreachable collector and there is no collector here to be unreachable.

    func chatList() async -> [ChatThreadSummary]? { chat.list() }
    func chatThread(id: String) async throws -> ChatThread? { chat.thread(id) }
    func chatNew(model: ChatModelName) async -> String? { chat.new(model: model) }
    func chatSend(id: String, text: String) async -> WriteResult { chat.send(id: id, text: text) }

    func chatSetModel(id: String, model: ChatModelName) async -> WriteResult {
        chat.setModel(id: id, model: model)
    }

    func chatSetEffort(id: String, effort: JarvisEffort) async -> WriteResult {
        chat.setEffort(id: id, effort: effort)
    }

    func chatStop(id: String) async -> WriteResult { chat.stop(id: id) }
    func chatDelete(id: String) async -> WriteResult { chat.delete(id: id) }

    func chatArchive(id: String, archived: Bool) async -> WriteResult {
        chat.archive(id: id, archived: archived)
    }

    func jarvisToday() async throws -> JarvisDay? { jarvis.todayRecord() }
    func jarvisDays() async -> [JarvisDaySummary]? { jarvis.daySummaries() }
    func jarvisDay(_ day: String) async throws -> JarvisDay? { jarvis.day(day) }
    func submitOvernightTasks(requestID: UUID, text: String, runAt: Date) async throws -> String {
        let id = requestID.uuidString.lowercased()
        let start = ISO8601DateFormatter().string(from: runAt)
        if let existing = intakePlans.first(where: { $0.id == id }) {
            guard existing.request == text, existing.runAt == start else {
                throw OvernightSubmissionError(message: "This request already has a different plan.")
            }
            return id
        }
        let at = Fmt.stampNow()
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let children = lines.map { line in
            OvernightRun(id: UUID().uuidString.lowercased(), title: String(line.prefix(80)),
                         status: "scheduled", createdAt: at, updatedAt: at, request: line,
                         parentId: id, runAt: start)
        }
        let plan = OvernightRun(id: id, title: "Plan overnight tasks", status: "done", createdAt: at,
                                updatedAt: at, request: text,
                                markdown: "In this demo, each line becomes a task. On the Pi, Codex reads the whole description and splits it into assignments.",
                                kind: "intake", runAt: start, children: children)
        intakePlans.insert(plan, at: 0)
        return id
    }

    private var demoIntakeRuns: [OvernightRun] {
        intakePlans.flatMap { original -> [OvernightRun] in
            var plan = original
            let children = (plan.children ?? []).map { original -> OvernightRun in
                var child = original
                if child.status == "scheduled", let date = Fmt.date(child.runAt), date <= Date() {
                    child.status = "done"
                    child.markdown = "This is a sample report for the scheduled demo task."
                    child.updatedAt = child.runAt ?? child.updatedAt
                }
                return child
            }
            plan.children = children
            return [plan] + children
        }
    }

    func overnightRuns(before cursor: String?) async throws -> OvernightRunPage {
        OvernightRunPage(runs: demoIntakeRuns + jarvis.jobList().map(OvernightRun.legacy), nextCursor: nil)
    }

    func overnightRun(id: String) async throws -> OvernightRun? {
        demoIntakeRuns.first { $0.id == id } ?? jarvis.jobList().first { $0.id == id }.map(OvernightRun.legacy)
    }

    func overnightFile(run: String, file: String) async throws -> URL? { nil }

    func jarvisJobs() async -> [JarvisJob]? { jarvis.jobList() }
    func jarvisSay(text: String) async -> WriteResult { jarvis.say(text) }
    func jarvisStop() async -> WriteResult { jarvis.stop() }
    func jarvisSetModel(_ model: JarvisModelName) async -> WriteResult { jarvis.setModel(model) }

    func jarvisSetEffort(_ effort: JarvisEffort) async -> WriteResult {
        jarvis.setEffort(effort)
    }

    func jarvisCompact() async -> WriteResult { jarvis.compact() }

    func jarvisJob(text: String, title: String) async -> WriteResult {
        jarvis.file(text: text, title: title)
    }

    func jarvisJobStop(id: String) async -> WriteResult {
        for plan in intakePlans.indices {
            if let index = intakePlans[plan].children?.firstIndex(where: { $0.id == id }) {
                intakePlans[plan].children?[index].status = "stopped"
                intakePlans[plan].children?[index].updatedAt = Fmt.stampNow()
                return .ok
            }
        }
        return jarvis.stopJob(id)
    }

    /// **Nil is the honest demo answer.** There is no Mac behind a fixture, so
    /// the voice degrades exactly as it does when the real one is asleep -- which
    /// also means the canned shelf, which is in the bundle and needs no network,
    /// is the half of the feature a demo can actually show.
    func jarvisTts(text: String) async -> Data? { nil }
    func jarvisWarmTts() {}

    // MARK: - the door

    /// The row the payload carries, from the message behind it.
    private static func door(_ msg: MailMessageFull) -> MailMessageSummary {
        let sent = msg.outbox.last
        return MailMessageSummary(
            key: msg.key,
            from: msg.fromName ?? msg.fromAddr ?? "unknown",
            subject: msg.subject,
            date: msg.date,
            unread: msg.unread,
            flagged: msg.flagged,
            // Null stays null. A failed triage record has no verdict, and this
            // is the join where that would quietly become a zero.
            urgency: msg.ai?.urgency,
            tags: msg.ai?.tags ?? [],
            summaryLine: msg.ai?.summary.first,
            hasAi: msg.ai != nil,
            hasDraft: !(msg.draft?.text ?? "").isEmpty || !(msg.userDraft?.text ?? "").isEmpty,
            attachmentsN: msg.attachments.count,
            outboxStatus: sent?.status
        )
    }

    private static let draftText = """
        Hi,

        Thanks for the note. Short answer is yes, and I can have the numbers over to \
        you by Friday.

        One thing I want to be straight about: the fall pilot is three dorms, not the \
        whole campus, so treat everything in it as a floor rather than a run rate.

        Alex
        """

    // MARK: - the fixture

    private static func seed(now: Date) -> [MailMessageFull] {
        func ago(_ s: Double) -> String { Fmt.stampNow(now.addingTimeInterval(-s)) }

        /// Everything a message record carries that is the same for all of
        /// them. The address is the operator's, the mailbox is one account, and
        /// the poller writes the same four bookkeeping fields every time.
        func base(_ key: String, _ uid: Int) -> MailMessageFull {
            MailMessageFull(
                key: key, messageId: "<\(key)@mail.example.com>", uid: uid,
                uidvalidity: 812_004_119, fromName: nil, fromAddr: nil,
                to: "owner@example.com", replyTo: nil, subject: "", date: nil,
                size: nil, unread: false, flagged: false, inInbox: true,
                references: [], attachments: [], bodyCached: true, bodyTruncated: false,
                body: nil, ai: nil, draft: nil, userDraft: nil, outbox: [])
        }

        var mail: [MailMessageFull] = []

        // 1 · needs today, unread, an attachment, and a session draft already
        //     written and waiting to arrive in the field on its own.
        var m1 = base("b41e0c7d92af5613", 41_207)
        m1.fromName = "NGU Dining Services"
        m1.fromAddr = "dining@example.edu"
        m1.replyTo = "rfp@example.edu"
        m1.subject = "RFP: student delivery pilot, responses due Sept 5"
        m1.date = ago(2_400)
        m1.size = 84_112
        m1.unread = true
        m1.attachments = [MailAttachment(n: 1, name: "delivery-pilot-rfp.pdf",
                                         size: 62_118, ctype: "application/pdf")]
        m1.body = """
            Hello,

            Dining Services is accepting proposals for a delivery pilot serving Kestrel \
            Commons to the Harbor, Linden and Aster residence halls during the fall \
            term.

            Responses are due by 5pm on September 5. Please include per-delivery pricing, \
            proof of general liability coverage, and a sidewalk operating plan.

            The attached RFP has the full requirements.

            Regards,
            Mira Vale
            Dining Services, Northgate University
            """
        m1.ai = MailAiArtifact(
            tags: ["lead", "campus", "action-needed"], urgency: 3,
            summary: [
                "Dining wants per-delivery pricing and proof of insurance by Sept 5.",
                "Pilot covers Kestrel Commons to Harbor, Linden and Aster this fall.",
                "A sidewalk operating plan is required with the response.",
            ],
            model: "claude-sonnet", status: "ok", at: ago(2_100))
        m1.draft = MailDraft(
            status: "ready",
            text: """
                Hi Mira,

                Thanks for sending this. We will respond before the 5th.

                Two quick questions so the pricing is right: is the pilot exclusive to one \
                operator, and does the sidewalk plan need to cover the Marsh Road crossing \
                or only the interior paths?

                Our coverage is in place and I can send the certificate with the response.

                Alex
                """,
            instructions: nil, model: "claude-opus", error: nil, at: ago(1_800))
        mail.append(m1)

        // 2 · this week, a draft of the operator's own in the field, and a reply
        //     already queued.
        var m2 = base("7c2a15e8d0b34f96", 41_206)
        m2.fromName = "Nadia Sorin"
        m2.fromAddr = "nadia@capital.example.com"
        m2.replyTo = "nadia@capital.example.com"
        m2.subject = "Re: Ferryline seed deck"
        m2.date = ago(10_800)
        m2.size = 12_004
        m2.body = """
            Alex,

            Read the deck twice. The campus wedge is the interesting part, not the \
            hardware.

            Before I take it to partners I need the fall pilot numbers: deliveries per \
            day, cost per delivery, and what the ad side actually billed.

            Nadia
            """
        m2.ai = MailAiArtifact(
            tags: ["investor"], urgency: 2,
            summary: [
                "Wants fall pilot numbers before taking the deck to her partners.",
                "Asks for deliveries per day, cost per delivery, and billed ad revenue.",
            ],
            model: "claude-sonnet", status: "ok", at: ago(10_500))
        m2.userDraft = MailDraft(
            status: "ready",
            text: """
                Nadia,

                Numbers for the fall pilot are below. The ad line is billed, not booked.

                Alex
                """,
            instructions: nil, model: nil, error: nil, at: ago(9_000))
        m2.outbox = [MailOutboxEntry(
            id: "2026-08-16-0914-1f7c", key: m2.key, to: "nadia@capital.example.com",
            subject: "Re: Ferryline seed deck", status: .queued,
            queuedAt: ago(240), sentAt: nil, smtpReply: nil, error: nil)]
        mail.append(m2)

        // 3 · whenever, unread, and a sender that does not take replies.
        var m3 = base("0d5b8fa61c73e924", 41_205)
        m3.fromName = "NGU Student Accounts"
        m3.fromAddr = "billing@example.edu"
        m3.replyTo = "billing@example.edu"
        m3.subject = "Fall term statement is available"
        m3.date = ago(28_800)
        m3.size = 9_440
        m3.unread = true
        m3.body = """
            Your fall term statement is now available in the student portal.

            Payment is due September 20. This message was sent to all enrolled \
            students and does not accept replies.
            """
        m3.ai = MailAiArtifact(
            tags: ["billing"], urgency: 1,
            summary: ["Fall statement is posted in the portal and due September 20."],
            model: "claude-sonnet", status: "ok", at: ago(28_500))
        mail.append(m3)

        // 4 · urgency 0. The quietest message in the box, and the one that gets
        //     no mark at all: "ignorable" is the absence of a claim.
        var m4 = base("e28c6b09f4a17d35", 41_204)
        m4.fromName = "The Sidewalk Brief"
        m4.fromAddr = "newsletter@example.com"
        m4.replyTo = "newsletter@example.com"
        m4.subject = "Sidewalk robots are quietly winning the last hundred feet"
        m4.date = ago(39_600)
        m4.size = 148_220
        m4.body = """
            THE SIDEWALK BRIEF

            Delivery robots have stopped being a demo and started being infrastructure \
            on a handful of campuses. The economics are still thin and the sidewalks are \
            still contested, but the operators who survived 2024 are now the incumbents.

            Read the full story on the web.
            """
        m4.ai = MailAiArtifact(
            tags: ["newsletter"], urgency: 0,
            summary: ["Trade newsletter on campus delivery robots. Nothing to act on."],
            model: "claude-sonnet", status: "ok", at: ago(39_300))
        mail.append(m4)

        // 5 · no triage record at all. This is the row that proves "not triaged
        //     yet", and the one the pending count is counting.
        var m5 = base("95d3f7ab210ce648", 41_203)
        m5.fromName = "Corin Blake"
        m5.fromAddr = "corin@example.com"
        m5.replyTo = "corin@example.com"
        m5.subject = "bot 2 wheel came loose again by the library"
        m5.date = ago(46_800)
        m5.size = 3_180
        m5.unread = true
        m5.body = """
            same wheel as last week. i carried it back to the shop, nothing bent.

            we need the longer bolts before the next run.
            """
        mail.append(m5)

        // 6 · a triage record that gave up. `has_ai` is true and `urgency` is
        //     null, which is the pair that would read as level 0 anywhere the
        //     two facts were collapsed -- so this row exists to prove they are
        //     not, in the list and in the reader's summary panel both.
        var m6 = base("c4e70d1b8a52f39c", 41_202)
        m6.fromName = "Facilities Work Orders"
        m6.fromAddr = "workorders@example.edu"
        m6.replyTo = "workorders@example.edu"
        m6.subject = "Fwd: Fwd: Re: bollard placement, Marsh Road gate (17 attachments)"
        m6.date = ago(54_000)
        m6.size = 2_204_880
        m6.body = """
            ---------- Forwarded message ----------

            See thread below. Bollard spacing at the Marsh Road gate is being revised \
            again; the drawings in the earlier message are superseded.

            ---------- Forwarded message ----------
            """
        m6.bodyTruncated = true
        m6.ai = MailAiArtifact(
            tags: [], urgency: nil, summary: [], model: "claude-sonnet",
            status: "failed", at: ago(53_400))
        mail.append(m6)

        // 7 · a reply that was written, filed, and refused by the far end. The
        //     one message here whose reply did not leave, which is what gives
        //     SEND FAILED and its RETRY somewhere to be seen.
        var m7 = base("5f19d4c8e07b32a1", 41_201)
        m7.fromName = "Sam Ridley"
        m7.fromAddr = "sales@parts.example.com"
        m7.replyTo = "sales@parts.example.com"
        m7.subject = "longer M4 bolts, 50 pack, ship today?"
        m7.date = ago(61_200)
        m7.size = 4_620
        m7.body = """
            Alex,

            We have the 30mm M4s in stock. Fifty of them ship today if the order is in \
            before three.

            Sam
            """
        m7.ai = MailAiArtifact(
            tags: ["service"], urgency: 2,
            summary: ["Fifty 30mm M4 bolts ship today if the order is in before three."],
            model: "claude-sonnet", status: "ok", at: ago(61_000))
        m7.userDraft = MailDraft(
            status: "ready",
            text: "Sam,\n\nPut me down for the fifty. Ship to the shop address.\n\nAlex",
            instructions: nil, model: nil, error: nil, at: ago(60_000))
        m7.outbox = [MailOutboxEntry(
            id: "2026-08-16-0620-9c3d", key: m7.key, to: "sales@parts.example.com",
            subject: "Re: longer M4 bolts, 50 pack, ship today?", status: .error,
            queuedAt: ago(59_400), sentAt: nil, smtpReply: nil,
            error: "535 5.7.8 the Pi was refused at the smtp door")]
        mail.append(m7)

        // 8 · answered this morning, and starred. The row says "replied" rather
        //     than nothing, so a message already dealt with does not read
        //     as untouched.
        var m8 = base("3ab7c05e19d2f846", 41_200)
        m8.fromName = "Jo Marsh"
        m8.fromAddr = "ads@example.org"
        m8.replyTo = "ads@example.org"
        m8.subject = "fall rate card + the bot wrap idea"
        m8.date = ago(72_000)
        m8.size = 21_900
        m8.flagged = true
        m8.body = """
            Hi Alex,

            Attaching the fall rate card. Boards are repricing about 12% over last \
            year, which I think helps your case rather than hurts it.

            If the wrap idea is real for September I can hold a slot in the issue that \
            lands during move-in.

            Jo
            """
        m8.ai = MailAiArtifact(
            tags: ["campus", "lead"], urgency: 1,
            summary: [
                "Holding a move-in issue slot if the bot wrap is real for September.",
                "Campus board rates are up about 12% on last year.",
            ],
            model: "claude-sonnet", status: "ok", at: ago(71_700))
        m8.outbox = [MailOutboxEntry(
            id: "2026-08-16-0802-4b19", key: m8.key, to: "ads@example.org",
            subject: "Re: fall rate card + the bot wrap idea", status: .sent,
            queuedAt: ago(30_600), sentAt: ago(30_540), smtpReply: "250 2.0.0 OK",
            error: nil)]
        mail.append(m8)

        return mail
    }
}
