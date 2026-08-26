import SwiftUI

/* The sessions, under the box.

   **A section rather than a page**, which is the whole of what the landing did
   to this list. It used to be the chat tab's front: a bar carrying the tab's
   name and a count, a rule, the standing sentence, the cards, and two doors
   marked `[+ new]`. The front is the composer now, so the bar's name is
   redundant, its count has moved onto the chip that opens this, and the doors
   are gone -- a new session is what typing into the box and pressing Return
   already does.

   What is left is exactly the part that was ever about the conversations
   themselves: the cards, the sweep that gathers several of them, the delete
   that arms before it acts, and the archive they go into and come back out of.
   None of that changed.

   **The rows come from above.** The chip over the composer counts these, so the
   landing polls the list and this is handed the answer -- one read, one clock,
   and no way for the number on the chip to disagree with the number of cards
   under it.

   **And so does the mode.** What is ticked, what is armed and what is open are
   held in an object the landing owns rather than in this view's own state, for
   one reason: the door into the mode is drawn on the chip's row, up there,
   because the chip is centred and a sibling beside it would push it off centre.
   Two views over one set of facts means one place the facts live.
*/

/// What the reader is in the middle of doing to the list. Held by the landing
/// so that the section and the door on the chip row are the same mode.
@MainActor
@Observable
final class ChatSelection {

    /// Which row is one click from being gone. One id rather than a set: arming
    /// a second row disarms the first, because two live confirmations on one
    /// list is a way to delete the wrong one.
    var armed: String?

    /// The one line under the list that says what did not happen. The pill
    /// carries the act rather than the failure: a sweep that could not archive
    /// is not a delete that did not happen, and `×del` over it would be naming
    /// the wrong verb.
    var note: NoteLine?

    /// The list is collecting rather than opening.
    ///
    /// **A mode, not a modifier click.** A sweep is several clicks long, and
    /// between any two of them the reader has to be able to see that this list
    /// is no longer the one that opens conversations -- which a held key cannot
    /// say and a control that reads `[done]` can.
    private(set) var selecting = false
    private(set) var selected: Set<String> = []

    /// The sweep's own arm, separate from `armed` because the two guard
    /// different things: one row about to go, or everything ticked.
    var armedSweep = false

    var showArchived = false

    struct NoteLine: Equatable {
        var tag: String
        var text: String
    }

    func enterSelect() {
        selecting = true
        // One armed thing at a time on one list. The row that was one click from
        // going takes its arm with it into the mode, and the line about the last
        // failure is about a list the reader has stopped reading.
        armed = nil
        note = nil
    }

    func leaveSelect() {
        selecting = false
        selected = []
        armedSweep = false
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var counted: String {
        "\(selected.count) conversation\(selected.count == 1 ? "" : "s")"
    }

    /// Unwind one confirmation, innermost first: the sweep's, then the mode that
    /// confirmation lives in, then a single row's own arm. Answers false when
    /// there was nothing to unwind, so the key that asked can go elsewhere.
    ///
    /// One per press. A key that undid two of them at once would take back a
    /// decision the reader had not asked to take back.
    @discardableResult
    func escape() -> Bool {
        if armedSweep { armedSweep = false; return true }
        if selecting { leaveSelect(); return true }
        if armed != nil { armed = nil; return true }
        return false
    }

    /// The selection, reconciled against a list that is re-read every five
    /// seconds. A conversation taken away from the web console would otherwise
    /// keep its place in the count and in the next sweep, which would be acting
    /// on something that is not there.
    func reconcile(_ rows: [ChatThreadSummary]) {
        selected.formIntersection(rows.map(\.id))
    }
}

/// The door into the mode and the door back out, drawn on the chip's row.
///
/// Nothing to collect on an empty list. Once the mode is on the control stays
/// whatever the list does underneath it, so a sweep that emptied the page still
/// has its way out.
struct ChatSelectDoor: View {
    var pick: ChatSelection
    var empty: Bool

    var body: some View {
        if pick.selecting || !empty {
            ChatTextButton(
                text: pick.selecting ? "[done]" : "[select]",
                ink: HT.inkMid,
                label: pick.selecting ? "Done selecting" : "Select conversations") {
                if pick.selecting { pick.leaveSelect() } else { pick.enterSelect() }
            }
        }
    }
}

struct ChatSessionList: View {

    var model: MailModel
    var pick: ChatSelection
    /// The collector's answer, as the landing last read it: the rows that are
    /// not put away, and the ones that are.
    var rows: [ChatThreadSummary]
    var archivedRows: [ChatThreadSummary]
    /// Re-read, after a write. The clock belongs to the landing.
    var reload: () async -> Void
    var open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // While the list is collecting, the sweep's own line stands at the
            // head of the section. The standing sentence is under the cards on
            // this page rather than over them, so there is nothing up here for
            // it to take the place of -- this is simply where the controls for
            // a mode belong, which is beside what the mode is about.
            if pick.selecting { sweepLine.padding(.bottom, HT.s1) }

            list
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - the sweep

    /// What is selected and what can be done to it.
    @ViewBuilder
    private var sweepLine: some View {
        if pick.selected.isEmpty {
            ChatNote("click a conversation to select it")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
                Text("\(pick.selected.count) selected")
                    .font(HT.body)
                    .foregroundStyle(HT.inkBright)
                    .lineLimit(1)

                // **No confirmation on archive**, on purpose. The collector can
                // put every one of these back, the line that does it is on this
                // same page, and `[sure?]` over an act with nothing behind it
                // teaches the reader to click through the one that has.
                ChatTextButton(text: "[archive]", label: "Archive \(pick.counted)") {
                    Task { await sweepArchive() }
                }
                sweepDeleteControl

                Spacer(minLength: 0)
            }
            .frame(height: HT.row)
        }
    }

    /* Taking several conversations away, in the row's own idiom one size up:
       the control writes what the next click will do into its own label, and a
       second click is the act.

       The count is in the armed label rather than only above it, because a
       sweep is the one delete on this page where the reader can have lost track
       of how much is ticked -- and the number is the whole question. */
    private var sweepDeleteControl: some View {
        ChatTextButton(
            text: pick.armedSweep ? "[sure? delete \(pick.selected.count)]" : "[delete]",
            ink: pick.armedSweep ? HT.fault : HT.inkMid,
            hoverInk: HT.fault,
            label: pick.armedSweep
                ? "Confirm deleting \(pick.counted)"
                : "Delete \(pick.counted)") {
            if pick.armedSweep { Task { await sweepDelete() } } else { pick.armedSweep = true }
        }
    }

    // MARK: - the sessions

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            // "yet" would be a lie about a box whose conversations are all put
            // away, with the archived line directly under it saying so.
            ChatNote(archivedRows.isEmpty ? "no sessions yet" : "every session is archived")
        } else {
            VStack(alignment: .leading, spacing: HT.s1) {
                ForEach(rows) { card($0, restorable: false) }
            }
        }

        if let note = pick.note {
            HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                StatusPill(text: note.tag, tone: .fault, glyph: false)
                Text(note.text)
                    .font(HT.body)
                    .foregroundStyle(HT.fault)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HT.row)
        }

        archivedSection
    }

    /* Put away is not gone, and this is the half of the list that proves it.

       **Behind a door rather than always open**: the archived rows are the ones
       the reader took out of the way, and a list that drew them anyway would
       have made archiving a delete with a gentler word. **Behind a labelled
       door rather than none**, for the other half of the same reason -- a
       conversation nobody can find again was deleted whatever the button said,
       so the count is on the page even while the section is shut. */
    @ViewBuilder
    private var archivedSection: some View {
        if !archivedRows.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                Text("\(archivedRows.count) archived ·")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineLimit(1)
                ChatTextButton(text: pick.showArchived ? "[hide]" : "[show]",
                               ink: HT.inkMid,
                               label: pick.showArchived
                                   ? "Hide archived conversations"
                                   : "Show archived conversations") {
                    pick.showArchived.toggle()
                }
                Spacer(minLength: 0)
            }
            .padding(.top, HT.row)

            if pick.showArchived {
                // A rule rather than a heading: the line above already named
                // the section, and this only has to say where it starts.
                Rectangle().fill(HT.line).frame(height: 1).padding(.top, HT.s1)
                VStack(alignment: .leading, spacing: HT.s1) {
                    ForEach(archivedRows) { card($0, restorable: true) }
                }
                .padding(.top, HT.s1)
            }
        }
    }

    private func card(_ t: ChatThreadSummary, restorable: Bool) -> some View {
        // The restore closure is what makes a card an archived one: it is the
        // control the reserved column draws instead of the delete, and only a
        // row that is already put away has anywhere to be put back to.
        let putBack: (() -> Void)? = restorable ? { Task { await restore(t) } } : nil
        return SessionCard(
            thread: t,
            now: model.now,
            armed: pick.armed == t.id,
            selecting: pick.selecting,
            selected: pick.selected.contains(t.id),
            open: { open(t.id) },
            arm: { pick.armed = t.id; pick.note = nil },
            remove: { Task { await remove(t) } },
            toggle: { pick.toggle(t.id) },
            restore: putBack)
    }

    // MARK: - acting

    private func remove(_ t: ChatThreadSummary) async {
        pick.armed = nil
        let name = chatUntitled(t.title)
        switch await model.store.chatDelete(id: t.id) {
        case .busy:
            pick.note = .init(tag: "×del", text: "\(name) · a turn is in flight")
        case .failed:
            pick.note = .init(tag: "×del", text: "\(name) · not deleted")
        case .ok:
            pick.note = nil
        }
        await reload()
    }

    private func restore(_ t: ChatThreadSummary) async {
        let name = chatUntitled(t.title)
        let result = await model.store.chatArchive(id: t.id, archived: false)
        pick.note = result == .ok ? nil : .init(tag: "×arc", text: "\(name) · not restored")
        await reload()
    }

    /// Put the selection away.
    ///
    /// One request per conversation, because the collector has no route that
    /// takes a list -- and no `busy` branch to draw, because the flag lives
    /// outside the thread file and a turn in flight does not hold it.
    private func sweepArchive() async {
        var refused = 0
        for id in pick.selected {
            if await model.store.chatArchive(id: id, archived: true) != .ok { refused += 1 }
        }
        pick.note = refused == 0 ? nil : .init(tag: "×arc", text: "\(refused) not archived")
        // The selection was consumed either way: the rows that went are gone
        // from this list, and a set still holding the ones that did not would be
        // arming the next sweep on the reader's behalf.
        pick.leaveSelect()
        await reload()
    }

    private func sweepDelete() async {
        pick.armedSweep = false
        var refused = 0
        var inFlight = 0
        for id in pick.selected {
            switch await model.store.chatDelete(id: id) {
            case .ok: break
            case .busy: refused += 1; inFlight += 1
            case .failed: refused += 1
            }
        }
        // The reason goes on the line only when it is the reason for all of
        // them: "a turn is in flight" under a mixed sweep would be an
        // explanation for some of what happened, which is worse than none.
        if refused == 0 {
            pick.note = nil
        } else {
            pick.note = .init(tag: "×del",
                              text: refused == inFlight
                                  ? "\(refused) not deleted · a turn is in flight"
                                  : "\(refused) not deleted")
        }
        pick.leaveSelect()
        await reload()
    }
}

// MARK: - one conversation, as a card

/* Two lines and a reserved column. Line one is what was asked, drawn as the
   transcript draws a user turn -- the prompt's own `$`, the question in the
   brightest ink on the page -- with the state and the clock flush right and no
   dots between. Line two is what came back, indented to where the transcript
   puts an answer under its question, with the byline after it.

   **The four states are told apart three ways over**: by the word beside the
   clock, by the glyph before that word, and by the rail down the left edge. Only
   the third is colour, so the card survives being printed 1-bit.

   **A rail means something is wrong.** An idle card carries none -- rule 6
   applied to a list. A faint rail down fifty cards is a wall of frames, and the
   two that are actually amber stop being found.
*/
struct SessionCard: View {

    var thread: ChatThreadSummary
    var now: Date
    var armed: Bool
    /// The list is collecting. A click gathers the card instead of opening it,
    /// and the row says which of the two it is doing in the column the prompt
    /// usually has.
    var selecting: Bool
    var selected: Bool
    var open: () -> Void
    var arm: () -> Void
    var remove: () -> Void
    var toggle: () -> Void
    /// Present only on a row that is already put away, and the way this card
    /// knows it is one: the reserved column draws it instead of the delete.
    var restore: (() -> Void)?

    @State private var hovering = false

    private var state: ChatStateWord {
        ChatStateWord(queued: thread.queued, status: thread.status)
    }

    private var live: Bool { chatInFlight(queued: thread.queued, status: thread.status) }
    private var blank: Bool { thread.title.isEmpty && thread.turnCount == 0 }
    private var title: String { chatUntitled(thread.title) }

    /// The rail, or nothing. Running and queued share amber on purpose -- they
    /// are one fact to a reader ("not yours right now") and the words beside them
    /// are what tell them apart.
    private var rail: Color? {
        if live { return HT.caution }
        if thread.status == .error { return HT.fault }
        return nil
    }

    /// What line two says, in the order the reader needs it. A thread being
    /// answered right now says so with the cursor rather than with stale text; a
    /// thread that failed says that instead of an answer, because that is what
    /// happened instead of one.
    ///
    /// **The runner's own reason is not available here.** `ChatThreadSummary` has
    /// no error field -- only the thread does, and the list route never fetches
    /// one -- so a failed card carries the view's own word.
    private var said: (text: String, ink: Color, cursor: Bool) {
        if live {
            return (thread.queued ? "waiting for the runner" : "answering", HT.caution, true)
        }
        if thread.status == .error { return ("the session failed", HT.fault, false) }
        if let preview = thread.preview, !preview.isEmpty { return (preview, HT.inkMid, false) }
        return (blank ? "nothing asked yet" : "no answer yet", HT.inkMid, false)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: selecting ? toggle : open) {
                VStack(alignment: .leading, spacing: 0) {
                    ask
                    saidRow
                }
                .padding(.vertical, HT.s1)
                .padding(.leading, HT.cw2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            // A column that is always reserved, so nothing on the card can be
            // drawn over the control at any width. Hidden at rest: ten cards each
            // carrying a visible delete is a column of buttons down a page whose
            // job is reading. Hidden outright while the list is collecting: a
            // per-row act inside a mode about the selection is a second thing
            // for the same click to mean.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if !selecting, hovering || armed { rowControl }
            }
            .frame(width: HT.cw * 11)
            .padding(.trailing, HT.cw2)
        }
        // A card is one step off the ground; the card under the cursor is two,
        // and so is a card that has been gathered -- the same step, because
        // being pointed at and being picked are both "this one".
        .background(selected || hovering ? HT.surface3 : HT.surface2)
        .overlay(alignment: .leading) {
            if let rail { Rectangle().fill(rail).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: chatRadius, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var ask: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            // The prompt column doubles as the selection mark while the list is
            // collecting: one column, one meaning at a time, and the `$` has
            // nothing to say about a card that is being counted rather than
            // opened. A glyph inside the brackets rather than a colour on them,
            // so ticked and not ticked survive being printed 1-bit.
            if selecting {
                Text(selected ? "[+]" : "[ ]")
                    .font(HT.body)
                    .foregroundStyle(selected ? HT.inkBright : HT.inkMid)
            } else {
                // Dim on both marks for a session nobody has typed into: an
                // empty one has no question in it and the green `$` would be
                // claiming one.
                Text("$")
                    .font(HT.body)
                    .foregroundStyle(blank ? HT.inkMid : HT.prompt)
            }
            Text(title)
                .font(HT.body)
                .foregroundStyle(blank ? HT.inkMid : HT.inkBright)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                if !state.glyph.isEmpty {
                    Text("\(state.glyph) \(state.word)")
                        .font(HT.body)
                        .foregroundStyle(state.tone.ink ?? HT.inkMid)
                        .lineLimit(1)
                }
                Text(Fmt.relTime(thread.updatedAt, now: now))
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.leading, HT.cw2)
        }
        .frame(height: HT.row)
    }

    private var saidRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Clipped at one line on purpose: this is scanned, not read, and
                // the reader who wants the rest of it is one click from all of
                // it.
                Text(said.text)
                    .font(HT.body)
                    .foregroundStyle(said.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The block cursor, spent on the single card whose whole claim is
                // "still writing".
                if said.cursor { BlinkCursor().padding(.leading, HT.cw) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // What the document IS, as opposed to where it is now: which model,
            // how much conversation. The byline of a document rather than a
            // reading at the right margin.
            Text(byline)
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: HT.row)
        .padding(.leading, HT.cw2)
    }

    private var byline: String {
        guard thread.turnCount > 0 else { return thread.model.rawValue }
        return "\(thread.model.rawValue) · \(thread.turnCount) "
            + (thread.turnCount == 1 ? "turn" : "turns")
    }

    /// What the reserved column offers this row. An archived card's one act is
    /// getting out of the archive, and the delete it would otherwise carry is
    /// still there a click later, on the row it goes back to.
    @ViewBuilder
    private var rowControl: some View {
        if let restore {
            // No arming. Restoring is the undo of an act that was itself
            // reversible, and a `[sure?]` on it would be asking a question with
            // nothing behind it.
            ChatTextButton(text: "[restore]", ink: HT.inkMid, hoverInk: HT.inkBright,
                           label: "Restore \(title)", action: restore)
        } else {
            deleteControl
        }
    }

    /* Taking a conversation away, in two clicks and no dialog.

       **Armed rather than confirmed in a modal**, which is the console's own
       idiom and the only one available to a row: the control writes what the
       next click will do into its own label, so the question and the button are
       the same four characters of screen. `[x]` is a door; `[sure?]` is the act,
       and it is drawn in fault tone with a word rather than only a colour.

       Deliberately not the reader's only line of defence: the collector refuses
       to delete a thread with a turn in flight, which is the case where a stray
       click would cost something a subprocess is still writing. */
    private var deleteControl: some View {
        ChatTextButton(text: armed ? "[sure?]" : "[x]",
                       ink: armed ? HT.fault : HT.inkMid,
                       hoverInk: HT.fault,
                       label: armed ? "Confirm deleting \(title)" : "Delete \(title)") {
            if armed { remove() } else { arm() }
        }
    }
}
