import Foundation

/* The demo chat assistant, ported from `fixture.ts`'s chat block.
 *
 * Four conversations for the four states the conversation route has to draw --
 * answered, mid-stream, failed, never-used -- and a back catalogue for the list,
 * which is a different question: four rows prove that a row renders and prove
 * nothing about a list. A card's whole claim is that ten conversations read as
 * ten countable objects, and that claim cannot be checked against three of them.
 *
 * **Mutable and not persisted.** Demo mode has no collector, so without somewhere
 * to put a message the chat tab would be the one page in this console that cannot
 * be tried, and the input is the whole feature. A relaunch is a fresh demo.
 *
 * Note what the mid-stream thread is: a `partial` with no assistant turn after
 * it, `status: running`, and a tool list already showing. That is exactly the
 * record the runner leaves on disk half a second into a turn, and drawing it is
 * the one thing the demo has to prove -- a fixture whose streaming state was a
 * finished answer would look identical to the bug this view is most likely to
 * have.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

@MainActor
final class DemoChatStore {

    /// How long the fixture pretends a turn takes, and how fast it streams. Short
    /// next to a real 20-to-60-second session, because a demo is watched rather
    /// than left -- and the tick is what makes `partial` visibly a partial rather
    /// than a value that appears whole.
    private static let tick: Duration = .milliseconds(220)
    /// The path unit firing, a beat later.
    private static let pickup: Duration = .milliseconds(900)
    private static let steps = 40

    private var threads: [String: ChatThread] = [:]
    /// Which conversations are put away, held beside the threads rather than on
    /// them -- the collector's own arrangement, where the flag lives outside the
    /// thread file. It is the reason archiving is allowed mid-turn while
    /// deleting is not, and a fixture that stored it on the record would have
    /// quietly made that a fixture decision instead of the wire's.
    private var archivedIds: Set<String> = []
    private let openedAt: Date

    init(now: Date = Date()) {
        openedAt = now
        for thread in DemoChatStore.seed(now: now) { threads[thread.id] = thread }
        archivedIds = [DemoChatStore.seededArchive]
    }

    // MARK: - reads

    /// Newest-updated first, the way the collector lists them.
    func list() -> [ChatThreadSummary] {
        threads.values
            .map { thread in
                ChatThreadSummary(
                    id: thread.id,
                    title: thread.title,
                    preview: DemoChatStore.preview(thread),
                    updatedAt: thread.updatedAt,
                    status: thread.status,
                    model: thread.model,
                    turnCount: thread.turns.count,
                    queued: thread.queued,
                    archived: archivedIds.contains(thread.id))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// One demo thread by id. The answered one stands in for any id the demo did
    /// not invent, the way the dossier answers for any slug: what a demo has to
    /// prove is the rendering.
    func thread(_ id: String) -> ChatThread {
        if let held = threads[id] { return held }
        var fallback = DemoChatStore.answered(now: openedAt)
        fallback.id = id
        return fallback
    }

    /// Put a thread the fixture did not seed into the store.
    ///
    /// One caller: the Messages tab's pinned conversation, which is an ordinary
    /// chat thread with a fixed id (build decision 10). It is adopted rather
    /// than seeded here because what it says belongs beside the rest of the
    /// Messages fixture, and because its id is a preference rather than a
    /// constant this file could state.
    func adopt(_ thread: ChatThread) {
        threads[thread.id] = thread
    }

    // MARK: - writes

    func new(model: ChatModelName) -> String {
        let at = Fmt.stampNow()
        let id = DemoChatStore.mintId()
        threads[id] = ChatThread(id: id, title: "", createdAt: at, updatedAt: at,
                                 model: model, status: .idle, turns: [])
        return id
    }

    func send(id: String, text: String) -> WriteResult {
        guard var held = threads[id] else { return .failed }
        // The same refusal the collector makes, and worth having in the fixture:
        // it is the one response the view has a whole state for.
        if held.queued || held.status == .running { return .busy }

        let at = Fmt.stampNow()
        if held.title.isEmpty {
            // The tags come off the front first. A tag says which architecture
            // the turn is pointed at, or which pass to make before answering,
            // and a session list whose rows all open "@cmo …" or "@web …" has
            // stopped telling them apart -- the words after it are the ones
            // that say what was asked. Only the leading run: an `@mail` in the
            // middle of a question is part of the question.
            //
            // A message that is nothing but tags leaves an empty title, which is
            // the state `chatUntitled` already has a word for. Inventing one from
            // a pointer would be worse than "new session".
            held.title = String(ChatTags.strippedOfLeadingTags(text)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").prefix(80))
        }
        held.updatedAt = at
        held.error = nil
        // Queued and NOT running, exactly as the collector leaves it: the runner
        // has not picked it up yet, and this is the window the view has to draw
        // from `queued` alone because no process has written a status.
        held.queued = true
        held.turns.append(ChatTurn(role: .user, text: text, at: at))
        threads[id] = held

        Task { [weak self] in
            try? await Task.sleep(for: DemoChatStore.pickup)
            guard let self, var current = self.threads[id], current.queued else { return }
            current.queued = false
            current.status = .running
            current.partial = ""
            current.updatedAt = Fmt.stampNow()
            self.threads[id] = current
            self.stream(id)
        }
        return .ok
    }

    /// `updated_at` deliberately untouched, like the collector: flipping a toggle
    /// is not the conversation moving, and a thread that jumped to the top of the
    /// list on a settings change would be lying about what happened.
    func setModel(id: String, model: ChatModelName) -> WriteResult {
        guard var held = threads[id] else { return .failed }
        if held.queued || held.status == .running { return .busy }
        held.model = model
        threads[id] = held
        return .ok
    }

    func setEffort(id: String, effort: JarvisEffort) -> WriteResult {
        guard var held = threads[id] else { return .failed }
        if held.queued || held.status == .running { return .busy }
        held.effort = effort
        threads[id] = held
        return .ok
    }

    /// Idle is a no-op success, like the real route.
    func stop(id: String) -> WriteResult {
        guard var held = threads[id] else { return .failed }
        if held.status != .running && !held.queued { return .ok }

        let at = Fmt.stampNow()
        let said = held.partial ?? ""
        held.status = .idle
        held.partial = nil
        held.queued = false
        held.updatedAt = at
        held.turns.append(ChatTurn(
            role: .assistant,
            text: said.isEmpty ? "[stopped]" : "\(said)\n\n[stopped]",
            at: at,
            tools: Array(DemoChatStore.tools.prefix(2)),
            model: held.model,
            elapsedS: 3.1))
        threads[id] = held
        return .ok
    }

    /// Take a conversation away, and refuse while one is in flight -- the same
    /// two answers the collector gives, because `busy` is the branch the list has
    /// a whole line for and a fixture that always succeeded would never draw it.
    func delete(id: String) -> WriteResult {
        guard let held = threads[id] else { return .failed }
        if held.queued || held.status == .running { return .busy }
        threads.removeValue(forKey: id)
        // The flag is kept beside the threads, so taking a thread away has to
        // take its flag with it.
        archivedIds.remove(id)
        return .ok
    }

    /// Put a conversation away, or take it back out.
    ///
    /// **Deliberately not refused mid-turn**, and that is the collector's rule
    /// rather than a corner the fixture cut: the flag is outside the thread
    /// file, so setting it touches nothing the runner is holding. A thread can
    /// be archived while it is being answered and the answer still lands in it.
    func archive(id: String, archived: Bool) -> WriteResult {
        guard threads[id] != nil else { return .failed }
        if archived { archivedIds.insert(id) } else { archivedIds.remove(id) }
        return .ok
    }

    // MARK: - the runner

    /// Stream one reply into a thread, a few characters at a time.
    ///
    /// The fixture standing in for `chat-runner.py`: it exists so that the states
    /// the view polls for -- queued, running with a growing `partial`, then idle
    /// with a turn -- are real in a demo rather than described. A stop request
    /// lands by the thread's status moving out of running underneath it, which is
    /// the same signal the real one gives.
    private func stream(_ id: String) {
        let reply = Array(DemoChatStore.reply)
        let step = Int((Double(reply.count) / Double(DemoChatStore.steps)).rounded(.up))

        Task { [weak self] in
            var at = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: DemoChatStore.tick)
                // Gone, or stopped, or someone else finished it. Either way this
                // timer no longer owns the thread.
                guard let self, var held = self.threads[id], held.status == .running
                else { return }

                at += step
                if at < reply.count {
                    held.partial = String(reply.prefix(at))
                    held.updatedAt = Fmt.stampNow()
                    self.threads[id] = held
                    continue
                }

                let landed = Fmt.stampNow()
                held.status = .idle
                held.partial = nil
                held.claudeSessionId = held.claudeSessionId ?? "demo-session-new"
                held.updatedAt = landed
                held.turns.append(ChatTurn(
                    role: .assistant, text: DemoChatStore.reply, at: landed,
                    tools: DemoChatStore.tools, model: held.model, elapsedS: 8.8))
                self.threads[id] = held
                return
            }
        }
    }

    // MARK: - the wire's own fields

    /// The newest answer's first line, the way the collector cuts it. Kept here
    /// rather than derived in the view: a demo's job is to prove the rendering of
    /// what the wire carries, and a view that computed this itself would render a
    /// field the Pi does not send.
    private static func preview(_ thread: ChatThread) -> String {
        for turn in thread.turns.reversed() where turn.role == .assistant {
            let line = turn.text.split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return String((line.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).prefix(120))
        }
        return ""
    }

    private static func mintId() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                from: Date())
        return String(format: "%04d-%02d-%02d-%02d%02d-%04x",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                      Int.random(in: 0..<0xffff))
    }

    // MARK: - the fixture

    private static let reply =
        "Yes, and it is the collector rather than anything upstream.\n\n"
        + "halftone-collector.service has been up 4 days and its last poll of every "
        + "source succeeded, so the feed itself is healthy. What is not healthy is the "
        + "camera source: the camera monitor on :8787 answers, and what it answers "
        + "with is a frame that is 2h 19m old.\n\n"
        + "That is the RTSP camera, not this Pi. tapo-c100 at 10.0.0.4 refuses a TCP "
        + "connection on 554, which is what the nodes panel is already drawing as "
        + "Offline. Power-cycling the camera is the usual fix.\n\n"
        + "I have not touched anything."

    private static let tools = [
        "Bash(systemctl status halftone-collector)",
        "Bash(journalctl -u halftone-collector -n 40 --no-pager)",
        "Read(/home/pi/halftone-collector/config.json)",
    ]

    private static func answered(now: Date) -> ChatThread {
        func ago(_ s: Double) -> String { Fmt.stampNow(now.addingTimeInterval(-s)) }
        return ChatThread(
            id: "2026-08-17-0914-3f0a",
            title: "why did the mail poller stop at 03:12?",
            createdAt: ago(2_940), updatedAt: ago(2_881),
            model: .sonnet, status: .idle,
            claudeSessionId: "demo-session-a",
            turns: [
                ChatTurn(role: .user, text: "why did the mail poller stop at 03:12?",
                         at: ago(2_940)),
                ChatTurn(
                    role: .assistant,
                    text: "It did not stop. charon-mail-poll.timer is still active and last "
                        + "fired 3 minutes ago; what stopped at 03:12 was the run succeeding."
                        + "\n\nEvery fire since then has exited 1 with the same line:\n\n"
                        + "    imaplib.IMAP4.error: AUTHENTICATE failed\n\n"
                        + "The app password is rejected, which usually means it was revoked "
                        + "on the Google account rather than that anything changed on this "
                        + "Pi. The timer keeps firing every 5 minutes and will start working "
                        + "again the moment a valid password is in the poller's "
                        + "EnvironmentFile.\n\nI cannot read that file to check which "
                        + "password is in it, and I would not be able to tell a revoked one "
                        + "from a valid one by looking anyway.",
                    at: ago(2_881),
                    tools: [
                        "Bash(systemctl status charon-mail-poll.timer)",
                        "Bash(systemctl list-timers charon-mail-poll.timer)",
                        "Bash(journalctl -u charon-mail-poll -n 80 --no-pager)",
                    ],
                    model: .sonnet, elapsedS: 22.6),
            ])
    }

    /// One past conversation. `prior` is the exchanges that came *before* the one
    /// the list quotes, newest last.
    ///
    /// **Written out rather than generated.** A counter would have filled these
    /// threads with the same sentence repeated, which is invisible on the list --
    /// where only the turn count shows -- and is the entire screen the moment
    /// somebody opens one. That also makes the follow-up shape true: the second
    /// question in a real thread is short, leans on the answer above it, and is
    /// where a conversation stops being a search box.
    private static func past(_ id: String, _ ago: Double, _ model: ChatModelName,
                             _ title: String, _ answer: String,
                             _ prior: [(String, String)] = [],
                             now: Date) -> ChatThread {
        func stamp(_ s: Double) -> String { Fmt.stampNow(now.addingTimeInterval(-s)) }
        let step = 90.0
        let span = Double(prior.count + 1) * step
        var turns: [ChatTurn] = []

        for (i, exchange) in prior.enumerated() {
            let base = ago + span - (Double(i) * step)
            turns.append(ChatTurn(role: .user, text: exchange.0, at: stamp(base)))
            turns.append(ChatTurn(role: .assistant, text: exchange.1, at: stamp(base - 20),
                                  model: model, elapsedS: 4.1 + Double(i) * 2.3))
        }
        turns.append(ChatTurn(role: .user, text: title, at: stamp(ago + 40)))
        turns.append(ChatTurn(role: .assistant, text: answer, at: stamp(ago),
                              model: model, elapsedS: 11.4))

        return ChatThread(
            id: id, title: title,
            createdAt: stamp(ago + span), updatedAt: stamp(ago),
            model: model, status: .idle,
            claudeSessionId: "demo-session-\(id.suffix(4))",
            turns: turns)
    }

    /// One back-catalogue thread starts put away, because the archived line and
    /// the restore beside it are drawn only when something is in there -- and a
    /// fixture where nothing ever is leaves that half of the list unproven.
    /// Deliberately one of the old ones: the four state-provers are on the list
    /// to be looked at, and archiving one would take a state off the page.
    private static let seededArchive = "2026-08-11-0845-c207"

    private static func seed(now: Date) -> [ChatThread] {
        func ago(_ s: Double) -> String { Fmt.stampNow(now.addingTimeInterval(-s)) }

        // Never typed into. The one thread whose card draws both marks dim.
        let empty = ChatThread(
            id: "2026-08-17-0933-0c41", title: "",
            createdAt: ago(20), updatedAt: ago(20),
            model: .sonnet, status: .idle, turns: [])

        // Mid-stream: a partial with no assistant turn after it.
        let running = ChatThread(
            id: "2026-08-17-0931-b1c7", title: "is the nvme filling up?",
            createdAt: ago(64), updatedAt: ago(2),
            model: .opus, status: .running,
            claudeSessionId: "demo-session-b",
            turns: [ChatTurn(role: .user, text: "is the nvme filling up?", at: ago(64))],
            partial: "Root is at 34% of 916G, so no — nothing is close to full.\n\n"
                + "The one number worth watching is /var/log, which has grown to 2.1G "
                + "since the journal")

        // Filed, and the runner has not picked it up. Not a status.
        let queued = ChatThread(
            id: "2026-08-17-0928-5e82", title: "why is the fan spinning at idle?",
            createdAt: ago(180), updatedAt: ago(174),
            model: .opus, status: .idle,
            turns: [ChatTurn(role: .user, text: "why is the fan spinning at idle?",
                             at: ago(174))],
            queued: true)

        // A timeout: the runner giving up on itself.
        let failed = ChatThread(
            id: "2026-08-16-2203-77de",
            title: "summarise everything in the journal since the reboot",
            createdAt: ago(41_000), updatedAt: ago(40_400),
            model: .opus, status: .error,
            error: "the session did not finish within 600s",
            turns: [ChatTurn(role: .user,
                             text: "summarise everything in the journal since the reboot",
                             at: ago(41_000))])

        // A second failure, and deliberately a different KIND: the session
        // refusing, which is the sandbox working. A list with one red row proves
        // the colour renders; two prove the word beside it is carrying the
        // meaning.
        let refused = ChatThread(
            id: "2026-08-11-2014-3d55", title: "rebuild the pi-hole blocklists",
            createdAt: ago(600_000), updatedAt: ago(599_400),
            model: .sonnet, status: .error,
            error: "the session refused: writes are not permitted",
            turns: [ChatTurn(role: .user, text: "rebuild the pi-hole blocklists",
                             at: ago(600_000))])

        let catalogue = [
            past("2026-08-17-0806-2a91", 4_800, .sonnet,
                 "what is holding port 8788 open?",
                 "halftone-collector, pid 812, since the 08:40 restart. Nothing else has "
                 + "bound it since the reboot, and the unit has not been restarted by "
                 + "anything but you.", now: now),
            past("2026-08-17-0312-6b40", 22_000, .sonnet,
                 "did the backup actually run last night?",
                 "Yes, at 03:00, and it took 41 seconds. restic reports 1.2G added and no "
                 + "errors. The next one is scheduled for 03:00 tomorrow.",
                 [("is restic even installed on here?",
                   "It is, 0.16.4, and it is driven by restic-backup.timer rather than by "
                   + "cron.")], now: now),
            past("2026-08-16-1944-d3f8", 61_000, .opus,
                 "can i move the journal to the sd card?",
                 "You can, and I would not. The SD card is the fallback boot device and "
                 + "writing the journal to it burns the card you fall back to. Cap it on "
                 + "the NVMe instead with SystemMaxUse in journald.conf.",
                 [("what is actually taking up space in /var?",
                   "The journal, at 2.1G. Everything else in /var together is under 400M."),
                  ("is 2.1G a lot for a journal?",
                   "It is more than it needs to be. journald keeps 10% of the filesystem "
                   + "by default, which on a 916G disk is a cap you will never reach, so "
                   + "it just grows until something else stops it.")], now: now),
            past("2026-08-16-1120-8c15", 88_000, .sonnet,
                 "explain the charon-mail-poll unit to me",
                 "It is a systemd timer firing every 5 minutes at a oneshot service. The "
                 + "service runs the poller once and exits, so the timer is what keeps it "
                 + "alive rather than a long-running process.",
                 [("what units do i actually have running for charon?",
                   "Three: charon-mail-poll.timer, charon-cmo.timer and "
                   + "halftone-collector.service. The first two are timers, the third is "
                   + "the only long-running one."),
                  ("why is the collector a service and not a timer?",
                   "Because it holds the HTTP port. A timer would bind and release 8788 "
                   + "every few minutes and nothing could keep a connection open to it.")],
                 now: now),
            past("2026-08-15-2201-4f77", 170_000, .sonnet,
                 "is tailscale actually routing the subnet or am i just lucky?",
                 "It is routing it. The Pi advertises 10.0.0.0/24 and the route is "
                 + "approved on the tailnet, so the Mac reaches the Zero through it rather "
                 + "than over the LAN.", now: now),
            past("2026-08-14-0930-1e63", 290_000, .opus,
                 "why did pi-hole stop blocking after the reboot?",
                 "It had not stopped; the Zero came back before the router handed out DNS, "
                 + "so the first few minutes of queries went straight out. It has been "
                 + "blocking since.",
                 [("is the zero even up?",
                   "It is, and it has been for 6 days. Its last reboot was the power cut "
                   + "on the 8th.")], now: now),
            past("2026-08-13-1712-9ab4", 400_000, .sonnet,
                 "how much of the nvme is actually the journal",
                 "2.1G of 916G. It is the largest single thing in /var but it is not close "
                 + "to being a problem, and journald will cap it at 4G on its own.",
                 [("what is the biggest directory on this box?",
                   "/var, at 2.6G, and almost all of that is one thing.")], now: now),
            past("2026-08-11-0845-c207", 570_000, .opus,
                 "what would i lose if the sd card died right now?",
                 "Nothing that is not on the NVMe. The card is the fallback boot path and "
                 + "holds no state of its own since the migration.",
                 [("which device am i actually booting off now?",
                   "nvme0n1p2 is root. The card is still in the slot and still bootable, "
                   + "but nothing has read from it since the migration on the 2nd.")],
                 now: now),
        ]

        return [empty, running, queued, answered(now: now), failed] + catalogue + [refused]
    }
}
