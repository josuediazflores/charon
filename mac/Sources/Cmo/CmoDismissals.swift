import Foundation
import Observation
import SwiftUI

/* What the user has waved off, as the three views need to read it.
 *
 * **The payload is the truth and this is the minute before it catches up.**
 * `dismissed.jsonl` travels in the telemetry document like everything else, so
 * the confirmed list arrives on a later poll -- and later can be a while: the
 * console polls every 10s but the collector re-reads the CMO's files on its own
 * 60s cadence, so a dismissal is confirmed in about a minute rather than in a
 * tick. What a click needs is for the row to dim NOW. So this holds one small
 * overlay of pending changes and merges it over the payload's list for however
 * long the confirmation takes.
 *
 * **Pending entries are pruned the moment the payload agrees**, which is what
 * keeps this from becoming a second source of truth -- exactly the contract
 * `MailModel`'s pending sets follow, and for the same reason. Without it a
 * dismissal made from the web console would be overridden here forever by an
 * overlay that had already got what it asked for.
 *
 * **Nothing on this page is deleted.** A dismissed item stays in the agent's
 * memory, which is what stops it being rediscovered as new next week; the
 * archive is where it goes to be out of the way, and every row restores in one
 * click.
 */

@MainActor
@Observable
final class CmoDismissals {

    private enum PendingState { case dismissed, restored }

    private struct Pending {
        var state: PendingState
        /// Carried whole so the archive can list an optimistic dismissal as a
        /// row before the collector has written its `dismissed_at`.
        var entry: CmoDismissed
    }

    private var pending: [String: Pending] = [:]

    /// What the last payload confirmed. Newest first, straight off the
    /// collector's own tail.
    private var confirmed: [CmoDismissed] = []

    /// The console's one store, for the two write routes. Held rather than
    /// passed to every call site: the control that files a dismissal lives
    /// inside the markdown renderer, three views below the page.
    private weak var model: MailModel?

    func bind(_ model: MailModel) {
        if self.model !== model { self.model = model }
    }

    /// Take the payload's list, and drop every pending entry it now agrees
    /// with. Called on each poll from the tab that owns this.
    func reconcile(_ payload: TelemetryPayload?) {
        confirmed = payload?.cmo?.data?.dismissed ?? []
        guard !pending.isEmpty else { return }
        let keys = Set(confirmed.map(\.key))
        pending = pending.filter { key, p in
            // The payload now says what this entry was asking for, so the entry
            // has nothing left to add.
            keys.contains(key) != (p.state == .dismissed)
        }
    }

    /// Every dismissal in effect, newest first.
    var all: [CmoDismissed] {
        let keys = Set(confirmed.map(\.key))
        let held = confirmed.filter { pending[$0.key]?.state != .restored }
        // Optimistic ones first: the list is newest-first and these are the
        // newest things there are.
        let fresh = pending.values
            .filter { $0.state == .dismissed && !keys.contains($0.entry.key) }
            .map(\.entry)
            .sorted { $0.dismissedAt > $1.dismissedAt }
        return fresh + held
    }

    /// Whether this exact thing is dismissed right now.
    func has(_ kind: CmoDismissKind, _ title: String, _ date: String) -> Bool {
        let key = Dismissal.key(kind, title, date)
        if let p = pending[key] { return p.state == .dismissed }
        return confirmed.contains { $0.key == key }
    }

    func has(_ entry: Dismissal) -> Bool { has(entry.kind, entry.title, entry.date) }

    /// Both resolve false when the collector refused or was unreachable, and
    /// roll the optimistic change back before they do.
    @discardableResult
    func dismiss(_ entry: Dismissal) async -> Bool { await act(entry, .dismissed) }

    @discardableResult
    func restore(_ entry: Dismissal) async -> Bool { await act(entry, .restored) }

    private func act(_ entry: Dismissal, _ state: PendingState) async -> Bool {
        let key = entry.key
        pending[key] = Pending(
            state: state,
            entry: CmoDismissed(kind: entry.kind, title: entry.title, lane: entry.lane,
                                date: entry.date, dismissedAt: Fmt.stampNow()))

        guard let store = model?.store else {
            pending.removeValue(forKey: key)
            return false
        }
        let ok = state == .dismissed
            ? await store.cmoDismiss(entry)
            : await store.cmoRestore(entry)

        if !ok {
            // Rolled back rather than left hopeful. The control says FAILED and
            // the row goes back to what the collector still believes, which is
            // true.
            pending.removeValue(forKey: key)
        }
        return ok
    }
}

/* ── DismissControl ────────────────────────────────────────────────────
   [ DISMISS ]   [ DISMISSED · RESTORE ]   [ FAILED ]

   The control that curates: one button, both directions.

   Drawn as the reader's COPY is -- a ghost button in caps -- because it is the
   same kind of thing: a small action on the block it sits under.

   **The label is the whole state channel.** It says what has happened and what
   the next click will do, in words, so nothing here depends on hue and the page
   survives being printed 1-bit. The flash after a click follows COPY's two
   seconds, and a refusal says FAILED rather than quietly leaving an optimistic
   row dimmed over a write that never landed.
*/
struct DismissControl: View {
    var entry: Dismissal
    /// Drop the state half of the label where the surround already states it --
    /// an archive row is dismissed by definition, and a draft footer is short
    /// on line.
    var terse: Bool = false

    @Environment(CmoDismissals.self) private var dismissals
    @State private var flash: String?
    @State private var flashToken = 0

    private var on: Bool { dismissals.has(entry) }

    private var label: String {
        if let flash { return flash }
        if on { return terse ? "restore" : "dismissed · restore" }
        return "dismiss"
    }

    var body: some View {
        HTButton(title: label, variant: .ghost, size: .sm, caps: true) {
            let wasOn = on
            Task {
                let ok = wasOn
                    ? await dismissals.restore(entry)
                    : await dismissals.dismiss(entry)
                show(ok ? (wasOn ? "restored" : "dismissed") : "failed")
            }
        }
    }

    /// Two seconds, then back to the standing label. The token is what keeps a
    /// second click from being cleared by the first click's timer.
    private func show(_ word: String) {
        flash = word
        flashToken &+= 1
        let mine = flashToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            if flashToken == mine { flash = nil }
        }
    }
}
