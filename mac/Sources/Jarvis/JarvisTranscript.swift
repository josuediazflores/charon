import SwiftUI

/* The transcript, and the four kinds of thing that land in it.
 *
 * **A transcript has to answer "who said this" on every line**, and in a
 * monospace console there are three channels for that: position, ink and a
 * sigil. Ink already says how healthy a thing is and the green `$` is already
 * the prompt, so position is what is left: the human's turn is a tinted card at
 * the right margin, borrowed whole from the chat list's session card, and the
 * answer is prose on the ground at the left.
 */

/// Which band a percentage is in. The thresholds are the collector's own -- it
/// writes a notice turn on crossing 50, 75 and 90 -- so the meter and the
/// notices agree about when the day changed instead of each having an opinion
/// about it.
enum ContextBand {
    case quiet, caution, fault

    init(pct: Double) {
        if pct < 50 { self = .quiet } else if pct <= 75 { self = .caution } else { self = .fault }
    }

    var ink: Color {
        switch self {
        case .quiet: return HT.inkMid
        case .caution: return HT.caution
        case .fault: return HT.fault
        }
    }
}

/// The non-colour channel for a job. A glyph and a word, always both, so a card
/// survives being printed 1-bit -- and so `done` and `failed`, the two a reader
/// actually scans for, are told apart without hue.
///
/// **`stopped` is not drawn as a fault.** A job you cancelled did what you
/// asked; red there would put something on screen that nobody has to look into.
struct JobWord {
    var glyph: String
    var word: String
    var ink: Color

    init(_ state: JarvisJobState) {
        switch state {
        // `~` rather than a dot, the glyph the chat transcript's `~queued` pill
        // already uses for this state one tab over.
        case .queued: self = JobWord(glyph: "~", word: "queued", ink: HT.caution)
        case .running: self = JobWord(glyph: "›", word: "running", ink: HT.caution)
        case .done: self = JobWord(glyph: "+", word: "done", ink: HT.nominal)
        case .error: self = JobWord(glyph: "×", word: "failed", ink: HT.fault)
        case .stopped: self = JobWord(glyph: "-", word: "stopped", ink: HT.inkMid)
        }
    }

    private init(glyph: String, word: String, ink: Color) {
        self.glyph = glyph
        self.word = word
        self.ink = ink
    }
}

// MARK: - the context meter

/* Context, in the composer's control row beside the character count.
 *
 * **It belongs on the budget line and nowhere else.** `n/4000` already reads as
 * "how much room is left in this box"; the day's context is the same sentence
 * one level up, and whoever is watching one is watching both.
 *
 * **A dash, never a guess.** Null context means the collector has had no result
 * event to take a number from; `stale` means a fold has happened and no turn has
 * run since, so the last reading describes a session that no longer exists.
 * Drawing the stale number would be worse than estimating -- it would be precise
 * and wrong. A dimmed number is still read as a number, so it is not dimmed, it
 * is gone.
 *
 * **Never "% remaining".** The reading is what the *last* turn sent, so the next
 * one will be larger: a floor, and the wording says so.
 */
struct ContextMeter: View {
    var ctx: JarvisContext?

    var body: some View {
        if let ctx, !ctx.stale {
            let band = ContextBand(pct: ctx.pct)
            // A second mark rather than a different one: the escalation is more
            // of the same thing, and `×` is this console's word for failed --
            // which a filling context is not. Quiet carries no word at all: a
            // meter that shouted at 12% would have nothing left to say at 82%.
            let glyph = band == .fault ? "!! " : band == .caution ? "! " : ""
            let word = band == .fault ? " nearly full" : band == .caution ? " filling" : ""
            Text("\(glyph)context \(Int(ctx.pct))%\(word)")
                .font(HT.body)
                .foregroundStyle(band.ink)
                .lineLimit(1)
                .fixedSize()
        } else {
            Text("context — "
                 + ((ctx?.stale ?? false)
                    ? "· folded, nothing measured since"
                    : "· nothing measured yet"))
                .font(HT.body)
                .foregroundStyle(HT.inkFaint)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - the turns

/// The human's turn: a tinted card at the right margin.
///
/// **The block is right-aligned and the text inside it is not.** The position
/// says who spoke; ragging the right edge of the prose would say the same thing
/// a second time and charge the reader for it. ~62 cells at the widest: past
/// about that width a card stops reading as a turn and starts reading as the
/// page. The clock sits outside it, hard against its left edge, so the two are
/// one object rather than a reading at a far margin.
struct JarvisAskTurn: View {
    var text: String
    var at: String?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: HT.cw) {
            Spacer(minLength: 0)
            Group {
                if let at, !at.isEmpty {
                    Text(Fmt.hhmm(at)).font(HT.body).foregroundStyle(HT.inkMid)
                } else {
                    // No time yet: this is the optimistic copy of something the
                    // Pi has not confirmed. `--:--` there would be a stated
                    // unknown where the truth is "not yet".
                    Color.clear
                }
            }
            .frame(width: HT.cw * 5, height: HT.row, alignment: .trailing)

            // ~62 cells at the widest. A message is usually one line and
            // occasionally a pasted unit file; past about that width a card stops
            // reading as a turn and starts reading as the page.
            MaxWidth(limit: HT.cw * 62) {
                Text(text)
                    .font(HT.body)
                    .foregroundStyle(HT.inkBright)
                    .lineSpacing(HT.row - 11)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, HT.s1)
                    .padding(.horizontal, HT.cw2)
                    .background(hovering ? HT.surface3 : HT.surface2)
                    // mail's own radius step, so the three dialects round
                    // identically rather than each inventing a curve.
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onHover { hovering = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, HT.row)
    }
}

/// The answer: prose on the ground at the left margin, full measure, no box.
///
/// The clock lives in the receipts under the answer rather than in a gutter
/// beside it. A gutter would inset the prose from the margin that is doing the
/// work of saying who spoke -- and the card above has already drawn the turn
/// boundary a clock column would otherwise be earning its width with.
struct JarvisAnswerTurn: View {
    var turn: JarvisSayTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tools = turn.tools, !tools.isEmpty { ToolLines(tools: tools) }
            if !turn.text.isEmpty { AnswerBody(text: turn.text) }
            TurnMeta {
                Text(meta).font(HT.body).foregroundStyle(HT.inkMid)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }

    private var meta: String {
        var parts: [String] = []
        if !turn.at.isEmpty { parts.append(Fmt.hhmm(turn.at)) }
        parts.append(turn.model?.rawValue ?? "—")
        if let elapsed = turn.elapsedS { parts.append("\(String(format: "%.1f", elapsed))s") }
        return parts.joined(separator: " · ")
    }
}

/// A job, as a card in the transcript, updated in place.
///
/// **In the transcript and not in a sidebar.** A job was handed off at a point in
/// the conversation and what it found is part of what happened that day; the
/// collector rewrites the turn's state as the record moves, so this card goes
/// running → done where it stands rather than being replaced by a new one
/// further down. `at` is when it was filed and never moves, for the same reason.
///
/// **No rail while it runs.** A rail means *this block is the thing in trouble*,
/// and a job doing what it was asked to do is not; the glyph and the word already
/// say which state it is in. Only a failure earns one.
struct JarvisJobCard: View {
    var turn: JarvisJobTurn
    /// The runner's own record, or nil when the jobs route has not answered yet
    /// or the collector's cap of 50 has aged the job out. **The card never waits
    /// on this to say what state it is in**, only to say what came back.
    var job: JarvisJob?
    var onStop: (String) -> Void

    /// The turn is the collector's copy and the record is the runner's: the same
    /// fact written by two processes, and the record is the fresher of the two by
    /// up to one poll.
    private var state: JarvisJobState { job?.state ?? turn.state }
    private var running: Bool { state == .running || state == .queued }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            outcome(for: state)
            if let elapsed = job?.elapsedS {
                Text("\(String(format: "%.1f", elapsed))s")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .padding(.top, HT.s1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, HT.s1)
        .padding(.horizontal, HT.cw2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HT.surface2)
        .overlay(alignment: .leading) {
            if state == .error { Rectangle().fill(HT.fault).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, HT.row)
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            // What it is before it says anything about itself.
            Text("job").font(HT.body).foregroundStyle(HT.inkMid)
            Text(turn.title.isEmpty ? "untitled job" : turn.title)
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            let word = JobWord(state)
            Text("\(word.glyph) \(word.word)")
                .font(HT.body)
                .foregroundStyle(word.ink)
                .lineLimit(1)
                .fixedSize()

            Text(Fmt.hhmm(turn.at))
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .lineLimit(1)
                .fixedSize()

            // Only while there is something to stop, and stopping one job says
            // nothing about the conversation: two lanes, two locks, two stop
            // flags, and three jobs can be running while only one is regretted.
            if running {
                ChatTextButton(text: "[stop]", ink: HT.inkMid, hoverInk: HT.caution,
                               label: "Stop \(turn.title.isEmpty ? "this job" : turn.title)") {
                    onStop(turn.jobId)
                }
            }
        }
        .frame(height: HT.row)
    }

    /// What came back, landing in the card it was asked from. A stopped job has
    /// neither a result nor a reason and draws nothing here -- the state word
    /// above is the whole story, and inventing a line for it would be the console
    /// saying something the record did not.
    @ViewBuilder
    private func outcome(for state: JarvisJobState) -> some View {
        if let error = job?.error {
            Text(error)
                .font(HT.body)
                .foregroundStyle(HT.fault)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, HT.s1)
        } else if let result = job?.result, !result.isEmpty {
            // Departure Mono at 11 here and not the answer's 13: a result is
            // scanned for what it found, and the one element that changes face is
            // the one somebody sits and reads.
            Text(result)
                .font(HT.body)
                .foregroundStyle(HT.ink)
                .lineSpacing(HT.row - 11)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, HT.s1)
        } else if running {
            // Two different facts and two different sentences: a queued job is on
            // disk and a running one is on a CPU. They share a colour because
            // they are one thing to a reader waiting on them, and the words are
            // what tell them apart.
            Text(state == .queued
                 ? "filed · its runner has not picked it up yet"
                 : "running on the pi · the conversation is not waiting for it")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, HT.s1)
        }
    }
}

/// A notice: a line in his voice, carrying the act it is about.
///
/// **Never model-generated and never fabricated here.** The collector writes the
/// wording when context crosses 50, 75 or 90, once per crossing, with the number
/// already in the sentence.
///
/// **It carries a real control, not a suggestion.** A line that read "say the
/// word" with no way to say it would be a notice about a feature rather than an
/// offer of one. Spent once it has been acted on: a fold recorded after this line
/// was written is this line answered.
struct JarvisNotice: View {
    var turn: JarvisNoticeTurn
    var folded: Bool
    var onCompact: () -> Void

    /// The reading is frozen at the crossing, so the tone is too: this is the
    /// record of a moment and not a second opinion about where the day stands.
    private var ink: Color {
        ContextBand(pct: turn.pct) == .fault ? HT.fault : HT.caution
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            Text("!").font(HT.body).foregroundStyle(ink)
            Text(turn.text)
                .font(HT.body)
                .foregroundStyle(ink)
                .lineSpacing(HT.row - 11)
                .fixedSize(horizontal: false, vertical: true)

            if turn.action == "compact" {
                if folded {
                    Text("· folded").font(HT.body).foregroundStyle(HT.inkMid)
                } else {
                    // Amber because it belongs to the amber line that raised it,
                    // and because folding the day is a thing you do when
                    // something is filling up rather than the thing this page is
                    // for. Never the cyan: that is spent on send.
                    ChatTextButton(text: "[compact]", ink: ink, hoverInk: HT.inkBright,
                                   action: onCompact)
                }
            }

            Spacer(minLength: 0)

            Text(Fmt.hhmm(turn.at))
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

/// The fold, drawn where it happened.
///
/// **After a compaction the transcript and the context are no longer the same
/// object**, and this line is the only place a reader can learn that. The turns
/// above it are still the record of the day; what gets *sent* from here on is a
/// digest plus whatever came after. It says what was folded and not what was
/// lost, because nothing was.
struct JarvisFoldLine: View {
    var fold: JarvisCompaction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            Rectangle()
                .fill(HT.line)
                .frame(width: HT.cw3, height: 1)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
            Text("folded \(fold.turnsFolded) "
                 + (fold.turnsFolded == 1 ? "turn" : "turns")
                 + " · everything above is still here, the context is not")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(Fmt.hhmm(fold.at))
                .font(HT.body)
                .foregroundStyle(HT.inkFaint)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HT.row)
    }
}

/// The in-flight turn: whatever has been said so far, with a cursor on the end.
struct JarvisStreaming: View {
    var partial: String
    var queued: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                StatusPill(text: queued ? "~queued" : "~running", tone: .caution, glyph: false)
                Text(queued ? "filed · waiting for the runner" : "answering")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StreamingBody(text: partial)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HT.row)
    }
}

/// A turn that did not become an answer, and a write the collector refused.
struct JarvisFail: View {
    var pill: String
    var message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            StatusPill(text: pill, tone: .fault, glyph: false)
            Text(message)
                .font(HT.body)
                .foregroundStyle(HT.fault)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HT.row)
    }
}

// MARK: - the scrollback

/// One row of the day: a turn or a fold, with the position it arrived in.
///
/// The two are merged because they are written by two different acts -- a runner
/// appends turns, the compact route appends folds -- and the reader needs them
/// interleaved, since the whole meaning of a fold is *where in the day it
/// happened*. `order` is what makes the sort stable: Swift's `sorted` is not,
/// and a fold written in the same second as the turn that provoked it has to stay
/// after it.
private struct TimelineRow: Identifiable {
    var id: Int { order }
    var at: String
    var order: Int
    var turn: JarvisTurn?
    var fold: JarvisCompaction?
}

struct JarvisTranscript: View {

    var doc: JarvisDay?
    var jobs: [JarvisJob]?
    /// A message this window sent that the Pi has not confirmed yet.
    var sending: String?
    var failed: String?
    var onCompact: () -> Void
    var onStopJob: (String) -> Void

    private var live: Bool {
        guard let doc else { return false }
        return chatInFlight(queued: doc.queued, status: doc.status)
    }

    private var timeline: [TimelineRow] {
        let turns = doc?.turns ?? []
        let folds = doc?.compactions ?? []
        var rows: [TimelineRow] = turns.enumerated().map { index, turn in
            TimelineRow(at: turn.at, order: index, turn: turn, fold: nil)
        }
        rows += folds.enumerated().map { index, fold in
            TimelineRow(at: fold.at, order: turns.count + index, turn: nil, fold: fold)
        }
        return rows.sorted { a, b in a.at == b.at ? a.order < b.order : a.at < b.at }
    }

    /// Whether a fold happened after a given moment -- i.e. whether the notice
    /// sitting there has already been acted on.
    private func foldedAfter(_ at: String) -> Bool {
        (doc?.compactions ?? []).contains { $0.at > at }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if timeline.isEmpty, sending == nil, !live {
                Text("nothing said today · talk reads this pi, and jobs do the changing")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(timeline) { row in
                if let turn = row.turn {
                    line(turn)
                } else if let fold = row.fold {
                    JarvisFoldLine(fold: fold)
                }
            }

            // Before the record catches up, what this window typed is the only
            // copy of it there is.
            if let sending { JarvisAskTurn(text: sending, at: nil) }

            if live {
                JarvisStreaming(partial: doc?.partial ?? "", queued: doc?.queued ?? false)
            }

            // The runner's own reason, in the transcript rather than in a banner:
            // it is a thing that happened at a point in the day, and the box
            // under it is usable again.
            if doc?.status == .error, !live {
                JarvisFail(pill: "×turn", message: doc?.error ?? "the session failed")
            }

            if let failed { JarvisFail(pill: "×write", message: failed) }

            // The blank last row. A real row rather than padding on the
            // container: padding below the last line is padding scrolled past,
            // which lands an answer's final line hard against the frame.
            Color.clear.frame(height: HT.row)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HT.cw2)
        .padding(.top, HT.row)
    }

    /// One turn of the timeline.
    ///
    /// **A kind this console does not recognise is skipped, never thrown on**,
    /// which the contract requires by name: the collector ships separately from
    /// this app and will grow a fourth kind while a window is open, and a day
    /// that refused to render because one line of it was new would lose the whole
    /// day to something purely additive.
    @ViewBuilder
    private func line(_ turn: JarvisTurn) -> some View {
        switch turn {
        case .say(let say):
            if say.role == .user {
                JarvisAskTurn(text: say.text, at: say.at)
            } else {
                JarvisAnswerTurn(turn: say)
            }
        case .job(let job):
            JarvisJobCard(turn: job,
                          job: jobs?.first { $0.id == job.jobId },
                          onStop: onStopJob)
        case .notice(let notice):
            JarvisNotice(turn: notice,
                         folded: foldedAfter(notice.at),
                         onCompact: onCompact)
        case .unknown:
            EmptyView()
        }
    }
}
