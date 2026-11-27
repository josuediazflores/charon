import AppKit
import ImageIO
import SwiftUI

/// Shared navigation and window appearance for the console.
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
    @State private var navigatorOpen = false
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        GeometryReader { window in
            HStack(spacing: 0) {
                rail
                    .frame(width: collapsed ? SidebarView.collapsedWidth : min(284, max(172, window.size.width * 0.185)))
                    .clipped()
                    .popover(isPresented: $navigatorOpen,
                             attachmentAnchor: .point(UnitPoint(x: 1, y: 0.08)), arrowEdge: .trailing) {
                        DestinationPicker(items: settings.landingOptions, current: tab) { destination in
                            tab = destination
                            navigatorOpen = false
                        }
                    }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: collapsed)
            .environment(\.workspaceScale, min(1, max(0.72, window.size.width / 1536)))
        }
        .ignoresSafeArea(.container, edges: .top)
        // The window's own backdrop is the ground. The shell hands it through.
        .background(Color.clear)
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .toolbarBackgroundVisibility(Ground.shared.glass ? .hidden : .automatic, for: .windowToolbar)
        // Above the rail and the pane, which makes it a
        // treatment of the console rather than a texture on one page.
        .overlay { if settings.scanlines { Scanlines() } }
        .focusedSceneValue(\.destinationPickerOpen, $navigatorOpen)
        .focusedSceneValue(\.consoleModel, model)
        .background { shortcuts }
        .background {
            WindowChrome(wash: Ground.shared.glass
                ? .glass(transparency: settings.glassTransparency, blur: settings.glassBlur,
                         reduceTransparency: reduceTransparency)
                : .standard(family: settings.ground, opacity: settings.groundOpacity, picture: settings.backdrop))
        }
        .background { WindowProbe { probed in
            if consoleWindow !== probed { consoleWindow = probed }
        } }
        // Keep the destination name in the Window menu and accessibility tree.
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
            collapsed: collapsed,
            onToggle: toggleSidebar,
            items: settings.availableTabs,
            active: tab,
            onSelect: { tab = $0 },
            footer: AnyView(railFooter))
    }

    private var railFooter: some View {
        let status = feedDown ? "Offline" : (model.payload == nil ? "Connecting…" : "Connected")
        let mode = model.connection.mode == .demo ? "Demo " + DemoMode.preference.rawValue : "Live"
        let detail = [
            mode,
            (model.payload?.health).map { "\($0.ok) of \($0.total) sources reporting" },
            model.fetchedAt.map { "Last sync \(Fmt.dur(model.now.timeIntervalSince($0))) ago" }
        ].compactMap { $0 }.joined(separator: ". ")
        return HStack(spacing: 9) {
            Circle().fill(feedDown ? HT.fault : (model.payload == nil ? HT.inkMid : Color.green))
                .frame(width: 10, height: 10)
            if !collapsed { Text(status).fixedSize() }
        }
        .foregroundStyle(Color(white: 0.79))
        .help([status, detail].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
        .accessibilityHint(detail)
    }

    /// Keep each destination's usual shortcut when another feature is turned off.
    private var shortcuts: some View {
        ZStack {
            Button("Toggle sidebar", action: toggleSidebar)
                .keyboardShortcut("s", modifiers: [.option, .command])

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
        } else if tab == "jarvis" {
            JarvisTabView(model: model)
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

private enum WindowWash: Equatable {
    case standard(family: GroundFamily, opacity: Double, picture: Double)
    case glass(transparency: Double, blur: Double, reduceTransparency: Bool)
}

private struct WindowChrome: NSViewRepresentable {
    let wash: WindowWash

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
        mount(in: window)?.apply(wash)
    }

    private func mount(in window: NSWindow) -> GroundBackdrop? {
        guard let frameView = window.contentView?.superview else { return nil }
        if let standing = frameView.subviews.first(where: {
            $0.identifier == GroundBackdrop.id
        }) as? GroundBackdrop { return standing }

        let backdrop = GroundBackdrop(frame: frameView.bounds)
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

    private let tint = CAGradientLayer()
    private var applied: WindowWash?

    override init(frame frameRect: NSRect) {
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

        tint.startPoint = CGPoint(x: 0.95, y: 1)
        tint.endPoint = CGPoint(x: 0.15, y: 0.25)
        tint.locations = [0, 0.30, 0.66]
        tint.frame = plate.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        plate.layer?.addSublayer(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func apply(_ wash: WindowWash) {
        guard applied != wash else { return }
        applied = wash
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch wash {
        case let .standard(family, opacity, strength):
            material = .underWindowBackground
            setBlurStrength(1)
            tint.isHidden = true
            plate.layer?.backgroundColor = NSColor(family.palette.void).withAlphaComponent(opacity).cgColor
            art.alphaValue = strength
            art.layer?.contents = strength > 0 ? BackdropPicture.image : nil
        case let .glass(transparency, blur, reduceTransparency):
            material = .hudWindow
            setBlurStrength(reduceTransparency ? 0 : blur)
            art.layer?.contents = nil
            plate.layer?.backgroundColor = nil
            tint.isHidden = false
            // Leave the upper-right open to the scenery. Darken the reading edge
            // more when the user dials down blur and sharp highlights come through.
            let transmission = reduceTransparency ? 0 : transparency
            tint.colors = [
                NSColor(white: 0.16, alpha: 1 - transmission).cgColor,
                NSColor(white: 0.10, alpha: 1 - transmission * (0.55 + 0.20 * blur)).cgColor,
                NSColor(white: 0.07, alpha: 1 - transmission * (0.37 + 0.20 * blur)).cgColor
            ]
        }
        CATransaction.commit()
    }

    private var blurStrength: Double = 1

    private func setBlurStrength(_ strength: Double) {
        guard strength != blurStrength else { return }
        blurStrength = strength
        // AppKit applies the mask to the desktop material alone. The tint,
        // window controls and text keep their own opacity.
        // The HUD material transmits about three fifths of clear glass contrast.
        // Account for that difference so the middle of the slider visibly softens detail.
        let materialContrast = 0.60
        let coverage = strength / (strength + (1 - strength) * materialContrast)
        maskImage = strength == 1 ? nil : NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.white.withAlphaComponent(coverage).setFill()
            rect.fill(using: .copy)
            return true
        }
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
