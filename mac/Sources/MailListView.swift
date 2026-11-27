import SwiftUI

/* The inbox, and what is known about the mailbox above it.
 *
 * Ported from the web console's mail view.
 *
 * **The row is three lines and the third one is not the message.** Line one and
 * two are what the sender wrote; line three is what a session on the Pi made of
 * it, and it is dim, chipped and visibly second. Nothing the machine wrote is
 * ever allowed to sit where the sender's own words would.
 *
 * **The unread dot is the channel and the ink is the reinforcement**, never the
 * other way round: a read row printed in one bit is still told apart from an
 * unread one by a missing dot.
 */

/// Urgency as a dot with a word behind it. Level 0 keeps no mark at all, for
/// the reason it never had one: "ignorable" is the absence of a claim rather
/// than a claim of its own.
private func listUrgency(_ level: Int?) -> (word: String, tone: Color)? {
    switch level {
    case 3: return ("needs today", M.fault)
    case 2: return ("this week", M.caution)
    case 1: return ("whenever", M.inkDim)
    default: return nil   // 0 and nil both draw nothing, for different reasons
    }
}

/// What the newest send record says, in a word. The word IS the channel: no
/// colour is spent on any of the three, and a reply that failed to go out reads
/// as failed on a black-and-white printout.
func outboxWord(_ status: OutboxStatus) -> String {
    switch status {
    case .queued: return "reply queued"
    case .sent: return "replied"
    case .error: return "send failed"
    }
}

// MARK: - the health strip

/// SourcePanel's whole job, in the mail dialect.
///
/// `standby` draws nothing here on purpose: never-configured is not in trouble,
/// and the empty state below says what to do about it instead. Drawing both
/// would be the page saying the same thing twice in two voices.
struct HealthStrip: View {
    let health: Health

    var body: some View {
        if health.level != .live, health.level != .standby,
           health.pill != nil || health.note != nil {
            let fault = health.level == .failed
            let caution = health.level == .stale
            let tone: Color = fault ? M.fault : (caution ? M.caution : M.inkMid)

            HStack(alignment: .top, spacing: 8) {
                Icon(name: fault ? .fault : (caution ? .alert : .unread), size: 14)
                    .foregroundStyle(tone)
                    .padding(.top, 2)

                // A glyph as well as a hue, always: the strip has to survive
                // being printed in one bit.
                (Text(health.pill ?? "").foregroundStyle(tone)
                    + Text(health.pill != nil && health.note != nil ? " · " : "")
                        .foregroundStyle(M.inkMid)
                    + Text(health.note ?? "").foregroundStyle(M.inkMid))
                    .font(Face.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                .fill(fault ? M.faultWash : (caution ? M.cautionWash : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                .strokeBorder(fault ? M.fault : (caution ? M.caution : M.line), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - the counts

/// Four numbers and when the poller last spoke to Gmail. Dim, with dividers:
/// this is bookkeeping about the box, and the rows under it are the box.
struct CountsLine: View {
    let counts: MailCounts?
    let lastPollAt: String?
    let dim: Bool

    var body: some View {
        // Recomputed on every repaint like every other relative time here, and
        // a mailbox nobody has polled yet says so rather than printing an age
        // it does not have.
        let polled = lastPollAt.map { "polled \(Fmt.relTime($0)) ago" } ?? "never polled"

        let totals = HStack(spacing: 6) {
            if let counts {
                pair(counts.unread, "unread")
                sep
                pair(counts.urgent, "urgent")
                sep
                pair(counts.triagePending, "to triage")
                sep
                pair(counts.outboxQueued, "queued")
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                totals
                Text(polled).foregroundStyle(M.inkDim)
            }
            VStack(alignment: .leading, spacing: 3) {
                totals
                Text(polled).foregroundStyle(M.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Face.body)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var sep: some View {
        Text("·").foregroundStyle(M.lineStrong)
    }

    private func pair(_ n: Int, _ label: String) -> some View {
        (Text(Fmt.num(n)).foregroundStyle(dim ? M.inkDim : M.inkMid)
            + Text(" " + label).foregroundStyle(M.inkDim))
            .fixedSize()
    }
}

// MARK: - the row

struct MailRow: View {
    let m: MailMessageSummary
    let dim: Bool
    let selected: Bool
    let model: MailModel

    @State private var hover = false
    /// Archiving takes a message out of the inbox and there is no undo, so what
    /// replaces the control says the thing is done rather than offering a way
    /// back the Pi does not have. A refusal flashes for two seconds.
    @State private var flashFailed = false

    private var gone: Bool { model.isArchived(m.key) }
    private var unread: Bool { model.unread(m) }
    /// A stale list demotes every row, and the dot is what keeps the unread
    /// ones legible through it.
    private var strong: Bool { unread && !dim && !gone }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button {
                model.selection = m.key
            } label: {
                open
            }
            .buttonStyle(.plain)

            // A reserved column rather than an overlay, so a row that is not
            // being pointed at is exactly as wide as one that is.
            archiveColumn
                .padding(.top, 10)
                .padding(.leading, 2)
                .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .fill(selected ? M.raised : (hover ? M.surface : .clear))
        )
        // Cyan is selection in this console and it says nothing else; here it
        // is a rail rather than a wash, which leaves CONFIRM SEND the loudest
        // thing on the page -- as it must be. (Cyan, use 1 of 2.)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(M.select).frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: M.r, style: .continuous))
        .animation(M.move, value: hover)
        .animation(M.move, value: selected)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    // MARK: line by line

    private var open: some View {
        HStack(alignment: .top, spacing: 10) {
            lead
            Avatar(who: m.from, dim: dim)
            VStack(alignment: .leading, spacing: 0) {
                top
                subject
                if note { noteLine }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // **One element, one label.** A label on a container whose children are
        // elements too does not replace them: it is prepended to each, so a row
        // with eight leaves in it was read out eight times over -- the whole
        // sentence, then the whole sentence again, before VoiceOver reached the
        // next message. `ignore` collapses the row's parts into the one thing
        // they add up to, which is what `spoken` already is. The archive key is
        // outside this button and stays its own element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
    }

    private var lead: some View {
        Group {
            if gone {
                Icon(name: .archive, size: 12).foregroundStyle(M.inkDim)
            } else if unread {
                Circle()
                    .fill(dim ? M.inkMid : M.accent)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 12)
        .padding(.top, 6)
        // Said in words by `spoken`, so the shape is decoration.
        .accessibilityHidden(true)
    }

    private var top: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(m.from)
                .font(.system(size: 13, weight: strong ? .semibold : .regular))
                .foregroundStyle(fromInk)
                .lineLimit(1)
                .truncationMode(.tail)

            marks

            if let urg = listUrgency(m.urgency) {
                Circle()
                    .fill(dim && urg.tone != M.inkDim ? M.inkMid : urg.tone)
                    .frame(width: 6, height: 6)
                    .help(urg.word)
            }

            Spacer(minLength: 4)

            if let date = m.date {
                Text(Fmt.relTime(date))
                    .font(Face.body)
                    .monospacedDigit()
                    .foregroundStyle(M.inkDim)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// The facts that are not worth a word: what is attached, what he starred,
    /// whether a reply is already drafted. And one that is worth a word and
    /// cannot be left where the word is -- a send that failed is reported on
    /// line three, which the row-note setting can turn off, and nothing else
    /// would say it happened.
    private var marks: some View {
        HStack(spacing: 5) {
            if m.attachmentsN > 0 {
                HStack(spacing: 2) {
                    Icon(name: .clip, size: 12)
                    if m.attachmentsN > 1 {
                        Text("\(m.attachmentsN)").font(Face.body).monospacedDigit()
                    }
                }
                .help("\(m.attachmentsN) attachment\(m.attachmentsN == 1 ? "" : "s")")
            }
            if m.flagged { Icon(name: .star, size: 12).help("starred") }
            if m.hasDraft { Icon(name: .pencil, size: 12).help("reply drafted") }
            if m.outboxStatus == .error {
                Icon(name: .fault, size: 12).help(outboxWord(.error))
            }
        }
        .foregroundStyle(M.inkDim)
        // Every one of these is a word in `spoken` as well.
        .accessibilityHidden(true)
    }

    private var subject: some View {
        Text(m.subject)
            .font(.system(size: 13))
            .foregroundStyle(subjectInk)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 1)
    }

    /// Line three exists when there is something on it. A message the triage
    /// worker has not reached yet says so, because an empty third line and a
    /// message nobody has read are the same picture otherwise.
    private var note: Bool {
        ConsoleSettings.shared.rowNote
            && (!m.tags.isEmpty || m.summaryLine != nil || m.outboxStatus != nil || !m.hasAi)
    }

    private var noteLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(m.tags, id: \.self) { Tag(text: $0, dim: dim) }
            if let status = m.outboxStatus { Tag(text: outboxWord(status), dim: dim) }
            Text(m.summaryLine ?? (m.hasAi ? "" : "not triaged yet"))
                .font(Face.body)
                .foregroundStyle(M.inkDim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.top, 3)
    }

    private var archiveColumn: some View {
        Group {
            if gone {
                Text("archived")
                    .font(Face.body)
                    .foregroundStyle(M.inkDim)
                    .lineLimit(1)
                    .padding(.top, 4)
            } else {
                IconKey(icon: flashFailed ? .fault : .archive,
                        label: flashFailed ? "not archived" : "archive",
                        help: flashFailed
                            ? "not archived · the collector did not take it"
                            : "archive",
                        tone: flashFailed ? M.fault : nil) {
                    Task {
                        let ok = await model.archive(m.key)
                        if !ok {
                            flashFailed = true
                            try? await Task.sleep(for: .seconds(2))
                            flashFailed = false
                        }
                    }
                }
                // Hidden until the row is pointed at, and its column reserved
                // either way. Kept visible while it is flashing a refusal: a
                // failure the cursor walked away from would never be read.
                .opacity(hover || flashFailed ? 1 : 0)
                .animation(M.move, value: hover)
            }
        }
    }

    // MARK: ink

    private var fromInk: Color {
        if dim { return strong ? M.inkMid : M.inkDim }
        if gone { return M.inkDim }
        return strong ? M.inkBright : M.inkMid
    }

    private var subjectInk: Color {
        if dim || gone { return M.inkDim }
        return strong ? M.ink : M.inkMid
    }

    /// Every channel the row draws in shape or hue, said in words as well.
    private var spoken: String {
        var parts: [String] = []
        if gone { parts.append("archived") } else if unread { parts.append("unread") }
        parts.append(m.from)
        if m.attachmentsN > 0 {
            parts.append("\(m.attachmentsN) attachment\(m.attachmentsN == 1 ? "" : "s")")
        }
        if m.flagged { parts.append("starred") }
        if m.hasDraft { parts.append("reply drafted") }
        if let urg = listUrgency(m.urgency) { parts.append(urg.word) }
        if let date = m.date { parts.append(Fmt.relTime(date)) }
        parts.append(m.subject)
        if let status = m.outboxStatus { parts.append(outboxWord(status)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - the list

struct MailListView: View {
    let model: MailModel

    var body: some View {
        let health = model.health
        let messages = model.messages

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HealthStrip(health: health)

                // Bookkeeping about a box there is no bookkeeping for is not
                // a reading, it is a fifth way of saying "nothing has run yet".
                // With no counts and no poll behind it this line had four
                // zeroes and the word `never polled` in it, over an empty state
                // that already says so, under an app bar that says so too.
                if model.counts != nil || model.data?.lastPollAt != nil {
                    CountsLine(counts: model.counts,
                               lastPollAt: model.data?.lastPollAt,
                               dim: health.dim)
                }

                if messages.isEmpty {
                    empty(health: health)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(messages) { m in
                            MailRow(m: m, dim: health.dim,
                                    selected: m.key == model.selection, model: model)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private static let dormant = "Not wired. Run the mail poller once to write a state file."

    /// The list's own empty state is a line, not a full pane: it stands where
    /// the rows would be, inside a column that already has a header over it.
    @ViewBuilder
    private func empty(health: Health) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.env?.status == .dormant {
                // **One statement per fact.** The health note under this line
                // read "no mailbox state yet; the mail poller has never run",
                // which is the sentence above it with the words rearranged --
                // and the app bar's subtitle and the counts line were saying it
                // a third and a fourth time. This is the one that says what to
                // do about it, so it is the one that stays. The note is still
                // worth carrying where nobody has to read it twice, so it rides
                // on the label rather than under the line.
                Text(Self.dormant)
                    .accessibilityLabel(Text(
                        health.note.map { "\(Self.dormant) \($0)" } ?? Self.dormant))
            } else {
                Text("Nothing in the inbox.")
            }
        }
        .font(Face.body)
        .foregroundStyle(M.inkDim)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }
}
