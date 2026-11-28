import SwiftUI

/* Ask the CMO. A question typed here is filed by the collector, answered by a
   session on the Pi a minute later, and read back in this window.

   **This is one window running one process.** ASK.EXE has a title bar, a
   scrollback that fills from the top the way a terminal's does, and a prompt on
   its last line that never leaves the frame. One conversation is open at a time
   -- the one the caller names, or the newest -- and every other thread is a door
   under the frame rather than a second buffer competing for the same eye.

   **It renders in two places and is one view.** On the CMO tab it is a panel in
   the grid, uncontrolled: it keeps the open conversation in its own state,
   because a cell in a dashboard has no route of its own and switching threads
   there should not be a navigation at all. On the ask page it is the whole
   page, controlled: the route says which conversation is open, so the back
   control walks them and no local state can disagree with it. Nothing else
   differs, and the two never draw at once.

   **Nothing here is synchronous and the window never pretends otherwise.** A
   question in flight wears [~ASK] thinking for as long as it really takes; the
   answer arrives on a poll like every other fact in this console. The one
   optimism is the few tens of milliseconds between pressing Return and the
   collector confirming the id -- and even that rolls back to a FAILED line
   rather than leaving a question on screen that no Pi ever received.

   Read-only sessions, and the footer says so wherever an answer can be read --
   which is why the footer is inside this view and not in the page around it.
   The CMO can draft copy in an answer; it cannot send anything and it cannot
   write to the memory the 6am run depends on. */

/// How often a thinking thread is re-fetched. The collector re-reads the CMO's
/// files on its own 60s cadence, so the summary in the payload can lag the file
/// on disk by a minute -- this asks the thread's own route instead, which is
/// always current.
private let thinkingPoll: Duration = .seconds(10)

/// How many other conversations the embedded window lists before deferring to
/// the page. Five, the same run the briefings line shows before `all ▸`: the
/// collector carries up to fifty summaries, and a fifty-row list of doors stops
/// the tab being a dashboard.
private let embedThreads = 5

/// The collector's own ceiling on a question, stated here so the field stops at
/// it rather than letting the Pi reject something already typed.
let questionMax = 2000

/// How many conversations there are and how many are being worked on.
///
/// Counted in here because a question typed a second ago is one of them and
/// only this view knows about it; handed out so the page can print it.
struct AskCounts: Equatable {
    var total = 0
    var thinking = 0
}

/// A question this window has sent and the payload has not confirmed yet.
private struct AskPending: Identifiable {
    /// Stable across the id arriving, so nothing remounts under it.
    var id: String
    var question: String
    var at: String
    /// The collector's id, once it answers. Nil while in flight.
    var threadId: String?
    /// The collector refused or was unreachable. The typed question stays on
    /// screen either way -- losing what he wrote is the one unforgivable
    /// failure here.
    var failed: Bool
}

private enum ThreadRecord {
    case loading
    case missing
    case failed(String)
    case ok(CmoAskThread)
}

/// One conversation this window knows about: a thread the payload lists, or one
/// this copy of the app just started and the payload has not caught up to.
private struct AskRow: Identifiable {
    var id: String
    var threadId: String?
    var pending: AskPending?
}

struct AskWindow: View {

    var payload: TelemetryPayload
    var model: MailModel
    /// Controlled only: the open conversation, or nil for the newest.
    var selected: String? = nil
    /// Controlled only: open the window on nothing, so the prompt starts a
    /// conversation instead of continuing one.
    var fresh: Bool = false
    /// Point the window at a conversation -- nil means an empty one.
    ///
    /// Its presence is what makes the window controlled: a caller that offers
    /// somewhere to put the selection owns it. Absent, selection is local state
    /// and the doors under the frame switch it in place.
    var onSelectThread: ((String?) -> Void)? = nil
    /// Wired only where the window has somewhere to grow into, which is the
    /// page. Absent, the □ box draws disabled.
    var onMaximize: (() -> Void)? = nil
    /// Wired only where closing means something. Absent, the ✕ box draws
    /// disabled, which is the honest chrome for a window with nowhere to go.
    var onClose: (() -> Void)? = nil
    var onCounts: ((AskCounts) -> Void)? = nil
    /// Buffer height, in rows.
    var maxRows: Int = 28
    /// The page's window is the page, and its prompt is the one thing on it to
    /// type into. The tab's is one panel among seven and must not take the
    /// caret on arrival.
    var autoFocus: Bool = false

    @State private var localThread: String?
    @State private var localFresh = false
    @State private var pending: [AskPending] = []
    @State private var sending: [String: (text: String, failed: Bool)] = [:]
    @State private var records: [String: ThreadRecord] = [:]
    @State private var tick = 0
    /// The buffer's own contents, measured. See `htMeasureHeight`.
    @State private var bufferHeight: CGFloat = HT.row * 2

    // MARK: - which conversation is open

    /// Controlled by the route on the ask page, local on the CMO tab. One flag,
    /// because everything that differs between the two follows from the same
    /// fact: a controlled window IS the page, and an uncontrolled one is a
    /// panel in a grid.
    private var controlled: Bool { onSelectThread != nil }
    private var routed: String? { controlled ? selected : localThread }
    private var isFresh: Bool { controlled ? fresh : localFresh }

    private var data: CmoData? { payload.cmo?.data }

    /// The collector already sorts, and this window is the thing that depends
    /// on it.
    private var summaries: [CmoAskThreadSummary] {
        (data?.ask ?? []).sorted { $0.updated > $1.updated }
    }

    private var byId: [String: CmoAskThreadSummary] {
        Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Every conversation this window knows about, newest first.
    private var rows: [AskRow] {
        let mine = pending.map { AskRow(id: $0.id, threadId: $0.threadId, pending: $0) }
        let theirs = summaries
            .filter { s in !pending.contains { $0.threadId == s.id } }
            .map { AskRow(id: $0.id, threadId: $0.id, pending: nil) }
        return mine + theirs
    }

    /// The one conversation the window is running.
    ///
    /// The empty window selects nothing -- except a question typed into it a
    /// moment ago, which has no id yet and therefore nothing to be read back
    /// from. One that got an id is not shown here at all: `ask()` points the
    /// window at that thread the instant the collector names it.
    private var active: AskRow? {
        if isFresh {
            guard let unfiled = pending.first(where: { $0.threadId == nil || $0.failed })
            else { return nil }
            return AskRow(id: unfiled.id, threadId: nil, pending: unfiled)
        }
        // A selection naming a thread this payload has not listed yet is still
        // a real selection: the thread is fetched by id, and the fetch is the
        // thing that knows whether it exists.
        if let routed {
            return rows.first { $0.threadId == routed }
                ?? AskRow(id: routed, threadId: routed, pending: nil)
        }
        return rows.first
    }

    private var activeId: String? { active?.threadId }
    private var others: [AskRow] { rows.filter { $0.id != active?.id } }
    private var doors: [AskRow] { controlled ? others : Array(others.prefix(embedThreads)) }

    // MARK: - fetching the open thread

    /// What makes a thread worth re-fetching.
    ///
    /// A summary that changed is the ordinary trigger, and it covers the case
    /// the whole window turns on: thinking → idle moves both fields at once. A
    /// thread with no summary yet -- just asked, or a payload from before this
    /// feature -- has nothing to notice a change in, so the tick carries it.
    ///
    /// The tick is in every version, including an idle thread's. It only moves
    /// when this window knows something the payload does not yet: the poll
    /// while something is working, and the instant a follow-up is filed.
    private func version(_ id: String) -> String {
        guard let s = byId[id] else { return "new#\(tick)" }
        return "\(s.updated)/\(s.status.rawValue)#\(tick)"
    }

    private var wanted: String {
        guard let activeId else { return "" }
        return "\(activeId)@\(version(activeId))"
    }

    private var record: ThreadRecord? { activeId.flatMap { records[$0] } }

    private var doc: CmoAskThread? {
        if case .ok(let thread) = record { return thread }
        return nil
    }

    private var summary: CmoAskThreadSummary? { activeId.flatMap { byId[$0] } }

    /// Whether the window is waiting on a session.
    ///
    /// Either the payload's summary or the thread's own record can say so, and
    /// one saying it is enough. They disagree for a minute at a time in both
    /// directions, and the two ways of being wrong are not symmetric. Printing
    /// "thinking" over an answer that has already landed costs one poll.
    /// Dropping it off a question still being worked on says the conversation
    /// is finished when it is not, which is the one claim this window must
    /// never make.
    private var activeThinking: Bool {
        guard let active else { return false }
        if summary != nil || doc != nil {
            return summary?.status == .thinking || doc?.status == .thinking
        }
        // With neither to go on, a question this window has sent and heard
        // nothing back about is waiting until the collector refuses it.
        return !(active.pending?.failed ?? false)
    }

    /// The clock only runs while the window is working. An idle window polls
    /// nothing, which is the same rule the telemetry feed follows for a window
    /// nobody is looking at. A question the collector refused is not working
    /// either -- it is over -- so it does not hold the clock open.
    private var polling: Bool {
        guard let active else { return false }
        if active.pending?.failed ?? false { return false }
        return activeId == nil || activeThinking
    }

    // MARK: - staleness

    /// A thread answered before the last morning run reflects an older reading
    /// of the CMO's files. Said out loud rather than left for the reader to work
    /// out from a timestamp: the answer is still true about what it read, and
    /// the only wrong thing about it is that the world moved.
    private var stale: String? {
        guard let doc,
              let started = Fmt.date(data?.heartbeat.startedAt),
              let updated = Fmt.date(doc.updated),
              updated < started else { return nil }
        return String(doc.updated.prefix(10))
    }

    private var counts: AskCounts {
        // A question the payload has not caught up to still counts, or the
        // page's header would say "2 threads" over a window drawing three.
        let unconfirmed = pending.filter { $0.threadId == nil || byId[$0.threadId!] == nil }
        let thinking = summaries.filter { $0.status == .thinking }.count
            + unconfirmed.filter { p in
                if let id = p.threadId, case .ok(let thread) = records[id] {
                    return thread.status == .thinking
                }
                return !p.failed
            }.count
        return AskCounts(total: summaries.count + unconfirmed.count, thinking: thinking)
    }

    // MARK: - the window

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One process, framed. The minimise box stays disabled -- this
            // window does not go away, and a control that does nothing is worse
            // than a control that is visibly off. Which of the other two is
            // wired is the whole difference between the two places this draws:
            // on the tab the window has somewhere to grow into, which is the
            // page; on the page it has somewhere to close to, which is the tab.
            // Neither ever has both.
            HTWindow(name: "ASK.EXE",
                     onMaximize: controlled ? nil : onMaximize,
                     onClose: onClose,
                     flush: true) {
                VStack(alignment: .leading, spacing: 0) {
                    scrollback
                    prompt
                }
            }

            Text("answers may draft · the cmo never sends · "
                 + "sessions read memory, never write it")
                .font(HT.body)
                .foregroundStyle(HT.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, HT.s1)
                .overlay(alignment: .top) {
                    Rectangle().fill(HT.lineFaint).frame(height: 1)
                }
                .padding(.top, HT.row)

            if !doors.isEmpty || active != nil { doorsBlock }
        }
        .task(id: wanted) { await load() }
        .task(id: polling) { await poll() }
        .onChange(of: Set(summaries.map(\.id))) { _, ids in
            // A pending question is dropped the moment the payload names it,
            // which is what keeps this from being a second source of truth --
            // the rule `CmoDismissals` follows for the same reason.
            let next = pending.filter { $0.threadId == nil || !ids.contains($0.threadId!) }
            if next.count != pending.count { pending = next }
        }
        .onChange(of: counts) { _, c in onCounts?(c) }
        .onAppear { onCounts?(counts) }
    }

    // MARK: - the buffer

    /// The window's scrollback: one conversation, oldest turn at the top, the
    /// way a terminal fills. Questions, answers, receipts and whatever the
    /// process is currently doing are all lines in the same buffer, and the last
    /// of them is always the most recent thing that happened -- which is why
    /// this scrolls to its end rather than to its start.
    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let empty = emptyLine {
                        Text(empty)
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Before the record lands, the question this copy of the
                    // app just typed is the only copy of it there is.
                    if doc == nil, let p = active?.pending {
                        AskQuestion(text: p.question)
                        if p.failed { AskRefused() }
                    }

                    ForEach(Array((doc?.turns ?? []).enumerated()), id: \.offset) { _, turn in
                        if turn.role == .q {
                            AskQuestion(text: turn.text)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                if !turn.text.isEmpty {
                                    MarkdownDoc(nodes: Markdown.parse(turn.text))
                                        .padding(.top, HT.s2)
                                }
                                AskAnswerMeta(turn: turn)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if case .loading = record, active?.pending == nil {
                        AskNote("reading the thread")
                    }
                    if case .missing = record {
                        AskNote("this thread is not on the Pi.")
                    }
                    if case .failed(let message) = record {
                        AskFault(message)
                    }

                    if let outbound = activeId.flatMap({ sending[$0] }) {
                        AskQuestion(text: outbound.text)
                        if outbound.failed { AskRefused() }
                    }

                    // Drawn from the summary rather than from the last turn: a
                    // question queued a second ago has a record with one turn in
                    // it and nothing else to say, and the honest thing to print
                    // is that it is still waiting.
                    if activeThinking,
                       !(active?.pending?.failed ?? false),
                       !(activeId.flatMap({ sending[$0]?.failed }) ?? false) {
                        ThinkingMeta()
                    }

                    if let stale, !activeThinking {
                        AskMetaRow {
                            Text("stale · reflects \(stale)")
                                .font(HT.body)
                                .foregroundStyle(HT.caution)
                        }
                    }

                    // The blank last row of the buffer. A real row rather than
                    // padding on the container: padding below the last line is
                    // padding scrolled past, which lands an answer's final line
                    // hard against the frame.
                    Color.clear
                        .frame(height: HT.row)
                        .id("ask-end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HT.cw2)
                .padding(.top, HT.row)
                .htMeasureHeight { bufferHeight = $0 }
            }
            // The buffer, counted in rows because that is the unit a terminal
            // is measured in: 28 on its own page is the height at which a long
            // answer becomes a thing to scroll rather than a thing that pushes
            // the prompt off the bottom of the window; 18 in the CMO tab's grid
            // keeps it a panel among panels. The prompt is the point of the
            // window either way and it never leaves.
            .frame(height: Swift.min(Swift.max(bufferHeight, HT.row * 2),
                                     CGFloat(maxRows) * HT.row))
            // The buffer's own scroll position and nothing else's: this window
            // is a panel in the CMO tab's grid, and an answer landing there must
            // not drag the whole dashboard down to it. No animation anywhere
            // near it -- a terminal repaints, it does not scroll.
            .onChange(of: painted) { _, _ in proxy.scrollTo("ask-end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("ask-end", anchor: .bottom) }
        }
    }

    /// What the buffer currently says, as one string. The bottom line moves when
    /// a turn lands, when a question is typed into it, and when the thinking
    /// line comes or goes -- so those are what bring the end back into view.
    private var painted: String {
        [
            String(doc?.turns.count ?? 0), String(activeThinking), stale ?? "",
            emptyLine ?? "", recordWord,
            active?.pending?.question ?? "", String(active?.pending?.failed ?? false),
            activeId.flatMap { sending[$0]?.text } ?? "",
            String(activeId.flatMap { sending[$0]?.failed } ?? false),
        ].joined(separator: "|")
    }

    private var recordWord: String {
        switch record {
        case .none: return ""
        case .loading: return "loading"
        case .missing: return "missing"
        case .failed: return "error"
        case .ok: return "ok"
        }
    }

    /// The line to draw when there is no conversation in the buffer at all.
    private var emptyLine: String? {
        guard active == nil else { return nil }
        return isFresh ? "new thread · type below" : "no conversations yet · type below"
    }

    // MARK: - the prompt

    /// Pinned under the buffer and ruled off from it on the same hairline every
    /// other divider uses: what has already happened is above the line and what
    /// is about to is below it.
    private var prompt: some View {
        AskField(
            placeholder: continuing ? "follow up…" : "ask the cmo",
            busy: activeId.map { sending[$0] != nil } ?? false,
            autoFocus: autoFocus,
            onSubmit: submit)
            .padding(.horizontal, HT.cw2)
            .padding(.vertical, HT.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(HT.lineFaint).frame(height: 1) }
    }

    /// The prompt continues the open conversation when there is one and it is
    /// not mid-answer; otherwise it starts a new one. There is only one field to
    /// choose between them.
    private var continuing: Bool { activeId != nil && !activeThinking }

    // MARK: - the doors

    private var doorsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(doors) { row in
                let s = row.threadId.flatMap { byId[$0] }
                AskDoor(
                    label: {
                        if let q = s?.firstQ, !q.isEmpty { return q }
                        if let q = row.pending?.question, !q.isEmpty { return q }
                        return row.threadId ?? row.id
                    }(),
                    value: "\(s?.turns ?? 1) turns",
                    open: { select(row.threadId) })
            }

            // The rest of them, on the page that lists every one.
            if !controlled, others.count > doors.count, let onMaximize {
                AskQuiet(text: "all \(others.count) threads ›", action: onMaximize)
            }

            // A door, not an action: it opens the window on nothing and the
            // prompt starts a conversation rather than continuing one.
            if active != nil {
                AskQuiet(text: "new thread ›", action: { select(nil) })
            }
        }
        .padding(.top, HT.row)
    }

    // MARK: - selection and asking

    private func select(_ id: String?) {
        if let onSelectThread {
            onSelectThread(id)
        } else {
            localThread = id
            // Nothing open and nothing selected is the empty window, which is
            // the only state whose prompt starts a conversation rather than
            // continuing one.
            localFresh = (id == nil)
        }
    }

    private func submit(_ question: String) {
        if continuing, let activeId {
            Task { await followUp(activeId, question) }
        } else {
            Task { await ask(question) }
        }
    }

    private func ask(_ question: String) async {
        let key = "\(Date().timeIntervalSince1970)-\(Int.random(in: 0..<0xffff))"
        pending.insert(
            AskPending(id: key, question: question, at: Fmt.stampNow(),
                       threadId: nil, failed: false),
            at: 0)

        let id = await model.store.cmoAsk(question: question, thread: nil)
        pending = pending.map { p in
            guard p.id == key else { return p }
            var out = p
            out.threadId = id
            out.failed = (id == nil)
            return out
        }
        // The new conversation is pointed at the instant it has a name, so the
        // window keeps showing it -- and on the page, so the address keeps
        // saying which one it is.
        if let id { select(id) }
    }

    private func followUp(_ id: String, _ question: String) async {
        sending[id] = (text: question, failed: false)
        let got = await model.store.cmoAsk(question: question, thread: id)
        guard got != nil else {
            sending[id] = (text: question, failed: true)
            return
        }
        // The collector wrote the question turn before it answered, so the
        // record on disk already has it. Re-read rather than splice a copy in
        // here: one source of truth for what the thread contains, and it is the
        // Pi's.
        sending.removeValue(forKey: id)
        tick &+= 1
    }

    // MARK: - reading

    private func load() async {
        let id = String(wanted.prefix(while: { $0 != "@" }))
        guard !id.isEmpty else { return }
        if records[id] == nil { records[id] = .loading }
        do {
            let thread = try await model.store.cmoThread(id: id)
            records[id] = thread.map { ThreadRecord.ok($0) } ?? .missing
        } catch is CancellationError {
            return
        } catch {
            records[id] = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func poll() async {
        guard polling else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: thinkingPoll)
            if Task.isCancelled { return }
            tick &+= 1
        }
    }
}

// MARK: - buffer lines

/// The question line: a shell prompt with the question as the command. Every
/// question is drawn the same, answered or not -- what he asked does not become
/// less true while it is waiting.
private struct AskQuestion: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw) {
            Text("$")
                .foregroundStyle(HT.prompt)
                .fixedSize()
            Text(text)
                .foregroundStyle(HT.inkBright)
                .lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(HT.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

/// The receipts, ruled off above rather than merely spaced: a different kind of
/// statement from the answer over it, and the rule is what stops it being read
/// as one more paragraph.
private struct AskMetaRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HT.s1)
            .overlay(alignment: .top) { Rectangle().fill(HT.lineFaint).frame(height: 1) }
            .padding(.top, HT.s2)
    }
}

private struct AskNote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        AskMetaRow {
            Text(text).font(HT.body).foregroundStyle(HT.inkDim)
        }
    }
}

private struct AskFault: View {
    var message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        AskMetaRow {
            HStack(spacing: HT.cw) {
                StatusPill(text: "×ask", tone: .fault, glyph: false)
                Text(message)
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AskRefused: View {
    var body: some View {
        AskFault("not filed: the collector did not take it")
    }
}

/// How long it took, what it opened, when.
///
/// `read:` is printed even when the session did not say -- "not stated" and
/// "read nothing" are different claims, and only one of them can be checked.
private struct AskAnswerMeta: View {
    var turn: CmoAskTurn

    private var hhmm: String { String(Fmt.clock(turn.at).prefix(5)) }

    var body: some View {
        if let error = turn.error {
            AskMetaRow {
                HStack(spacing: HT.cw) {
                    StatusPill(text: "×ask", tone: .fault, glyph: false)
                    Text(error)
                        .font(HT.body)
                        .foregroundStyle(HT.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("· \(hhmm)").font(HT.body).foregroundStyle(HT.inkDim)
                }
            }
        } else {
            AskMetaRow {
                Text("answered in \(Fmt.dur(turn.durationS)) · read: "
                     + ((turn.reads?.isEmpty ?? true)
                        ? "not stated" : (turn.reads ?? []).joined(separator: " · "))
                     + " · \(hhmm)")
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What the process claims to be doing while it thinks. All of them things this
/// CMO could truthfully be caught at, none of them progress: the verb is
/// decoration and the pill beside it is the truth.
private let thinkingVerbs = [
    "sweeping", "deduping", "drafting", "pitching",
    "scouting", "snooping", "canvassing", "prospecting",
    "benchmarking", "anchoring", "segmenting", "positioning",
    "budgeting", "quoting", "sourcing", "verifying",
    "skimming", "rummaging", "clipping", "headlining",
    "schmoozing", "tabling", "postering", "leafleting",
    "wrapping", "trundling", "beeping", "percolating",
]

/// The line a question in flight wears. [~ASK] is the pill, the cycling verb is
/// the word, and neither is a colour: the state survives being printed 1-bit,
/// where the verb simply reads as whatever it last was.
///
/// The swap is a repaint on a timer and not an animation -- the same legality as
/// the COPY button flashing COPIED, and the same reason it is a hard cut.
private struct ThinkingMeta: View {
    @State private var verb = thinkingVerbs.randomElement() ?? "thinking"

    var body: some View {
        AskMetaRow {
            HStack(spacing: HT.cw) {
                StatusPill(text: "~ask", glyph: false)
                Text("\(verb)…").font(HT.body).foregroundStyle(HT.inkDim)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2500))
                if Task.isCancelled { return }
                var next = verb
                while next == verb { next = thinkingVerbs.randomElement() ?? verb }
                verb = next
            }
        }
    }
}

// MARK: - the doors

/// One other conversation, as a leader: what was asked, and how far it got.
private struct AskDoor: View {
    var label: String
    var value: String
    var open: () -> Void

    @State private var hovering = false

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Button(action: open) {
                Text(label)
                    .font(HT.body)
                    .foregroundStyle(hovering ? HT.inkBright : HT.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering = $0 }

            GlyphRun(glyph: ".", color: HT.inkFaint)

            Text(value)
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
        }
        .frame(height: HT.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(value)"))
        .accessibilityAddTraits(.isButton)
    }
}

/// A quiet door: dim at rest, brightening under the cursor the way the archive
/// link does, because it is the same kind of thing -- a place to go, not an act.
struct AskQuiet: View {
    var text: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(HT.body)
                .foregroundStyle(hovering ? HT.inkBright : HT.inkDim)
                .lineLimit(1)
                .frame(height: HT.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - the field

/* The prompt as a real input. A `$`, the text, and a block cursor that blinks
   only while the field is empty -- the one animation this design system allows,
   spent on the element whose whole job is to say "type here".

   Deliberately not `CommandField`: that is a bordered search box with a
   shortcut cap printed on it, which is the right control for filtering a table
   and the wrong one for a prompt line. Not `Prompt` either, which draws a
   command and cannot receive one.

   The field is sized in cells to its own content, so the cursor sits directly
   after the placeholder the way a terminal's does rather than at the far end of
   an empty row. */
struct AskField: View {
    var placeholder: String
    /// A question from this field is already in flight.
    var busy: Bool = false
    var autoFocus: Bool = false
    var onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var cells: Int { Swift.max(text.count, placeholder.count) + 1 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            Text("$")
                .font(HT.body)
                .foregroundStyle(HT.prompt)
                .fixedSize()

            ZStack(alignment: .leading) {
                // The placeholder is drawn rather than handed to the field: a
                // system prompt is grey by policy, and this one is as bright as
                // the typing it stands in for.
                if text.isEmpty {
                    Text(placeholder)
                        .font(HT.body)
                        .foregroundStyle(HT.inkBright)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(HT.body)
                    .foregroundStyle(HT.inkBright)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit(submit)
                    .onChange(of: text) { _, typed in
                        if typed.count > questionMax { text = String(typed.prefix(questionMax)) }
                    }
                    .accessibilityLabel(Text(placeholder))
            }
            .frame(width: CGFloat(cells) * HT.cw, alignment: .leading)

            // Only while empty. A caret and a block cursor in the same field at
            // the same time is two cursors, and the native caret is the one that
            // knows where the typing is.
            if text.isEmpty { BlinkCursor() }

            Spacer(minLength: 0)
        }
        .frame(minHeight: HT.row)
        // The whole line is the field's hit target: the sigil, the gap, the
        // block cursor, the empty run to the right. A prompt line that only
        // takes focus on its eleven placeholder characters feels dead, and
        // "feels dead" is indistinguishable from broken.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .task { if autoFocus { focused = true } }
    }

    private func submit() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        text = ""
        onSubmit(question)
    }
}
