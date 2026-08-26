import Foundation
import SwiftUI

/* Read-state for one list, per copy of the app: the ● says "this row carries a
 * timestamp you have not looked at from here", and opening the row clears it.
 *
 * `UserDefaults` rather than the Pi, because seen-ness is a property of this
 * screen's reader and not of the data, and the cost of another device showing
 * the dot again is zero. Keyed on the timestamp rather than a boolean, so a row
 * that moves again after being read goes back to unseen.
 *
 * Two lists use this -- the watchlist and the documents table -- and they must
 * not share a key, so the key is the argument: a company and a document could
 * be called the same thing, and acknowledging one is not acknowledging the
 * other. Conversations deliberately have no dot: an unread badge is for things
 * that change without him, a thread he started cannot surprise him, and the ask
 * window prints [~ASK] thinking on the one state worth a word anyway.
 */
@MainActor
@Observable
final class SeenMarks {
    private let storageKey: String
    private var seen: [String: String]

    init(_ storageKey: String) {
        self.storageKey = storageKey
        seen = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func mark(_ name: String, _ when: String?) {
        guard let when, !when.isEmpty, seen[name] != when else { return }
        seen[name] = when
        UserDefaults.standard.set(seen, forKey: storageKey)
    }

    func isNew(_ name: String, _ when: String?) -> Bool {
        guard let when, !when.isEmpty else { return false }
        return seen[name] != when
    }
}

/// The unseen mark itself, so every list draws it the same way. A glyph, not a
/// hue: present or absent survives being printed 1-bit. The label is per list
/// because the dots mean different things -- a company moved, a document was
/// rewritten -- and only a screen reader is ever told which.
struct NewDot: View {
    var label: String

    var body: some View {
        PixelGlyph(name: .dot, color: HT.inkBright)
            .accessibilityLabel(Text(label))
            .accessibilityHidden(false)
    }
}
