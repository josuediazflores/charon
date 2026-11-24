import AppKit
import ImageIO
import SwiftUI

/* ── the shell ─────────────────────────────────────────────────────────
     ◧ HALFTONE  │ $ Search nodes, commits      ⌘K    DEMO 1  ⟳  ▲▲▲ LIVE
   > ◉ Overview  ├──────────────────────────────────────────────────────
     ⏻ Hardware  │  TUESDAY 18 AUGUST
     ▤ CMO       │  All sources reporting.
     ✉ Mail      │
     ❯ Chat      │  ┌─ PI-HOLE ───────────── pi-zero-w ▲▲▲ ┐
     ✦ Jarvis    │  │ ads blocked today                    │
     ⌘ Settings  │  │ 13,315                               │
     ─────────── │
     sources 7/7 │
     last sync 4s│

   The rail, the bar, and the one scroll container under them.

   **Three things are decided here and nowhere else.**

   *Which tab is showing*, which is this console's whole router: the web reads
   it out of the address bar, and a native window has no address bar, so a
   string of state stands in for the hash. The rule the hash encodes survives
   the translation -- a cold start lands on the stored landing tab, validated
   against the rail's own list, and falls back to Overview when that tab has
   since been cut.

   *Whether the sidebar is visible.* The Mac remembers the manual choice.
   Mail can temporarily collapse it while a message is open.

   *When the payload guard applies.* Settings is answered above it, because a
   page made entirely of local preferences has nothing for a payload to add --
   and under the guard it would be unreachable in exactly the state somebody
   needs it in: a cold start against a dead Pi, where the landing tab makes the
   Connecting panel a trap rather than an inconvenience.
*/

struct ConsoleShellView: View {

    @State private var model = MailModel()
    /// This copy of the app's own preferences, observed rather than read: the
    /// Settings tab writes them and the shell has to notice.
    @State private var settings = ConsoleSettings.shared
    /// The CMO's curation overlay and its two read-state stores, held by the
    /// shell rather than by the tab.
    ///
    /// A dismissal is confirmed in about a minute -- the console polls every
    /// 10s and the collector re-reads the CMO's files on its own 60s cadence --
    /// and a tab is switched away from in a second. Held on the tab, the
    /// optimistic row would come back undimmed the moment somebody looked at
    /// Overview and came back, over a write that had landed perfectly. Held
    /// here, the overlay outlives the tab and the payload prunes it wherever
    /// the reader happens to be, which is the rule the reference's own provider
    /// follows from the root of the app.
    @State private var dismissals = CmoDismissals()
    @State private var watchSeen = SeenMarks("cmo-watch-seen")
    @State private var docsSeen = SeenMarks("cmo-docs-seen")
    @State private var tab: String = ConsoleSettings.shared.landing
    /// A reader can reveal the sidebar for its own message.
    @State private var expandedMailMessage: String?
    /// Bumped by ⌘K. The command field watches it and puts the caret in.
    @State private var commandFocus = 0
    /// The console pane's own width, for the padding step at 720. Measured on
    /// the pane rather than the window: the rail and the chrome are outside it.
    @State private var consoleWidth: CGFloat = 0
    /// Whether this window is on a screen. Handed down as `consoleVisible` so
    /// the two things that move can stop when there is nothing to move for.
    @State private var windowVisible = true
    /// The console window itself, held so the occlusion listener can tell it
    /// apart from every other window this process makes. Nil until the probe's
    /// first pass, and the listener fails open on nil: an orb that keeps
    /// drawing for a beat is nothing, an orb that stopped because a tooltip
    /// died is a bug this file has already had.
    @State private var consoleWindow: NSWindow?

    @Environment(\.scenePhase) private var scenePhase

    private var feedDown: Bool { model.feedDown }

    private var autoCollapseMessage: String? {
        settings.railCollapse && tab == "mail" ? model.selection : nil
    }

    private var collapsed: Bool {
        if let message = autoCollapseMessage { return expandedMailMessage != message }
        return settings.sidebarCollapsed
    }

    private func toggleSidebar() {
        if let message = autoCollapseMessage {
            expandedMailMessage = collapsed ? message : nil
        } else {
            settings.sidebarCollapsed.toggle()
        }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            // The rail or the strip, and the same answer whether or not a
            // payload has landed: the rail appearing when the first poll
            // returns would be a layout jump between two pictures of one route.
            if collapsed {
                RailStub(onShow: toggleSidebar)
            } else {
                rail
            }

            VStack(spacing: 0) {
                topBar
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // **The ground family, as identity.** The tokens are read through a
        // cache rather than through the environment -- `HT.surface3` is a
        // static, and a static is a value SwiftUI has no way to notice changing
        // -- so a panel drawn on the old ground would sit there on the new one
        // until something else happened to repaint it. Naming the rail and the
        // pane after the family throws both away and draws them again, which is
        // a full repaint of everything on screen and is exactly what is wanted
        // for a switch somebody makes about once. It is deliberately on this
        // stack and not on the whole body: the poll, the payload watchers and
        // the window chrome hang off the modifiers below, and re-identifying
        // those would restart the poller to change a colour.
        .id(settings.groundFamily)
        // The window's own backdrop is the ground. The shell hands it through.
        .background(Color.clear)
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        // Above the rail, the bar and the pane, which is what makes it a
        // treatment of the console rather than a texture on one page.
        .overlay { if settings.scanlines { Scanlines() } }
        .background { shortcuts }
        // The wash is read here rather than inside the chrome, and that read is
        // the whole of the live binding: the settings object is observed, so
        // moving the slider re-runs this body, hands the configurator a
        // different number, and `updateNSView` puts it on the layer in the same
        // pass. No relaunch, and no notification to keep in step.
        //
        // The family rides the same path, for the same reason and by the same
        // mechanism: the backdrop is behind the title bar as well as the
        // content, so it is the one fill in the app the `.id` above cannot
        // reach.
        .background { WindowChrome(ground: settings.groundOpacity,
                                   family: settings.ground,
                                   picture: settings.backdrop) }
        .background { WindowProbe { probed in
            if consoleWindow !== probed { consoleWindow = probed }
        } }
        // The Window menu and the title bar read this. One destination, one
        // name, and no second opinion about where you are.
        .navigationTitle(ConsoleNav.label(tab))
        .onChange(of: autoCollapseMessage) { _, _ in expandedMailMessage = nil }
        .onChange(of: settings.isEnabled(.messages)) { _, enabled in
            if !enabled { model.cancelHeldMessages() }
        }
        .onChange(of: settings.isTabAvailable(tab)) { _, available in
            if !available { tab = "overview" }
        }
        .environment(\.consoleVisible, windowVisible)
        .sheet(isPresented: $model.showingConnection) {
            ConnectionSheet(model: model)
        }
        .task {
            dismissals.bind(model)
            await model.refresh()
            model.startPolling()
        }
        .onChange(of: model.payload) { _, next in dismissals.reconcile(next) }
        .onChange(of: scenePhase) { _, phase in
            model.active = (phase == .active)
        }
        // scenePhase does not move for a window that is merely behind another
        // or scrolled off a space, so the poll listens for the two AppKit facts
        // as well: a console nobody is looking at is not re-read, and a window
        // coming back is re-read at once rather than up to ten seconds later.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in model.active = true }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in model.active = false }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didChangeOcclusionStateNotification)) { note in
            // Every window this process makes posts this notification, and the
            // process makes more windows than it looks like it does: tooltips,
            // sheets, the completion popup. A tooltip going away reports itself
            // not visible, and an unfiltered read of that clobbered the flag
            // for a console that was plainly on screen -- which paused the orb
            // and, worse, quietly stopped the poll. Only the console's own
            // window gets a say. `nil` fails open: until the probe has run,
            // nothing here is allowed to stop anything.
            guard let window = note.object as? NSWindow,
                  window === consoleWindow else { return }
            let visible = window.occlusionState.contains(.visible)
            model.active = visible
            // Held apart from `model.active` on purpose. That flag also goes
            // down when the app is simply not frontmost, which is the right
            // rule for a poll and the wrong one for the art: this one is only
            // ever about whether the window is on a screen. See `consoleVisible`.
            windowVisible = visible
        }
    }

    // MARK: - the rail

    private var rail: some View {
        SidebarView(
            name: "Halftone",
            brandAside: AnyView(
                IconButton(icon: "<", label: "Hide sidebar", bordered: true, action: toggleSidebar)
                    .help("Hide sidebar (⌥⌘S)")
            ),
            items: settings.availableTabs,
            active: tab,
            onSelect: { tab = $0 },
            footer: AnyView(railFooter))
    }

    private var railFooter: some View {
        Panel(dense: true) {
            VStack(alignment: .leading, spacing: 0) {
                DotLeader(label: "sources", value: sourceCount)
                DotLeader(label: "last sync", value: lastSync,
                          tone: feedDown ? .caution : .default)
            }
        }
    }

    private var sourceCount: String {
        let ok = model.payload?.health?.ok ?? 0
        let total = model.payload?.health?.total ?? 0
        return "\(ok)/\(total > 0 ? "\(total)" : "—")"
    }

    /// How long ago the document on screen arrived. Measured off the model's
    /// own clock, which the poll moves -- so this counts up between ticks
    /// rather than only when a fetch happens to succeed.
    private var lastSync: String {
        guard let at = model.fetchedAt else { return "—" }
        return Fmt.dur(model.now.timeIntervalSince(at))
    }

    // MARK: - the bar

    private var topBar: some View {
        TopBar {
            // Inert, on purpose: ⌘K puts the caret in it and nothing else
            // happens. The reference searches nothing either, and porting the
            // affordance without the behaviour is the faithful move.
            CommandField(placeholder: "Search nodes, commits", focusToken: commandFocus)
        } actions: {
            if let demo = demoTag {
                Text("DEMO \(demo)")
                    .font(HT.body)
                    .foregroundStyle(HT.c11)
                    .lineLimit(1)
                    .fixedSize()
            }
            IconButton(glyph: .refresh, label: "Refresh", bordered: true) {
                Task { await model.refresh() }
            }
            StatusLamp(level: feedDown ? 0 : 3, of: 3,
                       tone: feedDown ? .fault : .nominal,
                       label: feedDown ? "offline" : "live")
        }
    }

    /// Which fixture is on screen, or nil in live mode. The chip is the one
    /// thing standing between a demo payload and being read as a reading.
    private var demoTag: String? {
        guard model.connection.mode == .demo else { return nil }
        return DemoMode.preference.rawValue
    }

    /// ⌘K and the rail's own numbers. Everything else in this window is a
    /// binding the tab that owns it declares.
    ///
    /// Keep each destination's usual number when another feature is turned off.
    ///
    /// Drawn the way ⌘K is drawn, which is not at all: transparent, out of the
    /// hit test and out of the accessibility tree, because the visible control
    /// for each of these is the rail row it selects.
    private var shortcuts: some View {
        ZStack {
            Button("Toggle sidebar", action: toggleSidebar)
                .keyboardShortcut("s", modifiers: [.option, .command])

            Button("Search nodes, commits") { commandFocus &+= 1 }
                .keyboardShortcut("k", modifiers: .command)

            ForEach(Array(ConsoleNav.items.enumerated()), id: \.element.id) { i, item in
                if settings.isTabAvailable(item.id) {
                    Button(item.label) { tab = item.id }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))),
                                          modifiers: .command)
                }
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - the pane

    @ViewBuilder
    private var content: some View {
        if tab == "settings" {
            // Answered before the guard: preferences are facts about this copy
            // of the app, so there is nothing for a payload to add and nothing
            // for a missing one to withhold -- and under the guard the page
            // would be unreachable in exactly the state somebody needs it in.
            console { SettingsView(model: model) }
        } else if tab == "overview" {
            console { overview }
        } else if tab == ConsoleNav.overnight.id {
            OvernightTasksView(model: model)
        } else if model.payload == nil {
            console { connecting }
        } else if tab == "mail" {
            // The one tab that is not a console page. It owns its own inset,
            // its own two panes and its own scrolling, so it is handed the
            // pane whole rather than dropped into the scroller.
            MailTabView(model: model)
        } else if tab == "messages" {
            // Handed the pane whole for the mail tab's reason and in the mail
            // tab's dialect: two panes, its own scrolling, its own inset.
            MessagesTabView(model: model, openSettings: { tab = "settings" })
        } else if tab == "chat" {
            // Handed the pane for a narrower reason: its conversation route is a
            // window whose buffer takes the leftover height, and a page dropped
            // into a scroller grows instead of taking anything. The tab applies
            // the console's own margins itself -- same modifier, same numbers.
            ChatTabView(model: model)
        } else {
            console { page }
        }
    }

    @ViewBuilder
    private var page: some View {
        if let payload = model.payload {
            switch tab {
            case "hardware":
                HardwareView(payload: payload, feedDown: feedDown, now: model.now,
                             base: model.connection.url, bearer: bearerToken)
            case "cmo":
                CmoTabView(model: model, payload: payload, feedDown: feedDown,
                           dismissals: dismissals,
                           watchSeen: watchSeen, docsSeen: docsSeen)
            case "jarvis":
                JarvisTabView(model: model)
            default:
                overview
            }
        }
    }

    private var overview: some View {
        let connection = model.connection
        let profile = OverviewLayoutStore.profileKey(isDemo: connection.mode == .demo, collectorURL: connection.url)
        return ConsoleView(profileKey: profile, isDemo: connection.mode == .demo, payload: model.payload, connectionError: model.error,
                           feedDown: feedDown, now: model.now, base: model.connection.url, bearer: bearerToken)
            .id(profile)
    }

    private var bearerToken: String? {
        let token = model.connection.token
        return token.isEmpty ? nil : token
    }

    private var connecting: some View {
        Panel(title: "Connecting") {
            VStack(alignment: .leading, spacing: 0) {
                Prompt(path: "~", command: "halftone telemetry --follow", cursor: true)
                Text(model.error ?? "waiting for the first payload from the collector")
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, HT.row)
            }
        }
    }

    /// The console's one scroll container, and the only place the page padding
    /// is stated. Sixteen points of row and three cells of gutter, dropping to
    /// two cells on a narrow pane -- measured on this box, never on the window.
    private func console<C: View>(@ViewBuilder _ page: () -> C) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: HT.row) { page() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .htConsolePad(narrow: consoleWidth > 0 && consoleWidth <= HT.bpSm)
        }
        .background(Color.clear)
        .htMeasureWidth { consoleWidth = $0 }
    }
}

/* The window itself: one ground to the edges, including the band the traffic
   lights sit in.

   The mail app hid the title bar and stood its own bar in its place, which
   worked while the window held one pane. It cannot hold a rail: the lights
   would land on the brand row, and on the twenty-eight-point strip the rail
   collapses to they would land on nothing at all. So the title bar is back and
   painted out -- transparent, no separator -- which leaves the console below it
   laid out exactly as the reference lays it out, and puts the current tab's
   name somewhere it can actually be read.

   **The ground is the window's, not the console's.** The window is made
   non-opaque and its own colour cleared, and a `GroundBackdrop` -- a blur of
   whatever is behind the window, washed over with the ground of the family
   `ConsoleSettings.groundFamily` names, at the opacity
   `ConsoleSettings.groundOpacity` holds -- is put in behind everything the
   window draws. It goes into the frame view rather than into SwiftUI because
   that is the one place that is behind the title bar as well as behind the
   content: a backdrop mounted inside the console would stop at the top of the
   rail and leave the traffic-light band a flat cut-out of a translucent
   window. Nothing in the console fills the ground again -- see the note on
   `HT.void`.

   **The picture stands where the desktop stood.** A picture of the app's own
   goes in between the blur and the wash -- over one, under the other -- at the
   strength `ConsoleSettings.backdrop` holds, and zero is no picture.

   **It gets a strength and the desktop does not, and that is not an
   inconsistency.** The desktop arrives here already blurred, with its local
   contrast spent, which is the state the ink ramp was measured against. A
   picture arrives sharp. Handing it the wash alone put full-contrast edges
   directly under the type and cost the rail its labels, so the picture is
   printed at a level of its own on the way in, and the wash goes over the
   result exactly as before.

   **The wash is a value, not a constant.** Its opacity and its colour both
   arrive as properties, so every chrome pass carries the current pair and the
   pass a preference change causes lands them on the layer. Both halves stay
   idempotent: the backdrop is mounted once, and the fill is only rewritten when
   one of the two has actually moved -- which is why the family is carried as
   well as the colour it resolves to. Comparing colours would be comparing two
   freshly built `NSColor`s, and the alpha alone would leave a family switch at
   the same transparency looking like nothing happened. */
/// The hosting window, reported upward. The occlusion listener needs to know
/// which `NSWindow` is the console, and a SwiftUI view has no address for its
/// own window -- so this borrows `WindowChrome`'s trick: a zero-sized probe
/// whose only job is to be in the window and say which one it is in.
private struct WindowProbe: NSViewRepresentable {
    var report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // No window until it is in one; the first pass after that has it.
        DispatchQueue.main.async { report(probe.window) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { report(view.window) }
    }
}

private struct WindowChrome: NSViewRepresentable {

    /// How much of the blur the wash leaves showing, this pass.
    var ground: Double

    /// Which ground it is a wash of, this pass.
    var family: GroundFamily

    /// How strongly the picture behind that wash is printed, this pass. Zero
    /// is no picture.
    var picture: Double

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view has no window until it is in one; the first pass after that
        // is where the chrome can be set.
        DispatchQueue.main.async { paint(probe.window) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { paint(view.window) }
    }

    private func paint(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        styleWindowButtons(in: window)
        mount(in: window)?.wash(ground, of: family, picture: picture)
    }

    /// Clip only the painted lights. AppKit still owns the full button hit areas,
    /// hover symbols, accessibility actions and window arrangement menu.
    private func styleWindowButtons(in window: NSWindow) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let maskName = "CharonPixelWindowLight"
        for kind in kinds {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.wantsLayer = true
            guard let layer = button.layer, !layer.bounds.isEmpty else { continue }
            let scale = window.backingScaleFactor
            if let installed = layer.mask {
                guard installed.name == maskName else { continue }
                if installed.frame == layer.bounds && installed.contentsScale == scale { continue }
            }

            // Inscribe the stepped circle in the native light. Snap each edge to
            // the backing grid so the shape keeps its size on 1x and 2x screens.
            let diameter = min(12, layer.bounds.width, layer.bounds.height)
            let cell = diameter / 7
            let originX = (layer.bounds.width - diameter) / 2
            let originY = (layer.bounds.height - diameter) / 2
            func snap(_ point: CGFloat) -> CGFloat { (point * scale).rounded() / scale }

            let path = CGMutablePath()
            for (row, inset) in [2, 1, 0, 0, 0, 1, 2].enumerated() {
                let left = snap(originX + CGFloat(inset) * cell)
                let right = snap(originX + CGFloat(7 - inset) * cell)
                let bottom = snap(originY + CGFloat(row) * cell)
                let top = snap(originY + CGFloat(row + 1) * cell)
                path.addRect(CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
            }

            let mask = CAShapeLayer()
            mask.name = maskName
            mask.frame = layer.bounds
            mask.contentsScale = scale
            mask.path = path
            layer.mask = mask
        }
    }

    /// Put the backdrop at the very back of the frame view, once, and hand it
    /// back either way. Re-checked on every pass rather than remembered: the
    /// frame view is replaced when the window goes full screen, and a backdrop
    /// held in a `@State` would go with it and leave the window see-through --
    /// which is also why the one that is already there is returned rather than
    /// replaced, so a pass that only carries a new wash is a new wash.
    private func mount(in window: NSWindow) -> GroundBackdrop? {
        guard let frameView = window.contentView?.superview else { return nil }
        if let standing = frameView.subviews.first(where: {
            $0.identifier == GroundBackdrop.id
        }) as? GroundBackdrop { return standing }

        let backdrop = GroundBackdrop(frame: frameView.bounds, wash: ground,
                                      of: family, picture: picture)
        frameView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }
}

/// The blur, the picture over it, and the one fill over both.
///
/// `.underWindowBackground` behind the window rather than behind the view: this
/// is the ground the whole app stands on, so what it samples is the desktop,
/// not the console.
private final class GroundBackdrop: NSVisualEffectView {

    static let id = NSUserInterfaceItemIdentifier("halftone.ground")

    /// The picture, when the preference asks for one. Over the blur and under
    /// the wash, standing exactly where the desktop stood, and printed at a
    /// strength of its own on the way in.
    private let art = NSView()

    /// The wash. A plain layer-backed view rather than a colour on the effect
    /// view itself, which has no such property -- and a subview keeps it to one
    /// fill in one place, which is the whole rule.
    private let plate = NSView()

    /// What is currently on the two layers, as the three things that decide it.
    /// Held so the chrome can be re-applied on every pass without touching a
    /// layer on the passes that change nothing.
    private var applied: Double = .nan
    private var appliedFamily: GroundFamily?
    private var appliedArt: Double = .nan

    init(frame frameRect: NSRect, wash opacity: Double, of family: GroundFamily,
         picture strength: Double) {
        super.init(frame: frameRect)
        identifier = Self.id
        material = .underWindowBackground
        blendingMode = .behindWindow
        // Kept lit while the window is not key. A ground that drained to grey
        // every time he clicked another app would be the one animation in the
        // system, and it would be the background doing it.
        state = .active
        autoresizingMask = [.width, .height]

        // The picture first and the wash second, because that is the order they
        // stack in. Sized here as well as in `layout`: the first layout pass has
        // not run when the backdrop is mounted, and a wash that waited for one
        // would leave the window showing bare blur until something else moved.
        for slab in [art, plate] {
            slab.wantsLayer = true
            slab.frame = bounds
            slab.autoresizingMask = [.width, .height]
            addSubview(slab)
        }
        // Cropped to fill, never stretched. The window is whatever shape it has
        // been dragged to and the picture has an aspect of its own, so one of
        // the two has to give, and a picture pulled out of shape is a worse
        // answer than a picture with its edges off the window.
        art.layer?.contentsGravity = .resizeAspectFill
        art.layer?.masksToBounds = true

        wash(opacity, of: family, picture: strength)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Set the picture and the fill. Called on every chrome pass, so it does
    /// nothing unless the colour, the alpha or the picture moved.
    ///
    /// The ground is taken from the family passed in rather than read off
    /// `HT.void`, so this cannot land a stale wash on a pass that arrived
    /// before the token cache did.
    func wash(_ opacity: Double, of family: GroundFamily, picture strength: Double) {
        guard opacity != applied || family != appliedFamily || strength != appliedArt
        else { return }
        applied = opacity
        appliedFamily = family
        appliedArt = strength
        // Explicitly unanimated: a layer colour is one of the properties Core
        // Animation will cross-fade on its own given the chance, and the only
        // motion in this console is a cursor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.layer?.backgroundColor = NSColor(family.palette.void)
            .withAlphaComponent(opacity).cgColor
        // Cleared rather than faded to nothing at zero, so the layer is not
        // carrying a picture nobody can see. The decode behind it is a lazy
        // static and runs once: a console left at zero never pays for it at
        // all.
        art.alphaValue = strength
        art.layer?.contents = strength > 0 ? BackdropPicture.image : nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        art.frame = bounds
        plate.frame = bounds
    }
}

/// The picture behind the window, decoded once.
///
/// **Once, and lazily, for the whole app.** A `static let` rather than a
/// property on the backdrop: there is one picture and it is the same picture in
/// every window, so a per-backdrop decode would be paying twice for the same
/// four thousand pixels -- and because a lazy static is not touched until
/// something asks, a console left with the preference off never decodes it.
///
/// **Full size, not a thumbnail.** The obvious economy here is to decode this
/// down to something nearer the window's own pixels, and it is the wrong one:
/// the picture is a dither, its grain is a structure rather than a texture, and
/// every resampler turns that structure into noise. Core Animation's own
/// scaling on the way to the screen is one such pass and unavoidable; a second
/// one at decode would be a choice.
///
/// Nil when the resource is not there, which lands on the same picture as the
/// preference being off: the blur shows through and nothing says a word about
/// it. A missing background is not worth an alert.
private enum BackdropPicture {
    static let image: CGImage? = {
        guard let url = Bundle.main.url(forResource: "Backdrop", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
}
