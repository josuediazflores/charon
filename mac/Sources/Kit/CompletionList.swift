import SwiftUI

/* ── CompletionList ────────────────────────────────────────────────────
     ┌──────────────────────────────────────────────┐
     │ / cmo     ground the answer in the CMO's files│
     │ → cite    every claim names the file or url … │
     └──────────────────────────────────────────────┘
     $ @c|

   The list that opens over a half-typed word, and the state behind it.

   **A sibling of `Listbox` and deliberately not a reuse of it.** They draw the
   same recipe -- an opaque ground, one bright rule around it, rows a cell tall
   with a reserved glyph column -- and they are worked completely differently.
   A `Listbox` is a control: it owns a focusable `Button`, its keyboard is
   bolted to that button's `onKeyPress`, and opening it means the caret is in
   it. A completion list must never take the caret: the whole point of it is
   that somebody is typing, in a text view, and the arrow keys have to reach
   this list *without* the text view ever stopping being the first responder.
   So this one has no button, no focus and no keyboard of its own. It is a
   picture of a model, and the keys are routed into that model by whoever owns
   the field -- `PromptBox`, from `doCommandBy`.

   **It opens upward.** Same reason `Listbox` does: its home is the composer at
   the bottom of the chat page, and a list dropping downward from there would
   open into the window's own bottom edge. The offset is the caller's, because
   only the caller knows where the `@` is.

   **The glyph column is the kind, not the current value.** A `Listbox` marks
   the row you are on with a dot, because a picker has a value. A completion
   list has no value yet, so the reserved cell is spent on the thing a reader
   actually needs before they choose: whether this word names a place or gives
   an order. One shape per kind, so the distinction survives the colour being
   thrown away.
*/

// MARK: - a row

/// One offer: the mark, the word, what it will do, and the text that lands in
/// the field if it is taken.
///
/// `insert` is separate from `name` and that is the point of it: what is shown
/// is a bare word, what is typed is the whole token with its sigil back on. The
/// caller builds both, because the caller is the only one that knows the
/// grammar the field is being completed in.
struct CompletionRow: Identifiable, Equatable {
    /// One cell, and a shape rather than a tint. See the file note.
    var glyph: String
    var name: String
    var hint: String
    var insert: String

    var id: String { name }
}

// MARK: - the state

/// What the list is showing and where, written by the field and read by the
/// picture.
///
/// `@Observable` and owned by the view that draws the popup, the way
/// `MailModel` and `ConsoleSettings` are owned: the field's coordinator is an
/// AppKit object living outside SwiftUI's update cycle, and this is the one
/// wire back into it. Everything the field writes goes through the three
/// methods below rather than through the properties, so "offered", "closed" and
/// "moved" are three things that happen rather than five properties that have
/// to be set in the right order.
@Observable
final class CompletionModel {

    /// The rows on offer, already filtered and already in the order they should
    /// be read.
    private(set) var rows: [CompletionRow] = []
    /// Which row the cursor is on. Keyboard and mouse share it, so arrowing and
    /// pointing cannot disagree about where you are.
    private(set) var cursor = 0
    private(set) var open = false
    /// What has been typed into the token so far. Not drawn -- the field is
    /// already showing it, an inch below -- but held because it is what a trace
    /// of this thing has to print to be worth reading.
    private(set) var query = ""
    /// Where the token being completed sits, in the coordinate space of the
    /// view that draws the popup: origin top-left, y down. The field converts
    /// into that space, because the field is the only thing that knows about
    /// its own scroller.
    private(set) var anchor: CGRect = .zero

    /// Taking a row by pointing at it. Installed by the field, because
    /// accepting means editing text and the list has no text to edit.
    /// Ignored by observation: it is plumbing, not something drawn.
    @ObservationIgnored var onPick: ((Int) -> Void)?

    /// The row an accept would take, or nil if there is nothing to take.
    var chosen: CompletionRow? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    /// Show these rows for this token.
    ///
    /// The cursor survives a re-offer of the *same* rows and resets on a
    /// different set: re-anchoring because the caret moved a cell should not
    /// throw away which row somebody had arrowed to, and narrowing the list
    /// from eight words to two must not leave the cursor pointing at a row that
    /// is no longer the row it was pointing at.
    func offer(_ next: [CompletionRow], query: String, anchor: CGRect) {
        if next != rows {
            rows = next
            cursor = 0
        }
        self.query = query
        self.anchor = anchor
        open = !next.isEmpty
    }

    /// Nothing to complete, or somebody said so. Idempotent on purpose: the
    /// field closes this from four different places and none of them should
    /// have to check first.
    func close() {
        guard open || !rows.isEmpty else { return }
        open = false
        rows = []
        cursor = 0
        query = ""
    }

    /// Move the cursor by a row, wrapping. The wrap is `Listbox`' own
    /// arithmetic: a list of eight is a ring, and arrowing off the end of it
    /// into a dead stop is a keyboard that behaves differently at the edges for
    /// no reason a reader can see.
    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        cursor = (cursor + step % rows.count + rows.count) % rows.count
    }

    /// The pointer is over a row. Same cursor the arrows move.
    func point(at index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    /// The pointer took a row.
    func pick(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
        onPick?(index)
    }
}

// MARK: - the picture

struct CompletionList: View {

    var model: CompletionModel
    /// Announced, never drawn.
    var label: String = "Completions"

    /// The name column, in cells, from the widest word actually on offer plus
    /// one for the gap. Computed rather than fixed at six so a longer word than
    /// `jarvis` does not push its own hint out of the column the others are in.
    private var nameWidth: CGFloat {
        CGFloat((model.rows.map(\.name.count).max() ?? 0) + 1) * HT.cw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                CompletionListRow(
                    row: row,
                    nameWidth: nameWidth,
                    under: index == model.cursor,
                    hover: { model.point(at: index) },
                    pick: { model.pick(index) })
            }
        }
        // As wide and as tall as it needs to be. The height needs no ceiling:
        // the vocabulary this completes is eight words long by design, so the
        // tallest this can ever be is eight rows, which is half the composer's
        // own page.
        .fixedSize(horizontal: true, vertical: true)
        // Masked with a bright rule, because it sits over live transcript: the
        // surface tints used elsewhere are a few percent of luminance and the
        // answer underneath would read straight through them. This is one of
        // the places the ground is painted opaque on purpose -- the same call
        // `Listbox` makes, for the same reason.
        .background(HT.groundMask)
        .overlay { Rectangle().strokeBorder(HT.lineBright, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

private struct CompletionListRow: View {
    var row: CompletionRow
    var nameWidth: CGFloat
    var under: Bool
    var hover: () -> Void
    var pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: HT.cw) {
                Text(row.glyph)
                    .frame(width: HT.cw, alignment: .leading)
                    .foregroundStyle(HT.inkDim)
                Text(row.name)
                    .frame(width: nameWidth, alignment: .leading)
                    .foregroundStyle(under ? HT.inkBright : HT.ink)
                Text(row.hint)
                    .foregroundStyle(HT.inkMid)
            }
            .font(HT.body)
            .lineLimit(1)
            .padding(.leading, HT.cw)
            .padding(.trailing, HT.cw2)
            .frame(height: HT.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The list's own mask is under this; a row that is not lit adds
            // nothing to it.
            .background(under ? HT.surface3 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing in this list may take the caret: it is open *because*
        // somebody is typing into the field underneath it.
        .focusEffectDisabled()
        .onHover { if $0 { hover() } }
        .accessibilityLabel(Text("\(row.name): \(row.hint)"))
    }
}
