import SwiftUI

/* ── CMO ───────────────────────────────────────────────────────────────
   The morning run: what it found, how far each lead has got, and the window to
   ask it about any of it.

   **Composition only.** Whether a panel is stale is `SourcePanel`'s business
   and the wording of why is the collector's. Nothing here sets a tone.

   Two things on this tab are not readouts and are worth naming. The rows are
   doors: an item opens the briefing at the section it was written in, which is
   the whole reason the reader takes an ordinal rather than a title. And
   `archive ›` turns the tab into a selection: rows toggle instead of opening,
   and `done (n)` commits every choice in one go.
*/

/// The widest the pipeline bar is allowed to run, in cells.
private let barCells = 30

/// The four buckets, in pipeline order, as a density ramp.
///
/// The glyphs are the non-colour channel: █▓▒░ is four distinguishable runs
/// printed 1-bit, so the ink ramp beside them is reinforcement and not the
/// reading. No hue is spent here at all -- green, amber and red mean health in
/// this system and a lead's stage is not a health, and cyan means selection and
/// is spent once per view.
private struct PipelineBucket: Identifiable {
    var id: String
    var glyph: String
    var ink: Color
    var count: Int
    var cells: Int
}

struct CmoView: View {

    var model: MailModel
    var payload: TelemetryPayload
    var feedDown: Bool
    var watchSeen: SeenMarks
    var docsSeen: SeenMarks
    var navigate: (CmoRoute) -> Void

    @Environment(CmoDismissals.self) private var dismissals

    /// Bulk curation. The selection holds whole entries rather than keys so
    /// committing needs no second lookup, and it dies with the mode -- cancel
    /// forgets everything.
    @State private var selecting = false
    @State private var chosen: [String: Dismissal] = [:]
    @State private var committing = false

    /// Document order is the agent's own ranking; a header press re-sorts, a
    /// second press flips the direction.
    @State private var sortKey: SortKey?
    @State private var sortDir = 1

    private enum SortKey: String { case pri, added }

    // MARK: - reading the source

    private var env: SourceEnvelope<CmoData>? { payload.cmo }
    private var d: CmoData? { env?.data }
    private var agent: CmoAgentResult? { d?.agent }

    /// Every non-zero lane and no others, the same rule as the masthead's
    /// source counts: a line that silently omits a bucket stops adding up to
    /// the total beside it.
    private var lanes: [CmoLane] { (agent?.lanes ?? []).filter { $0.ready > 0 } }

    /// The date out of `briefings/YYYY-MM-DD.md`. The heartbeat carries the
    /// path the wrapper wrote; the briefing route wants only the day.
    private func briefingDay(_ path: String?) -> String? {
        guard let path, path.hasSuffix(".md"), path.count >= 13 else { return nil }
        let day = String(path.dropLast(3).suffix(10))
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              day.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        return day
    }

    private var runDate: String? {
        let value = d?.heartbeat.runDate ?? ""
        return value.isEmpty ? nil : value
    }

    /// The briefing the heartbeat points at, falling back to the one the agent
    /// result belongs to -- a failed run has no briefing of its own, but the
    /// previous success left one behind.
    private var current: String? { briefingDay(d?.heartbeat.briefing) ?? d?.agentDate }

    private var offered: [String] {
        var seen = Set<String>()
        return ([current].compactMap { $0 } + (d?.briefings ?? []))
            .filter { seen.insert($0).inserted }
    }

    /// The result on screen is not always the run the heartbeat describes.
    /// Saying so is the whole reason `agent_date` travels in the payload.
    private var borrowed: Bool {
        guard let agentDate = d?.agentDate else { return false }
        return agentDate != runDate
    }

    /// The briefing these rows were read out of, which is the agent result's
    /// own day whenever the two disagree -- opening an item from yesterday's
    /// run has to land in yesterday's document. Nil when no run has left one
    /// behind, and a row with nowhere to go stays inert rather than pretending.
    private var itemsDay: String? { d?.agentDate ?? runDate }

    private func isDismissed(_ title: String) -> Bool {
        guard let itemsDay else { return false }
        return dismissals.has(.item, title, itemsDay)
    }

    // MARK: - the rows

    private struct ItemRow: Identifiable {
        /// The payload ordinal, which survives any table sort and is what the
        /// reader is addressed by.
        var id: Int
        var item: CmoItem
    }

    private var itemRows: [ItemRow] {
        let rows = (agent?.items ?? []).enumerated().map { ItemRow(id: $0.offset, item: $0.element) }
        guard let sortKey else { return rows }
        return rows.sorted { a, b in
            switch sortKey {
            case .pri:
                if a.item.pri != b.item.pri {
                    return sortDir == 1 ? a.item.pri < b.item.pri : a.item.pri > b.item.pri
                }
            case .added:
                // A brand-new item's first_seen IS the run's day, so the
                // fallback states the same fact for payloads that predate the
                // field.
                let x = a.item.added ?? itemsDay ?? ""
                let y = b.item.added ?? itemsDay ?? ""
                if x != y { return sortDir == 1 ? x < y : x > y }
            }
            return a.id < b.id
        }
    }

    private struct DraftRow: Identifiable {
        var id: Int
        var draft: CmoDraft
    }

    private var draftRows: [DraftRow] {
        (agent?.drafts ?? []).enumerated().map { DraftRow(id: $0.offset, draft: $0.element) }
    }

    private struct WatchRow: Identifiable {
        var id: String { watch.name }
        var watch: CmoWatch
    }

    private var watchRows: [WatchRow] { (agent?.watchlist ?? []).map { WatchRow(watch: $0) } }

    private struct DocRow: Identifiable {
        var id: String { doc.slug }
        var doc: CmoDoc
    }

    private var docRows: [DocRow] { (d?.docs ?? []).map { DocRow(doc: $0) } }

    // MARK: - the pipeline

    private func buckets(dim: Bool) -> [PipelineBucket] {
        let p = agent?.pipeline
        let raw: [(String, String, Color, Int)] = [
            ("new", "█", HT.c15, p?.new ?? 0),
            ("drafted", "▓", HT.c7, p?.drafted ?? 0),
            ("contacted", "▒", HT.c8, p?.contacted ?? 0),
            ("dead", "░", HT.c0, p?.dead ?? 0),
        ]
        let total = raw.reduce(0) { $0 + $1.3 }
        // Proportional only once the counts would overflow the row. Below the
        // cap the bar is one cell per lead, which is the more literal of the
        // two readings and the one worth having on a small pipeline.
        let scale = total > barCells ? Double(barCells) / Double(total) : 1
        return raw.map { key, glyph, ink, count in
            PipelineBucket(
                id: key, glyph: glyph, ink: dim ? HT.inkDim : ink, count: count,
                // A non-empty bucket always keeps a cell. Rounding one
                // contacted lead away to nothing states that there are none,
                // which is the single thing this bar must never say.
                cells: count == 0 ? 0 : Swift.max(1, Int((Double(count) * scale).rounded())))
        }
    }

    // MARK: - the page

    private var subtitle: String {
        if feedDown { return "Collector unreachable. Showing the last values received." }
        guard let d else { return "No run recorded yet." }
        switch d.heartbeat.status {
        case .ok, .noNewItems:
            return "Run \(d.heartbeat.runDate) · \(Fmt.num(d.heartbeat.newItems)) new items."
        default:
            return d.heartbeat.detail ?? "The last run did not finish."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            PageHead(title: "Daily briefing", subtitle: subtitle)
            grid
            bottomBar
        }
    }

    private var grid: some View {
        HTGrid {
            briefingCell
            runCell
            pipelineCell
            draftsCell
            watchlistCell
            documentsCell
            Cell(span: 8, spanMd: 12) {
                // The CMO answering back, in the grid with everything it read
                // to do it, rather than behind a click. The same window the ask
                // page runs, uncontrolled: its doors switch conversations in
                // place because a cell has no route of its own to put a
                // selection in, and eighteen rows of buffer instead of the
                // page's twenty-eight because this is still a dashboard.
                AskWindow(payload: payload, model: model,
                          onMaximize: { navigate(.ask(thread: nil, fresh: false)) },
                          maxRows: 18)
            }
        }
    }

    // MARK: - briefing

    private var briefingCell: some View {
        Cell(span: 8, spanMd: 12) {
            VStack(alignment: .leading, spacing: HT.row) {
                SourcePanel(env: env, feedDown: feedDown, title: "Briefing",
                            glyph: .cmo, ticks: true, flush: true) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        laneLine
                        DataTable(
                            columns: itemColumns,
                            rows: itemRows,
                            empty: env?.status == .dormant
                                ? "Not wired. Run the CMO job once to produce a heartbeat."
                                : "No items in the last run",
                            onRowClick: itemsDay == nil ? nil : { row in
                                guard let itemsDay else { return }
                                if selecting {
                                    toggle(Dismissal(kind: .item, title: row.item.title,
                                                     lane: row.item.lane, date: itemsDay))
                                } else {
                                    navigate(.briefing(date: itemsDay, scope: .item(row.id)))
                                }
                            },
                            isRowSelected: selecting ? { row in
                                guard let itemsDay else { return false }
                                return chosen[Dismissal.key(.item, row.item.title, itemsDay)] != nil
                            } : nil)
                    }
                }
                briefingLinks
            }
        }
    }

    private var laneLine: some View {
        HStack(spacing: 0) {
            if lanes.isEmpty {
                Text("no new items by lane")
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
            } else {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    if index > 0 {
                        Text("· ").font(HT.body).foregroundStyle(HT.inkDim)
                    }
                    Text("\(lane.lane) ").font(HT.body).foregroundStyle(HT.inkDim)
                    Text(Fmt.num(lane.ready)).font(HT.body).foregroundStyle(HT.ink)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        // The panel is flush so its table can run edge to edge, which leaves
        // this line with no inset at all. One cell is the table's own
        // horizontal padding, so the two start on the same column.
        .padding(.horizontal, HT.cw)
        .padding(.vertical, HT.s2)
    }

    private var itemColumns: [DataColumn<ItemRow>] {
        [
            DataColumn(
                key: "pri", header: "Pri",
                headerView: AnyView(sortHeader("Pri", .pri)),
                width: 56,
                cell: { row in
                    // pri 1 is act-today, so it lights all three pips. The
                    // level carries the reading with no colour at all.
                    //
                    // A dismissed row loses its priority entirely rather than
                    // dimming it: the agent's ranking is a claim about what to
                    // do next, and the user has answered it. × is the
                    // struck-out channel, and it prints.
                    isDismissed(row.item.title)
                        ? AnyView(Text("×").font(HT.body)
                            .modifier(TableInk(normal: HT.inkDim))
                            .accessibilityLabel(Text("dismissed")))
                        : AnyView(StatusLamp(level: 4 - row.item.pri, of: 3))
                }),
            DataColumn(key: "lane", header: "Lane",
                       cell: { DataColumn<ItemRow>.muted($0.item.lane) }),
            DataColumn(key: "title", header: "Item", flexible: true,
                       cell: { row in
                           // The primary treatment is dropped rather than
                           // dimmed on top of: both set a colour, and which one
                           // wins would be a question about ordering.
                           isDismissed(row.item.title)
                               ? DataColumn<ItemRow>.muted(row.item.title)
                               : DataColumn<ItemRow>.primary(row.item.title)
                       }),
            DataColumn(
                key: "added", header: "Added",
                headerView: AnyView(sortHeader("Added", .added)),
                align: .trailing,
                cell: { DataColumn<ItemRow>.muted($0.item.added ?? itemsDay ?? "—") }),
        ]
    }

    /// The header is still a header: the control inherits its typography and
    /// adds only the direction glyph, which is the non-colour channel for "this
    /// column ranks the table".
    private func sortHeader(_ label: String, _ key: SortKey) -> some View {
        Button {
            if sortKey == key {
                sortDir *= -1
            } else {
                sortKey = key
                // First press: pri reads best-first, a date column reads
                // newest-first.
                sortDir = key == .added ? -1 : 1
            }
        } label: {
            HStack(spacing: 0) {
                Text(label.uppercased())
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .lineLimit(1)
                if sortKey == key {
                    PixelGlyph(name: sortDir == 1 ? .caretUp : .caretDown, color: HT.inkDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var briefingLinks: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if borrowed, let agentDate = d?.agentDate {
                Text("showing briefing from \(agentDate) · ")
                    .font(HT.body).foregroundStyle(HT.inkDim)
            }
            if offered.isEmpty {
                Text("no briefings on disk yet").font(HT.body).foregroundStyle(HT.inkDim)
            } else {
                Text("briefings: ").font(HT.body).foregroundStyle(HT.inkDim)
                ForEach(Array(offered.prefix(5).enumerated()), id: \.offset) { index, day in
                    if index > 0 { Text(" · ").font(HT.body).foregroundStyle(HT.inkDim) }
                    // Into the console's own reader rather than out to the text
                    // file. The raw route is still one dim link away, on the
                    // reader page itself.
                    CmoLink(text: day) { navigate(.briefing(date: day, scope: .whole)) }
                }
                Text(" · ").font(HT.body).foregroundStyle(HT.inkDim)
                // The library page carries the rest; this line stays a week
                // wide however long the Pi keeps writing.
                CmoLink(text: "all ›") { navigate(.briefings) }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    // MARK: - run

    private var runCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: env, feedDown: feedDown, title: "Run",
                        meta: d?.heartbeat.runDate, ticks: true) { h in
                VStack(alignment: .leading, spacing: 0) {
                    Metric(label: "new items", value: Fmt.num(d?.heartbeat.newItems),
                           size: .compact, dim: h.dim)

                    VStack(alignment: .leading, spacing: 0) {
                        // Computed at render, never baked into the payload.
                        DotLeader(label: "last run",
                                  value: Fmt.relTime(d?.heartbeat.finishedAt, now: model.now))
                        DotLeader(label: "duration", value: Fmt.dur(d?.heartbeat.durationSec))
                        DotLeader(label: "attempt", value: Fmt.num(d?.heartbeat.attempt))
                        DotLeader(label: "deduped today",
                                  value: Fmt.num(agent?.memory?.dedupedToday))
                        DotLeader(label: "ledger", value: Fmt.num(agent?.memory?.seen))
                    }
                    .padding(.top, HT.row)

                    Rule(variant: .solid, label: "items / day")

                    // Removed rather than dimmed when the source is not live:
                    // the strip asserts what the last fortnight did, and a
                    // stale panel no longer covers the window it draws.
                    if !h.hideDelta {
                        Sparkline(data: (d?.itemsDaily ?? []).map(\.count), cap: true,
                                  label: "new items per day, last 14 days")
                    }
                }
            }
        }
    }

    // MARK: - pipeline

    private var pipelineCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(
                env: env, feedDown: feedDown, title: "Pipeline",
                meta: agent?.leadsUpdated.map { "\(Fmt.num($0)) updated" },
                ticks: true
            ) { h in
                let rows = buckets(dim: h.dim)
                VStack(alignment: .leading, spacing: 0) {
                    // Block glyphs set at the panel's normal leading leave a
                    // hairline of ground above and below the run, which reads
                    // as a gap in the data rather than as one continuous bar.
                    HStack(spacing: 0) {
                        ForEach(rows) { bucket in
                            Text(String(repeating: bucket.glyph, count: bucket.cells))
                                .foregroundStyle(bucket.ink)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(HT.body)
                    .kerning(0)
                    .tracking(0)
                    .lineLimit(1)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { bucket in
                            DotLeader(label: "\(bucket.glyph) \(bucket.id)",
                                      value: Fmt.num(bucket.count),
                                      tone: h.dim ? .standby : .default)
                        }
                    }
                    .padding(.top, HT.row)
                }
            }
        }
    }

    // MARK: - drafts

    private var draftsCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: env, feedDown: feedDown, title: "Drafts",
                        icon: "✍", ticks: true, flush: true) { _ in
                DataTable(
                    columns: [
                        DataColumn(key: "title", header: "Draft", flexible: true,
                                   cell: { DataColumn<DraftRow>.primary($0.draft.title) }),
                        DataColumn(key: "target", header: "With", align: .trailing,
                                   cell: { DataColumn<DraftRow>.muted($0.draft.target) }),
                    ],
                    rows: draftRows,
                    empty: "No drafts queued",
                    dense: true,
                    // Every row goes to the same place. The briefing collects
                    // its drafts in one ✍️ section and does not address them
                    // individually, so pointing each row at its own anchor
                    // would invent a structure the document does not have. In
                    // selection mode each row is its own thing again: the draft
                    // is dismissed under the title this table shows.
                    onRowClick: itemsDay == nil ? nil : { row in
                        guard let itemsDay else { return }
                        if selecting {
                            toggle(Dismissal(kind: .draft, title: row.draft.title,
                                             lane: nil, date: itemsDay))
                        } else {
                            navigate(.briefing(date: itemsDay, scope: .drafts))
                        }
                    },
                    isRowSelected: selecting ? { row in
                        guard let itemsDay else { return false }
                        return chosen[Dismissal.key(.draft, row.draft.title, itemsDay)] != nil
                    } : nil)
            }
        }
    }

    // MARK: - watchlist

    private var watchlistCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: env, feedDown: feedDown, title: "Watchlist",
                        ticks: true, flush: true) { _ in
                DataTable(
                    columns: [
                        DataColumn(key: "name", header: "Company", flexible: true,
                                   cell: { row in
                                       AnyView(HStack(spacing: HT.s1) {
                                           // The dot only while an event is
                                           // unseen from this Mac. A glyph, not
                                           // a hue -- and its own column, kept
                                           // whether or not it is filled, so
                                           // the names read straight down the
                                           // table instead of jogging a cell
                                           // sideways row by row.
                                           Group {
                                               if watchSeen.isNew(row.watch.name, row.watch.when) {
                                                   NewDot(label: "new event")
                                               }
                                           }
                                           .frame(width: HT.cw2, alignment: .leading)
                                           // A company with a dossier on disk is
                                           // a door; one without is just a name.
                                           Text(row.watch.name)
                                               .font(HT.body)
                                               .lineLimit(1)
                                               .modifier(TableInk(
                                                   normal: hasDossier(row.watch.name)
                                                       ? HT.ink : HT.inkBright))
                                           Spacer(minLength: 0)
                                       })
                                   }),
                        DataColumn(key: "when", header: "When", align: .trailing,
                                   cell: { row in
                                       // The date as the agent wrote it. Not
                                       // relative: this is a calendar day, and
                                       // "3d" would imply a precision a day
                                       // stamp does not have.
                                       row.watch.when.map { AnyView(
                                           Text($0).font(HT.body).lineLimit(1)
                                               .modifier(TableInk(normal: HT.ink)))
                                       } ?? DataColumn<WatchRow>.muted("—")
                                   }),
                    ],
                    rows: watchRows,
                    empty: "Nothing watched",
                    dense: true,
                    // A press acknowledges whatever was new, then opens the
                    // dossier when there is one to open.
                    onRowClick: { row in
                        watchSeen.mark(row.watch.name, row.watch.when)
                        if hasDossier(row.watch.name) {
                            navigate(.file(kind: .watch, slug: row.watch.name))
                        }
                    })
            }
        }
    }

    private func hasDossier(_ name: String) -> Bool { (d?.dossiers ?? []).contains(name) }

    // MARK: - documents

    private var documentsCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: env, feedDown: feedDown, title: "Documents",
                        glyph: .cmo, ticks: true, flush: true) { _ in
                DataTable(
                    columns: [
                        DataColumn(key: "slug", header: "Document", flexible: true,
                                   cell: { row in
                                       AnyView(HStack(spacing: HT.s1) {
                                           // The same reserved column as the
                                           // watchlist, for the same reason.
                                           Group {
                                               if docsSeen.isNew(row.doc.slug, row.doc.updated) {
                                                   NewDot(label: "updated")
                                               }
                                           }
                                           .frame(width: HT.cw2, alignment: .leading)
                                           Text(row.doc.slug)
                                               .font(HT.body)
                                               .lineLimit(1)
                                               .modifier(TableInk(normal: HT.ink))
                                           Spacer(minLength: 0)
                                       })
                                   }),
                        DataColumn(key: "updated", header: "Updated", align: .trailing,
                                   cell: {
                                       // The day only. `updated` is already
                                       // local time, so this is a slice and not
                                       // a conversion, and a calendar day is all
                                       // an mtime is worth saying out loud.
                                       DataColumn<DocRow>.muted(String($0.doc.updated.prefix(10)))
                                   }),
                    ],
                    rows: docRows,
                    // The operator's ground truth. Every row is a door -- the
                    // collector only lists a document its own route can serve
                    // -- so unlike the watchlist there is no inert row here.
                    empty: "No documents on the Pi yet.",
                    dense: true,
                    onRowClick: { row in
                        docsSeen.mark(row.doc.slug, row.doc.updated)
                        navigate(.file(kind: .doc, slug: row.doc.slug))
                    })
            }
        }
    }

    // MARK: - the bottom bar

    /// Everything this tab does not show: every briefing on disk, and
    /// everything waved off. Dim, because it is a place to go back to rather
    /// than a thing to do now. In selection mode the line becomes the commit
    /// bar, and cancel forgets every choice.
    private var bottomBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !selecting {
                CmoQuietButton(text: "archive ›", disabled: itemsDay == nil) {
                    selecting = true
                }
                Text(" · ").font(HT.body).foregroundStyle(HT.inkDim)
                CmoQuietButton(text: "view archive ›") { navigate(.archive) }
            } else {
                CmoQuietButton(text: committing ? "archiving…" : "done (\(chosen.count))",
                               bright: true,
                               disabled: chosen.isEmpty || committing) {
                    Task { await commit() }
                }
                Text(" · ").font(HT.body).foregroundStyle(HT.inkDim)
                CmoQuietButton(text: "cancel") { leaveSelecting() }
                Text(" · click items and drafts to select")
                    .font(HT.body).foregroundStyle(HT.inkDim)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func toggle(_ entry: Dismissal) {
        if chosen[entry.key] != nil {
            chosen.removeValue(forKey: entry.key)
        } else {
            chosen[entry.key] = entry
        }
    }

    private func leaveSelecting() {
        selecting = false
        chosen = [:]
    }

    private func commit() async {
        committing = true
        // Each dismissal rolls itself back on failure inside the store; a row
        // that failed simply stays undimmed, which is the true state of the
        // disk.
        await withTaskGroup(of: Void.self) { group in
            for entry in chosen.values {
                group.addTask { @MainActor in _ = await dismissals.dismiss(entry) }
            }
        }
        committing = false
        leaveSelecting()
    }
}

/// The way into the archive and the two words that commit a selection. Dim at
/// rest, brightening under the cursor the way the rail's own items do -- which
/// is the whole affordance, since a tty has no underline to offer.
struct CmoQuietButton: View {
    var text: String
    var bright: Bool = false
    var disabled: Bool = false
    var action: () -> Void

    @State private var hovering = false

    private var ink: Color {
        if disabled { return HT.inkFaint }
        if hovering { return HT.inkBright }
        return bright ? HT.ink : HT.inkDim
    }

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            Text(text)
                .font(HT.body)
                .foregroundStyle(ink)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .disabled(disabled)
    }
}
