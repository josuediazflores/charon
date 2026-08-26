import AppKit
import SwiftUI

/* ── PromptBox ─────────────────────────────────────────────────────────
   $ ask about this pi
     |

   The composer's field: two rows of cells with a caret in them.

   **Deliberately not `AskField` and deliberately not `TextEditor`.** `AskField`
   is one line whose Return always submits, with no disabled state and nothing
   beside it -- right for the CMO's prompt and wrong here, where pasting a unit
   file into the box is the ordinary case. `TextEditor` cannot be told that
   Return means send and Shift+Return means newline: the text system consumes
   the key before SwiftUI sees it. AppKit already has the distinction --
   `insertNewline:` against `insertNewlineIgnoringFieldEditor:` -- so the field
   is an `NSTextView` and the two commands are answered by name.

   Everything a text view arrives with that is off this grid is turned off: the
   fill, the border, the inset, the system face, the ruler. What is left is a
   run of cells on the void, which is what a terminal is.
*/

/// What the caret is sitting in, in the caller's own grammar.
///
/// The range is the whole token, sigil and all, and it is what an accepted row
/// replaces -- **not** just the part in front of the caret. A completion taken
/// in the middle of `@cmXjunk` has to leave `@cmo` behind and not `@cmojunk`,
/// because on the far side of this the runner's `\b` means the second one is
/// not a tag at all. The caller works that range out because the caller owns
/// the boundary rule; the field only applies it.
struct PromptToken {
    var range: NSRange
    /// What has been typed into the token so far. Passed along for the list to
    /// hold; nothing here reads it.
    var query: String
    /// What to offer, already filtered and already in order. Empty closes the
    /// list.
    var rows: [CompletionRow]
}

/// The composer's completion wiring: a list to write into and a grammar to
/// read the field with.
///
/// Two members and not six closures, because the list's own state is a thing
/// the popup has to read anyway -- so the field writes into that rather than
/// calling back with five different pieces of it. The one closure left is the
/// half a text field genuinely cannot supply.
struct PromptCompletion {
    /// The list's state, written by this field's coordinator and read by
    /// whatever draws the popup. Owned by the caller, so the popup can be
    /// mounted wherever it will not be clipped -- which is never inside this
    /// file: a field lives in a scroll view and a list that opened inside one
    /// would be cut off by it.
    var model: CompletionModel
    /// The token the caret is inside, given the whole text and the caret in
    /// UTF-16 units. Nil for "the caret is not in one", which closes the list.
    var token: (_ text: String, _ caret: Int) -> PromptToken?
}

struct PromptBox: NSViewRepresentable {

    @Binding var text: String
    /// The collector's own ceiling, enforced here so an over-long message is
    /// refused before it is filed rather than after.
    var maxLength: Int
    /// Not editable, and said out loud in ink: a greyed field whose greying is
    /// invisible on a dark ground is a field that looks broken.
    var disabled: Bool = false
    /// Put the caret in on arrival. The conversation page does; a panel in a
    /// grid must not.
    var autoFocus: Bool = false
    /// Put the caret back in, whenever this moves. `autoFocus` is a one-shot on
    /// purpose -- a field that grabbed the caret on every update would take it
    /// off whatever the reader had clicked -- so a page that wants to hand focus
    /// back after arrival bumps this instead. `CommandField`'s own trick, and
    /// ⌘K is the same shape of request.
    var focusToken: Int = 0
    /// Which runs of the text get the box, recomputed from the text itself on
    /// every change. Opt-in and nil by default: a composer that has nothing to
    /// raise pays for nothing, which is why the Jarvis box is unchanged by this
    /// existing.
    ///
    /// A closure rather than a vocabulary, so this file stays a text field:
    /// what counts as worth raising is the caller's question -- Chat asks
    /// `ChatTags` -- and this only paints the answer.
    var highlight: ((String) -> [NSRange])? = nil
    /// The list that opens over a half-typed word, if the caller wants one.
    ///
    /// Opt-in and nil by default, on exactly the terms `highlight` is: a
    /// composer with nothing to complete pays for nothing, and the Jarvis box
    /// -- which passes neither -- behaves after this parameter exists exactly
    /// as it did before, down to `doCommandBy` being the same two lines it
    /// always was. **Every branch this adds is gated on the list being open**,
    /// which a field with no list can never be.
    ///
    /// A closure and a model rather than a vocabulary, for the same reason:
    /// this file knows where the caret is, what the run under it looks like on
    /// screen, and which key was pressed. It does not know what a token is,
    /// what the list holds, or what an accepted row spells. See
    /// `PromptCompletion`.
    var completion: PromptCompletion? = nil
    /// Whether the field has the caret, reported as it changes.
    ///
    /// **A page with a composer on it cannot bind a bare letter without this.**
    /// SwiftUI hands `onKeyPress` to a focusable ancestor of whatever is
    /// focused, so a landing that binds `n` and holds this field eats every `n`
    /// somebody types into it -- which is not a subtle bug, it is a box that
    /// silently refuses one letter of the alphabet. Nothing in AppKit's text
    /// delegate answers this: `textDidBeginEditing` fires on the first
    /// keystroke rather than on the click. So the view reports it.
    ///
    /// Opt-in and nil by default, on the same terms as `highlight` and
    /// `completion`: a field nobody asked pays nothing.
    var onCaret: ((Bool) -> Void)? = nil
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // **The stack is built by hand, and that is what pins it to TextKit 1.**
        // `NSTextView(frame:)` arrives on TextKit 2, where there is no
        // `NSLayoutManager` to override and reaching for `.layoutManager` drops
        // the view back a version at runtime with a warning about it. The box a
        // tag stands in is painted in that layout manager's background pass, so
        // the version is a decision this file makes rather than one it discovers.
        let storage = NSTextStorage()
        let layout = TagBoxLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        // Nothing else in the chain holds the store: a layout manager's
        // reference back to it is not an owning one, so the coordinator keeps it
        // for as long as the field is on screen.
        context.coordinator.storage = storage

        let view = CaretView(frame: .zero, textContainer: container)
        // Deferred, because becoming first responder happens inside an AppKit
        // pass that a SwiftUI update is often already driving, and writing to
        // observed state in the middle of one is the "modifying state during
        // view update" fault. The same deferral the caret and the list use.
        view.onCaret = { has in
            DispatchQueue.main.async { context.coordinator.parent.onCaret?(has) }
        }
        view.delegate = context.coordinator
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        // The two above are not enough on recent macOS: grammar and Writing
        // Tools each draw their own colored underlines through the field.
        // Nothing may scribble on the terminal.
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        if #available(macOS 15.1, *) {
            view.writingToolsBehavior = .none
        }
        view.drawsBackground = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.insertionPointColor = NSColor(HT.prompt)
        view.allowsUndo = true
        view.font = PromptBox.face
        view.defaultParagraphStyle = PromptBox.paragraph
        view.typingAttributes = PromptBox.attributes(disabled: disabled)

        // The wrapping half of the setup. Without it a text view in a scroller
        // keeps the width it was created at, which here is zero: every line
        // wraps after no characters at all.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        view.string = text
        view.isEditable = !disabled
        context.coordinator.wasDisabled = disabled
        PromptBox.paint(view, disabled: disabled, highlight: highlight)

        let scroller = NSScrollView()
        scroller.documentView = view
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = false
        scroller.hasHorizontalScroller = false
        scroller.autohidesScrollers = true
        scroller.verticalScrollElasticity = .none

        // Taking a row by pointing at it lands back here, because accepting one
        // means editing text and the list has no text to edit.
        context.coordinator.adopt(completion, for: view)
        return scroller
    }

    func updateNSView(_ scroller: NSScrollView, context: Context) {
        guard let view = scroller.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.adopt(completion, for: view)

        // Both writes are conditional, and that is not tidiness: this runs on
        // every SwiftUI update, including the one caused by the keystroke that is
        // being typed, and re-attributing the whole store on each of those would
        // be reaching into the field while somebody is using it.
        if view.string != text {
            view.string = text
            PromptBox.paint(view, disabled: disabled, highlight: highlight)
            // The text moved from outside -- the composer clearing itself on a
            // send is the only caller that does this -- so whatever the list
            // was offering was about a token that is no longer there. Setting
            // `string` fires no change notification, so nothing else would
            // notice.
            context.coordinator.closeLater()
        }
        if context.coordinator.wasDisabled != disabled {
            context.coordinator.wasDisabled = disabled
            view.isEditable = !disabled
            view.typingAttributes = PromptBox.attributes(disabled: disabled)
            PromptBox.paint(view, disabled: disabled, highlight: highlight)
            // A field that cannot be typed into has nothing to complete. The
            // chat composer disables itself for the length of every turn, so
            // this is the ordinary way the list closes as often as it is the
            // exceptional one.
            if disabled { context.coordinator.closeLater() }
        }

        if autoFocus && !context.coordinator.focused {
            context.coordinator.focused = true
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }

        // Asked for rather than assumed, and only when the number actually
        // moved: `updateNSView` runs on every keystroke, and a
        // `makeFirstResponder` on each of those would run the resign/become
        // pair under a live caret.
        if context.coordinator.token != focusToken {
            context.coordinator.token = focusToken
            DispatchQueue.main.async {
                guard let window = view.window, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    /// Three passes, always in this order: the ranges handed to the layout
    /// manager, the whole field back to base, then the tag runs' ink on top.
    /// Attributes only -- nothing here calls `replaceCharacters`, because a
    /// field that edited what somebody typed while they typed it would be a
    /// field that fights back.
    ///
    /// The base pass is not an optimisation to skip when there is a highlighter:
    /// it is what un-paints the token that stopped being a tag on the last
    /// keystroke -- and, since the third pass hides a tag's `@`, it is also what
    /// brings that `@` back the instant `@cmo` becomes `@cmoj`.
    private static func paint(_ view: NSTextView, disabled: Bool,
                              highlight: ((String) -> [NSRange])?) {
        guard let storage = view.textStorage else { return }
        let text = view.string
        let whole = NSRange(location: 0, length: text.utf16.count)
        let tags = (highlight?(text) ?? []).filter { NSMaxRange($0) <= whole.length }

        // **Before the marked-text guard, and deliberately.** An attribute is
        // fastened to characters and rides along when the text around it moves;
        // a drawn rect is fastened to nothing, so a box left standing while an
        // input method inserts ahead of it would be painted around the wrong
        // word. Handing over the ranges mutates no attribute and cannot take the
        // IME's underline off, which is what the guard below is protecting.
        (view.layoutManager as? TagBoxLayoutManager)?.paint(tags)

        // Not while an input method is composing. The marked run carries the
        // IME's own underline, and a blanket re-attribute would take it off
        // mid-word. Committing the composition fires another change, and that
        // one paints.
        if view.hasMarkedText() { return }
        storage.setAttributes(attributes(disabled: disabled), range: whole)

        let ink = boxed(disabled: disabled)
        let sigil = hiddenSigil()
        for range in tags {
            storage.addAttributes(ink, range: range)
            // The `@`, hidden: clear ink and minus its own advance, so the name
            // closes over it and the box reads `cmo`. **Attributes on the
            // character that is there** -- the store still holds `@cmo`, which
            // is what `parent.text` is set from a few lines later in
            // `textDidChange` and what leaves this field on a copy.
            //
            // One UTF-16 unit and no arithmetic about it: `@` is ASCII, and the
            // scan cannot report a tag that does not open with one. The guard is
            // for the store, not for the rule -- a range that somehow arrived
            // with nothing after its sigil would hide the whole token.
            guard range.length > 1 else { continue }
            storage.addAttributes(
                sigil, range: NSRange(location: range.location, length: 1))
        }

        // The caret does not inherit the run it is sitting after. Without this,
        // typing the character past a tag continues its ink off into the rest of
        // the sentence -- and the next paint would clear it, so the field would
        // flicker once per keystroke.
        view.typingAttributes = attributes(disabled: disabled)
    }

    // MARK: - where the token is

    /// The cell a run of text starts in, in the coordinate space SwiftUI put
    /// this field in: origin top-left, y counting down.
    ///
    /// **The same route `TagBoxLayoutManager` takes** to find the box a chip
    /// stands in (see `draw(_:within:at:)` at the bottom of this file): the
    /// line fragment for the vertical, `location(forGlyphAt:)` for the
    /// horizontal. Deliberately the *first* glyph's cell rather than the run's
    /// bounding rect -- the list hangs off the `@`, so it stays put while the
    /// word behind the sigil grows and shrinks under it.
    ///
    /// **Through the scroller, and that is not ceremony.** This field is two
    /// rows tall and scrolls: a token on the second line of a field that has
    /// been scrolled is not where the layout manager says it is relative to
    /// what SwiftUI drew. The text view is flipped and the scroll view is not,
    /// so the y is turned back over once at the end.
    static func anchor(of range: NSRange, in view: NSTextView) -> CGRect {
        guard let layout = view.layoutManager,
              range.length > 0 else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range,
                                       actualCharacterRange: nil)
        guard glyphs.length > 0, glyphs.location < layout.numberOfGlyphs else {
            return .zero
        }

        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location,
                                           effectiveRange: nil)
        let origin = view.textContainerOrigin
        let cell = CGRect(
            x: line.minX + layout.location(forGlyphAt: glyphs.location).x + origin.x,
            y: line.minY + origin.y,
            width: HT.cw, height: line.height)

        guard let scroller = view.enclosingScrollView else { return cell }
        let shown = scroller.convert(cell, from: view)
        if scroller.isFlipped { return shown }
        return CGRect(x: shown.minX,
                      y: scroller.bounds.height - shown.maxY,
                      width: shown.width, height: shown.height)
    }

    // MARK: - the grid

    /// `fileprivate` for one reader: `TagBoxLayoutManager` needs the same face
    /// this field is set in to know how tall the type's own box is.
    fileprivate static var face: NSFont { Face.ns(11) }

    /// The 16px row, stated: a text view left to its own leading would put the
    /// second line of a message off the grid every other element sits on.
    private static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = HT.row
        p.maximumLineHeight = HT.row
        return p
    }

    private static func attributes(disabled: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: face,
            .foregroundColor: NSColor(disabled ? HT.inkDim : HT.inkBright),
            .paragraphStyle: paragraph,
        ]
    }

    /// What is read inside the box. The surface itself is not here and cannot
    /// be: `TagBoxLayoutManager` draws it, because a stroke is not something an
    /// attribute can ask for.
    ///
    /// The ink stays whatever the field's state says it is, so a disabled field
    /// is still a greyed field: the box says "this is a token" and the ink says
    /// "you cannot type right now", and neither has to shout over the other.
    /// It reads as the base ink today and is stated anyway -- this is the tag's
    /// own contract, and a tag that quietly followed a future change to the
    /// field's base ink would be a tag nobody decided the colour of.
    private static func boxed(disabled: Bool) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor(disabled ? HT.inkDim : HT.inkBright)]
    }

    /// What takes a registered tag's `@` off the screen without taking it out of
    /// the field: no ink, no cell, and a mark saying so.
    ///
    /// Laid over `boxed` rather than instead of it, so the sigil is still inside
    /// the run the layout manager boxes -- the box is the tag's geometry, and
    /// the hidden character contributes nothing to it because it advances
    /// nothing. The kern is not optional and neither is the ink: clear ink alone
    /// leaves a blank cell in front of the name, and the kern alone would stack
    /// the `@` under the `c`.
    ///
    /// The third is the one that is easy to think unnecessary. Clear ink hides a
    /// glyph from every colour the *attributes* choose, and a selected run is
    /// not drawn in those -- `NSTextView.selectedTextAttributes` carries
    /// `selectedTextColor`, which replaces the foreground wholesale and would
    /// paint the `@` straight back on top of the `c`. So the character is marked
    /// as well as cleared, and `TagBoxLayoutManager` declines to draw it at all.
    ///
    /// The number comes off the face this field is actually set in. See
    /// `TagBox.sigilKern(in:)`.
    private static func hiddenSigil() -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.clear,
            .kern: TagBox.sigilKern(in: face),
            .htHiddenSigil: true,
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptBox
        /// One-shot: the caret is put in on arrival and never taken back.
        var focused = false
        /// The last `focusToken` acted on, so a request is answered once.
        var token = 0
        /// The disabled state the field is currently painted in, so a repaint
        /// only happens when it actually moves.
        var wasDisabled = false
        /// The text store, held because nothing else in a hand-built TextKit 1
        /// stack holds it. See `makeNSView`.
        var storage: NSTextStorage?

        /// Where a token the list is **done with** starts, or nil.
        ///
        /// One latch for the two ways a list stops being wanted while the caret
        /// is still standing in the word that opened it: Escape, and an accept
        /// that landed in front of a space rather than in front of nothing. A
        /// list that reopened on the next keystroke after Escape would make
        /// Escape mean "flicker", and one that reopened on the word it had just
        /// finished writing would never let go of it.
        ///
        /// A location and not a flag, so it clears itself: the caret leaving
        /// that token -- or reaching a different one -- is the event that ends
        /// it, and nothing has to remember to.
        var settled: Int?

        init(_ parent: PromptBox) { self.parent = parent }

        // MARK: - the list

        /// Point the list's mouse path back here. Idempotent, and re-run on
        /// every update so a caller that swapped models is not left driving the
        /// old one.
        func adopt(_ completion: PromptCompletion?, for view: NSTextView) {
            guard let model = completion?.model else { return }
            // Every capture weak, the model's included: a model holding a
            // closure that holds the model is a ring that never comes apart.
            model.onPick = { [weak self, weak view, weak model] index in
                guard let self, let view, let model else { return }
                model.point(at: index)
                self.accept(in: view)
            }
        }

        /// Close the list on the next turn of the main loop.
        ///
        /// **Never synchronously.** Every caller of this is inside a SwiftUI
        /// update or inside an AppKit notification that is about to cause one,
        /// and writing to an `@Observable` a view is in the middle of reading
        /// is the "modifying state during view update" fault. The same
        /// deferral `updateNSView` already uses to put the caret in.
        func closeLater() {
            guard let model = parent.completion?.model else { return }
            DispatchQueue.main.async { model.close() }
        }

        /// Ask the caller what the caret is in, and tell the list -- next turn,
        /// for the reason above.
        ///
        /// Returns immediately for a field with no list, which is what keeps a
        /// composer that opted out of this from paying a hop per keystroke.
        func requeryLater(_ view: NSTextView) {
            guard parent.completion != nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.requery(view)
            }
        }

        private func requery(_ view: NSTextView) {
            guard let completion = parent.completion else { return }
            let model = completion.model

            // Four refusals before the grammar is even asked, in the order
            // they are written: a field that cannot be typed into completes
            // nothing; an input method mid-composition owns the keyboard and
            // this must not open over the top of it; a field nobody is typing
            // in has no caret at all; and a selection is not a caret.
            guard !parent.disabled, !view.hasMarkedText(),
                  view.window?.firstResponder === view else {
                model.close()
                return
            }
            let caret = view.selectedRange()
            guard caret.length == 0 else {
                model.close()
                return
            }

            guard let token = completion.token(view.string, caret.location) else {
                settled = nil
                model.close()
                return
            }
            if settled == token.range.location {
                model.close()
                return
            }
            settled = nil
            guard !token.rows.isEmpty else {
                model.close()
                return
            }
            model.offer(token.rows, query: token.query,
                        anchor: PromptBox.anchor(of: token.range, in: view))
        }

        /// Take the row under the list's cursor.
        ///
        /// **`insertText(_:replacementRange:)` and never `replaceCharacters`.**
        /// That one edits the store behind the text view's back: no undo group,
        /// no change notification, and the paint pass this file runs on every
        /// keystroke would not know the token it is boxing had moved. This is
        /// the same call typing a character makes, which is why Cmd-Z takes a
        /// completion back exactly the way it takes typing back.
        ///
        /// **The whole run comes out, and a space goes in behind it.** The run
        /// because a completion accepted with the caret parked mid-word would
        /// otherwise leave the tail of the old word stuck on the new one, and
        /// the boundary rule on the far side of the wire reads `@cmojunk` as
        /// nothing at all. The space because the same rule wants the token
        /// finished -- and not doubled, so a run that already had a space after
        /// it simply keeps the one it had.
        private func accept(in view: NSTextView) {
            guard let completion = parent.completion else { return }
            let model = completion.model
            let caret = view.selectedRange()
            guard let row = model.chosen, caret.length == 0,
                  let token = completion.token(view.string, caret.location) else {
                model.close()
                return
            }

            let text = view.string as NSString
            let after = NSMaxRange(token.range)
            var padded = true
            if after < text.length,
               let next = Unicode.Scalar(text.character(at: after)),
               CharacterSet.whitespacesAndNewlines.contains(next) {
                padded = false
            }

            settled = token.range.location
            model.close()
            // The pointer path arrives here having never taken the caret; the
            // keyboard path arrives here already holding it. Asked for only
            // when it actually moved, because `makeFirstResponder` on the view
            // that already is one still runs the resign/become pair.
            if let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
            view.insertText(padded ? row.insert + " " : row.insert,
                            replacementRange: token.range)
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if view.string.count > parent.maxLength {
                view.string = String(view.string.prefix(parent.maxLength))
            }
            // After the truncation and not before it, because the cut is what
            // decides the answer: a `@cmo` whose `o` fell off the end of the
            // ceiling is a `@cm` and has to stop being raised. Setting `string`
            // has also just dropped every attribute in the field, so this pass
            // is putting the base back as much as it is painting tags.
            //
            // Here rather than in `updateNSView`, because the SwiftUI update
            // this keystroke causes finds `view.string == text` and repaints
            // nothing -- which is exactly the guard that keeps the field from
            // being reattributed underneath a live caret.
            // Gated on there being something to raise: a field with no
            // highlighter behaves exactly as it did before this parameter
            // existed, down to not being touched on a keystroke at all.
            if let highlight = parent.highlight {
                PromptBox.paint(view, disabled: parent.disabled, highlight: highlight)
            }
            parent.text = view.string
            requeryLater(view)
        }

        /// The caret moved without the text changing: an arrow key, a click, a
        /// Home. The list is about where the caret is, so it has to answer to
        /// that as well as to what was typed -- clicking away from a half-typed
        /// word has to put the list away even though nothing was edited.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            requeryLater(view)
        }

        /// The caret left the field. Nothing on screen explains a list floating
        /// over a page whose composer is not being typed into.
        func textDidEndEditing(_ notification: Notification) {
            closeLater()
        }

        /// Enter sends, Shift+Enter is a newline. The other way round is a chat
        /// box that needs a mouse to use, and this one is typed into.
        ///
        /// **The list gets first refusal, and only while it is open.** With it
        /// closed -- which is always, for a field that passed no
        /// `completion` -- this method is the two lines it was before the list
        /// existed: Return submits, everything else is the text view's own.
        /// That is the whole of the contract with the Jarvis composer.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let completion = parent.completion, completion.model.open {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    completion.model.move(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    completion.model.move(1)
                    return true
                // Return takes the row instead of sending, and Tab takes it
                // instead of putting a tab in. Both are what a completion list
                // means by "yes"; the send is one Escape away and the message
                // is still in the box.
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    accept(in: textView)
                    return true
                // Escape arrives as one of these two depending on what else is
                // bound, so both are answered rather than one being guessed at.
                case #selector(NSResponder.cancelOperation(_:)),
                     #selector(NSStandardKeyBindingResponding.complete(_:)):
                    settled = completion.token(
                        textView.string,
                        textView.selectedRange().location)?.range.location
                    completion.model.close()
                    return true
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            // Shift+Return arrives as `insertNewlineIgnoringFieldEditor:`, whose
            // own default is to put a line break in. Answered by letting the text
            // view do exactly that.
            return false
        }
    }
}

/// The field, with one thing added: it says when it takes the caret and when it
/// gives it up.
///
/// A subclass and not a delegate call, because there is no delegate call: the
/// text system reports editing rather than focus. Two overrides, both of which
/// ask `super` first and report what `super` answered -- so a refusal to become
/// first responder is not reported as a focus.
private final class CaretView: NSTextView {
    var onCaret: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onCaret?(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { onCaret?(false) }
        return gave
    }
}

// MARK: - the composer's half of the box

/// The mark on a character that is in the field and not on the screen.
///
/// One character wears it -- the `@` of a token that registered -- and the only
/// two things that touch it are `PromptBox.hiddenSigil`, which puts it on, and
/// `TagBoxLayoutManager.drawGlyphs`, which reads it. Deliberately an attribute
/// on the character rather than a second copy of the tag ranges: what the draw
/// pass leaves out is then *exactly* what the attribute pass hid, with no state
/// in between the two that could fall a keystroke out of step.
private extension NSAttributedString.Key {
    static let htHiddenSigil = NSAttributedString.Key("htHiddenSigil")
}

/// The layout manager that draws `TagBox` behind the ranges the field's
/// highlighter reported, and that leaves a hidden sigil undrawn.
///
/// **Ranges and not rects.** What is kept is where the tags are in the text,
/// and the geometry is asked of the layout every time it is drawn -- so a field
/// that got wider, or a message that rewrapped, is right without anybody having
/// been told about it. The one thing a stored range needs is the clamp below:
/// a repaint can land between an edit and the pass that recomputes them.
final class TagBoxLayoutManager: NSLayoutManager {

    private var tags: [NSRange] = []

    /// The tags, as of this keystroke. Marks the field dirty when the answer
    /// actually moved: a box is not an attribute, so nothing else would.
    func paint(_ ranges: [NSRange]) {
        guard ranges != tags else { return }
        tags = ranges
        for container in textContainers { container.textView?.needsDisplay = true }
    }

    /// **Before `super` and not after it.** This pass is also where the text
    /// system paints selection and the input method's marked run, and a box laid
    /// down afterwards would be a box over the top of both. Under them it is
    /// what it should be: the surface those two are drawn on.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        draw(tags, within: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// **Drawn around the hidden sigil rather than through it.**
    ///
    /// Clear ink is enough for ordinary text and is not enough for selected
    /// text: the selection is drawn in `selectedTextColor`, which replaces the
    /// foreground the attributes asked for, so a `@` left in this pass comes
    /// back the moment somebody drags across the line -- and, having no advance,
    /// comes back *on top of* the `c` it is hiding behind. A character with no
    /// cell gets no pass either.
    ///
    /// Split rather than clipped: the glyphs either side of each hidden one are
    /// handed to `super` as their own ranges, so everything the default pass
    /// does for real text -- selection ink, an input method's underline, the
    /// disabled grey -- keeps happening to all of it.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let hidden = hiddenGlyphs(within: glyphsToShow)
        guard !hidden.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let end = NSMaxRange(glyphsToShow)
        var cursor = glyphsToShow.location
        for skip in hidden {
            if skip.location > cursor {
                super.drawGlyphs(
                    forGlyphRange: NSRange(location: cursor,
                                           length: skip.location - cursor),
                    at: origin)
            }
            cursor = max(cursor, NSMaxRange(skip))
        }
        if cursor < end {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor,
                                                    length: end - cursor),
                             at: origin)
        }
    }

    /// The glyphs of the marked characters that fall inside `glyphsToShow`, in
    /// the order they are drawn in.
    private func hiddenGlyphs(within glyphsToShow: NSRange) -> [NSRange] {
        guard let storage = textStorage, glyphsToShow.length > 0 else { return [] }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard NSMaxRange(chars) <= storage.length else { return [] }

        var out: [NSRange] = []
        storage.enumerateAttribute(.htHiddenSigil, in: chars) { mark, range, _ in
            guard mark != nil else { return }
            let glyphs = self.glyphRange(forCharacterRange: range,
                                         actualCharacterRange: nil)
            let shown = NSIntersectionRange(glyphs, glyphsToShow)
            if shown.length > 0 { out.append(shown) }
        }
        return out.sorted { $0.location < $1.location }
    }

    private func draw(_ ranges: [NSRange], within glyphsToShow: NSRange, at origin: NSPoint) {
        guard !ranges.isEmpty,
              let container = textContainers.first,
              let storage = textStorage else { return }

        let fill = NSColor(TagBox.fill)
        let rule = NSColor(TagBox.line)

        for chars in ranges where NSMaxRange(chars) <= storage.length {
            let glyphs = glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let shown = NSIntersectionRange(glyphs, glyphsToShow)
            guard shown.length > 0 else { continue }

            // The face this run is actually set in, so the box is the type's box
            // even if a caller ever sets the field in something else.
            let font = storage.attribute(.font, at: chars.location, effectiveRange: nil)
                as? NSFont ?? PromptBox.face

            // One box per line fragment, which is the whole of the wrapping
            // answer: a tag that broke gets drawn once on each side of the break
            // rather than once around a rect spanning both.
            enumerateLineFragments(forGlyphRange: shown) { fragment, _, _, fragmentGlyphs, _ in
                let part = NSIntersectionRange(shown, fragmentGlyphs)
                guard part.length > 0 else { return }

                let run = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                let box = TagBox.around(x: run.minX, width: run.width,
                                        baseline: baseline,
                                        ascent: font.ascender, descent: -font.descender)
                    .offsetBy(dx: origin.x, dy: origin.y)

                fill.setFill()
                NSBezierPath(rect: box).fill()
                rule.setStroke()
                let edge = NSBezierPath(rect: TagBox.rule(box))
                edge.lineWidth = TagBox.stroke
                edge.stroke()
            }
        }
    }
}
