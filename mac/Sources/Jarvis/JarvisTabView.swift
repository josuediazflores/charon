import AppKit
import SwiftUI

/* Jarvis. One assistant, one conversation per day, work running beside it.
 *
 * **It is not the Chat tab and shares no route with it.** Chat is a list of
 * conversations you start and delete; this is one conversation a day, already
 * started, with a work lane beside it that answers even while the talk lane is
 * busy. Nothing in this file touches the chat routes.
 *
 * **Two lanes, and the composer is built around the difference.** Filing a turn
 * is refused with a 409 while one is in flight; filing a JOB never is, and that
 * is the whole point of the feature. So the box stays typable while an answer
 * streams, `send` is the only control that goes away, and `[run as job]` is live
 * the entire time. A composer that greyed out wholesale while Jarvis was
 * thinking would hide exactly the control the split exists to provide.
 *
 * **Nothing here is synchronous and the page never pretends otherwise.** A turn
 * is filed, a path unit fires, and the answer arrives on a poll. The one
 * optimism is the copy of a message held on screen between pressing send and the
 * record confirming it -- and even that rolls back to a FAILED line rather than
 * leaving a message on screen that no Pi ever received.
 */

/// The collector's own ceiling on a message. The same number the chat routes
/// enforce, stated rather than shared: the number belongs to the collector, the
/// two pages happen to agree, and a change to the chat tab must not silently
/// move this limit.
private let jarvisTextMax = 4000

/// How much of the typed text becomes a job's title. A card sits in the
/// transcript for minutes under this name, so it wants a label rather than the
/// first eighty characters of a prompt.
private let jarvisTitleMax = 60

/// How long the transcript takes to fold. 220ms rather than the dialect's 120:
/// that number is for a colour under a cursor and should feel instant, while
/// this is a panel the size of the page moving, which at 120ms reads as a glitch
/// rather than as a fold.
private let jarvisFold: Double = 0.22

/// The buffer's floor, counted in rows because that is the unit a terminal is
/// measured in.
private let jarvisRows = 12

/// Off, speaking as it streams, or reading the finished answer as one take.
private enum VoiceMode { case off, live, whole }

/// What the orb and the word beside it both read from. One derivation, so the
/// picture and the word can never disagree -- which is the failure that makes a
/// presence indicator worse than none, because a reader who has learned to trust
/// the shape stops reading the word.
private struct Presence {
    var word: String
    /// Deliberately not linear. A turn in flight is the loudest thing that
    /// happens here (0.9). Work running in the other lane is real but is not his
    /// attention (0.3), which is the two-lane split expressed as a texture. Idle
    /// is 0.05 rather than 0, because a sphere that stops dead reads as broken
    /// rather than as resting.
    var activity: Double
    /// What he is DOING, as a colour -- three values and no more. Gold is the
    /// resting identity; blue is a turn of his in flight (thinking, queued,
    /// filing -- one family, one hue, so "queued" cannot read as a different
    /// kind of event than the "thinking" it becomes); red is a real fault
    /// (failed, unreachable), spent there and nowhere else so it agrees with
    /// what red means everywhere else in this console. Never cyan: cyan is
    /// "this one" and is spent exactly twice in the whole app.
    var ink: Color = HT.c11
}

struct JarvisTabView: View {

    var model: MailModel

    /// `#jarvis/<YYYY-MM-DD>`, or nil for today.
    ///
    /// **Today is the landing page**, and it is the only day anything can be
    /// written to: every write route in the contract acts on today and takes no
    /// day at all. So an earlier day is drawn without a composer rather than
    /// with a disabled one -- the box is not refused there, it does not apply.
    @State private var day: String?

    @State private var doc: JarvisDay?
    @State private var missing = false
    /// The collector did not answer for today. Held apart from `missing`, which
    /// is a fact about a date, because this is a fact about the network and the
    /// two want opposite words on screen.
    @State private var unreachable = false
    @State private var rows: [JarvisDaySummary]?
    @State private var jobs: [JarvisJob]?
    @State private var sending: String?
    @State private var failed: String?
    /// How many say-turns the record held when the in-flight message was filed.
    /// The optimistic copy clears when the record grows PAST this. See the chat
    /// conversation's own note: the collector is threaded, so a poll GET can
    /// return a pre-send record while the send POST is still open.
    @State private var sentBaseline: Int?

    /// The transcript folded away. Not persisted: a fold is about the next
    /// minute, not about the reader, and a day that reopened collapsed tomorrow
    /// would be a day whose history you have to remember to ask for.
    ///
    /// **Open on arrival.** It was collapsed until asked for, which meant a day
    /// with five turns in it opened as an orb and an empty box: a page that has
    /// something to show showing nothing, and a fold to find before it would.
    /// The record is what the tab is for, so the record is what it opens on.
    @State private var folded = false
    /// The open transcript's own height, so the fold has two numbers to move
    /// between. Measured on the content rather than on the frame, which is what
    /// keeps it true as the day grows.
    @State private var measured: CGFloat = 0

    @State private var voice: VoiceMode = .off
    @State private var speaker = Speaker()
    /// One extractor per in-flight turn. A cursor, not a render input, so it
    /// lives beside the view rather than in it.
    @State private var cursor: SentenceCursor?
    /// How many assistant say turns existed when the cursor was cut, so turn end
    /// can tell "the answer landed" from "the turn failed and the newest
    /// assistant turn is an earlier one" -- finalizing against an old turn with
    /// nothing yet spoken would prefix-match trivially and read the whole of it
    /// aloud.
    @State private var voiceBase = 0

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var today: Bool { day == nil }

    private var live: Bool {
        guard let doc else { return false }
        return chatInFlight(queued: doc.queued, status: doc.status)
    }

    private var openDay: String? { doc?.day ?? day }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            Rule(variant: .bright).padding(.top, HT.row)
            dayStrip.padding(.top, HT.row)
            JarvisNote("one conversation a day · jobs run in their own lane "
                       + "and never block it")
                .padding(.top, HT.row)

            panel.padding(.top, HT.row)
            if today { talkRow.padding(.top, HT.row) }

            // The web console prints the jobs disclosure here ("talk reads
            // only · jobs may write, and every write shows"). Removed at the
            // user's request 2026-08-19; the job cards remain the place every
            // write shows.
        }
        .frame(maxWidth: chatMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: model.connection.baseURL + model.connection.mode.rawValue) {
            speaker.bind(model.store)
        }
        // Read on arrival and when the route moves, and deliberately NOT on the
        // poll: it is a list of calendar days, a new one appears at midnight, and
        // re-reading sixty summaries once a second while an answer streams would
        // be sixty summaries a second spent learning nothing.
        .task(id: day ?? "") { rows = await model.store.jarvisDays() }
        .task(id: pollKey) { await poll() }
        .onChange(of: doc) { _, _ in pumpVoice() }
        .onChange(of: voice) { _, _ in pumpVoice() }
        .onDisappear { speaker.cancel() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: - the hero

    /* **The orb is the header, not an ornament in it.** Presence is the one thing
       on this page that is about the assistant rather than about the
       conversation, so it gets the top of the page to itself.

       **Colour says what he is DOING, and never who he is.** (2026-08-24; it
       was "one colour, always" before that.) The old ban was on tone-as-
       identity: a sphere that is red because it happens to be Jarvis makes a
       real red harder to trust. This is the reserved counterpart, colour-as-
       doing: gold at rest because gold is Jarvis, blue while a turn of his is
       in flight, red only when something has actually failed -- which is red
       AGREEING with the console's fault vocabulary rather than borrowing it.
       The orb still cannot be the only channel -- it is hidden from assistive
       tech and it is one hue in a 1-bit render -- so the word underneath
       remains the state's non-colour channel, in the same neutral ink as
       always. The mapping lives on `Presence`, beside the word and the
       activity, so the three can never disagree.

       **The sphere is a GPU fluid now, not a character grid.** Picked by the
       user on 2026-08-23; the preset, its provenance and the Bayer screen that
       prints it are documented in `LiquidOrb.metal`. Nothing above changes: it
       is the same size, the same one colour and the same `activity`, and
       `OrbView` still draws it on any Mac that cannot start the renderer. */
    private var hero: some View {
        VStack(spacing: 0) {
            LiquidOrbView(activity: presence.activity, ink: presence.ink,
                          label: "Jarvis is \(presence.word)")
                .padding(.bottom, HT.row)

            Text("JARVIS")
                .font(HT.lead)
                .tracking(22 * 0.08)
                .foregroundStyle(HT.inkBright)
                .frame(height: HT.row2)

            Text(presence.word)
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .frame(height: HT.row)

            heroMeta.padding(.top, HT.s1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HT.row2)
        .padding(.bottom, HT.row)
    }

    private var heroMeta: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            Text(openDay ?? "—").font(HT.body).foregroundStyle(HT.inkFaint)
            if today {
                Text("· today").font(HT.body).foregroundStyle(HT.inkFaint)
            } else {
                ChatTextButton(text: "· ◂ back to today", ink: HT.inkMid) { day = nil }
            }
            if let doc {
                Text("· \(Fmt.relTime(doc.updatedAt, now: model.now))")
                    .font(HT.body)
                    .foregroundStyle(HT.inkFaint)
            }
        }
    }

    /// Ordered by what a reader most needs to know. A turn in flight outranks a
    /// failure, because the failure is the previous turn's and this one is
    /// happening now; and work outranks idle, because a day with three jobs
    /// running is not a day where nothing is happening.
    /// Whether the microphone is open.
    ///
    /// **Always false in this port.** Dictation is deferred (SPEC-CMO decision
    /// 1) and nothing sets it, but the state keeps its name and its place at the
    /// top of the priority order below, because the order is the contract and
    /// the day the mic lands this is where it belongs.
    private var listening: Bool { false }

    private var presence: Presence {
        // **Listening outranks everything.** It is the only state here the reader
        // caused half a second ago and is waiting on, and the orb is the largest
        // thing on the page.
        if listening { return Presence(word: "listening", activity: 1) }
        if sending != nil { return Presence(word: "filing", activity: 0.6, ink: HT.c12) }
        if doc?.queued == true { return Presence(word: "queued", activity: 0.9, ink: HT.c12) }
        if doc?.status == .running { return Presence(word: "thinking", activity: 0.9, ink: HT.c12) }
        // **Speaking sits below the turn itself.** While a turn streams the
        // reader is watching text arrive and 'thinking' is the truer word; the
        // voice still finishing an answer after the turn closed is when this is
        // the state.
        if speaker.speaking { return Presence(word: "speaking", activity: 0.45) }
        if unreachable { return Presence(word: "unreachable", activity: 0, ink: HT.c9) }
        let working = (doc?.turns ?? []).contains { turn in
            if case .job(let j) = turn { return j.state == .running || j.state == .queued }
            return false
        }
        if working { return Presence(word: "working", activity: 0.3) }
        if doc?.status == .error { return Presence(word: "failed", activity: 0.12, ink: HT.c9) }
        return Presence(word: "idle", activity: 0.05)
    }

    // MARK: - the days

    /// Every day there is a record for, as one row of chips.
    ///
    /// **A strip rather than a page.** Today is the landing page and is where all
    /// six writes go; an earlier day is somewhere you look something up. A list
    /// route would have made the reader pick a conversation before they could say
    /// anything to the one that is live.
    @ViewBuilder
    private var dayStrip: some View {
        if rows == nil {
            JarvisNote("the days are on the pi · not read yet")
        } else if rows?.isEmpty ?? true {
            JarvisNote("no earlier days")
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
                    ForEach(rows ?? []) { row in
                        DayChip(row: row, open: row.day == openDay) { day = row.day }
                    }
                }
                .padding(.bottom, HT.s1)
            }
            .accessibilityLabel(Text("Days"))
        }
    }

    // MARK: - the panel

    /* **A panel, not a window, and the reason is one glyph.** A title bar always
       draws all three boxes and disables the ones with no handler, so wiring only
       the fold would leave two dead controls sitting beside the live one. Two
       thirds of that chrome was furniture on a page whose subject is a
       conversation rather than a running process. This is the same frame without
       the window dressing: the label, and one arrow that does the only thing this
       panel does.

       Folding hides the history and NOTHING else -- the composer stays, because
       the reason to fold a long day away is usually to get a clean screen to type
       into, and a fold that took the input with it is a fold nobody uses twice. */
    private var panel: some View {
        VStack(spacing: 0) {
            head
            VStack(spacing: 0) {
                collapse
                if today { composer } else { closed }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { PanelBodyFrame().stroke(HT.inkDim, lineWidth: 1) }
        }
    }

    private var head: some View {
        HStack(spacing: HT.cw) {
            Text("TRANSCRIPT")
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The count moves into the bar when the body is away, so folding
            // costs no information.
            if folded, sayCount > 0 {
                Text("· \(sayCount) \(sayCount == 1 ? "turn" : "turns")")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .fixedSize()
            }

            // `▲`/`▼` and not `▸`, which is not in Departure Mono at all. The
            // arrow says what the click will DO rather than what the state is.
            ChatTextButton(text: folded ? "▼" : "▲", ink: HT.inkMid,
                           label: folded ? "Expand the transcript" : "Collapse the transcript") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: jarvisFold)) {
                    folded.toggle()
                }
            }
            .frame(width: HT.cw3)
        }
        .padding(.leading, HT.cw)
        .padding(.trailing, HT.s1)
        .frame(height: HT.row2)
        .background(Color.clear)
        .overlay { Rectangle().strokeBorder(HT.inkDim, lineWidth: 1) }
    }

    /// The body stays mounted and is clipped rather than unmounted, so the scroll
    /// position survives a fold and the transcript does not have to be rebuilt on
    /// the way back.
    private var collapse: some View {
        buffer
            .htMeasureHeight { height in if height > 0 { measured = height } }
            .frame(height: folded ? 0 : (measured > 0 ? measured : nil), alignment: .top)
            .clipped()
    }

    @ViewBuilder
    private var buffer: some View {
        if missing {
            bufferNote("no record for this day on the pi.")
        } else if unreachable {
            // Said out loud rather than drawn as a quiet day. The composer below
            // is disabled off the same flag, because a box you can type into over
            // a Pi that is not answering is a message that goes nowhere and says
            // it went.
            bufferNote("the collector is not answering · today is on the pi, not here")
        } else {
            JarvisTranscript(
                doc: doc, jobs: jobs, sending: sending, failed: failed,
                onCompact: { Task { await compact() } },
                onStopJob: { id in Task { await stopJob(id) } })
                .frame(minHeight: CGFloat(jarvisRows) * HT.row, alignment: .topLeading)
        }
    }

    private func bufferNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            JarvisNote(text)
            Spacer(minLength: 0)
        }
        .frame(minHeight: HT.row * 6, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, HT.cw2)
        .padding(.top, HT.row)
    }

    /// Turns a reader would call turns. Job cards and notice lines are in the
    /// same array and are not things anybody said, so they are not counted on the
    /// folded row.
    private var sayCount: Int {
        (doc?.turns ?? []).reduce(0) { n, turn in
            if case .say = turn { return n + 1 }
            return n
        }
    }

    // MARK: - the composer

    private var composer: some View {
        JarvisComposer(
            busy: live || sending != nil,
            offline: unreachable,
            busyReason: unreachable ? "the collector is not answering" : busyReason,
            model: doc?.model ?? .sonnet,
            // Shown as `medium` when the record names nothing, because that is
            // what the CLI does by default -- but nothing is written until a
            // choice is made, so an untouched day never claims a level it did not
            // run with.
            effort: doc?.effort ?? .medium,
            ctx: doc?.context,
            onStop: live ? { Task { await stop() } } : nil,
            onSend: { text in Task { await send(text) } },
            onJob: { text, title in await file(text, title) },
            onModel: { m in Task { await changeModel(m) } },
            onEffort: { e in Task { await changeEffort(e) } })
    }

    private var busyReason: String? {
        if sending != nil { return "filing…" }
        if doc?.queued == true { return "queued · the runner has not picked this up yet" }
        if doc?.status == .running {
            return "answering · [stop] to give up on it · jobs still file"
        }
        return nil
    }

    /// No composer at all rather than a disabled one. Nothing can be written to
    /// an earlier day -- not because it is locked, but because every write route
    /// in the contract means today.
    private var closed: some View {
        HStack(spacing: 0) {
            Text("an earlier day · reading only · ")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
            ChatTextButton(text: "today", ink: HT.inkMid) { day = nil }
            Text(" is where you can type")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HT.cw2)
        .padding(.vertical, HT.row)
        .overlay(alignment: .top) { Rectangle().fill(HT.lineFaint).frame(height: 1) }
    }

    // MARK: - the talk row

    /* **Talk lives outside the panel, on its own.** It was a fourth control in
       the composer row, which made the most physical thing on the page look like
       a setting. It is also not part of the transcript: the transcript is the
       record, and this is a way of putting words into the box.

       **The mic is deferred** (SPEC-CMO decision 1). The web's own button is
       blocked in production anyway -- the Pi serves that page over plain http and
       the browser refuses to open a microphone outside a secure context -- so
       rather than port a control that cannot work, the row keeps only the half
       that does: voice OUT. The row used to carry the words "dictation not
       built yet" beside the toggle, which is a note about this program's
       backlog rather than anything the reader can act on; a control that is not
       there is not a control anybody is looking for. */
    private var talkRow: some View {
        HStack(spacing: HT.cw2) {
            voiceButton

            if voice != .off, speaker.unavailable {
                // The Mac is asleep or tts is not configured: a dim word, never a
                // fault tone. The text lane is whole and the answer is on screen,
                // so nothing here needs looking into -- red would be an alarm
                // about an amenity.
                Text("voice unavailable")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
    }

    /// `◌` and `•`, both confirmed in Departure Mono at a true 7px advance, and
    /// the word changes with them, so the toggle survives 1-bit. Ink, never cyan:
    /// a setting, not the act that puts a message in the day.
    private var voiceButton: some View {
        let on = voice != .off
        let label = voice == .off ? "◌ voice" : voice == .live ? "• voice live" : "• voice whole"
        return Button(action: toggleVoice) {
            Text(label)
                .font(HT.body)
                .foregroundStyle(on ? HT.inkBright : HT.ink)
                .padding(.horizontal, HT.cw2)
                .frame(height: HT.row2)
                .overlay {
                    Rectangle().strokeBorder(on ? HT.inkBright : HT.lineBright, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(Text(label))
        .help(voice == .off
              ? "speak answers as they stream"
              : voice == .live ? "wait and read the whole answer at the end" : "voice off")
    }

    /// off → live → whole → off, one button.
    private func toggleVoice() {
        switch voice {
        case .off:
            // Switching the voice on is the earliest signal a spoken reply is
            // wanted, so it is also the first warm ping.
            speaker.warm()
            voice = .live
        case .live:
            // The hop to `whole` cancels the audio but leaves the cursor alone,
            // so the completion pass speaks only what was never spoken -- "stop
            // talking, give me the rest at the end" falls out of the
            // emitted-prefix arithmetic for free.
            speaker.cancel()
            voice = .whole
        case .whole:
            // Off means quiet now, not quiet after the queue drains.
            speaker.cancel()
            voice = .off
        }
    }

    // MARK: - the voice

    /// **Only assistant say text is ever spoken.** `partial` is the talk lane's
    /// own field -- job cards and notices never pass through it -- and the
    /// finalize below reads nothing but an assistant say turn.
    private func pumpVoice() {
        if voice == .off || !today {
            cursor = nil
            return
        }
        if live {
            // Both on-modes cut the cursor at turn start: it is the turn-open
            // marker and the `voiceBase` snapshot either way.
            if cursor == nil {
                cursor = SentenceCursor()
                voiceBase = answerCount(doc)
            }
            // Re-feeding an unchanged snapshot is a no-op by the cursor's own
            // contract. Only `live` feeds at all; `whole` leaves the cursor
            // starving on purpose, so the finalize below emits the entire answer
            // as one gapless run.
            if voice == .live, let cursor {
                for sentence in cursor.feed(doc?.partial ?? "") { speaker.enqueue(sentence) }
            }
            return
        }
        guard let held = cursor else { return }
        cursor = nil
        // A failed turn appended no answer, and finalizing against whatever
        // assistant turn happens to be newest would speak the wrong one.
        if doc?.status == .error || answerCount(doc) <= voiceBase { return }
        for turn in (doc?.turns ?? []).reversed() {
            if case .say(let say) = turn, say.role == .assistant {
                for sentence in held.finalize(say.text) { speaker.enqueue(sentence) }
                return
            }
        }
    }

    private func answerCount(_ d: JarvisDay?) -> Int {
        (d?.turns ?? []).reduce(0) { n, turn in
            if case .say(let say) = turn, say.role == .assistant { return n + 1 }
            return n
        }
    }

    // MARK: - reading

    /* Fast while something is happening, slow otherwise, and stopped entirely
       while nobody is looking at the window.

       **A running job does NOT count as live**, which is the opposite of what it
       first looks like it should be. The 1s rate exists for exactly one thing:
       the say runner rewrites `partial` every half second, so a streaming answer
       is only visible at that rate. The job runner writes nothing into this
       record -- a card changes state twice in several minutes -- so a second-rate
       poll while a job runs spends sixty requests a minute re-reading identical
       bytes.

       **An earlier day is not polled at all.** It is a finished record: no runner
       writes to it, no route in the contract can, and a timer against it would be
       a request a second for a file that will never change again. */
    private var pollKey: String {
        "\(day ?? "")|\(model.active)|\(live || sending != nil)"
    }

    private func poll() async {
        guard today else {
            await load()
            return
        }
        guard model.active else { return }
        let fast = live || sending != nil
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: fast ? chatLivePoll : chatIdlePoll)
            if Task.isCancelled { return }
        }
    }

    private func load() async {
        do {
            let got = today
                ? try await model.store.jarvisToday()
                : try await model.store.jarvisDay(day ?? "")
            if Task.isCancelled { return }
            doc = got
            // A 404 is a fact about the date and a transport failure is not.
            // Today can never be missing -- the collector mints it -- so this
            // only ever fires on a date reached from the strip.
            missing = (got == nil && !today)
            // **And nil on TODAY means the collector did not answer**, which is a
            // different sentence from "nothing has been said today" and must not
            // be drawn as it.
            unreachable = (got == nil && today)
            if let got, let baseline = sentBaseline, askCount(got) > baseline {
                sending = nil
                sentBaseline = nil
            }
            // Only when the day actually has a card to fill in. A day of pure
            // conversation is the ordinary case, and it has no business asking a
            // second route once a second for a list it will not draw.
            if let got, got.turns.contains(where: { if case .job = $0 { return true }
                                                    return false }) {
                jobs = await model.store.jarvisJobs()
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { missing = false }
        }
    }

    private func askCount(_ d: JarvisDay) -> Int {
        d.turns.reduce(0) { n, turn in
            if case .say(let say) = turn, say.role == .user { return n + 1 }
            return n
        }
    }

    // MARK: - acting

    /// Every write lands the same way: say what went wrong if it did, then
    /// re-read. The record on the Pi is the one source of truth for what the day
    /// contains, so nothing here splices a copy into it by hand.
    @discardableResult
    private func settle(_ result: WriteResult, _ what: String) async -> Bool {
        switch result {
        case .busy: failed = "\(what): a turn is already in flight"
        case .failed: failed = "\(what): the collector did not take it"
        case .ok: failed = nil
        }
        await load()
        return result == .ok
    }

    private func send(_ text: String) async {
        failed = nil
        // Barge-in: a filed question ends the previous answer's voice mid-word,
        // and -- while voice is on -- warms the Mac for the reply now coming.
        speaker.cancel()
        if voice != .off { speaker.warm() }
        sentBaseline = doc.map(askCount) ?? 0
        sending = text
        if await settle(await model.store.jarvisSay(text: text), "not sent") == false {
            sending = nil
            sentBaseline = nil
        }
    }

    /// Filing work. **The one write that is never refused**, so a failure here is
    /// never the in-flight excuse: if this one comes back anything but ok, the
    /// collector is actually in trouble.
    private func file(_ text: String, _ title: String) async -> Bool {
        failed = nil
        return await settle(await model.store.jarvisJob(text: text, title: title),
                            "job not filed")
    }

    private func stop() async {
        await settle(await model.store.jarvisStop(), "not stopped")
    }

    private func stopJob(_ id: String) async {
        await settle(await model.store.jarvisJobStop(id: id), "job not stopped")
    }

    /// Folding the day so far into a digest.
    ///
    /// `busy` is the ordinary answer while a turn is in flight rather than a
    /// fault: compacting under a live session would race the runner's own rewrite
    /// of the session id. Nothing on screen waits for a model afterwards -- the
    /// digest is written by the talk lane on its next turn, which is why the
    /// meter goes to `—` and stays there until one has run.
    private func compact() async {
        await settle(await model.store.jarvisCompact(), "not compacted")
    }

    /// Optimistic, and safe to be: a refusal restores the record's own value on
    /// the re-read a beat later, and the alternative is a control that does not
    /// move until the Pi answers.
    private func changeModel(_ m: JarvisModelName) async {
        doc?.model = m
        await settle(await model.store.jarvisSetModel(m), "model unchanged")
    }

    private func changeEffort(_ e: JarvisEffort) async {
        doc?.effort = e
        await settle(await model.store.jarvisSetEffort(e), "effort unchanged")
    }
}

// MARK: - the day chip

/// A glyph and a word for anything that is not a quiet day: a strip of dates told
/// apart by hue alone would say nothing at all on a monochrome screen, and the
/// word is the channel that survives.
///
/// **The open day is not cyan.** The accent is spent on send; this one is
/// bracketed and bright, which is a shape and a weight rather than a hue.
private struct DayChip: View {
    var row: JarvisDaySummary
    var open: Bool
    var go: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            HStack(spacing: HT.s1) {
                if chatInFlight(queued: row.queued, status: row.status) {
                    Text("›").foregroundStyle(HT.caution)
                }
                if row.status == .error {
                    Text("×").foregroundStyle(HT.fault)
                }
                // `MM-DD`, taken by slicing, which is safe for exactly one
                // reason: a day id is already a local calendar day and not an
                // instant, so nothing here can name yesterday in the wrong
                // timezone the way slicing a timestamp would.
                Text(open ? "[\(short)]" : short)
                    .foregroundStyle(open || hovering ? HT.inkBright : HT.inkMid)
            }
            .font(HT.body)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(accessibility))
    }

    private var short: String {
        row.day.count >= 10 ? String(row.day.dropFirst(5)) : row.day
    }

    private var accessibility: String {
        if chatInFlight(queued: row.queued, status: row.status) { return "\(row.day) running" }
        if row.status == .error { return "\(row.day) failed" }
        return row.day
    }
}

// MARK: - the composer

/* The input line: one box, two lanes, and the difference stated out loud.
 *
 * Shaped after the chat composer -- a `$` sigil, a field reset to inherit
 * everything, Enter sends and Shift+Enter is a newline. It departs from it in
 * exactly one way, and that way is the feature this page exists for.
 *
 * **The field is not disabled while a turn is in flight.** The say route answers
 * 409 then and the job route never does, so the honest disabled control is
 * `send`, alone. Greying the box wholesale -- which a one-lane conversation must
 * -- would hide the work lane at precisely the moment it is worth reaching for.
 */
private struct JarvisComposer: View {

    /// A turn is in flight: `send` is refused and the model has already been read
    /// off the record by the runner.
    var busy: Bool
    /// **The collector did not answer, and this is not `busy`.** Offline is the
    /// case where neither lane can be reached, so every control here writes to a
    /// Pi that is not listening. The field itself goes dead, which is the one
    /// state where that is the honest thing to do.
    var offline: Bool
    var busyReason: String?
    var model: JarvisModelName
    var effort: JarvisEffort
    var ctx: JarvisContext?
    var onStop: (() -> Void)?
    var onSend: (String) -> Void
    /// Resolves true when the collector took the job, which is when the box is
    /// cleared. **Not the optimistic path `send` takes**: a filed job comes back
    /// as a card within the second, so there is nothing worth drawing in the
    /// meantime.
    var onJob: (String, String) async -> Bool
    var onModel: (JarvisModelName) -> Void
    var onEffort: (JarvisEffort) -> Void

    @State private var text = ""
    @State private var filing = false

    private var message: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HT.cw) {
                Text("$")
                    .font(HT.body)
                    .foregroundStyle(HT.prompt)
                    .frame(height: HT.row)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && !offline {
                        Text("ask jarvis, or file it as a job")
                            .font(HT.body)
                            .foregroundStyle(HT.inkFaint)
                            .frame(height: HT.row)
                            .allowsHitTesting(false)
                    }
                    PromptBox(text: $text, maxLength: jarvisTextMax, disabled: offline,
                              onSubmit: submit)
                        .accessibilityLabel(Text("Message Jarvis"))
                }
                .frame(height: HT.row * 2)
            }

            // The budget line: how much room is left in the box, then how much is
            // left in the day. One thing read at two scales, which is why the
            // meter is here and not in a panel of its own.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(busyReason ?? "\(text.count)/\(jarvisTextMax) · enter sends")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                Text(" · ").font(HT.body).foregroundStyle(HT.inkMid)
                ContextMeter(ctx: ctx)
                Spacer(minLength: 0)
            }
            .padding(.top, HT.s2)

            controls.padding(.top, HT.cw)
        }
        .padding(.horizontal, HT.cw2)
        .padding(.vertical, HT.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(HT.lineFaint).frame(height: 1) }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: HT.cw2) {
            // Which model answers, and how hard it thinks. Both are settings
            // rather than acts, and both are refused while a turn is in flight
            // because the runner has already read the record to build its argv.
            Listbox(label: "Model", value: model.rawValue,
                    options: JarvisModelName.allCases.map(\.rawValue),
                    disabled: busy || offline) { picked in
                onModel(JarvisModelName(rawValue: picked) ?? .sonnet)
            }

            Listbox(label: "Effort", value: effort.rawValue,
                    options: JarvisEffort.allCases.map(\.rawValue),
                    disabled: busy || offline) { picked in
                onEffort(JarvisEffort(rawValue: picked) ?? .medium)
            }

            Spacer(minLength: 0)

            // **Live whatever the talk lane is doing.** The work lane has its own
            // spool, its own lock and its own runner, and the job route never
            // answers 409 -- so this control is never refused, and drawing it as
            // though it could be would be a lie about the one thing that makes
            // two lanes worth having. Ink and not cyan.
            ChatTextButton(text: filing ? "[filing…]" : "[run as job]",
                           ink: (message.isEmpty || filing || offline) ? HT.inkFaint : HT.ink) {
                guard !message.isEmpty, !filing, !offline else { return }
                Task { await fileJob() }
            }

            if let onStop {
                ChatTextButton(text: "[stop]", ink: HT.inkMid, hoverInk: HT.caution,
                               action: onStop)
            }

            sendButton
        }
    }

    /// **The page's single cyan spend.** The one thing here worth calling this
    /// one is the act that puts a message in the day's conversation. Everything
    /// else on this page is ink, green, amber or red.
    private var sendButton: some View {
        let enabled = !busy && !message.isEmpty && !offline
        return Button(action: submit) {
            Text("send")
                .font(HT.body)
                .foregroundStyle(enabled ? HT.void : HT.inkDim)
                .padding(.horizontal, HT.cw2)
                .frame(height: HT.row2)
                .background(enabled ? HT.signal : Color.clear)
                .overlay { Rectangle().strokeBorder(enabled ? HT.signal : HT.line, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }

    private func submit() {
        guard !message.isEmpty, !busy, !offline else { return }
        let outgoing = message
        text = ""
        onSend(outgoing)
    }

    private func fileJob() async {
        // The first line, cut to a label. The whole prompt goes to the runner
        // either way.
        let title = String((message.split(separator: "\n", maxSplits: 1,
                                          omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
            .prefix(jarvisTitleMax))
        filing = true
        let filed = await onJob(message, title)
        filing = false
        if filed { text = "" }
    }
}

// MARK: - the small parts

/// A sentence about the page, never a control. `ink-mid` and not `ink-dim`:
/// every demotion in this dialect stops at the contrast floor, because
/// everything demoted here is a word rather than a rule.
struct JarvisNote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(HT.body)
            .foregroundStyle(HT.inkMid)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The frame with no top edge: the head's own bottom rule is the one between
/// them, and two rules there would be two pixels where the design has one.
private struct PanelBodyFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
