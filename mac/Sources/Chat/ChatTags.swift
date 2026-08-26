import AppKit
import SwiftUI

/* ── ChatTags ──────────────────────────────────────────────────────────
   $ @cmo what is the watchlist tracking?      typed
     ┌───┐
     │cmo│ what is the watchlist tracking?     drawn
     └───┘

   Nine words that point a turn somewhere before it is answered. Four name
   an architecture -- `@cmo`, `@mail`, `@jarvis`, `@messages` -- and five order
   the turn to do something before it answers: `@web` says search the internet
   first, `@files` says search this box first, `@box` says measure this machine
   first, `@today` says read only the last day of it, and `@cite` says every
   claim has to name its source. The Pi's runner reads them out of the message
   text and prepends a short block, naming the files to open or stating the
   order to keep -- so a tag is a prompt change and nothing else, and nothing
   about it travels in the API call. What this file does is the other half:
   find the same tokens the runner will find, so the composer can raise them
   while they are being typed and the transcript can keep them raised
   afterwards.

   **The two kinds are one vocabulary here, and almost entirely deliberately.**
   A directive is typed, bounded, boxed, deduped and stripped off a title
   exactly like an architecture; the only place they part is the block the
   runner renders, on the far side of the wire. Every rule below still runs off
   `vocabulary` and still cannot tell the two apart.

   **The one thing that now can, and why.** This file used to say that nothing
   in it knew which kind a name was and nothing in it should have to. That is
   revoked, for one reader: the composer's completion list. Nine words is more
   than a person keeps in their head, so the list has to be offerable -- and a
   list has to have an order, which a `Set` does not, and a row has to say what
   the word will do, which a bare name does not. So `registry` below is the
   vocabulary written down *as a list*, with a kind and a one-clause hint on
   each entry, and `vocabulary` is derived from it. The scan, the boundary
   rule, the chip and the strip are untouched and still ask only the Set.

   **The vocabulary and the boundary rule are one contract in two languages.**
   The runner's half is a regex,
   `(?<![\w.@-])@(cmo|mail|jarvis|messages|web|files|box|cite|today)\b` with
   IGNORECASE, built from the keys of `TAG_TARGETS` in
   collector/chat-runner.py beside `turn_tags`. This half is a
   character scan, in the shape `Markdown.inline` already uses here
   (Sources/Markdown.swift) -- no regex, because a second dialect of the same
   rule is a second thing to keep true. Change one, change the other: a token
   this file raises and the runner ignores is a promise the app cannot keep.
   The recipe for adding the ninth word is written out in TAGS.md at the root
   of `mac/`.

   The rule, stated once:

     * `@` may not be an infix. A word character, a `.`, a `-` or another `@`
       in front of it means this is an address or a path, not a tag --
       `user@cmo.example.com` is mail, `@@cmo` is a typo.
     * The name may not have more word on the end of it. `@cmojunk` is a word
       that starts with a tag and is not one; `@cmo,` at the end of a clause
       is a tag with a comma after it.
     * Case is ignored and the name is reported lowercased. `@CMO` is what a
       keyboard does at the start of a sentence, and a tag that silently did
       nothing there would be a rule the reader has to learn by being burned.
*/

enum ChatTags {

    // MARK: - the registry

    /// Which of the two things a tag is on the far side of the wire.
    ///
    /// Carried here for exactly one reader -- the completion list, which shows
    /// it in a reserved column so the two kinds separate before the hint is
    /// read. Nothing about the scan, the box or the strip branches on it, and
    /// nothing about them should: see the note at the top of the file.
    enum Kind {
        /// A place: a root on the Pi and the files in it worth opening first.
        case architecture
        /// An order: one thing the turn owes before it is answered.
        case directive

        /// The kind's mark, one cell wide.
        ///
        /// Shapes and not a tint, the way every other state in this console is
        /// told apart: `/` is what the head of a path looks like, and `→` is
        /// the arrow the composer's own status line and `ToolLines` already
        /// use for "and then this happens". Both survive the colour being
        /// thrown away, which is the whole of the rule.
        var glyph: String {
            switch self {
            case .architecture: return "/"
            case .directive: return "→"
            }
        }
    }

    /// One word in the vocabulary: what it is called, which kind it is, and
    /// what it will do said in one lowercase clause.
    ///
    /// The hint is condensed from the runner's own line for the same tag -- an
    /// `Architecture`'s label or a `Directive`'s imperative in
    /// collector/chat-runner.py -- rather than written fresh, so the
    /// row in the list and the block on the wire cannot come to say different
    /// things. Short enough to sit on one row beside the name.
    struct TagSpec {
        let name: String
        let kind: Kind
        let hint: String
    }

    /// The vocabulary, and the whole of it, **in order**. Nine words,
    /// deliberately: the tag set is a list somebody maintains, not an open
    /// namespace.
    ///
    /// **This is the only place a tag name is written down in this app.** The
    /// scan, the boundary rule, the chip, the folded sigil, the composer's
    /// counter, the completion list and the derived thread title all come back
    /// to this array -- so a ninth word is one line here, and a ninth word plus
    /// an edit somewhere else is a bug about to happen. TAGS.md at the root of
    /// `mac/` is the recipe.
    ///
    /// **The order is the list's order and it is a decision.** Architectures
    /// first, because a place is the coarser thing to reach for; then
    /// directives; each group in the order it shipped, which is also roughly
    /// the order they are reached for. A `Set` cannot hold that -- its
    /// iteration order is a hash artefact that moves between runs -- and a
    /// completion list whose rows shuffled between two keystrokes would be a
    /// list nobody could build muscle memory on. That is the whole reason this
    /// is an array and `vocabulary` is derived from it rather than the other
    /// way round.
    static let registry: [TagSpec] = [
        TagSpec(name: "cmo", kind: .architecture,
                hint: "ground the answer in the CMO's files"),
        TagSpec(name: "mail", kind: .architecture,
                hint: "read the mail pipeline's own state"),
        TagSpec(name: "jarvis", kind: .architecture,
                hint: "read the jarvis workspace, days and jobs"),
        TagSpec(name: "messages", kind: .architecture,
                hint: "today's messages + summaries"),
        TagSpec(name: "web", kind: .directive,
                hint: "search the web before answering"),
        TagSpec(name: "files", kind: .directive,
                hint: "search this box before answering"),
        TagSpec(name: "box", kind: .directive,
                hint: "measure this machine before answering"),
        TagSpec(name: "cite", kind: .directive,
                hint: "every claim names the file or url it stands on"),
        TagSpec(name: "today", kind: .directive,
                hint: "read only the last 24 hours"),
    ]

    /// The same nine words as a set, for the scan.
    ///
    /// Derived and not stated, so the two cannot disagree -- and a `Set`
    /// because membership is what the boundary rule asks and membership is all
    /// it asks. Everything that was reaching for this before the registry
    /// existed still reaches for it and is unchanged by the registry existing.
    static let vocabulary: Set<String> = Set(registry.map(\.name))

    /// One tag found in a string: where it sits, and what it names.
    ///
    /// The range covers the `@` as well as the name -- it is what gets painted,
    /// and a raised `cmo` with a plain `@` left standing beside it would look
    /// like a mistake. The sigil is painted *away*, by both surfaces, rather
    /// than left out of the range: see `TagBox.sigilKern`. UTF-16, because both
    /// consumers are Cocoa: `NSTextStorage` counts in UTF-16 units and
    /// `Range(_:in:)` converts back for the `AttributedString` side.
    typealias Tag = (range: NSRange, name: String)

    // MARK: - the scan

    /// Every tag in `text`, in the order it was typed. Overlaps are impossible:
    /// a match consumes its own characters.
    static func scan(_ text: String) -> [Tag] {
        let s = Array(text)
        var out: [Tag] = []
        var i = 0
        // Where s[i] begins in UTF-16 units. Carried alongside rather than
        // recomputed, because `text.utf16` offsets and `Array(text)` indices
        // are different counts of the same string and only one of them is what
        // AppKit means by a location.
        var at = 0

        while i < s.count {
            if let hit = tag(in: s, at: i) {
                let units = s[i..<(i + hit.length)].reduce(0) { $0 + $1.utf16.count }
                out.append((NSRange(location: at, length: units), hit.name))
                at += units
                i += hit.length
                continue
            }
            at += s[i].utf16.count
            i += 1
        }
        return out
    }

    /// Just the ranges. What a text view wants, which has no use for the name.
    static func ranges(in text: String) -> [NSRange] { scan(text).map(\.range) }

    /// The distinct tags named, in the order they were named. Deduped the way
    /// the runner's `turn_tags` dedupes: saying `@cmo` twice is one pointer.
    static func names(in text: String) -> [String] {
        var found: [String] = []
        for hit in scan(text) where !found.contains(hit.name) { found.append(hit.name) }
        return found
    }

    /// `text` with the tags it opens with taken off.
    ///
    /// For a derived thread title, where the tag is a pointer at a subsystem
    /// or an order about how to answer rather than a word about the
    /// conversation: a list whose rows all read "@cmo …" or "@web …" is a list
    /// that has stopped distinguishing anything. Only the leading run comes
    /// off -- a tag in the middle of a sentence is part of what was said
    /// there.
    static func strippedOfLeadingTags(_ text: String) -> String {
        let s = Array(text)
        var i = 0
        while true {
            var j = i
            while j < s.count, s[j].isWhitespace { j += 1 }
            guard j < s.count, let hit = tag(in: s, at: j) else { break }
            i = j + hit.length
        }
        return String(s[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - the half-typed one

    /// A tag being typed: the run it occupies and how much of the name is in
    /// front of the caret.
    ///
    /// The range covers the whole token -- the `@`, everything word-ish before
    /// the caret and everything word-ish after it -- because that is what an
    /// accepted completion replaces. The prefix is only the part in front,
    /// because that is what was typed and therefore what filters the list.
    /// They are different for a caret parked in the middle of a word, which is
    /// the case that makes the distinction worth having.
    typealias Partial = (range: NSRange, prefix: String)

    /// The token the caret is sitting inside, if it is sitting inside one.
    ///
    /// **Built out of the same two helpers the finished scan is built out of**
    /// -- `isWord` and `isInfix`, at the bottom of this file. There is exactly
    /// one boundary rule in this app and it is stated once; a completion list
    /// that offered `@cmo` inside `user@cmo.example.com` would be a third
    /// dialect of the rule, and the second one is already a regex on the Pi.
    ///
    /// So the same two refusals apply, half-typed:
    ///
    ///   * the `@` may not be an infix -- `x@we` is the middle of an address
    ///     somebody is still typing, not a `@web` waiting to be finished;
    ///   * the run must be one unbroken word after the `@`, which is what
    ///     makes the range safe to replace whole.
    ///
    /// What is deliberately *not* checked is whether the name is in the
    /// vocabulary: a half-typed tag is by definition not one yet. `@` on its
    /// own is a partial with an empty prefix, which is what opens the list at
    /// its full height on the sigil alone.
    ///
    /// `caret` is a UTF-16 offset, because it comes from `NSTextView`'s
    /// selection and every range this file hands back is one. A caret that
    /// somehow lands inside a character rather than between two -- half of a
    /// surrogate pair -- is not a place a token starts, and comes back nil
    /// rather than being rounded to one side.
    static func partial(in text: String, at caret: Int) -> Partial? {
        let s = Array(text)

        // Where each character begins in UTF-16 units, plus the end. Carried
        // rather than recomputed for the same reason `scan` carries it: an
        // `Array(text)` index and an AppKit location are two different counts
        // of the same string.
        var offsets: [Int] = []
        offsets.reserveCapacity(s.count + 1)
        var at = 0
        for c in s {
            offsets.append(at)
            at += c.utf16.count
        }
        offsets.append(at)
        guard let cursor = offsets.firstIndex(of: caret) else { return nil }

        // Back over the word the caret is in, then the sigil it has to open
        // with, then what is in front of that sigil.
        var start = cursor
        while start > 0, isWord(s[start - 1]) { start -= 1 }
        guard start > 0, s[start - 1] == "@" else { return nil }
        let sigil = start - 1
        if sigil > 0, isInfix(s[sigil - 1]) { return nil }

        // Forward over the rest of the word. Past the caret on purpose: see
        // the note on `Partial`.
        var end = cursor
        while end < s.count, isWord(s[end]) { end += 1 }

        let location = offsets[sigil]
        return (NSRange(location: location, length: offsets[end] - location),
                String(s[start..<cursor]).lowercased())
    }

    /// The tags a half-typed name could still become, in the registry's order.
    ///
    /// A prefix match and not a fuzzy one: nine words in a fixed order is a
    /// list somebody learns the shape of, and a matcher that reordered them by
    /// score would take that back. An empty prefix matches everything, which is
    /// the `@`-alone case.
    static func completions(prefix: String) -> [TagSpec] {
        let typed = prefix.lowercased()
        guard !typed.isEmpty else { return registry }
        return registry.filter { $0.name.hasPrefix(typed) }
    }

    // MARK: - the treatment

    /// `text` with its tags marked for the box.
    ///
    /// The treatment is `TagBox` (Sources/Kit/TagBox.swift) and the composer
    /// paints the same one: a point of `HT.line` around a fill of
    /// `HT.surface2`, opened three points either side of the glyphs, ink left
    /// `HT.inkBright`. No hue, no weight, no rounding -- this is a texture that
    /// says "this token is a literal the machine reads", which is exactly what
    /// a tag is.
    ///
    /// **The `@` is cut out of the picture and not out of the string.** A tag
    /// that registered has earned its box, and the box is the thing that says
    /// "pointer" -- so the sigil is a second announcement of the same fact,
    /// wearing a cell. Its run is drawn in clear ink and kerned back by exactly
    /// its own advance (`TagBox.sigilKern`), so the name closes over it and the
    /// chip reads `cmo`. `text` is untouched: what was said is `@cmo`, what is
    /// selected and copied off this view is `@cmo`, and the split below is two
    /// slices of the same string.
    ///
    /// **A `Text` and not an `AttributedString`, and that is forced.** The box
    /// is drawn by `TagBoxRenderer`, a `TextRenderer` that asks each run
    /// whether it carries `TagRun` -- and the only way to put a
    /// `TextAttribute` on anything is `Text.customAttribute`. An attributed
    /// string cannot carry one, so the runs are concatenated instead. The ink
    /// is stated on the tag runs rather than left to the caller for the same
    /// reason the composer states it: the box and what is read on it are one
    /// decision.
    static func attributed(_ text: String) -> Text {
        let tags = scan(text)
        guard !tags.isEmpty else { return Text(text) }

        var parts: [Text] = []
        var cursor = text.startIndex
        for hit in tags {
            guard let span = Range(hit.range, in: text) else { continue }
            if cursor < span.lowerBound {
                parts.append(Text(String(text[cursor..<span.lowerBound])))
            }
            // Two runs, and `TagRun` on both: the box's geometry is the tag's,
            // and `TagBoxRenderer` unions the span back into one rect rather
            // than boxing a hidden sigil separately from the name it is hiding
            // behind. `HiddenSigil` on top of it is what takes that run out of
            // the glyph pass -- clear ink alone survives only until somebody
            // selects the line. Taken as a prefix rather than by index because
            // the scan does not report a tag that does not open with `@`, which
            // leaves nothing here to get wrong.
            let token = text[span]
            parts.append(Text(String(token.prefix(1)))
                .foregroundStyle(Color.clear)
                .kerning(TagBox.sigilKern)
                .customAttribute(TagRun())
                .customAttribute(HiddenSigil()))
            parts.append(Text(String(token.dropFirst()))
                .foregroundStyle(HT.inkBright)
                .customAttribute(TagRun()))
            cursor = span.upperBound
        }
        if cursor < text.endIndex {
            parts.append(Text(String(text[cursor...])))
        }
        guard let first = parts.first else { return Text(text) }
        return parts.dropFirst().reduce(first) { $0 + $1 }
    }

    // MARK: - the rule

    /// The tag beginning at `i`, if one does: its lowercased name and how many
    /// characters it spans. **The boundary rule lives here and nowhere else**,
    /// so the scan and the title strip cannot come to disagree about what a tag
    /// is.
    private static func tag(in s: [Character], at i: Int) -> (name: String, length: Int)? {
        guard s[i] == "@" else { return nil }
        if i > 0, isInfix(s[i - 1]) { return nil }

        var j = i + 1
        var word = ""
        while j < s.count, isWord(s[j]) {
            word.append(s[j])
            j += 1
        }
        let name = word.lowercased()
        guard vocabulary.contains(name) else { return nil }
        return (name, j - i)
    }

    /// The regex's `\w`: a letter, a digit, or an underscore.
    private static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// What in front of an `@` makes it part of something else instead of the
    /// start of a tag -- the regex's `(?<![\w.@-])`.
    private static func isInfix(_ c: Character) -> Bool {
        isWord(c) || c == "." || c == "@" || c == "-"
    }
}
