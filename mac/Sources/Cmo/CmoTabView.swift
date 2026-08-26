import AppKit
import SwiftUI

/* The CMO tab, and the six places inside it.
 *
 * The web reads these out of the address bar -- `#cmo/archive`,
 * `#cmo/2026-08-15/3`, `#cmo/ask/new` -- and a native window has no address
 * bar, so an enum stands in for the hash. The rule the hash encodes survives
 * the translation: a malformed sub-segment lands on the tab rather than on an
 * empty reader, which here is simply a route that cannot be constructed.
 *
 * **The curation overlay and the two read-state stores are the shell's**, and
 * arrive here as properties: a dismissal takes about a minute to be confirmed
 * and a tab is switched away from in a second. They are put into the
 * environment from here because the dismiss control lives inside the markdown
 * renderer, three views below any page, and threading a set and two callbacks
 * through a switch over block kinds would put this feature's plumbing in the
 * one file whose whole job is drawing markdown.
 */

/// Where the briefing reader was told to land.
enum ReaderScope: Equatable {
    case whole
    /// An ordinal into the payload's `agent.items`.
    case item(Int)
    /// The ✍️ section.
    case drafts
}

enum CmoFileKind: String, Equatable {
    case watch, doc
}

enum CmoRoute: Equatable, Hashable {
    case tab
    case archive
    case briefings
    /// `thread` nil is the newest conversation; `fresh` is the empty window,
    /// whose prompt starts a conversation instead of continuing one.
    case ask(thread: String?, fresh: Bool)
    case file(kind: CmoFileKind, slug: String)
    case briefing(date: String, scope: ReaderScope)
}

extension ReaderScope: Hashable {}
extension CmoFileKind: Hashable {}

struct CmoTabView: View {

    var model: MailModel
    var payload: TelemetryPayload
    var feedDown: Bool

    /// Held by the shell, because a curation overlay has to outlive a tab
    /// switch and a read-state has to outlive a page.
    var dismissals: CmoDismissals
    var watchSeen: SeenMarks
    var docsSeen: SeenMarks

    /// The route, and only the route, is the tab's own. The web loses its
    /// `#cmo/...` sub-route the moment another tab is opened, and so does this.
    @State private var route: CmoRoute = .tab

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: HT.row) {
                // The anchor every route change jumps to. Arriving from a long
                // tab the console is scrolled wherever the grid left it, and
                // every route here is its own page. No smooth behaviour: a
                // terminal repaints, it does not animate.
                Color.clear.frame(height: 0).id("cmo-top")
                page
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: route) { _, _ in proxy.scrollTo("cmo-top", anchor: .top) }
        }
        .environment(dismissals)
    }

    /// The address the `raw` links point at, in live mode only. A fixture has
    /// no collector behind it and a link to nothing is worse than no link.
    private var rawBase: URL? {
        model.connection.mode == .live ? model.connection.url : nil
    }

    @ViewBuilder
    private var page: some View {
        switch route {
        case .tab:
            CmoView(model: model, payload: payload, feedDown: feedDown,
                    watchSeen: watchSeen, docsSeen: docsSeen,
                    navigate: { route = $0 })

        case .archive:
            CmoArchiveView(payload: payload, feedDown: feedDown,
                           navigate: { route = $0 })

        case .briefings:
            CmoBriefingsView(payload: payload, feedDown: feedDown,
                             navigate: { route = $0 })

        case .ask(let thread, let fresh):
            CmoAskView(model: model, payload: payload, thread: thread, fresh: fresh,
                       navigate: { route = $0 })

        case .file(let kind, let slug):
            CmoFileView(model: model, kind: kind, slug: slug,
                        base: rawBase, navigate: { route = $0 })

        case .briefing(let date, let scope):
            CmoReaderView(model: model, payload: payload, date: date, scope: scope,
                          base: rawBase, navigate: { route = $0 })
        }
    }
}

// MARK: - shared chrome

/// The breadcrumb line every page under the tab opens with: where you are on
/// the left, what this page is and the way out to the file on the right.
struct CmoBar<Trail: View>: View {
    /// The crumbs after `◂ cmo`, each with an optional destination. A crumb
    /// with nowhere to go is where you already are.
    var crumbs: [(text: String, route: CmoRoute?)]
    var navigate: (CmoRoute) -> Void
    @ViewBuilder var trail: Trail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                CmoLink(text: "◂ cmo") { navigate(.tab) }
                ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                    Text(" / ").font(HT.body).foregroundStyle(HT.inkDim)
                    if let route = crumb.route {
                        CmoLink(text: crumb.text) { navigate(route) }
                    } else {
                        Text(crumb.text)
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: HT.cw2) { trail }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A destination inside the console, drawn in ink rather than in a hue: the
/// pages this reaches are all one tab deep, and colouring them would spend a
/// meaning on a breadcrumb.
struct CmoLink: View {
    var text: String
    var dim: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(HT.body)
                .foregroundStyle(hovering ? HT.inkBright : (dim ? HT.inkDim : HT.ink))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

/// The one way out to the file itself, for anyone who would rather read it raw.
///
/// Drawn only in live mode, and only with an address to point at: the route
/// wants the console's own session, so this opens in the browser the same way
/// the web console's own `raw` link does. A demo has no collector behind it and
/// a link to nothing is worse than no link.
struct RawLink: View {
    var base: URL?
    var path: String

    var body: some View {
        if let base {
            CmoLink(text: "raw", dim: true) {
                NSWorkspace.shared.open(base.appendingPathComponent(path))
            }
        }
    }
}

/// The sentence a page ends on: dim, full width, and never a control.
struct CmoNote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(HT.body)
            .foregroundStyle(HT.inkDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
