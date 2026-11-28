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
    /// A turn in flight uses blue and a failure uses red.
    var ink: Color = FocusInk.accent
}

struct JarvisWorkspace: View {
    let model: MailModel
    @Binding var tab: String
    @State private var openBrainDumpOnArrival = false
    @State private var draft = ""
    @State private var asJob = false

    var body: some View {
        if tab == ConsoleNav.overnight.id {
            OvernightTasksView(model: model, startInBrainDump: openBrainDumpOnArrival)
                .onAppear { openBrainDumpOnArrival = false }
        } else {
            JarvisTabView(model: model, draft: $draft, asJob: $asJob) {
                openBrainDumpOnArrival = true
                tab = ConsoleNav.overnight.id
            }
        }
    }
}

private struct JarvisTabView: View {

    var model: MailModel
    @Binding var draft: String
    @Binding var asJob: Bool
    let openBrainDump: () -> Void

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

    @State private var folded = false
    @State private var historyOpen = false
    @State private var todayID: String?
    @State private var filing = false
    @State private var focusToken = 0

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

    private var today: Bool { day == nil }

    private var live: Bool {
        guard let doc else { return false }
        return chatInFlight(queued: doc.queued, status: doc.status)
    }

    var body: some View {
        focusPage
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
    }

    // The chat owns its viewport so the composer stays reachable on long days.
    private var atStart: Bool {
        today && !unreachable && !live && sending == nil && failed == nil
            && doc?.status != .error && (doc?.turns.isEmpty ?? true)
            && (doc?.compactions.isEmpty ?? true)
    }

    private var dateLabel: String {
        let stamp = day ?? doc?.day
        if let stamp {
            guard let date = Self.dayFormatter.date(from: stamp) else { return stamp }
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @Environment(\.workspaceScale) private var scale

    private var focusPage: some View {
        Group {
            if atStart {
                GeometryReader { pane in
                    let narrow = pane.size.width < 650
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                dayHeading("Conversation", compact: false)
                                    .layoutPriority(1)
                                Spacer(minLength: 0)
                                FocusHero()
                                    .frame(width: min(pane.size.width * 0.32, 363 * scale),
                                           height: (narrow ? 115 : 167) * scale)
                                    .accessibilityHidden(true)
                            }
                            .padding(.leading, 8 * scale)
                            composer(expanded: true)
                                .padding(.top, (narrow ? 22 : 35) * scale)
                            HStack {
                                Button {
                                    draft = "Catch me up on the overnight work."
                                    asJob = false
                                    focusToken += 1
                                } label: { shortcutLabel("Review overnight work", symbol: "sunrise") }
                                .disabled(!draft.isEmpty)
                                BrainDumpButton(action: openBrainDump)
                                Spacer()
                                historyButton
                            }
                            .padding(.leading, 6 * scale)
                            .font(.system(size: 21 * scale))
                            .foregroundStyle(Color(white: 0.9))
                            .padding(.top, (narrow ? 25 : 40) * scale)
                        }
                        .frame(maxWidth: 1066)
                        .padding(.horizontal, narrow ? 22 : pane.size.width * 0.075)
                        .padding(.top, max(14, pane.size.height * (narrow ? 0.13 : 0.169)))
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                conversation
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(FocusInk.text)
    }

    private func dayHeading(_ title: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text(title)
                .font(.system(size: compact ? 25 : 48 * scale, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(dateLabel)
                .font(.system(size: compact ? 14 : 22 * scale))
                .foregroundStyle(Ground.shared.glass ? HT.ink : Color(white: 0.76))
            if today && presence.word != "idle" {
                Text(presence.word.capitalized).font(.caption.weight(.medium))
                    .foregroundStyle(presence.ink)
            }
        }
    }

    private func shortcutLabel(_ title: String, symbol: String) -> some View {
        let glass = Ground.shared.glass
        return Label(title, systemImage: symbol)
            .padding(.horizontal, glass ? 11 * scale : 0)
            .padding(.vertical, glass ? 6 * scale : 0)
            .background(glass ? Color.black.opacity(0.36) : .clear, in: Capsule())
    }

    private var historyButton: some View {
        Button { historyOpen = true } label: {
            shortcutLabel("History", symbol: "clock").padding(.vertical, 4)
        }
        .accessibilityLabel("Conversation history")
        .popover(isPresented: $historyOpen, arrowEdge: .bottom) { historyList }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation history").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    historyRow(nil, title: "Today", detail: "Current conversation")
                    ForEach(rows ?? []) { row in
                        if row.day != todayID {
                            let activity = chatInFlight(queued: row.queued, status: row.status)
                                ? "Running" : (row.status == .error ? "Failed" : "")
                            historyRow(row.day, title: row.day, detail: [activity, row.preview]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                        }
                    }
                    if rows == nil { Text("History unavailable").font(.caption).padding(8) }
                    else if rows?.allSatisfy({ $0.day == todayID }) == true {
                        Text("No earlier conversations").font(.caption).padding(8)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 305, height: 300)
    }

    private func historyRow(_ key: String?, title: String, detail: String) -> some View {
        Button {
            historyOpen = false
            guard key != day else { return }
            speaker.cancel()
            day = key
            doc = nil
            missing = false
            unreachable = false
            jobs = nil
            folded = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if day == key { Image(systemName: "checkmark") }
            }.padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                dayHeading(today ? "Conversation" : "Archived conversation", compact: true)
                Spacer()
                BrainDumpButton(action: openBrainDump)
                historyButton.font(FocusInk.body).foregroundStyle(FocusInk.secondary)
                if !missing && !unreachable {
                    Button {
                        folded.toggle()
                    } label: {
                        Image(systemName: folded ? "chevron.down" : "chevron.up")
                    }
                    .accessibilityLabel(folded ? "Expand the transcript" : "Collapse the transcript")
                    .help(folded ? "Expand transcript" : "Collapse transcript")
                    .foregroundStyle(FocusInk.secondary)
                }
                FocusHero(activity: today ? presence.activity : 0,
                          ink: today && presence.word != "idle" ? presence.ink : .white)
                    .frame(width: 72, height: 44)
                    .accessibilityHidden(true)
            }
            Divider().overlay(FocusInk.line)
            if folded {
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if missing { Text("No saved conversation for this day.").padding(.vertical) }
                            else if unreachable { Text("The collector is unavailable.").padding(.vertical) }
                            else if !today && doc == nil { ProgressView().controlSize(.small).padding() }
                            else {
                                JarvisTranscript(doc: doc, jobs: jobs, sending: today ? sending : nil,
                                                 failed: today ? failed : nil, readOnly: !today,
                                                 onCompact: { Task { await compact() } },
                                                 onStopJob: { id in Task { await stopJob(id) } })
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .glassReadingPane()
                    .onChange(of: sending) { _, newValue in
                        if newValue != nil && today { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear { if today { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
            if today { composer(expanded: false).padding(.top, 10) }
            else {
                HStack {
                    Text("Read only").foregroundStyle(FocusInk.secondary)
                    Spacer()
                    Button("Back to today") {
                        day = nil
                        doc = nil
                        missing = false
                        folded = false
                    }
                }.font(.system(size: 13)).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private func composer(expanded: Bool) -> some View {
        let unit = expanded ? scale : min(scale, 0.82)
        let shape = RoundedRectangle(cornerRadius: 17 * unit, style: .continuous)
        return VStack(alignment: .leading, spacing: 12 * unit) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(asJob ? "Describe the job…" : "Message Jarvis")
                        .foregroundStyle(FocusInk.secondary)
                        .font(.system(size: 22 * unit))
                        .allowsHitTesting(false)
                }
                PromptBox(text: $draft, maxLength: jarvisTextMax, disabled: unreachable,
                          focusToken: focusToken, inputFont: .systemFont(ofSize: 22 * unit),
                          fieldLabel: "Message Jarvis",
                          onSubmit: submit)
            }.frame(height: (expanded ? 82 : 52) * unit)
            HStack(spacing: 16 * unit) {
                Menu {
                    Section("Model") {
                        Picker("Model", selection: Binding(get: { doc?.model ?? .sonnet }, set: { m in Task { await changeModel(m) } })) {
                            ForEach(JarvisModelName.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(value) }
                        }
                    }
                    Section("Effort") {
                        Picker("Effort", selection: Binding(get: { doc?.effort ?? .medium }, set: { e in Task { await changeEffort(e) } })) {
                            ForEach(JarvisEffort.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(value) }
                        }
                    }
                    Divider()
                    ContextMeter(ctx: doc?.context)
                } label: {
                    HStack(spacing: 12 * unit) {
                        Text((doc?.model ?? .sonnet).rawValue.capitalized)
                        Image(systemName: "chevron.down").font(.system(size: 13 * unit)).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 13 * unit).frame(height: 42 * unit)
                    .overlay { RoundedRectangle(cornerRadius: 9 * unit).strokeBorder(Color.white.opacity(0.23)) }
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                .disabled(unreachable || live || sending != nil)
                .accessibilityLabel("Response settings")
                .accessibilityValue((doc?.model ?? .sonnet).rawValue.capitalized)
                Divider().frame(height: 22 * unit)
                HStack(spacing: 7 * unit) {
                    Toggle("As job", isOn: $asJob)
                        .labelsHidden().toggleStyle(.switch).tint(FocusInk.switchTint)
                        .accessibilityLabel("As job")
                    Text("As job")
                        .onTapGesture { asJob.toggle() }
                        .accessibilityHidden(true)
                }
                .disabled(unreachable || filing)
                .onChange(of: asJob) { _, _ in focusToken += 1 }
                Spacer(minLength: 2)
                if draft.count > 3750 { Text("\(draft.count)/4000").font(.caption2) }
                if live {
                    Button("Stop") { Task { await stop() } }.foregroundStyle(FocusInk.accent)
                }
                Button(action: toggleVoice) {
                    Image(systemName: voice == .off ? "speaker.wave.3" : "speaker.wave.3.fill")
                        .font(.system(size: 25 * unit))
                        .frame(width: 42 * unit, height: 42 * unit)
                }
                .foregroundStyle(voice == .off ? Color(white: 0.84) : FocusInk.accent)
                .accessibilityLabel("Spoken replies")
                .accessibilityValue(voiceLabel)
                .help("Spoken replies: \(voiceLabel). Click to cycle.")
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 23 * unit, weight: .medium))
                        .foregroundStyle(Color(white: 0.09))
                        .frame(width: 47 * unit, height: 47 * unit)
                        .background(canSubmit ? .white : Color(white: 0.73), in: Circle())
                }
                .buttonStyle(HTPressStyle())
                .accessibilityLabel(asJob ? "Run as job" : "Send message")
                .disabled(!canSubmit)
            }
            .font(.system(size: 19 * unit))
            if filing || (voice != .off && speaker.unavailable) {
                Text(filing ? "Filing job…" : "Spoken replies unavailable").font(.caption)
            }
        }
        .padding(21 * unit)
        .background(FocusInk.conversationWell, in: shape)
        .overlay { shape.strokeBorder(Ground.shared.glass ? HT.lineBright : Color.white.opacity(0.72), lineWidth: 1).allowsHitTesting(false) }
    }

    private var voiceLabel: String {
        switch voice {
        case .off: return "Off"
        case .live: return "As replies arrive"
        case .whole: return "After each reply"
        }
    }

    private var canSubmit: Bool {
        today && !unreachable && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (asJob ? !filing : (!live && sending == nil))
    }

    private func submit() {
        guard canSubmit else { return }
        let original = draft
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if asJob {
            filing = true
            let title = String(text.prefix(while: { !$0.isNewline }).prefix(jarvisTitleMax))
            Task {
                let filed = await file(text, title)
                filing = false
                if filed && draft == original { draft = ""; asJob = false }
            }
        } else {
            sending = text
            draft = ""
            Task {
                let accepted = await send(text)
                if !accepted && draft.isEmpty { draft = original }
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
        let requestedDay = day
        do {
            let got = today
                ? try await model.store.jarvisToday()
                : try await model.store.jarvisDay(day ?? "")
            guard !Task.isCancelled, day == requestedDay else { return }
            if today { todayID = got?.day ?? Self.dayFormatter.string(from: Date()) }
            doc = got
            // A 404 is a fact about the date and a transport failure is not.
            // Today can never be missing -- the collector mints it -- so this
            // only ever fires on a date reached from the strip.
            missing = (got == nil && !today)
            // **And nil on TODAY means the collector did not answer**, which is a
            // different sentence from "nothing has been said today" and must not
            // be drawn as it.
            unreachable = (got == nil && today)
            if today, let got, let baseline = sentBaseline, askCount(got) > baseline {
                sending = nil
                sentBaseline = nil
            }
            // Only when the day actually has a card to fill in. A day of pure
            // conversation is the ordinary case, and it has no business asking a
            // second route once a second for a list it will not draw.
            if let got, got.turns.contains(where: { if case .job = $0 { return true }
                                                    return false }) {
                let records = await model.store.jarvisJobs()
                if !Task.isCancelled && day == requestedDay { jobs = records }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, day == requestedDay else { return }
            unreachable = true
            missing = false
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

    private func send(_ text: String) async -> Bool {
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
            return false
        }
        return true
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
