import SwiftUI

/* The three pages under the tab that are not the briefing reader: the archive,
   the library, and the reference files on the Pi -- plus the ask window given a
   page of its own.
*/

// MARK: - archive

/* Only what the user has waved off. The briefing library lives on its own page:
   history is not curation, and a briefing nobody dismissed does not belong on a
   page called archive.

   Through `SourcePanel` like the tab it belongs to, and for the tab's own
   reason: both lists are read off the cmo envelope, so if the collector is
   unreachable this page is showing a cached copy of a curation list, and quietly
   drawing that as current is the exact lie the health layer exists to prevent.

   **Nothing on this page was deleted.** A dismissed item is still in the agent's
   memory, which is what stops it being rediscovered as new next week; the
   archive is where it goes to be out of the way, and every row restores in one
   click. */
struct CmoArchiveView: View {

    var payload: TelemetryPayload
    var feedDown: Bool
    var navigate: (CmoRoute) -> Void

    @Environment(CmoDismissals.self) private var dismissals

    private struct Row: Identifiable {
        var id: String { entry.key }
        var entry: CmoDismissed
    }

    private var env: SourceEnvelope<CmoData>? { payload.cmo }

    // Already newest first: the collector reverses its own tail, and the
    // optimistic overlay prepends.
    private var items: [Row] {
        dismissals.all.filter { $0.kind == .item }.map { Row(entry: $0) }
    }

    private var drafts: [Row] {
        dismissals.all.filter { $0.kind == .draft }.map { Row(entry: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            CmoBar(crumbs: [(text: "archive", route: nil)], navigate: navigate) { EmptyView() }

            HTGrid {
                Cell(span: 12) {
                    SourcePanel(env: env, feedDown: feedDown, title: "Dismissed items",
                                ticks: true, flush: true) { _ in
                        DataTable(
                            columns: [
                                DataColumn(key: "date", header: "Day", width: 84,
                                           // The day it came from, not the day
                                           // it was waved off: this is where to
                                           // go back to.
                                           cell: { dayCell($0.entry, .whole) }),
                                DataColumn(key: "lane", header: "Lane", width: 63,
                                           cell: { DataColumn<Row>.muted($0.entry.lane ?? "—") }),
                                DataColumn(key: "title", header: "Item", flexible: true,
                                           cell: { DataColumn<Row>.primary($0.entry.title) }),
                                DataColumn(key: "restore", header: "", width: 105,
                                           align: .trailing,
                                           cell: { restoreCell($0.entry) }),
                            ],
                            rows: items,
                            empty: "Nothing dismissed. Click into an item and dismiss it there.",
                            dense: true)
                    }
                }

                Cell(span: 12) {
                    SourcePanel(env: env, feedDown: feedDown, title: "Dismissed drafts",
                                icon: "✍", ticks: true, flush: true) { _ in
                        DataTable(
                            columns: [
                                DataColumn(key: "date", header: "Day", width: 84,
                                           // Straight to that day's drafts
                                           // section, which is the only place a
                                           // briefing addresses its drafts.
                                           cell: { dayCell($0.entry, .drafts) }),
                                DataColumn(key: "title", header: "Draft", flexible: true,
                                           cell: { DataColumn<Row>.primary($0.entry.title) }),
                                DataColumn(key: "restore", header: "", width: 105,
                                           align: .trailing,
                                           cell: { restoreCell($0.entry) }),
                            ],
                            rows: drafts,
                            empty: "Nothing dismissed. Open a briefing and dismiss a draft there.",
                            dense: true)
                    }
                }
            }

            CmoNote("Dismissing hides a thing from this console and tells the next run to "
                    + "leave it alone. Nothing here was deleted from the CMO's memory, which "
                    + "is what keeps a dismissed item from arriving again as a discovery.")
        }
    }

    private func dayCell(_ entry: CmoDismissed, _ scope: ReaderScope) -> AnyView {
        AnyView(CmoLink(text: entry.date, dim: true) {
            navigate(.briefing(date: entry.date, scope: scope))
        })
    }

    /// The same control the reader uses, so one view knows what a press here
    /// means.
    private func restoreCell(_ entry: CmoDismissed) -> AnyView {
        AnyView(HStack(spacing: 0) {
            Spacer(minLength: 0)
            DismissControl(entry: entry.asDismissal, terse: true)
        })
    }
}

// MARK: - briefings

/* The library: every briefing the CMO has written, one file a day, as a way
   back into any of them. Deliberately NOT part of the archive page -- the
   archive is what the user declined, and a briefing nobody dismissed sitting
   there reads as "why is this archived when I archived nothing". History is not
   curation. */
struct CmoBriefingsView: View {

    var payload: TelemetryPayload
    var feedDown: Bool
    var navigate: (CmoRoute) -> Void

    private var env: SourceEnvelope<CmoData>? { payload.cmo }
    private var briefings: [String] { env?.data?.briefings ?? [] }
    private var today: String { DemoCmo.isoDay(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            CmoBar(crumbs: [(text: "briefings", route: nil)], navigate: navigate) { EmptyView() }

            HTGrid {
                Cell(span: 12) {
                    SourcePanel(env: env, feedDown: feedDown, title: "Briefings",
                                glyph: .cmo,
                                meta: briefings.isEmpty ? nil : "\(briefings.count) on disk",
                                ticks: true) { _ in
                        if briefings.isEmpty {
                            Text("No briefings on disk yet.")
                                .font(HT.body)
                                .foregroundStyle(HT.inkDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(briefings, id: \.self) { day in
                                    HStack(spacing: 0) {
                                        CmoLink(text: day) {
                                            navigate(.briefing(date: day, scope: .whole))
                                        }
                                        // A word, not a colour: today's is the
                                        // file still being written to, and that
                                        // has to read 1-bit.
                                        if day == today {
                                            Text(" · today")
                                                .font(HT.body)
                                                .foregroundStyle(HT.inkDim)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(height: HT.row)
                                }
                            }
                        }
                    }
                }
            }

            CmoNote("One file a day, written by the 6:00 run and kept on the Pi. Nothing "
                    + "here expires; the collector lists the most recent 90.")
        }
    }
}

// MARK: - a file on the Pi

/* A reference file: a watchlist company's dossier, or one of the operator's own
   ground-truth documents, read the way briefings are read. Deliberately
   verb-free -- nothing here is dismissable, copyable-to-send, or actionable.
   These are things to read and leave.

   One view for both routes rather than two near-copies. What actually differs
   is a directory, a route segment and the words for a file that is not there,
   so that is all `spec` holds; the fetch, the four states and the rendering
   exist once. */
struct CmoFileView: View {

    var model: MailModel
    var kind: CmoFileKind
    var slug: String
    var base: URL?
    var navigate: (CmoRoute) -> Void

    @State private var doc: FileState = .loading

    private enum FileState {
        case loading, missing, ok(String)
        case failed(String)
    }

    private struct Spec {
        /// The directory on the Pi, named in the loading line.
        var dir: String
        /// The last-but-one segment of `/v1/cmo/<route>/<slug>`.
        var route: String
        /// The breadcrumb's middle crumb.
        var crumb: String
        /// What one of these files is called, as a panel title.
        var noun: String
        var missing: String
        var unreadable: String
    }

    private var spec: Spec {
        switch kind {
        case .watch:
            return Spec(
                dir: "watchlist", route: "dossier", crumb: "watch", noun: "Dossier",
                missing: "No dossier for \(slug) yet. Dossiers are research documents "
                    + "written to the Pi; this company has none on disk.",
                unreadable: "The collector did not hand over this dossier. The file may "
                    + "still be on the Pi.")
        case .doc:
            return Spec(
                dir: "docs", route: "doc", crumb: "docs", noun: "Document",
                missing: "No document named \(slug) on the Pi.",
                unreadable: "The collector did not hand over this document. The file may "
                    + "still be on the Pi.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            CmoBar(crumbs: [(text: spec.crumb, route: nil), (text: slug, route: nil)],
                   navigate: navigate) {
                RawLink(base: base, path: "v1/cmo/\(spec.route)/\(slug)")
            }

            Rule(variant: .bright)

            switch doc {
            case .loading:
                CmoNote("reading \(spec.dir)/\(slug).md")

            case .missing:
                Panel(title: spec.noun, meta: AnyView(metaText)) {
                    VStack(alignment: .leading, spacing: HT.row) {
                        CmoNote(spec.missing)
                        CmoLink(text: "◂ back to the CMO tab") { navigate(.tab) }
                    }
                }

            case .failed(let message):
                Panel(title: spec.noun, meta: AnyView(metaText),
                      footer: AnyView(HStack(spacing: HT.cw) {
                          StatusPill(text: "unreadable", tone: .fault)
                          Text(message).font(HT.body).foregroundStyle(HT.inkDim)
                              .fixedSize(horizontal: false, vertical: true)
                          Spacer(minLength: 0)
                      })) {
                    VStack(alignment: .leading, spacing: HT.row) {
                        CmoNote(spec.unreadable)
                        CmoLink(text: "◂ back to the CMO tab") { navigate(.tab) }
                    }
                }

            case .ok(let text):
                MarkdownDoc(nodes: Markdown.parse(text))
            }
        }
        .task(id: "\(kind.rawValue)/\(slug)") { await load() }
    }

    private var metaText: some View {
        Text(slug).font(HT.body).foregroundStyle(HT.inkDim).lineLimit(1)
    }

    private func load() async {
        doc = .loading
        do {
            let text = kind == .doc
                ? try await model.store.cmoDoc(slug: slug)
                : try await model.store.cmoDossier(slug: slug)
            doc = text.map { FileState.ok($0) } ?? .missing
        } catch is CancellationError {
            return
        } catch {
            doc = .failed((error as? LocalizedError)?.errorDescription
                          ?? error.localizedDescription)
        }
    }
}

// MARK: - the ask window, maximised

/* Everything that runs is in `AskWindow` -- the buffer, the prompt, the poll,
   the doors under the frame -- and the same view is a panel in the CMO tab's
   grid. This page adds the three things a page has that a panel does not: a way
   back, a count of what is on the Pi, and the room to run the scrollback
   twenty-eight rows deep instead of eighteen.

   The window is controlled here, which means the route says which conversation
   is open. That is the whole reason the page exists as a route: a conversation
   with an address can be walked back to, and the tab's copy keeps the same state
   locally because a cell in a dashboard has no address to put it in. */
struct CmoAskView: View {

    var model: MailModel
    var payload: TelemetryPayload
    /// The open conversation, or nil for the newest.
    var thread: String?
    /// The window with nothing open in it, so the prompt starts a conversation
    /// instead of continuing one.
    var fresh: Bool
    var navigate: (CmoRoute) -> Void

    @State private var counts = AskCounts()

    /// The breadcrumb's last segment, which is whatever the route named -- a
    /// thread id, or the word for the empty window.
    private var tail: String? { fresh ? "new" : thread }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            CmoBar(crumbs: crumbs, navigate: navigate) {
                Text("\(counts.total) \(counts.total == 1 ? "thread" : "threads")"
                     + " · \(counts.thinking) thinking")
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .lineLimit(1)
            }

            Rule(variant: .bright)

            // The column the process runs in on its own page. Ninety cells is
            // wide enough that an answer keeps the 78-cell measure every other
            // document in this console is set to, and narrow enough that the
            // frame reads as a window rather than as the page.
            AskWindow(
                payload: payload, model: model,
                selected: thread, fresh: fresh,
                // Replacing rather than pushing: turning a typed question into
                // a thread is not a place the reader navigated to.
                onSelectThread: { id in
                    navigate(.ask(thread: id, fresh: id == nil))
                },
                onClose: { navigate(.tab) },
                onCounts: { counts = $0 },
                maxRows: 28,
                autoFocus: true)
                .frame(maxWidth: HT.cw * 90, alignment: .leading)
        }
    }

    private var crumbs: [(text: String, route: CmoRoute?)] {
        guard let tail else { return [(text: "ask", route: nil)] }
        return [(text: "ask", route: .ask(thread: nil, fresh: false)),
                (text: tail, route: nil)]
    }
}
