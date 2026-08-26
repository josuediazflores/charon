import SwiftUI

/* The briefing, read in the console instead of handed over as a text file. The
   CMO writes one markdown document a day and the tab above it lists that
   document's items; opening one used to leave the console entirely, which is a
   strange thing for a page whose whole job is to be the place these numbers are
   read.

   This view fetches the markdown and nothing else. It takes no envelope and
   asks the staleness rule nothing, because a briefing is not a source: it
   either exists for a date or it does not, and neither answer is a
   degradation. */

/* ── item → heading ─────────────────────────────────────────────────────
   The agent writes `items` for the payload and headings for the document, in
   two separate passes, so the two texts are about the same thing and almost
   never the same string. Matching them on shared words is enough to land a
   reader on the right section, and is honest about failing: below the threshold
   the reader opens at the top of the document rather than guessing at a
   section, because scrolling someone to the wrong item is worse than scrolling
   them nowhere. */

/// Function words and spelled-out numbers. Without this the threshold below
/// means nothing -- "the" and "for" are shared by every pair of sentences in
/// English, so two of them would match any item to any heading.
private let stopWords: Set<String> = [
    "the", "and", "for", "with", "from", "that", "this", "into", "its", "are",
    "was", "were", "has", "have", "had", "but", "not", "you", "your", "our",
    "all", "any", "via", "per", "out", "off", "over", "under", "than", "then",
    "when", "what", "who", "how", "why", "their", "there", "here", "about",
    "after", "before", "onto", "upon", "also", "just", "more", "most", "some",
    "such", "only", "very", "both", "each", "other", "same", "been", "being",
    "does", "did", "one", "two", "three", "four", "five", "six", "seven",
    "eight", "nine", "ten",
]

/// Lowercase, drop everything that is not a letter -- which takes punctuation,
/// digits and emoji in one rule -- then keep the words worth comparing. Two
/// characters or fewer are dropped with the function words: no token that short
/// decides anything here.
func keyTokens(_ text: String) -> Set<String> {
    var out = Set<String>()
    var word = ""
    func flush() {
        if word.count >= 3, !stopWords.contains(word) { out.insert(word) }
        word = ""
    }
    for ch in text.lowercased() {
        if ch.isLetter { word.append(ch) } else { flush() }
    }
    flush()
    return out
}

/// The best heading for one item title, or nil when nothing scores well enough.
/// Ties go to the earlier heading, so the answer is stable and reads in
/// document order.
func matchHeading(_ title: String, _ headings: [Markdown.HeadingRef]) -> Markdown.HeadingRef? {
    let want = keyTokens(title)
    guard !want.isEmpty else { return nil }

    var best: (heading: Markdown.HeadingRef, score: Int)?
    for heading in headings {
        let score = keyTokens(heading.text).filter { want.contains($0) }.count
        if score > (best?.score ?? 0) { best = (heading, score) }
    }
    // Two shared words is the line between "these are the same item" and "these
    // are both about campus". One is routinely a coincidence in a document
    // where every heading says `campus` or `dining` somewhere.
    guard let best, best.score >= 2 else { return nil }
    return best.heading
}

/// The drafts section, by name. Substring rather than token equality so
/// `drafts ready`, `✍️ drafts` and `draft blocks` all resolve.
private func draftsHeading(_ headings: [Markdown.HeadingRef]) -> Markdown.HeadingRef? {
    headings.first { $0.text.lowercased().contains("draft") }
}

/// An item's lane section, for when the item has no heading of its own.
///
/// Digest lanes -- market especially -- list their items as bullets, so the
/// title matcher rightly declines; landing on the lane's section still beats
/// dropping the reader at the top of the whole document. The words are the
/// briefing's own pinned section names, with the lane key itself as the
/// fallback if the prose ever drifts.
private let laneWords: [String: [String]] = [
    "ads": ["advertiser"],
    "demand": ["act today", "demand"],
    "market": ["competitor", "market"],
]

private func laneHeading(_ lane: String,
                         _ headings: [Markdown.HeadingRef]) -> Markdown.HeadingRef? {
    let words = laneWords[lane] ?? [lane]
    return headings.first { heading in
        let t = heading.text.lowercased()
        return words.contains { t.contains($0) }
    }
}

// MARK: - the view

private enum DocState {
    case loading
    case ok(String)
    /// No file for that date. Not an error: most dates have no briefing.
    case missing
    case failed(String)
}

struct CmoReaderView: View {

    var model: MailModel
    var payload: TelemetryPayload
    var date: String
    var scope: ReaderScope
    var base: URL?
    var navigate: (CmoRoute) -> Void

    @State private var doc: DocState = .loading

    private var nodes: [MdNode] {
        if case .ok(let text) = doc { return Markdown.parse(text) }
        return []
    }

    private var headings: [Markdown.HeadingRef] { Markdown.headings(nodes) }

    /// The items the tab listed, and only if they are about THIS document.
    ///
    /// The payload carries one run's items; the footer offers every briefing on
    /// disk, so opening Tuesday's from Friday's console would otherwise walk
    /// Friday's items through a document that never contained them. Withheld
    /// rather than pointed somewhere wrong -- the same call `agent_date` exists
    /// to let the tab make.
    private var items: [CmoItem] {
        let d = payload.cmo?.data
        let runDate = (d?.heartbeat.runDate ?? "").isEmpty ? nil : d?.heartbeat.runDate
        let itemsDay = d?.agentDate ?? runDate
        return itemsDay == date ? (d?.agent?.items ?? []) : []
    }

    private var target: String? {
        switch scope {
        case .drafts:
            return draftsHeading(headings)?.id
        case .item(let n):
            guard items.indices.contains(n) else { return nil }
            let item = items[n]
            if let hit = matchHeading(item.title, headings) { return hit.id }
            return laneHeading(item.lane, headings)?.id
        case .whole:
            return nil
        }
    }

    /// A scoped route is its own PAGE, not a scroll position in the day's
    /// document: the slice runs from the matched heading to the next heading at
    /// its own depth or above. Trailing section rules are trimmed because a
    /// divider belongs between sections and a page of one section has no
    /// between. No match falls back to the whole document, which is also what
    /// the unscoped route shows.
    private var visible: [MdNode] {
        guard let target else { return nodes }
        guard let start = nodes.firstIndex(where: {
            if case .head(_, _, let id) = $0.block { return id == target }
            return false
        }) else { return nodes }
        guard case .head(let level, _, _) = nodes[start].block else { return nodes }

        var end = nodes.count
        var i = start + 1
        while i < nodes.count {
            switch nodes[i].block {
            case .h1:
                end = i
                i = nodes.count
            case .head(let l, _, _) where l <= level:
                end = i
                i = nodes.count
            default:
                i += 1
            }
        }
        while end > start + 1, case .hr = nodes[end - 1].block { end -= 1 }
        return Array(nodes[start..<end])
    }

    // MARK: - the walk along the bottom

    /// Unscoped, "next" is the first item, which makes the strip a way in
    /// rather than a dead end.
    private var at: Int? {
        if case .item(let n) = scope { return n }
        return nil
    }

    private var prev: Int? {
        guard let at, at > 0, at - 1 < items.count else { return nil }
        return at - 1
    }

    private var next: Int? {
        guard let at else { return items.isEmpty ? nil : 0 }
        return at + 1 < items.count ? at + 1 : nil
    }

    /// An ordinal past the end of the list gets no meta at all rather than a
    /// clamped one: a stale link saying "item 6 of 6" would be a number this
    /// page made up.
    private var meta: String? {
        switch scope {
        case .drafts: return "drafts"
        case .item(let n) where n < items.count: return "item \(n + 1) of \(items.count)"
        default: return nil
        }
    }

    /// The item this page is about, when it is about one. Resolved from the
    /// payload rather than from the document, because dismissal is keyed on the
    /// title the tab showed -- the heading over the prose is the agent's second
    /// wording of the same thing and is routinely not the same string.
    private var item: CmoItem? {
        guard case .item(let n) = scope, items.indices.contains(n) else { return nil }
        return items[n]
    }

    // MARK: - body

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            CmoBar(
                crumbs: [(text: "briefing \(date)",
                          route: target != nil ? .briefing(date: date, scope: .whole) : nil)],
                navigate: navigate
            ) {
                if let meta {
                    Text(meta).font(HT.body).foregroundStyle(HT.inkDim).lineLimit(1)
                }
                RawLink(base: base, path: "v1/cmo/briefing/\(date)")
            }

            Rule(variant: .bright)

            switch doc {
            case .loading:
                CmoNote("reading briefings/\(date).md")

            case .missing:
                Panel(title: "Briefing", meta: AnyView(metaText)) {
                    VStack(alignment: .leading, spacing: HT.row) {
                        CmoNote("No briefing for \(date). The CMO writes one file a day, "
                                + "and this day has none on disk.")
                        CmoLink(text: "◂ back to the CMO tab") { navigate(.tab) }
                    }
                }

            case .failed(let message):
                Panel(title: "Briefing", meta: AnyView(metaText),
                      footer: AnyView(HStack(spacing: HT.cw) {
                          StatusPill(text: "unreadable", tone: .fault)
                          Text(message).font(HT.body).foregroundStyle(HT.inkDim)
                              .fixedSize(horizontal: false, vertical: true)
                          Spacer(minLength: 0)
                      })) {
                    VStack(alignment: .leading, spacing: HT.row) {
                        CmoNote("The collector did not hand over this briefing. "
                                + "The file may still be on the Pi.")
                        CmoLink(text: "◂ back to the CMO tab") { navigate(.tab) }
                    }
                }

            case .ok:
                MarkdownDoc(nodes: visible, variant: .draft(date: date))

                // The verdict on this item, under the item. Only on a page that
                // IS one item -- the whole document has no single subject to
                // act on.
                if let item {
                    Rule()
                    HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
                        DismissControl(entry: Dismissal(kind: .item, title: item.title,
                                                        lane: item.lane, date: date))
                        Text("dismissed items stay in the briefing, dimmed · "
                             + "restore from the archive")
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                if !items.isEmpty {
                    Rule()
                    HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
                        if let prev {
                            CmoLink(text: "◂ \(items[prev].title)") {
                                navigate(.briefing(date: date, scope: .item(prev)))
                            }
                            .frame(maxWidth: HT.cw * 40, alignment: .leading)
                        } else {
                            Text("◂ start of items").font(HT.body).foregroundStyle(HT.inkDim)
                        }
                        Spacer(minLength: 0)
                        if let next {
                            CmoLink(text: "\(items[next].title) ›") {
                                navigate(.briefing(date: date, scope: .item(next)))
                            }
                            .frame(maxWidth: HT.cw * 40, alignment: .trailing)
                        } else {
                            Text("end of items ›").font(HT.body).foregroundStyle(HT.inkDim)
                        }
                    }
                }
            }
        }
        .task(id: date) { await load() }
    }

    private var metaText: some View {
        Text(date).font(HT.body).foregroundStyle(HT.inkDim).lineLimit(1)
    }

    private func load() async {
        doc = .loading
        do {
            if let text = try await model.store.cmoBriefing(date: date) {
                doc = .ok(text)
            } else {
                doc = .missing
            }
        } catch is CancellationError {
            return
        } catch {
            doc = .failed((error as? LocalizedError)?.errorDescription
                          ?? error.localizedDescription)
        }
    }
}
