import AppKit
import SwiftUI

/* The mail tab: a bar, one pane or two, and the standing rule under both.
 *
 * **This is the console's one exception and it stays one.** Everything above it
 * -- the rail, the top bar, the scanline overlay -- is the tty dialect; inside
 * this view the mail dialect applies and nothing else in the window changes.
 * The tab is handed the shell's own model rather than minting one, so there is
 * a single poller against a single mailbox however many tabs the rail grows.
 *
 * **One pane or two is measured, not guessed.** The split is decided on the
 * width of the content box rather than on the window, because the rail and the
 * window chrome are between the two numbers and only the box knows what is
 * left. Above 1000pt the list stays beside the message; below it, the message
 * is the whole page and the list stands down.
 *
 * **The keymap lives here and nowhere else.** One handler, at the top, so two
 * views cannot race for the same key: the walk and Escape are operations on the
 * model's selection, and `r` is a counter the reader watches. Every binding
 * stands down while a field has focus -- a bare letter that did not check would
 * eat the j out of a sentence.
 */

private let splitMin: CGFloat = 1000

/* How tall the standing rule under the panes is, this window, this width.
 *
 * The reader is a scroller and the rule is under it, so the rule's height is a
 * fact the reader has to know: without it the last line of a long message ends
 * flush against the rule it is being read over. A measurement rather than a
 * constant, because the sentence wraps -- one line on a wide window and two on
 * a narrow one -- and a number written down here would be wrong at one of the
 * two widths.
 */
private struct MailFootHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var mailFootHeight: CGFloat {
        get { self[MailFootHeightKey.self] }
        set { self[MailFootHeightKey.self] = newValue }
    }
}

struct MailTabView: View {

    var model: MailModel
    @FocusState private var keyboardHeld: Bool

    /// The standing rule's height, measured and handed to the reader.
    @State private var footHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= splitMin

            VStack(spacing: 0) {
                appBar(split: split)
                Hairline()

                HStack(spacing: 0) {
                    if split || model.selection == nil {
                        MailListView(model: model)
                            .frame(width: split ? 380 : nil)
                            .frame(maxWidth: split ? nil : .infinity)
                    }

                    if split { VHairline() }

                    if split || model.selection != nil {
                        pane
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                Hairline()

                // The standing rule, stated where the mail is rather than only
                // in the reader: every draft in this system is a draft until he
                // clicks SEND himself, and nothing on the Pi may click it for
                // him.
                Label("Only you can confirm and send a reply.", systemImage: "lock")
                    .font(Face.body)
                    .foregroundStyle(M.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .htMeasureHeight { footHeight = $0 }
            }
            .environment(\.mailFootHeight, footHeight)
        }
        .background(Ground.shared.glass ? HT.surface2 : Color.clear)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardHeld)
        .onKeyPress(phases: .down) { press in handle(press) }
        // The poll belongs to the shell, which owns it for every tab. All this
        // tab has to do on arrival is take the keys.
        .task { keyboardHeld = true }
        // A field letting go of the caret has to hand the keys back. Clicking
        // out of the reply box lands focus on whatever was clicked rather than
        // on this container, and without this the walk would work exactly once
        // per message -- until the first time somebody typed.
        .onChange(of: model.textFocused) { _, typing in
            if !typing { keyboardHeld = true }
        }
    }

    // MARK: - the bar

    private func appBar(split: Bool) -> some View {
        let inbox = model.counts?.inbox

        return HStack(spacing: 10) {
            Text("Mail")
                .font(Face.title)
                .tracking(0.22)
                .foregroundStyle(M.inkBright)

            Text(inbox.map { "\(Fmt.num($0)) message\($0 == 1 ? "" : "s")" }
                 ?? "no poll recorded yet")
                .font(Face.body)
                .foregroundStyle(M.inkDim)
                .lineLimit(1)

            Spacer(minLength: 8)

            // The way out of the open message, and it is a different thing at
            // each width. Narrow, the reader is the whole page and the arrow is
            // the door. Split, the list is beside the message and there is
            // nothing to close, so what stands here is the key that empties the
            // pane rather than a button for it -- printed, because esc is the
            // whole of the affordance in the layout that has no button.
            if model.selection != nil {
                if split {
                    HStack(spacing: 3) {
                        Kbd(text: "esc")
                        Text("close").font(Face.body).foregroundStyle(M.inkDim)
                    }
                } else {
                    Button { model.selection = nil } label: {
                        HStack(spacing: 6) {
                            Icon(name: .back, size: 16)
                            Text("Inbox").font(Face.body)
                        }
                        .foregroundStyle(M.inkMid)
                        .padding(.leading, 8)
                        .padding(.trailing, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: M.rSm, style: .continuous)
                            .strokeBorder(M.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the inbox (esc)")
                    .accessibilityLabel("Back to the inbox")
                }
            }

            // Not drawn over an open message at a narrow width: there the arrow
            // beside it is the one thing on the bar, and a settings door on top
            // of a message is a second way out of a room with one exit.
            if split || model.selection == nil {
                IconKey(icon: .gear, label: "Connection", help: "Connection") {
                    model.showingConnection = true
                }
            }
        }
        // Sixteen, not seventy-eight. The traffic lights used to sit in the
        // first seventy points of this bar, when it was the window's title bar;
        // the console put a real one back above the rail and this is an
        // ordinary bar inside a pane again.
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    // MARK: - the pane

    @ViewBuilder
    private var pane: some View {
        if let key = model.selection {
            // The id is load-bearing, not hygiene: the reader holds a
            // half-written reply, and walking from one message to another
            // without remounting would carry that draft into the next
            // message's save route.
            MailReaderView(messageKey: key, model: model)
                .id(key)
        } else {
            VStack {
                // With nothing in the list there is nothing to select and no
                // walk to explain, so the pane says the plainer true thing
                // rather than naming two keys that would move nowhere.
                EmptyPane(glyph: .mailOpen,
                          line: model.messages.isEmpty
                              ? "Nothing to read yet" : "Select a message",
                          why: model.messages.isEmpty ? nil : "Use J and K to move through the inbox.")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - the keymap

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Nothing here fires while somebody is typing, and that includes
        // Escape: the browser's own meaning for it inside a field is untouched
        // and a half-written reply cannot be navigated out from under.
        guard model.keysLive else { return .ignored }
        guard press.modifiers.isEmpty else { return .ignored }

        switch press.key {
        case .escape:
            guard model.selection != nil else { return .ignored }
            model.closeMessage()
            return .handled
        case .rightArrow:
            model.walkForward()
            return .handled
        case .leftArrow:
            model.walkBack()
            return .handled
        default:
            break
        }

        switch press.characters {
        case "j":
            model.walkForward()
            return .handled
        case "k":
            model.walkBack()
            return .handled
        case "r":
            guard model.selection != nil else { return .ignored }
            model.requestReply()
            return .handled
        default:
            return .ignored
        }
    }
}
