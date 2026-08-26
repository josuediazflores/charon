import Foundation

/* The CMO, for demo mode -- ported from the web console's demo fixture.
 *
 * Fixtured at the payload boundary like every other source, with one exception
 * that is forced rather than chosen: the briefing, the dossiers and the docs do
 * not travel in the telemetry document. They live behind their own text routes,
 * so demo mode has to answer for them separately or the reader is the only view
 * in this console that cannot be looked at without a Pi.
 *
 * The `stale` variant is the one worth building carefully: its heartbeat is
 * today's and failed, and its agent result is yesterday's success. That is what
 * puts "showing briefing from <date>" on screen, and a fixture is the only way
 * to look at it without breaking the real token.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

enum DemoCmo {

    // MARK: - clocks

    /// YYYY-MM-DD in local time, assembled from the parts. Slicing an ISO
    /// string is UTC and would name tomorrow every evening.
    static func isoDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local ISO seconds, the way the collector stamps a dismissal. Not the UTC
    /// `Z` form: nothing renders these fields, but a fixture that states the
    /// wrong shape is a trap for whoever writes the next reader of it.
    static func stamp(_ secondsAgo: Double, now: Date) -> String {
        Fmt.stampNow(now.addingTimeInterval(-secondsAgo))
    }

    private static func day(_ back: Int, now: Date) -> String {
        isoDay(now.addingTimeInterval(-Double(back) * 86_400))
    }

    /// `day` minus n calendar days, in the same local-parts form as `isoDay`.
    private static func dayBefore(_ dayString: String, _ n: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let at = f.date(from: dayString) else { return dayString }
        return isoDay(at.addingTimeInterval(-Double(n) * 86_400))
    }

    // MARK: - the fortnight

    /// Fourteen days ending today, most of them empty. The collector zero-fills
    /// the quiet days rather than omitting them, so the fixture states the
    /// zeros too -- a strip built only from the days that had items draws a
    /// flat line over a dead fortnight.
    private static let dailyCounts = [0, 0, 3, 0, 1, 0, 0, 5, 2, 0, 0, 4, 0, 17]

    private static func itemsDaily(now: Date) -> [CmoDay] {
        dailyCounts.enumerated().map { i, count in
            CmoDay(date: day(dailyCounts.count - 1 - i, now: now), count: count)
        }
    }

    /// Newest first, like the collector's scandir.
    private static func briefings(now: Date) -> [String] {
        [0, 1, 2].map { day($0, now: now) }
    }

    // MARK: - one run

    /// The agent's own account of one run. Parameterised by day because the
    /// whole point of the failed variant is that the result belongs to another.
    private static func agentResult(_ d: String) -> CmoAgentResult {
        CmoAgentResult(
            newItems: 17,
            briefing: "briefings/\(d).md",
            leadsUpdated: 2,
            summary: "briefing written",
            // `added` mixes days on purpose: it is the column the sort demo
            // needs, and the two backdated rows are resurfaced-with-changes
            // items whose first_seen predates the run.
            items: [
                CmoItem(pri: 1, lane: "demand",
                        title: "NGU dining posts an RFP for delivery pilots", added: d),
                CmoItem(pri: 1, lane: "ads",
                        title: "Campus DOOH rates up 12% for the fall buy",
                        added: dayBefore(d, 2)),
                CmoItem(pri: 2, lane: "ads",
                        title: "Curbot wraps signed with a regional QSR chain", added: d),
                CmoItem(pri: 2, lane: "demand",
                        title: "Two dorm councils asking about late-night runs",
                        added: dayBefore(d, 1)),
                CmoItem(pri: 3, lane: "market",
                        title: "Trundleworks adds four campuses, none in our region", added: d),
                CmoItem(pri: 3, lane: "market",
                        title: "Portway Labs renews three campus dining contracts", added: d),
            ],
            pipeline: CmoPipeline(new: 0, drafted: 2, contacted: 0, dead: 0),
            drafts: [
                CmoDraft(title: "Reddit reply · r/example late-night food thread",
                         target: "operator"),
                CmoDraft(title: "Sponsor deck cover note", target: "sam review"),
                CmoDraft(title: "X post · fall pilot recap", target: "corin review"),
                CmoDraft(title: "Dining services follow-up email", target: "operator"),
            ],
            memory: CmoMemory(seen: 17, leads: 2, dedupedToday: 0, compacted: nil),
            // `market` is here at zero on purpose: the lane line filters empty
            // buckets and this is the row that proves it.
            lanes: [
                CmoLane(lane: "ads", ready: 3),
                CmoLane(lane: "demand", ready: 2),
                CmoLane(lane: "market", ready: 0),
            ],
            // Two entries with nothing to report, which is the ordinary state
            // of a watchlist -- quiet is not a gap to be filled, and both
            // fields go null together.
            watchlist: [
                CmoWatch(name: "curbot", event: "raised $15M Series B", when: "2026-08-14"),
                CmoWatch(name: "trundleworks", event: "four new campuses", when: "2026-08-11"),
                CmoWatch(name: "ferrybot", event: nil, when: nil),
                CmoWatch(name: "portway campus", event: "renewed three dining contracts",
                         when: "2026-07-29"),
                CmoWatch(name: "curbside labs", event: nil, when: nil),
            ])
    }

    // MARK: - curation

    /// What the user has waved off. Newest first, like the collector's own
    /// tail. One entry per case worth looking at: a draft, whose title is the
    /// briefing's own `### A.` heading with the letter stripped; an item from
    /// today, which is what makes the dimmed row visible in mode 1; and one
    /// from yesterday, which is the row `stale` demotes, since that variant's
    /// items belong to the previous run.
    private static func dismissed(now: Date) -> [CmoDismissed] {
        [
            CmoDismissed(kind: .draft,
                         title: "Reddit reply · r/example late-night food thread",
                         lane: nil, date: day(0, now: now),
                         dismissedAt: stamp(3_600, now: now)),
            CmoDismissed(kind: .item,
                         title: "Portway Labs renews three campus dining contracts",
                         lane: "market", date: day(0, now: now),
                         dismissedAt: stamp(5_400, now: now)),
            CmoDismissed(kind: .item,
                         title: "Two dorm councils asking about late-night runs",
                         lane: "demand", date: day(1, now: now),
                         dismissedAt: stamp(90_000, now: now)),
        ]
    }

    /// The operator's reference documents, sorted by slug the way the collector sorts
    /// them. Every row is unseen on a fresh install, so the ● shows without the
    /// fixture having to state a read-state it does not own.
    private static func docs(now: Date) -> [CmoDoc] {
        [
            CmoDoc(slug: "brand-voice", updated: stamp(86_400 * 9, now: now)),
            CmoDoc(slug: "overview", updated: stamp(1_800, now: now)),
            CmoDoc(slug: "sidewalk-ad-market", updated: stamp(86_400 * 2, now: now)),
        ]
    }

    // MARK: - ask the cmo
    //
    // Three threads, one per state the page has to draw: one still thinking,
    // one answered with its receipts, and one from before the last morning run,
    // which is the only way to look at the stale label without waiting a day.
    //
    // Each is a whole record rather than a summary with a canned body behind
    // it: a thinking thread whose fetch returned an answer would be a fixture
    // that contradicts itself, and the contradiction would look exactly like
    // the bug this page is most likely to have.

    static let answeredId = "2026-08-16-0913-4c1f"
    static let thinkingId = "2026-08-16-0902-7ab3"
    static let oldId = "2026-08-14-1642-9d02"

    /// The answered thread, whole. Two paragraphs of plain prose, which is the
    /// shape the system prompt actually asks for, and the receipts line the
    /// runner strips off the end into `reads`.
    static func answered(now: Date) -> CmoAskThread {
        CmoAskThread(
            id: answeredId,
            created: stamp(5_141, now: now),
            updated: stamp(5_100, now: now),
            sessionId: "demo-session",
            status: .idle,
            turns: [
                CmoAskTurn(role: .q,
                           text: "why did nettlefizz rank first over the incumbent exit?",
                           at: stamp(5_141, now: now)),
                CmoAskTurn(
                    role: .a,
                    text: """
                        The exit is bigger news, but news is not a deadline. Nettlefizz's \
                        ambassador budget is committed for a Sept to Dec window, which \
                        closes around move-in on Sept 14. Four weeks of usefulness. The \
                        exit story stays potent for months and feeds the fundraise \
                        narrative rather than a sale.

                        Ranking logic came from the briefing's clock section and the \
                        leads file: Nettlefizz is status **drafted** with a live route; \
                        the exit is a market item with no counterparty to act on. Priority \
                        means "act today," and only one of the two can be acted on today.
                        """,
                    at: stamp(5_100, now: now),
                    reads: ["briefings/\(day(1, now: now)).md", "memory/leads.md",
                            "memory/seen-items.jsonl"],
                    durationS: 41),
            ])
    }

    /// Asked, queued, and not answered yet. One turn and no session id, which
    /// is exactly what the collector writes and the runner has not touched.
    static func thinking(now: Date) -> CmoAskThread {
        CmoAskThread(
            id: thinkingId,
            created: stamp(40, now: now),
            updated: stamp(40, now: now),
            sessionId: nil,
            status: .thinking,
            turns: [
                CmoAskTurn(role: .q, text: "what should sam lock before monday?",
                           at: stamp(40, now: now)),
            ])
    }

    /// Answered two days ago, so a morning run has happened since. This is the
    /// one the stale label is for: the answer is still true about what it read,
    /// and what it read is not what the CMO knows now.
    static func old(now: Date) -> CmoAskThread {
        CmoAskThread(
            id: oldId,
            created: stamp(86_400 * 2 + 300, now: now),
            updated: stamp(86_400 * 2, now: now),
            sessionId: "demo-session-old",
            status: .idle,
            turns: [
                CmoAskTurn(
                    role: .q,
                    text: "pricing anchor sanity check — is $899/mo defensible on one campus?",
                    at: stamp(86_400 * 2 + 300, now: now)),
                CmoAskTurn(
                    role: .a,
                    text: """
                        Not as a list price on day one. Curbot's $899/mo/bot is the \
                        anchor to quote, not the number to charge: they are out of stock \
                        at it, which makes it a ceiling nobody is currently paying.

                        - **Open at $499/mo** for the first three advertisers and call it \
                        a pilot rate, in writing, with the renewal at list.
                        - The comparable that actually moves an NGU buyer is a \
                        pouring-rights style deal, not a screen-network CPM.

                        The market doc has the CPM maths; it does not have a signed \
                        campus rate card, and until one exists every number here is a \
                        proposal.
                        """,
                    at: stamp(86_400 * 2, now: now),
                    reads: ["docs/sidewalk-ad-market.md", "docs/ad-revenue-research.md"],
                    durationS: 63),
            ])
    }

    static func threads(now: Date) -> [CmoAskThread] {
        [answered(now: now), thinking(now: now), old(now: now)]
    }

    static func askSummaries(now: Date) -> [CmoAskThreadSummary] {
        [thinking(now: now), answered(now: now), old(now: now)].map { t in
            CmoAskThreadSummary(
                id: t.id,
                firstQ: String((t.turns.first?.text ?? "").prefix(80)),
                turns: t.turns.count,
                updated: t.updated,
                status: t.status)
        }
    }

    /// What the fixture answers with, once its timer has run. Short next to the
    /// real twenty to sixty seconds, because a demo is watched rather than
    /// left, and long enough that the thinking state is genuinely on screen.
    static let answerDelay: Duration = .seconds(6)

    static let answer = """
        Short version: nothing here is blocked on them. The two things only Sam can \
        close are the dining-services reply and the sponsor deck cover note, and both \
        are drafted and waiting on a signature rather than on a decision.

        - **RFP response** — due `2026-09-05`, so Monday is not the deadline, but the \
        dining contact goes quiet after move-in week.
        - **Sponsor deck** — the cover note is drafted and marked "sam review" in the \
        drafts panel.

        Everything else in this week's briefings is mine or Corin's.
        """

    // MARK: - the source body

    static func ok(now: Date) -> CmoData {
        let today = day(0, now: now)
        return CmoData(
            heartbeat: CmoHeartbeat(
                source: "cmo", schemaVersion: 1, status: .ok,
                detail: "briefing written",
                runDate: today,
                startedAt: stamp(22_029, now: now),
                finishedAt: stamp(21_600, now: now),
                durationSec: 429, attempt: 1, newItems: 17,
                briefing: "briefings/\(today).md", commit: nil,
                nextRun: stamp(-64_800, now: now)),
            agent: agentResult(today),
            agentDate: today,
            itemsDaily: itemsDaily(now: now),
            briefings: briefings(now: now),
            dismissed: dismissed(now: now),
            // Two with dossiers, the rest without: the watchlist demos both the
            // linked and the plain company name.
            dossiers: ["curbot", "trundleworks"],
            docs: docs(now: now),
            ask: askSummaries(now: now))
    }

    static func failedRun(now: Date) -> CmoData {
        let today = day(0, now: now)
        let yesterday = day(1, now: now)
        return CmoData(
            heartbeat: CmoHeartbeat(
                source: "cmo", schemaVersion: 1, status: .authExpired,
                detail: "claude auth failed, re-run claude setup-token and update secrets/env",
                runDate: today,
                startedAt: stamp(21_600, now: now),
                finishedAt: stamp(21_540, now: now),
                durationSec: 60, attempt: 1, newItems: nil,
                briefing: nil, commit: nil,
                nextRun: stamp(-64_800, now: now)),
            agent: agentResult(yesterday),
            agentDate: yesterday,
            itemsDaily: itemsDaily(now: now),
            // No briefing was written today, so today is not on the list. The
            // tab falls back to the agent result's own date for the link it
            // offers first.
            briefings: Array(briefings(now: now).dropFirst()),
            // The same file either way: a failed run does not un-dismiss
            // anything.
            dismissed: dismissed(now: now),
            dossiers: ["curbot", "trundleworks"],
            // Written by hand, not by the run, so a run that died has no
            // bearing on which of them are on disk.
            docs: docs(now: now),
            // Unchanged for the same reason, and worth stating: a failed
            // morning run is exactly when the stale label on an older thread
            // earns its place.
            ask: askSummaries(now: now))
    }

    // MARK: - the documents behind their own routes

    /// One demo dossier, served for any slug: what a demo has to prove is the
    /// rendering, and there is one interesting document to render.
    static func dossier(now: Date) -> String {
        """
        # Curbot / Curbside Labs — dossier

        updated \(isoDay(now)) · sources verified at research time

        ## what they do

        Sidewalk delivery robots for campuses, rebranded to Curbside Labs and
        repositioned toward logistics, advertising, and smart-city deployments.

        ## funding and valuation

        - $80M+ raised to date, per company statements — [source](https://example.com)

        ## product-market fit signals

        - 500+ robots across 40+ US locations, per the rebrand announcement (2026) —
          [source](https://example.com)

        ## sources

        - [example.com](https://example.com)
        """
    }

    /// One demo document, served for any slug, for the dossier's reason. Short
    /// on purpose -- the reader is the same view either way, and what this has
    /// to prove is the breadcrumb, the raw link and the missing copy, not the
    /// markdown renderer a briefing already exercises end to end.
    static func doc(now: Date) -> String {
        """
        # ferryline — overview

        updated \(isoDay(now))

        Ground truth for the CMO. If a briefing and this file disagree, this file wins.

        ## what ferryline is

        Sidewalk delivery on the NGU campus, run by students, priced under the apps.
        One bot fleet, one campus, no franchise story yet.

        ## who it serves

        - students who want Kestrel Commons food in a dorm without a $9 delivery fee
        - campus advertisers who want a moving surface in front of 9,000 people

        ## what it is not

        - not a restaurant marketplace
        - not a national logistics play, whatever the deck says next quarter
        """
    }

    /* The briefing itself.
       Written to the shape the CMO prompt actually asks for -- the `ferryline intel`
       title, the five emoji sections in priority order, drafts as fenced blocks
       -- and to exercise every construct the renderer claims to handle: h1, both
       heading levels, bold, a link, inline code, a bullet list, a rule, and a
       fenced draft. Two of its item headings are deliberately NOT verbatim
       copies of the fixture's `items` titles, because in a real briefing they
       never are and matching them is the reader's whole trick. The two market
       items have no heading of their own at all, which is the fallback case.

       Its one draft carries a lettered `###` heading, as the real briefings do.
       That heading IS the draft's name -- it is what the dismiss control acts on
       once the letter is stripped -- so a fixture without one would be the only
       place in the app where a draft cannot be waved off. */
    static let briefing = """
        # ferryline intel — Fri Aug 15 · NGU

        17 new items, 2 leads moved. Quiet on regulation, loud on campus dining.

        ## 💰 advertiser leads

        ### Campus DOOH rates climb 12% ahead of the fall buy

        Out-of-home inventory around campus is repricing before September. **Weldon
        Row** and two Marsh Road retailers have already booked static boards
        for the quarter, which is the same budget a bot wrap competes for.

        - rate card: [example.org/advertise](https://example.org/advertise)
        - comparable: Curbot lists a wrap at $899/mo/bot, currently out of stock
        - so what: price the fall wrap at parity and sell the audience, not the pixels

        ### Curbot wrap deal with a regional QSR chain

        A regional chain signed bot wraps across three campuses, none of them ours.
        Proof the format sells, and proof the incumbents are selling it first.

        ---

        ## 🟡 act today (student demand)

        ### NGU dining services opens an RFP for delivery pilots

        Dining posted an RFP for a delivery pilot, responses due `2026-09-05`. This is
        the operating contract rather than an ad buy, and it is the single most
        important thing in this briefing.

        ### Two dorm councils ask about late night runs

        Harbor and Linden both raised late-night food access in public minutes this week.
        Neither has been answered by anyone.

        ## 📊 competitor and market

        - Trundleworks adds four campuses, none in our region. So what: this region
          is still open, and the peer schools nearby are still unclaimed.
        - Portway Labs renews three campus dining contracts. So what: incumbency sits
          at the dining-services layer, which is the layer the RFP above is about.
        - No movement on state sidewalk-delivery rules this week.

        ## ✍️ drafts ready

        Nothing below has been sent. Read it, edit it, send it yourself.

        ### A. Reddit reply · r/example late-night food thread

        ```
        hey, saw the thread about late night food on campus.

        we run the bots that bring commons food to dorms. not a restaurant app, no $9 in
        fees, no driver waiting outside a gate that doesn't open.

        it is early and the bot sometimes gets stuck in a hedge. but it gets there.

        if your council wants a pilot next quarter, reply here and i'll bring numbers.
        ```

        ## 📈 tracking

        - new today: 17, against 4 yesterday
        - pipeline: 0 new · 2 drafted · 0 contacted · 0 dead
        - ledger: 17 lines, nothing compacted
        """
}
