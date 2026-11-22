import SwiftUI

/* ── the chat landing ──────────────────────────────────────────────────
                        [6 sessions ▼]
     ┌──────────────────────────────────────────────────────────┐
     │ $ ask about this pi                                      │
     │                                                          │
     │              [-DICTATE]  sonnet ▼   high ▼   ┌──────────┐│
     │                                              │   send   ││
     └──────────────────────────────────────────────────────────┘
        an assistant running on the pi · it reads this box and
             the web, and changes nothing but its own memory

   The front of the chat tab: a box in the middle of a lit pane.

   **The composer is the door.** This route used to be a list with `[+ new]` on
   it twice, which made starting a conversation a two-step: mint an empty
   session, land in it, then type. The empty session was a record on the Pi
   nobody had asked a question of, and it showed up in the list as one. Here the
   question comes first and the session is minted around it -- so there is no
   moment at which a thread exists with nothing in it, and no control that says
   "new" because typing is what new means.

   **The sessions are behind a chip, not in front of the box.** They are the
   back catalogue: worth a click, not worth the page. The chip carries the count
   so the number is on screen whether or not the section is, and opening it
   grows the page downward rather than moving the box.

   **The plate is the one decorative thing in this console and it does not
   move.** A dithered glow field, painted once per pane size and per ground
   family, in two of that family's own inks, over a wash that carries a little
   light the rest of the way down. No timer, no animation, no random number: the
   page costs exactly nothing while it sits there, which is the whole of the
   branch it was built on.
*/

struct ChatLandingView: View {

    var model: MailModel
    /// `#chat/new`: a session is being minted and this is the moment before it
    /// has a name. Nothing on this page navigates here any more -- the composer
    /// took that job -- but the route still exists and still works, because a
    /// window restored onto it has to land somewhere real.
    var fresh: Bool
    /// The pane is at or under the small breakpoint. Measured by the tab on the
    /// pane, and passed rather than re-measured: the plate is full-bleed here
    /// and the margins are the column's, so the two are separate questions about
    /// the same width.
    var narrow: Bool
    var navigate: (ChatRoute) -> Void

    @State private var allThreads: [ChatThreadSummary]?
    @State private var loading = true
    /// What the reader is in the middle of doing to the list. Held here rather
    /// than in the section, because the door into that mode is drawn up on the
    /// chip's row. See `ChatSelection`.
    @State private var pick = ChatSelection()
    /// Whether the section under the box is open.
    @State private var showing = false
    /// Which model will answer and how hard it will think. The conversation
    /// route reads these off the record; there is no record yet, so they are
    /// this page's own until the send mints one.
    @State private var picked: ChatModelName = .sonnet
    @State private var effort: JarvisEffort = ChatLandingView.restingEffort
    /// A send in flight: the session is being minted and the message filed.
    @State private var filing = false
    /// What the collector refused, in the list's own pill idiom. Never a dialog:
    /// a refusal is a thing that happened on the page and the box under it is
    /// usable again.
    @State private var refused: ChatSelection.NoteLine?
    /// Bumped to put the caret back in the field.
    @State private var caret = 0
    /// Whether the field currently has the caret. What tells a bare `n` pressed
    /// at the page from an `n` typed into the box.
    @State private var typing = false
    @State private var paneHeight: CGFloat = 0
    /// How tall the composition is with the section shut. Measured, so a
    /// sentence that wrapped onto a second row on a narrow pane is counted --
    /// and held across the section opening, so the box does not move when it
    /// does.
    @State private var rest: CGFloat = ChatLandingView.restingStack
    @FocusState private var keys: Bool

    /// Absent on the record means the runner's own `high`, so that is what this
    /// page rests at and the pick that costs no second write.
    private static let restingEffort: JarvisEffort = .high

    /// The composition's height with the section shut: the chip's row and its
    /// margin, the composer's own 82, and the standing sentence a step under it.
    /// Seeded rather than waited for, so the first paint lands where the second
    /// one will.
    private static let restingStack: CGFloat =
        HT.row * 2 + ChatLandingView.boxHeight + HT.s3 + HT.row

    /// The composer card's height, which is the app's own arithmetic and not a
    /// multiple of the row: padding, two rows of field, the gap, the control
    /// row, padding.
    private static let boxHeight: CGFloat = HT.s2 * 2 + HT.row * 2 + HT.s1 + HT.row2

    /// The step under the box. The card is 82 tall, which does not land on the
    /// 16 grid; setting whatever follows it off by `s3` rather than by a row
    /// puts the rest of the stack back on the grid without inventing a number.
    private static let afterBox: CGFloat = HT.s3

    private var threads: [ChatThreadSummary]? {
        let settings = ConsoleSettings.shared
        guard !settings.isEnabled(.messages) else { return allThreads }
        return allThreads?.filter { $0.id != settings.messagesAgentThreadId }
    }

    /// The list proper. Archived rows are not in it -- they are a section of
    /// their own below -- and neither is the count on the chip: "12 sessions"
    /// that included six the reader put away is counting the wrong thing.
    private var mainRows: [ChatThreadSummary] {
        (threads ?? []).filter { $0.archived != true }
    }

    private var archivedRows: [ChatThreadSummary] {
        (threads ?? []).filter { $0.archived == true }
    }

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // **The words say where the plate is not.** A caption over a plate
            // is legible because it puts the plate out -- and on this window
            // "putting it out" cannot be a patch of void painted over the top:
            // the console is translucent, so an opaque patch is a rectangle of
            // darkness on somebody's desktop, plainly a box exactly where the
            // design wanted nothing at all.
            //
            // So the type does not paint anything. Each plated run publishes its
            // own box, and the boxes are cut out of the plate's mask before the
            // plate is drawn. What is left under the words is the ground, the
            // wash and whatever is behind the window, untouched -- which is
            // what "it only takes the dots out from under the words" means on a
            // surface that is not opaque. See `htPlated`.
            .backgroundPreferenceValue(PlateHoles.self) { holes in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        wash
                        plate.mask { plateMask(holes, in: geo) }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .htMeasureHeight { paneHeight = $0 }
            // The keymap's own holder, and deliberately not focused on arrival:
            // the field takes the caret, which is the whole point of this page.
            // What is left for this to answer is the keys pressed while the
            // caret is somewhere else -- on a picker, on the chip, in the
            // section -- and `n` is one of them.
            .focusable()
            .focusEffectDisabled()
            .focused($keys)
            .onKeyPress(phases: .down) { press in key(press) }
            .onChange(of: threads) { _, rows in
                if let rows { pick.reconcile(rows) }
            }
            .task(id: fresh) { await mintIfFresh() }
            // `fresh` is in the key as well as the window's own state: a mint
            // that the collector refused lands back on this route in the same
            // view, and a poll keyed only on the window would never start.
            .task(id: "\(model.active)/\(fresh)") { await poll() }
    }

    // MARK: - the plate

    /* The wash and the dither, in that order, behind everything.

       **The wash carries the light down and the plate carries the texture.**
       The glow field is at the top of the pane and gone by its middle, which is
       right -- but it leaves the box sitting under a band of dots rather than
       inside a field of light. The wash is what puts it inside one: an ellipse
       wider than the column, centred above the top edge, at a fifteenth of the
       one rule colour this family has. Faint enough that it is never a gradient
       anybody would call a gradient.

       Both are read off the ground family, so all five keep working, and
       neither one is a hex. */
    private var plate: some View {
        DitherPane(ink: HT.inkMid, dim: HT.line)
            .opacity(0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    /// The plate's mask: everything, less the box each plated run stands in.
    ///
    /// The hole is a `destinationOut` inside the mask's own group and nowhere
    /// else. Grouped any higher it would clear the alpha of the window itself,
    /// which is a hole through to the desktop rather than a gap in a texture --
    /// this file has had that bug once and the group is why it cannot come back.
    private func plateMask(_ holes: [Anchor<CGRect>], in geo: GeometryProxy) -> some View {
        Rectangle()
            .fill(.black)
            .overlay {
                ForEach(holes.indices, id: \.self) { i in
                    let box = geo[holes[i]]
                    Rectangle()
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }

    private var wash: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            EllipticalGradient(
                stops: [
                    Gradient.Stop(color: HT.lineBright.opacity(0.15), location: 0),
                    Gradient.Stop(color: HT.lineBright.opacity(0), location: 0.76),
                ],
                center: .center)
                // The ending shape stated as a box: 78% of the pane wide and
                // 92% of it tall, as radii, which is a frame of twice each with
                // the ellipse inscribed in it.
                .frame(width: w * 0.78 * 2, height: h * 0.92 * 2)
                .position(x: w * 0.42, y: -h * 0.08)
        }
    }

    // MARK: - the column

    private var page: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // The composition sits a little above the middle of the pane
                // rather than dead on it, which is where a page of type wants to
                // be; the section then opens below the box instead of moving it,
                // because this is measured with the section shut.
                Color.clear.frame(height: lift)
                column
            }
            .frame(maxWidth: chatMeasure, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
            .htConsolePad(narrow: narrow)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.clear)
    }

    private var lift: CGFloat {
        // The console's own vertical margin is inside the scroller, so it comes
        // off both ends of the sum.
        Swift.max(0, (paneHeight - rest) / 2 - HT.row * 2)
    }

    private var column: some View {
        VStack(spacing: 0) {
            chipRow
            box

            if let refused {
                HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                    StatusPill(text: refused.tag, tone: .fault, glyph: false)
                    Text(refused.text)
                        .font(HT.body)
                        .foregroundStyle(HT.fault)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, ChatLandingView.afterBox)
            }

            if showing {
                section.padding(.top, ChatLandingView.afterBox)
            }

            note.padding(.top, showing ? HT.row : ChatLandingView.afterBox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **Its own key, and not `htMeasureHeight`.** Preferences reduce upward,
        // and that one's key takes the larger of what it finds -- so a column
        // taller than the pane would be reported to the pane's own measurement
        // as the pane's height, and the lift computed from it would push the box
        // down every time the section opened. Two questions, two keys.
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: ColumnHeight.self, value: geo.size.height)
            }
        }
        // Held while the section is shut and nothing has been refused, which is
        // the composition the lift is measured against.
        .onPreferenceChange(ColumnHeight.self) { h in
            if !showing, refused == nil, h > 0 { rest = h }
        }
    }

    // MARK: - the chip

    /* The door to the section, centred over the box, with the plate taken out
       from under it.

       **The select door hangs off the trailing edge rather than beside it.** The
       chip is centred and a sibling on its own row would push it off centre, so
       the one control the section needs up here is laid over the same row at the
       column's far edge. It is drawn only while the section is open: a mode
       about rows nobody can see is a mode about nothing. */
    private var chipRow: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatTextButton(text: chip, ink: HT.ink, label: chipLabel) {
                    showing.toggle()
                    if !showing { pick.leaveSelect() }
                }
                .htPlated()
                Spacer(minLength: 0)
            }

            if showing {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ChatSelectDoor(pick: pick, empty: mainRows.isEmpty).htPlated()
                }
            }
        }
        .frame(height: HT.row)
        .padding(.bottom, HT.row)
    }

    private var chip: String {
        // Em dash rather than a zero before the first read: the count is not
        // nought, it is not known, and the two are different things to somebody
        // deciding whether to open this.
        guard let threads else { return "[— sessions ▼]" }
        let n = threads.filter { $0.archived != true }.count
        return "[\(n) session\(n == 1 ? "" : "s") \(showing ? "▲" : "▼")]"
    }

    private var chipLabel: String {
        showing ? "Hide the sessions" : "Show the sessions"
    }

    // MARK: - the box

    /* The conversation's own composer, in a card.

       Every part of it is the part one route over: the same field, the same
       completion list over an `@`, the same two pickers, the same send. What the
       card adds is a surface and a corner -- `SessionCard`'s, so the two things
       on this page that are cards round identically.

       **Painted rather than clipped.** A `clipShape` here would take the
       completion list with it: it opens upward out of the field and would be cut
       off at the card's own top edge. Nothing inside the box overflows it, so
       the surface goes behind rather than around. */
    private var box: some View {
        ChatComposer(
            busy: filing,
            busyReason: filing ? "filing…" : nil,
            model: picked,
            effort: effort,
            onStop: nil,
            onSend: { text in Task { await cut(text) } },
            onModel: { picked = $0 },
            onEffort: { effort = $0 },
            autoFocus: true,
            seat: .card,
            focusToken: caret,
            onCaret: { typing = $0 })
        .background {
            RoundedRectangle(cornerRadius: chatRadius, style: .continuous)
                .fill(HT.surface2)
        }
    }

    // MARK: - the section

    @ViewBuilder
    private var section: some View {
        if threads == nil {
            ChatNote(loading
                     ? "reading the sessions"
                     : "the collector is not answering · sessions are on the pi, not here")
        } else {
            ChatSessionList(model: model,
                            pick: pick,
                            rows: mainRows,
                            archivedRows: archivedRows,
                            reload: { await load() },
                            open: { navigate(.thread($0)) })
        }
    }

    private var note: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatNote("an assistant running on the pi · it reads this box and the web, "
                     + "and changes nothing but its own memory", centred: true)
                .htPlated()
            Spacer(minLength: 0)
        }
    }

    // MARK: - the cut

    /* Return, and the page is a conversation.

       **One frame, no transition.** The route changes and the conversation is
       drawn whole, exactly as it is drawn when a card is clicked -- transcript
       filling from the top, the sent turn queued in it, the composer on the
       pane's bottom edge. Nothing here interpolates, tweens or fades: a terminal
       repaints.

       **And it changes only once the Pi has taken the message.** There is no
       thread to be optimistic in yet, so the session is minted, the effort
       applied if it is not the runner's own, the message filed -- and only a
       send that came back `ok` navigates. A refusal at either step leaves the
       reader on this page with what they typed still in the box and a line under
       it saying which step said no.

       The model is not a second write: it is what the mint is asked for. The
       effort is, because there is no mint field for it -- and it is only asked
       for when the pick is not the one the runner would have used anyway. */
    private func cut(_ text: String) async {
        guard !filing else { return }
        filing = true
        refused = nil
        defer { filing = false }

        guard let id = await model.store.chatNew(model: picked) else {
            refused = .init(tag: "×new", text: "no session · the collector did not mint one")
            return
        }
        // **Not allowed to stop the send.** A refused effort write means the
        // turn runs at the runner's own `high` instead of the pick, which is a
        // setting being wrong; refusing to file the message over it would be
        // losing what somebody typed to protect a setting. It is also the one
        // refusal with an obvious next move -- the same control is on the
        // conversation this is about to open, where it does report.
        if effort != ChatLandingView.restingEffort {
            _ = await model.store.chatSetEffort(id: id, effort: effort)
        }

        switch await model.store.chatSend(id: id, text: text) {
        case .ok:
            navigate(.thread(id))
        case .busy:
            refused = .init(tag: "×send", text: "not sent · a turn is already in flight")
        case .failed:
            refused = .init(tag: "×send", text: "not sent · the collector did not take it")
        }
    }

    private func mintIfFresh() async {
        guard fresh else { return }
        let id = await model.store.chatNew(model: picked)
        if Task.isCancelled { return }
        // A route rather than a mode, so the tab always names a real
        // conversation once there is one.
        navigate(id.map { ChatRoute.thread($0) } ?? .list)
    }

    // MARK: - reading

    /// Read on arrival and every five seconds after it, and stopped entirely
    /// while nobody is looking at the window -- the same rule the telemetry feed
    /// follows, with the same immediate read on the way back, so the first thing
    /// on screen after a return is current rather than five seconds old.
    private func poll() async {
        guard model.active, !fresh else { return }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: chatIdlePoll)
            if Task.isCancelled { return }
        }
    }

    private func load() async {
        let rows = await model.store.chatList()
        if Task.isCancelled { return }
        allThreads = rows
        loading = false
    }

    // MARK: - the keys

    /// `n` puts the caret in the box, and Escape disarms the way it closes
    /// anything else in this console.
    ///
    /// **`n` used to mint a session and now opens the door that does.** Bare,
    /// no modifier: ⌘N is the app's window and Ctrl+N is somebody's window
    /// manager.
    ///
    /// **And it is refused while the box has the caret.** SwiftUI hands
    /// `onKeyPress` to a focusable ancestor of whatever is focused, and this
    /// view is an ancestor of the composer -- so an unguarded `n` here is a
    /// composer that silently will not type the letter n. That is not a corner
    /// case, it is `fan` and `spinning`. The field says when it holds the
    /// caret; see `PromptBox.onCaret`.
    ///
    /// Escape is answered on the same terms and needs no guard, because it only
    /// claims the key when there is actually something armed to unwind -- an
    /// `.ignored` goes on to the field, where Escape is what closes the tag
    /// list.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape { return pick.escape() ? .handled : .ignored }
        guard press.modifiers.isEmpty, !typing else { return .ignored }
        if press.characters == "n" {
            caret &+= 1
            return .handled
        }
        return .ignored
    }
}

// MARK: - type on the plate

/// How tall the composition is. The landing's own, so that the pane's
/// measurement and the column's cannot reduce into each other.
private struct ColumnHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

/// Where the plate is not: one box per run of type standing on it, in the
/// pane's own coordinates. Collected rather than stated, so a sentence that
/// wrapped onto a second row takes its second row's worth of plate with it.
private struct PlateHoles: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>],
                       nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Type standing on the plate, in `DitherPlate`'s own idiom: a caption over
    /// a plate is legible because it puts the plate out. A cell of clearance
    /// either side and no vertical padding -- one row of type does not need the
    /// caption's.
    ///
    /// Nothing is painted here. The box is published upward and the plate's
    /// mask is where it is spent; see `plateMask`.
    func htPlated() -> some View {
        padding(.horizontal, HT.cw)
            .anchorPreference(key: PlateHoles.self, value: .bounds) { [$0] }
    }
}
