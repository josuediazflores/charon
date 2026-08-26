import Foundation

/* The demo Jarvis, ported from `fixture.ts`'s jarvis block.
 *
 * Today, eight days behind it, and six jobs. **The two lanes are the thing being
 * fixtured**, not the transcript: today is mid-stream on the talk lane with a job
 * running and another queued underneath it, which is the one arrangement the
 * whole feature exists to make possible and the one a screen that never had it
 * demoed would quietly get wrong.
 *
 * What is deliberately covered, because a branch the fixture never reaches is a
 * branch nobody has looked at:
 *
 *   - a `partial` with no assistant turn after it, which is the record the runner
 *     leaves half a second into a turn and looks identical to a finished answer
 *     if the view has the bug it is most likely to have;
 *   - `queued`, which on jarvis is a 900ms window rather than a state you can sit
 *     in -- the say route answers busy while a turn is in flight, so the fixture
 *     has to *pass through* it;
 *   - a job running and a job done with a result, in the transcript and in the
 *     jobs list at once, joined by the job id;
 *   - a notice at 50% carrying the compact action, which is the only turn kind
 *     with a button on it;
 *   - a compacted day, whose stale context is what makes the meter draw an em
 *     dash;
 *   - context readings in each of the meter's three bands, including the values
 *     either side of both boundaries, which is where a `>` that should have been
 *     a `>=` lives.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

@MainActor
final class DemoJarvisStore {

    /// Every model in play has the same window, so the fixture states it once.
    /// The field exists on the wire because that stops being true the moment a
    /// model with a different one answers.
    private static let window = 200_000

    /// The collector's three. **Ascending, and the notice rule relies on it** --
    /// it takes the last one still crossed, so a day that jumps from 48% to 91%
    /// in one turn gets the 90 line and not the 50 line it also passed.
    private static let thresholds = [50.0, 75.0, 90.0]

    /// The seed a compacted day starts its next session from -- the digest plus
    /// the prompt, and not much else. Stated rather than measured because the
    /// point being demonstrated is the drop.
    private static let seedTokens = 18_000

    /// What each demo turn adds to the reading. Far more than a real turn costs,
    /// and deliberately: the thresholds are at 50, 75 and 90, the notice is the
    /// one turn kind carrying a button, and a demo needing nine questions to
    /// reach the next crossing is a demo where nobody ever sees one.
    private static let turnTokens = 26_000

    private static let tick: Duration = .milliseconds(220)
    private static let steps = 40
    private static let pickup: Duration = .milliseconds(900)
    /// **Kept longer than the reply stream on purpose**, so a job filed during a
    /// turn is still running when the assistant answers. That overlap is the
    /// feature; a job that finished first would hide it.
    private static let jobPickup: Duration = .milliseconds(1_100)
    private static let jobRun: Duration = .seconds(14)

    /// How far into the answer today arrives. Mid-sentence on purpose: a partial
    /// cut at a paragraph break is indistinguishable from a short finished
    /// answer.
    private static let partialAt = 118

    private var days: [String: JarvisDay] = [:]
    private var jobs: [String: JarvisJob] = [:]
    private let now: Date
    private let today: String
    /// Today arrives mid-stream because that record is the one thing this demo
    /// has to prove. But it cannot *stay* there: the say route refuses while a
    /// turn is in flight and there is only one conversation, so a day left
    /// running for ever is a demo with the input locked shut. The fixture
    /// therefore does what the runner does and finishes the turn -- kicked from
    /// the first read rather than at init, so nothing ticks until the tab is
    /// actually open.
    private var streaming = false

    init(now: Date = Date()) {
        self.now = now
        self.today = DemoJarvisStore.isoDay(now)
        for job in seedJobs() { jobs[job.id] = job }
        for day in seedDays() { days[day.day] = day }
    }

    // MARK: - reads

    func todayRecord() -> JarvisDay? {
        if !streaming {
            streaming = true
            answer(from: DemoJarvisStore.partialAt)
        }
        return days[today]
    }

    /// Newest first, the way the collector's scandir leaves them.
    func daySummaries() -> [JarvisDaySummary] {
        days.values.map(DemoJarvisStore.summary).sorted { $0.day > $1.day }
    }

    /// One day by date, and **nil for a date this demo does not have**.
    ///
    /// Deliberately not the fallback the chat store uses. A thread id is opaque
    /// and nobody types one; a date is reachable from the strip, and the 404 it
    /// produces is the only one in this surface. A fixture that answered every
    /// date with yesterday would be hiding the one read path with a second
    /// outcome.
    func day(_ id: String) -> JarvisDay? { days[id] }

    /// Newest first, capped the way the collector caps it.
    func jobList() -> [JarvisJob] {
        Array(jobs.values.sorted { $0.createdAt > $1.createdAt }.prefix(50))
    }

    // MARK: - writes

    /// `busy` is the same refusal the collector makes and the reason the fixture
    /// keeps it: it is the response the view has a whole state for. The 900ms
    /// before the runner picks the turn up is `queued`, which on this surface is
    /// a window you pass through rather than one you can sit in -- so it is the
    /// only chance the demo gets to draw it.
    func say(_ text: String) -> WriteResult {
        guard var day = todayRecord() else { return .failed }
        if day.queued || day.status == .running { return .busy }

        let at = Fmt.stampNow()
        day.updatedAt = at
        day.error = nil
        day.queued = true
        day.turns.append(.say(JarvisSayTurn(role: .user, text: text, at: at)))
        days[day.day] = day

        Task { [weak self] in
            try? await Task.sleep(for: DemoJarvisStore.pickup)
            guard let self, var current = self.days[self.today], current.queued else { return }
            current.queued = false
            current.status = .running
            current.partial = ""
            current.updatedAt = Fmt.stampNow()
            self.days[self.today] = current
            self.answer(from: 0)
        }
        return .ok
    }

    /// Abandon the turn in flight. Stopping an idle day is a no-op success, like
    /// the real route. **The context reading is deliberately left alone**: it
    /// comes off the result event and a session that was killed never emitted
    /// one, so the meter not moving is the honest answer rather than an
    /// oversight. Nothing here touches a job.
    func stop() -> WriteResult {
        guard var day = todayRecord() else { return .failed }
        if day.status != .running && !day.queued { return .ok }

        let at = Fmt.stampNow()
        let said = day.partial ?? ""
        day.status = .idle
        day.partial = nil
        day.queued = false
        day.updatedAt = at
        day.turns.append(.say(JarvisSayTurn(
            role: .assistant,
            text: said.isEmpty ? "[stopped]" : "\(said)\n\n[stopped]",
            at: at,
            tools: Array(DemoJarvisStore.answerTools.prefix(2)),
            model: day.model,
            elapsedS: 3.1)))
        days[day.day] = day
        return .ok
    }

    func setModel(_ model: JarvisModelName) -> WriteResult {
        guard var day = todayRecord() else { return .failed }
        if day.queued || day.status == .running { return .busy }
        day.model = model
        days[day.day] = day
        return .ok
    }

    func setEffort(_ effort: JarvisEffort) -> WriteResult {
        guard var day = todayRecord() else { return .failed }
        if day.queued || day.status == .running { return .busy }
        day.effort = effort
        days[day.day] = day
        return .ok
    }

    /// Fold the day. Four writes and one refusal to write, and the last of those
    /// is the feature: a compaction entry goes on, the session id goes to nil,
    /// the context goes stale, and **`turns` is not touched at all**. If this
    /// ever grows a line that drops a turn, the thing it was protecting has been
    /// eaten by the thing protecting it.
    func compact() -> WriteResult {
        guard var day = todayRecord() else { return .failed }
        if day.queued || day.status == .running { return .busy }

        let at = Fmt.stampNow()
        day.claudeSessionId = nil
        day.updatedAt = at
        day.compactions.append(JarvisCompaction(
            at: at,
            // Zero only on a day with no reading at all, which is a day with
            // nothing worth folding -- the console does not offer the button
            // there.
            beforeTokens: day.context?.tokens ?? 0,
            kept: DemoJarvisStore.digest,
            // Every turn is behind the digest now. None of them went anywhere.
            turnsFolded: day.turns.count))
        if var ctx = day.context {
            ctx.stale = true
            day.context = ctx
        }
        days[day.day] = day
        return .ok
    }

    /// Hand work to the other lane.
    ///
    /// **It never returns `busy`**, and the fixture is the place that claim gets
    /// checked: today opens mid-stream, so every job filed from a demo is filed
    /// while the talk lane is answering, and a busy here would be the second lane
    /// having quietly become the first one again.
    func file(text: String, title: String) -> WriteResult {
        let at = Fmt.stampNow()
        let id = DemoJarvisStore.jobId(at, String(format: "%04x", Int.random(in: 0..<0xffff)))
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = JarvisJob(
            id: id,
            // A job with no name is still a job. The prompt's first line stands
            // in, the way an untitled chat thread takes its first message.
            title: named.isEmpty
                ? String(text.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").prefix(80))
                : named,
            text: text, state: .queued, createdAt: at, updatedAt: at)
        jobs[id] = job

        // The card goes into today's transcript the moment the job is filed,
        // because the collector writes it -- not the runner, which has not seen
        // the job yet.
        if var day = todayRecord() {
            day.updatedAt = at
            day.turns.append(.job(DemoJarvisStore.card(job)))
            days[day.day] = day
        }

        // Both timers check the state before writing one. A job stopped in its
        // first second is stopped in the spool, before any runner has it, and a
        // timer that wrote `running` over that would be the demo drawing a cancel
        // that did not take -- which is the one thing a stop button must never be
        // able to do.
        Task { [weak self] in
            try? await Task.sleep(for: DemoJarvisStore.jobPickup)
            guard let self, self.jobs[id]?.state == .queued else { return }
            self.move(id) { $0.state = .running; $0.model = .sonnet }
        }
        Task { [weak self] in
            try? await Task.sleep(for: DemoJarvisStore.jobRun)
            guard let self, self.jobs[id]?.state == .running else { return }
            self.move(id) {
                $0.state = .done
                $0.result = DemoJarvisStore.jobResult
                $0.tools = Array(DemoJarvisStore.answerTools.prefix(2))
                $0.elapsedS = 14.0
            }
        }
        return .ok
    }

    /// Stop one job, by id. A job that has already finished is a success -- the
    /// caller asked for a job that is not running and that is what it has.
    func stopJob(_ id: String) -> WriteResult {
        guard let job = jobs[id] else { return .failed }
        if job.state != .running && job.state != .queued { return .ok }
        // No error, and no result either: cancelled work is not failed work and
        // the card must not be able to draw it as such.
        move(id) { $0.state = .stopped }
        return .ok
    }

    // MARK: - the runners

    /// Move one job and its card together.
    ///
    /// The card in the transcript is the collector's copy and it rewrites it in
    /// place as the record moves. A fixture that moved only the record would
    /// leave a card reading "running" for ever, which is exactly the bug this
    /// surface is most likely to ship with and therefore exactly the one the demo
    /// has to be incapable of hiding.
    private func move(_ id: String, _ patch: (inout JarvisJob) -> Void) {
        guard var job = jobs[id] else { return }
        patch(&job)
        job.updatedAt = Fmt.stampNow()
        jobs[id] = job

        let dayId = String(job.createdAt.prefix(10))
        guard var day = days[dayId] else { return }
        day.turns = day.turns.map { turn in
            if case .job(let card) = turn, card.jobId == id {
                return .job(DemoJarvisStore.card(job))
            }
            return turn
        }
        days[dayId] = day
    }

    /// Stream the rest of one reply into today, a few characters at a time, and
    /// land it as a turn.
    ///
    /// What it does that the chat one does not is write the context reading, and
    /// then the notice if that reading crossed something. Both belong to the far
    /// side of a turn, which is the only place either number can honestly come
    /// from.
    private func answer(from: Int) {
        let reply = Array(DemoJarvisStore.reply)
        let step = Int((Double(reply.count) / Double(DemoJarvisStore.steps)).rounded(.up))

        Task { [weak self] in
            var at = from
            while !Task.isCancelled {
                try? await Task.sleep(for: DemoJarvisStore.tick)
                guard let self, var held = self.days[self.today], held.status == .running
                else { return }

                at += step
                if at < reply.count {
                    held.partial = String(reply.prefix(at))
                    held.updatedAt = Fmt.stampNow()
                    self.days[self.today] = held
                    continue
                }

                let stamp = Fmt.stampNow()
                // A fresh session after a compaction starts from the digest, not
                // from where the old one left off. Reading `stale` for that is
                // not a trick: it is precisely the field that says the count
                // above belongs to a session that no longer exists.
                let base = (held.context.map { $0.stale ? DemoJarvisStore.seedTokens : $0.tokens })
                    ?? DemoJarvisStore.seedTokens
                // Clamped at the window: a real session cannot send more than
                // fits in one, and a meter reading 104% is a fixture bug drawn as
                // a product bug.
                let tokens = Swift.min(DemoJarvisStore.window,
                                       base + DemoJarvisStore.turnTokens)
                let pct = (Double(tokens) / Double(DemoJarvisStore.window) * 100)
                    .rounded(.down)

                held.status = .idle
                held.partial = nil
                held.claudeSessionId = held.claudeSessionId ?? "demo-jarvis-fresh"
                held.updatedAt = stamp
                held.turns.append(.say(JarvisSayTurn(
                    role: .assistant, text: DemoJarvisStore.reply, at: stamp,
                    tools: DemoJarvisStore.answerTools, model: held.model, elapsedS: 8.8)))
                held.context = JarvisContext(tokens: tokens, window: DemoJarvisStore.window,
                                             pct: pct, at: stamp, stale: false)
                if let notice = DemoJarvisStore.notice(held, pct: pct, at: stamp) {
                    held.turns.append(.notice(notice))
                }
                self.days[self.today] = held
                return
            }
        }
    }

    // MARK: - the wire's own fields

    /// The collector's threshold rule, restated: one notice per crossing, and the
    /// state is the largest pct already noticed on this day rather than a flag
    /// kept anywhere. 51, 52 and 53% do not each get a line.
    private static func notice(_ day: JarvisDay, pct: Double,
                               at: String) -> JarvisNoticeTurn? {
        let noticed = day.turns.reduce(0.0) { highest, turn in
            if case .notice(let n) = turn { return Swift.max(highest, n.pct) }
            return highest
        }
        // The last one still crossed, so a day that jumps from 48% to 91% in one
        // turn gets the 90 line and not the 50 line it also passed. Which
        // threshold it was does not reach the sentence -- the reading at the
        // crossing does -- so the rule is an existence test.
        guard thresholds.contains(where: { pct >= $0 && $0 > noticed }) else { return nil }
        return JarvisNoticeTurn(
            notice: "context",
            text: "We're at \(Int(pct))% of my context for today. I can fold what's "
                + "happened so far into a summary and keep going -- say the word.",
            at: at,
            // The reading at the crossing, not the threshold that was crossed.
            // The line is a record of a moment and 78% is what the moment said.
            pct: pct,
            action: "compact")
    }

    /// The newest assistant say turn's first line, the way the collector cuts it.
    /// Job cards and notices are skipped rather than previewed: a row that said
    /// "we're at 78% of my context" as its summary of a day would be quoting the
    /// machinery instead of the day.
    private static func preview(_ day: JarvisDay) -> String {
        for turn in day.turns.reversed() {
            guard case .say(let say) = turn, say.role == .assistant else { continue }
            let line = say.text.split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return String((line.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).prefix(120))
        }
        return ""
    }

    /// One row. The counts are taken off the transcript rather than stated beside
    /// it: a fixture whose header disagrees with its own body teaches nothing
    /// about the view and everything about itself.
    private static func summary(_ day: JarvisDay) -> JarvisDaySummary {
        JarvisDaySummary(
            day: day.day,
            updatedAt: day.updatedAt,
            turnCount: day.turns.count,
            jobCount: day.turns.reduce(0) { n, turn in
                if case .job = turn { return n + 1 }
                return n
            },
            status: day.status,
            queued: day.queued,
            model: day.model,
            // Narrowed to the two numbers a row gets. `stale` is deliberately not
            // among them: a list cannot tell that a reading has been left behind
            // by a compaction, so it must not present these as where the day
            // stands.
            contextTokens: day.context?.tokens,
            contextPct: day.context?.pct,
            preview: preview(day))
    }

    /// The card the collector leaves in the transcript for one job. Built from
    /// the record rather than written twice: keeping the two agreeing is the
    /// collector's actual job here.
    private static func card(_ job: JarvisJob) -> JarvisJobTurn {
        JarvisJobTurn(jobId: job.id, title: job.title,
                      // `created_at`, not "now": a card marks where the work was
                      // handed off, and it does not move when the job finishes.
                      at: job.createdAt, state: job.state)
    }

    // MARK: - clocks

    /// YYYY-MM-DD in local time. Assembled from the parts rather than sliced off
    /// a UTC string, which would name the wrong day every evening.
    private static func isoDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A stamp at a stated clock time on a day `back` ago.
    ///
    /// Not a seconds-ago count: a turn "19 hours ago" lands on a different
    /// calendar day depending on what time the demo is opened, and a day record
    /// whose own turns are stamped outside it is the first thing to mislead
    /// whoever reads this next. History gets clock times because history has
    /// them.
    private func dayStamp(_ back: Int, _ hh: Int, _ mm: Int, _ ss: Int = 0) -> String {
        let at = now.addingTimeInterval(-Double(back) * 86_400)
        return "\(DemoJarvisStore.isoDay(at))T"
            + String(format: "%02d:%02d:%02d", hh, mm, ss)
    }

    /// `secondsAgo` back, but never across midnight into yesterday. Today's
    /// transcript is filed under today's date and rendered as ages, so it wants
    /// relative stamps -- except that a turn 2h 30m old is a turn stamped
    /// yesterday whenever the demo is opened before 02:30. The clamp piles the
    /// older turns up just after midnight instead: wrong by minutes, right about
    /// which day it is, and only the second of those is a lie about the data
    /// model.
    private func todayStamp(_ secondsAgo: Double) -> String {
        let midnight = Calendar.current.startOfDay(for: now)
        return Fmt.stampNow(Swift.max(midnight, now.addingTimeInterval(-secondsAgo)))
    }

    private func dayBefore(_ back: Int) -> String {
        DemoJarvisStore.isoDay(now.addingTimeInterval(-Double(back) * 86_400))
    }

    /// A job id from the stamp it was minted at. Derived rather than written out
    /// beside the record, because the id *is* the minting time and a fixture
    /// whose id disagreed with its own created_at would teach the next reader
    /// that it does not have to mean anything.
    private static func jobId(_ at: String, _ hex: String) -> String {
        let c = Array(at)
        guard c.count >= 16 else { return "\(at)-\(hex)" }
        return "\(String(c[0..<10]))-\(String(c[11..<13]))\(String(c[14..<16]))-\(hex)"
    }

    // MARK: - the fixture

    private static let reply =
        "It is back. The socket on 10.0.0.4 accepted a connection 40 seconds ago "
        + "and the monitor has taken four frames since.\n\n"
        + "What happened is the same thing as the other three times: the camera let "
        + "its DHCP lease expire at 09:51 and took a new address instead of renewing "
        + "the one it had, and nothing on this Pi noticed because the monitor kept "
        + "polling on its ten-second interval the whole way through. That is why the "
        + "source read \"3s ago\" over a two-hour outage.\n\n"
        + "A reservation on the router fixes it for good. I have not touched anything."

    private static let answerTools = [
        "Bash(nc -z -w2 10.0.0.4 554)",
        "Bash(journalctl -u camera-monitor -n 60 --no-pager)",
        "Read(/var/lib/halftone/camera.json)",
    ]

    private static let digest =
        "A digest of the day so far: the mail poller has been failing on "
        + "AUTHENTICATE since 03:12 and wants a new app password; the camera drops "
        + "off daily between 09:40 and 10:10 because it takes a new DHCP lease "
        + "rather than renewing; a nine-day journal trawl is done and a blocklist "
        + "diff is still running. Nothing on the Pi has been changed."

    private static let jobResult =
        "Done. 412 lines of output, of which the part worth reading is that nothing "
        + "in it disagrees with what the panel was already showing."

    private func seedJobs() -> [JarvisJob] {
        var out: [JarvisJob] = []

        let trawlAt = todayStamp(8_400)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(trawlAt, "a1f2"),
            title: "trawl the journal since the reboot",
            text: "go back through the whole journal since the last boot and find every "
                + "unit that failed more than once, with the times",
            state: .done, createdAt: trawlAt, updatedAt: todayStamp(8_185),
            result: "41,208 journal lines across 9 days.\n\n"
                + "Four camera outages: 09:44, 09:51, 09:47 and 09:51 on the 9th, 12th, "
                + "15th and today. Each ran between 2h 10m and 2h 22m and each ended "
                + "without anything being restarted.\n\n"
                + "Nothing else repeats. The mail poller failures are continuous rather "
                + "than periodic and start at one point, 03:12 today.",
            tools: [
                "Bash(journalctl --since -9d --no-pager | wc -l)",
                "Bash(journalctl --since -9d -p warning --no-pager)",
                "Bash(journalctl -u camera-monitor --since -9d --no-pager)",
            ],
            model: .opus,
            // Three and a half minutes. **The number the feature is about**: a
            // turn this long under the talk lane's lock is what made the
            // assistant unanswerable.
            elapsedS: 214.7))

        let diffAt = todayStamp(1_200)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(diffAt, "4ab8"),
            title: "diff the pihole blocklists against last week",
            text: "compare the current pihole blocklists against the copy from last "
                + "sunday and tell me what was added or dropped",
            state: .running, createdAt: diffAt, updatedAt: todayStamp(1_140),
            model: .sonnet))

        // Filed and not picked up, while a turn is in flight on purpose -- the job
        // route never answers busy and this is the fixture saying so.
        let indexAt = todayStamp(40)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(indexAt, "e07f"),
            title: "rebuild the search index over the briefings",
            text: "rebuild the search index over every briefing in cmo/briefings",
            state: .queued, createdAt: indexAt, updatedAt: indexAt))

        let pdfAt = dayStamp(1, 11, 40)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(pdfAt, "6d90"),
            title: "render every briefing to pdf",
            text: "render every briefing in cmo/briefings to pdf and put them in ~/out",
            state: .error, createdAt: pdfAt, updatedAt: dayStamp(1, 11, 55),
            error: "pandoc: command not found", model: .sonnet, elapsedS: 14.9))

        // Stopped, and **not an error**. Cancelled work did what you asked; the
        // card says so in a word and the frame stays quiet.
        let walkAt = dayStamp(2, 10, 26)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(walkAt, "b3c4"),
            title: "walk every repo and summarise what changed",
            text: "walk every repo under ~/Projects and summarise what changed this week",
            state: .stopped, createdAt: walkAt, updatedAt: dayStamp(2, 10, 31),
            model: .opus, elapsedS: 5.2))

        let auditAt = dayStamp(8, 9, 5)
        out.append(JarvisJob(
            id: DemoJarvisStore.jobId(auditAt, "0f18"),
            title: "audit the systemd timers",
            text: "list every timer on this box, what it runs, and when it last succeeded",
            state: .done, createdAt: auditAt, updatedAt: dayStamp(8, 9, 8),
            result: "Eleven timers. Nine have succeeded in the last 24 hours.\n\n"
                + "The two that have not are logrotate, which is weekly and ran on "
                + "Sunday, and restic-backup, whose last run is 03:00 this morning and "
                + "took 41s.",
            model: .sonnet, elapsedS: 38.4))

        return out
    }

    private func job(_ hexSuffix: String) -> JarvisJob? {
        jobs.values.first { $0.id.hasSuffix(hexSuffix) }
    }

    private func cardFor(_ hexSuffix: String) -> JarvisTurn? {
        job(hexSuffix).map { .job(DemoJarvisStore.card($0)) }
    }

    private func seedDays() -> [JarvisDay] {
        [todaySeed(), compacted(), quiet()] + pastDays()
    }

    /// Today. Read the shape of it rather than the words: two answered exchanges,
    /// a job card between them, the 50% notice the collector wrote when the second
    /// answer came back at 52%, a running job, a queued job, and then a question
    /// with no answer under it and a `partial` half way through one. Every one of
    /// those is a different thing to draw and the day is the only place they
    /// appear together.
    private func todaySeed() -> JarvisDay {
        var turns: [JarvisTurn] = [
            .say(JarvisSayTurn(role: .user, text: "morning. anything overnight?",
                               at: todayStamp(9_060))),
            .say(JarvisSayTurn(
                role: .assistant,
                text: "Two things, and only one of them wants you.\n\n"
                    + "The mail poller has been failing since 03:12 -- every fire since "
                    + "has exited 1 on AUTHENTICATE failed, which is an app password that "
                    + "has been revoked rather than anything on this Pi.\n\n"
                    + "The other is the camera: 10.0.0.4 refused a connection at 09:51 "
                    + "and the newest frame is 2h 19m old. Nothing else moved. Backups "
                    + "ran, the collector has been up 4 days, and the Zero is answering "
                    + "DNS.",
                at: todayStamp(9_002),
                tools: [
                    "Bash(systemctl list-timers --no-pager)",
                    "Bash(journalctl -u charon-mail-poll -n 60 --no-pager)",
                    "Read(/var/lib/halftone/state.json)",
                ],
                model: .sonnet, elapsedS: 18.2)),
        ]
        if let trawl = cardFor("a1f2") { turns.append(trawl) }
        turns.append(contentsOf: [
            .say(JarvisSayTurn(role: .user, text: "what did the trawl find?",
                               at: todayStamp(6_100))),
            .say(JarvisSayTurn(
                role: .assistant,
                text: "The camera has dropped off four times in nine days, always between "
                    + "09:40 and 10:10, and always for a bit over two hours.\n\n"
                    + "That window is the router's DHCP lease expiring, and the camera "
                    + "takes a new address rather than renewing the one it has. The fix is "
                    + "a reservation on 10.0.0.4, not anything on the monitor.",
                at: todayStamp(6_060),
                tools: ["Read(/home/pi/jarvis/jobs/trawl.json)"],
                model: .sonnet, elapsedS: 9.4)),
            // The collector's wording, verbatim, in the assistant's voice and with
            // the number in it. Never generated.
            .notice(JarvisNoticeTurn(
                notice: "context",
                text: "We're at 52% of my context for today. I can fold what's happened "
                    + "so far into a summary and keep going -- say the word.",
                at: todayStamp(6_059), pct: 52, action: "compact")),
        ])
        if let diff = cardFor("4ab8") { turns.append(diff) }
        if let index = cardFor("e07f") { turns.append(index) }
        turns.append(.say(JarvisSayTurn(role: .user, text: "is the camera back?",
                                        at: todayStamp(12))))

        var day = JarvisDay(
            day: today,
            createdAt: todayStamp(9_060), updatedAt: todayStamp(2),
            model: .sonnet, status: .running,
            claudeSessionId: "demo-jarvis-today",
            turns: turns,
            context: JarvisContext(
                tokens: 104_411, window: DemoJarvisStore.window, pct: 52,
                // The second answer's reading, and nothing since: the turn in
                // flight has not emitted a result event yet, and job turns never
                // touch this.
                at: todayStamp(6_060), stale: false),
            compactions: [],
            // False, and it cannot be otherwise beside a partial.
            queued: false)
        // Today's `partial` is a prefix of the canned answer rather than its own
        // text, which is what lets the first read pick the turn up where it was
        // left and finish it.
        day.partial = String(DemoJarvisStore.reply.prefix(DemoJarvisStore.partialAt))
        return day
    }

    /* Yesterday, folded twice.
       The day the whole compaction model has to be looked at on, and the reason
       it is yesterday and not today: `stale` makes the meter draw an em dash, and
       today has to keep a number in it for the live meter to be worth anything.

       Three things here are only true together:
       - the context reading is 20:44 and the newest compaction is 21:12. **That
         is what stale means, read off two stamps**: the reading describes a
         session that was thrown away after it was taken.
       - the session id is nil, cleared by that compaction and never rewritten
         because no turn ran afterwards.
       - `turns` is untouched and holds all seventeen of them, both notices
         included. The digests are in `compactions`, the transcript is whole, and
         the two have stopped being the same object.

       The 90% notice lands *after* the first fold, which looks wrong for a second
       and is not: thresholds are tracked per day against the highest pct already
       noticed, not per session. */
    private func compacted() -> JarvisDay {
        func said(_ hh: Int, _ mm: Int, _ text: String) -> JarvisTurn {
            .say(JarvisSayTurn(role: .user, text: text, at: dayStamp(1, hh, mm)))
        }
        func answer(_ hh: Int, _ mm: Int, _ ss: Int, _ elapsed: Double,
                    _ text: String) -> JarvisTurn {
            .say(JarvisSayTurn(role: .assistant, text: text, at: dayStamp(1, hh, mm, ss),
                               model: .opus, elapsedS: elapsed))
        }

        var turns: [JarvisTurn] = [
            said(7, 4, "i want to understand what the collector actually does between polls"),
            answer(7, 4, 41, 21.7,
                   "Nothing, and that is the design. Each source has its own interval and "
                   + "its own next-attempt clock; between them the process is asleep in a "
                   + "select with no work queued."),
            said(9, 18, "so why is it 40MB resident?"),
            answer(9, 18, 44, 16.2,
                   "Because it holds the last payload and the last frame in memory so a "
                   + "reader never waits on disk. Neither grows: they are replaced, not "
                   + "appended to."),
            .notice(JarvisNoticeTurn(
                notice: "context",
                text: "We're at 78% of my context for today. I can fold what's happened "
                    + "so far into a summary and keep going -- say the word.",
                at: dayStamp(1, 9, 18, 45), pct: 78, action: "compact")),
            said(10, 2, "can two readers hit it at once?"),
            answer(10, 2, 52, 12.8,
                   "They can, and they get the same object. The payload is built on the "
                   + "poll rather than on the request, which is also why an unreachable "
                   + "source cannot slow a reader down."),
        ]
        if let pdf = cardFor("6d90") { turns.append(pdf) }
        turns.append(contentsOf: [
            said(12, 55, "what would it take to add a source?"),
            answer(12, 55, 38, 19.4,
                   "A fetcher, an entry in the config, and a type in the model before "
                   + "either. The envelope is the same for all of them, so nothing in the "
                   + "console has to learn a new shape."),
            said(15, 20, "is dormant really worth its own status?"),
            answer(15, 20, 29, 14.1,
                   "It is the one that stops the dashboard crying wolf. A source you never "
                   + "configured is not a source in trouble, and without a word for that "
                   + "it gets drawn red beside the ones that are."),
            said(18, 7, "and stale_reason?"),
            answer(18, 7, 41, 11.6,
                   "That one exists because polling a dead camera every ten seconds keeps "
                   + "the fetch age at 3 forever. The age is our copy; the reason is the "
                   + "outage."),
            .notice(JarvisNoticeTurn(
                notice: "context",
                text: "We're at 90% of my context for today. I can fold what's happened "
                    + "so far into a summary and keep going -- say the word.",
                at: dayStamp(1, 18, 7, 42), pct: 90, action: "compact")),
            said(20, 44, "last one: why is health.ts the file that matters most?"),
            answer(20, 44, 36, 18.9,
                   "Because every visual decision in the console is downstream of it. "
                   + "Panel tone, lamp, pill, footer note, whether values dim, whether a "
                   + "delta is allowed — all one function, so none of them can disagree."),
        ])

        return JarvisDay(
            day: dayBefore(1),
            createdAt: dayStamp(1, 7, 4), updatedAt: dayStamp(1, 21, 12),
            model: .opus, status: .idle,
            claudeSessionId: nil,
            turns: turns,
            context: JarvisContext(
                tokens: 182_411, window: DemoJarvisStore.window, pct: 91,
                at: dayStamp(1, 20, 44, 36),
                // Nothing has run since 21:12's fold. **The console draws an em
                // dash**, not 91%.
                stale: true),
            compactions: [
                JarvisCompaction(
                    at: dayStamp(1, 13, 26), beforeTokens: 152_411,
                    kept: "A digest of the morning: the collector sleeps between polls, "
                        + "holds one payload and one frame resident, serves every reader "
                        + "the same object, and takes a new source as a fetcher plus a "
                        + "config entry plus a type. A pdf render job failed on a missing "
                        + "pandoc.",
                    turnsFolded: 10),
                JarvisCompaction(
                    at: dayStamp(1, 21, 12), beforeTokens: 182_411,
                    kept: "A digest of the day: as above, plus why dormant is its own "
                        + "status (a source you never configured is not in trouble), why "
                        + "stale_reason is separate from fetch age (the age is our copy, "
                        + "the reason is the outage), and that every visual decision comes "
                        + "out of the health rules.",
                    turnsFolded: 17),
            ])
    }

    /// A day nobody said anything on.
    ///
    /// One job handed off and no conversation, so context is nil and the preview
    /// comes out empty. **Nil context is the branch the console must draw as an em
    /// dash and must never draw as 0%** -- an unmeasured window is not an empty
    /// one -- and there is no other way to reach it from a fixture: every other
    /// day here has answered something.
    private func quiet() -> JarvisDay {
        JarvisDay(
            day: dayBefore(8),
            createdAt: dayStamp(8, 9, 5), updatedAt: dayStamp(8, 9, 8),
            model: .sonnet, status: .idle,
            turns: cardFor("0f18").map { [$0] } ?? [],
            context: nil)
    }

    /// The back catalogue, and the readings are chosen rather than invented: 83
    /// and 76 are over the second boundary, 61 sits in the middle band with
    /// today's 52, and 49, 34 and 12 are under the first. **49 and 76 are there
    /// for the boundaries themselves** -- one point either side is where a
    /// comparison written the wrong way round shows up, and it never shows up on
    /// 34.
    private func pastDays() -> [JarvisDay] {
        [
            pastDay(2, .opus, 83, [
                ("is the fan curve doing anything or is it just on?",
                 "It is doing something. The shim is on the 55°C step and has switched "
                 + "about twice an hour today; at idle the SoC sits at 47°C and the fan "
                 + "is off."),
                ("can i make it quieter at night?",
                 "Raise the on-threshold to 60°C between 22:00 and 07:00 and the SoC is "
                 + "still 20°C under anything that throttles. It will run hotter and it "
                 + "will not run slower."),
                ("what actually throttles it?",
                 "80°C soft, 85°C hard. get_throttled has read 0x0 every morning since "
                 + "the NVMe move, so neither has happened."),
            ], cards: [cardFor("b3c4")].compactMap { $0 }),
            pastDay(3, .sonnet, 34, [
                ("did anything reboot last night?",
                 "Nothing did. Uptime is 11 days and there is no boot record in the "
                 + "journal since the 6th."),
                ("then why did the dashboard go blank at 04:12?",
                 "Because the tab was asleep, not because the Pi was. The collector "
                 + "logged an uninterrupted poll every ten seconds straight through "
                 + "04:12."),
            ]),
            pastDay(4, .sonnet, 61, [
                ("how big is the halftone state dir getting?",
                 "312M, and 280M of that is camera frames. It grows about 40M a day and "
                 + "nothing prunes it."),
                ("what should prune it?",
                 "A timer running find -mtime +7 -delete over the frames directory. "
                 + "Seven days back is 40M, so the steady state is about an eighth of "
                 + "what you have now."),
                ("is anything reading frames older than a day?",
                 "No. The console asks for the newest frame and nothing else ever opens "
                 + "that directory."),
            ]),
            pastDay(5, .opus, 12, [
                ("what is the tailscale exit node set to?",
                 "None. The Pi advertises the 10.0.0.0/24 subnet route and takes no exit "
                 + "node, so nothing on the tailnet routes through here."),
            ]),
            pastDay(6, .sonnet, 76, [
                ("why is the commits panel showing repos_deferred?",
                 "Because the token was down to 140 calls and the collector stopped at "
                 + "40 repos rather than spend the rest. It is a floor on what you can "
                 + "see, not a failure, and the panel says so."),
                ("when does that reset?",
                 "On the hour, every hour. The remaining count is in the payload and the "
                 + "panel already draws it."),
            ]),
            pastDay(7, .sonnet, 49, [
                ("is the zero doing anything besides dns?",
                 "No. Pi-hole and nothing else, and its load average has not been over "
                 + "0.2 in a week."),
                ("could it run the camera monitor instead?",
                 "It could not. The monitor decodes an RTSP stream and the Zero is a "
                 + "single-core ARMv6 that would drop most of the frames. Leave it where "
                 + "it is."),
            ]),
        ]
    }

    /// One finished day. `pct` is stated and the token count is multiplied back
    /// out of it, which is backwards from the collector -- it floors the
    /// percentage out of the tokens. Backwards is right here: **the band is the
    /// thing under test**, and choosing a token count and hoping it lands where
    /// you meant is how a fixture ends up never crossing the boundary it was
    /// written for.
    ///
    /// Cards go in after the first exchange, which is where a job actually gets
    /// filed: you ask something, then hand off the part that will take a while.
    private func pastDay(_ back: Int, _ model: JarvisModelName, _ pct: Double,
                         _ exchanges: [(String, String)],
                         cards: [JarvisTurn] = []) -> JarvisDay {
        var turns: [JarvisTurn] = []
        for (i, exchange) in exchanges.enumerated() {
            let hh = 7 + i * 3
            turns.append(.say(JarvisSayTurn(role: .user, text: exchange.0,
                                            at: dayStamp(back, hh, 12))))
            turns.append(.say(JarvisSayTurn(
                role: .assistant, text: exchange.1, at: dayStamp(back, hh, 12, 31),
                model: model, elapsedS: 7.4 + Double(i) * 3.2)))
            if i == 0 { turns.append(contentsOf: cards) }
        }
        let last = dayStamp(back, 7 + (exchanges.count - 1) * 3, 12, 31)

        return JarvisDay(
            day: dayBefore(back),
            createdAt: dayStamp(back, 7, 12), updatedAt: last,
            model: model, status: .idle,
            claudeSessionId: "demo-jarvis-\(dayBefore(back))",
            turns: turns,
            context: JarvisContext(
                // The 411 is there so no reading in this fixture is a round
                // number. Round numbers read as placeholders and stop being
                // checked.
                tokens: Int((pct / 100 * Double(DemoJarvisStore.window)).rounded()) + 411,
                window: DemoJarvisStore.window, pct: pct, at: last, stale: false))
    }
}
