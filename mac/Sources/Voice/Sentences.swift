import Foundation

/* The sentence extractor: a prefix cursor over `partial` snapshots -- ported
 * from the web console's sentence extractor.
 *
 * **Pure, and deliberately so.** Nothing in this file knows about SwiftUI,
 * URLSession, audio or the record; it is fed strings and it returns sentences.
 *
 * The stream it reads: the say runner rewrites `partial` as WHOLE TEXT every
 * half second, and the console samples that at 1s. So what arrives here is not
 * deltas but successive snapshots, each normally a superset of the last --
 * prefix-stable, which is what lets a cursor over the text stand in for a
 * stream of it. "Normally" carries three exceptions, each a seam in the
 * runner's own write pattern and each handled by name below:
 *
 *   1. **The fold note.** The runner paints "folding the day so far…" into
 *      `partial` before a folded day's answer and clears it afterwards.
 *      Neither transition is prefix-stable, and the note is housekeeping the
 *      runner never intended as speech. On any prefix mismatch the cursor
 *      resyncs to the new text and emits nothing.
 *   2. **The markers.** `[output truncated]` and `[stopped]` are the runner's
 *      annotations, appended to text that is otherwise the answer. They are
 *      stripped before the cursor ever compares anything.
 *   3. **The result text.** The stored turn prefers the CLI's own result over
 *      the accumulated stream, and the two are allowed to differ. `finalize`
 *      speaks only a remainder that prefix-matches what was already spoken; a
 *      final text that contradicts the stream is spoken not at all, because a
 *      voice that repeats or corrects itself is worse than one that stops.
 *
 * **No character is ever emitted twice.** That is the invariant everything here
 * bends to: on a seam where the spoken prefix itself has been rewritten, the
 * cursor swallows the new text rather than re-reading it, trading completeness
 * for never stuttering. The text lane always has the whole answer; the voice is
 * a convenience and silence is its safe failure.
 */

/// The runner's two annotations, stripped before any comparison. Their exact
/// spellings are the runner's, stated here rather than shared because the two
/// programs have no source in common -- a drift in either direction degrades to
/// the marker being spoken once, not to a crash.
private let markers = ["[output truncated]", "[stopped]"]

/// What ends a sentence, when followed by whitespace. `…` is in the set because
/// the runner's own fold note ends with one and models use it freely; a
/// terminator at the very end of a snapshot is NOT a boundary, because the next
/// poll may reveal it was mid-sentence ("3." growing into "3.5").
private let terminators: Set<Character> = [".", "!", "?", "…"]

/// Closers a terminator may hide behind -- `he said."` -- checked for one
/// position only. A heuristic, not a parser: "e.g. x" splits wrongly and is
/// accepted, because the cost is an odd pause and the alternative is a sentence
/// model in a dashboard.
private let closers: Set<Character> = ["\"", "'", ")", "]"]

final class SentenceCursor {

    /// The last snapshot, markers stripped.
    private var seen: [Character] = []
    /// How much of `seen` has been emitted. Everything before this index has
    /// been spoken and may never be spoken again; everything after it is the
    /// held tail. Monotonic within a snapshot lineage, reset only by a seam.
    private var consumed = 0

    /// One `partial` snapshot. Returns the complete sentences it newly
    /// contains, in order; the incomplete tail is held for the next call.
    func feed(_ partial: String) -> [String] {
        let text = Array(SentenceCursor.strip(partial))

        if text.starts(with: seen) {
            // The ordinary poll: the same text with more on the end, or exactly
            // the same text again -- carving from `consumed` makes the identical
            // resend a no-op rather than a repeat.
            seen = text
            let cut = SentenceCursor.carve(text, from: consumed)
            consumed = cut.upTo
            return cut.sentences
        }

        // A seam. Resync and emit nothing on this call -- the next poll reads
        // whatever the new text grows into, from wherever the cursor lands here.
        let emitted = Array(seen.prefix(consumed))
        if text.starts(with: emitted) {
            // Nothing already spoken is contradicted; only the unspoken tail was
            // rewritten. This is the fold note clearing, and the note jumping
            // straight to the answer: the cursor keeps its place and the answer
            // streams out from its own first character.
            seen = text
        } else {
            // The spoken prefix itself is gone. **Never emitting a character
            // twice outranks completeness**, so the new text is swallowed whole
            // and speech resumes from whatever comes after it.
            seen = text
            consumed = text.count
        }
        return []
    }

    /// The stored turn's text, at turn end. Returns the unspoken remainder --
    /// tail included, since nothing further is coming -- or nothing at all when
    /// the final text contradicts what already streamed.
    func finalize(_ finalText: String) -> [String] {
        let text = Array(SentenceCursor.strip(finalText))
        let emitted = Array(seen.prefix(consumed))
        guard text.starts(with: emitted) else {
            // The CLI's account of the turn contradicts what was already spoken.
            // Speaking its remainder would splice two tellings of one answer
            // mid-sentence; speaking nothing leaves the text lane, which has the
            // canonical copy, to carry it.
            return []
        }
        var cut = SentenceCursor.carve(text, from: consumed)
        // The turn is over, so the tail is not "incomplete" any more -- it is
        // however the answer actually ended.
        let tail = String(text[cut.upTo...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { cut.sentences.append(tail) }
        seen = text
        consumed = text.count
        return cut.sentences
    }

    // MARK: - the arithmetic

    private static func strip(_ text: String) -> String {
        var out = text
        for marker in markers { out = out.replacingOccurrences(of: marker, with: "") }
        return out
    }

    /// Complete sentences in `text` from `from`, and where the held tail starts.
    ///
    /// A boundary is a terminator followed by whitespace, or a blank line -- the
    /// second because a heading or a list item ends at its paragraph break
    /// whether or not the model punctuated it, and holding "## status" until a
    /// full stop arrives holds it forever.
    private static func carve(_ text: [Character],
                              from: Int) -> (sentences: [String], upTo: Int) {
        var sentences: [String] = []
        var start = from
        var i = from

        func push(_ end: Int) {
            guard start < end, end <= text.count else { return }
            let sentence = String(text[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }

        while i < text.count {
            if text[i] == "\n", i + 1 < text.count, text[i + 1] == "\n" {
                push(i)
                while i < text.count, text[i] == "\n" { i += 1 }
                start = i
                continue
            }
            if terminators.contains(text[i]) {
                var j = i + 1
                if j < text.count, closers.contains(text[j]) { j += 1 }
                if j < text.count, text[j] == " " || text[j] == "\n" || text[j] == "\t" {
                    push(j)
                    start = j
                    i = j
                    continue
                }
            }
            i += 1
        }
        return (sentences, start)
    }
}
