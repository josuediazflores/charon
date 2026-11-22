import SwiftUI
import UniformTypeIdentifiers

/// The shell keeps the scroller and route title. Only the body of a known widget
/// comes from its caller, so dragging and resizing use the same grid on both builds.
struct OverviewDashboard<Content: View>: View {
    let profileKey: String
    let isDemo: Bool
    @ViewBuilder let content: (OverviewLayout.Entry, Bool, @escaping (Double) -> Void) -> Content

    var body: some View {
        OverviewPage(store: OverviewLayoutStore(key: profileKey), isDemo: isDemo, content: content)
            .id(profileKey)
    }
}

private struct OverviewPage<Content: View>: View {
    let store: OverviewLayoutStore
    let isDemo: Bool
    @ViewBuilder let content: (OverviewLayout.Entry, Bool, @escaping (Double) -> Void) -> Content

    @State private var saved: OverviewLayout?
    @State private var draft: OverviewLayout?
    @State private var libraryOpen = false
    @State private var setupKind: OverviewWidget?
    @State private var editingID: String?
    @State private var dragSession = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            if let layout = draft ?? saved {
                toolbar
                if layout.entries.isEmpty {
                    emptyState
                } else {
                    HTGrid {
                        ForEach(layout.entries, id: \.id) { entry in
                            Cell(span: entry.span, spanMd: entry.spanMd) {
                                if draft != nil {
                                    editingCell(entry, in: layout)
                                } else {
                                    widget(entry)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $libraryOpen) { widgetLibrary }
        .onAppear {
            // Polls rebuild this View value. Read defaults only when the
            // profile first appears and only write them when the user saves.
            if saved == nil { saved = store.load() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: HT.cw) {
            Spacer(minLength: 0)
            if let draft {
                HTButton(title: "Add Widget", action: openLibrary)
                    .modifier(OverviewControlFocus())
                    .accessibilityIdentifier("overview.add")
                HTButton(title: "Cancel", variant: .ghost, action: { self.draft = nil })
                    .modifier(OverviewControlFocus())
                    .accessibilityIdentifier("overview.cancel")
                HTButton(title: "Save", variant: .primary) {
                    store.save(draft)
                    saved = draft
                    self.draft = nil
                }
                .modifier(OverviewControlFocus())
                .accessibilityIdentifier("overview.save")
            } else {
                HTButton(title: "Edit Overview", action: beginEditing)
                    .modifier(OverviewControlFocus())
                    .accessibilityIdentifier("overview.edit")
            }
        }
    }

    private func openLibrary() {
        editingID = nil
        setupKind = nil
        libraryOpen = true
    }

    @ViewBuilder
    private var widgetLibrary: some View {
        if let kind = setupKind {
            let initial = draft?.entries.first { $0.id == editingID }?.configuration
            if kind == .custom {
                CustomWidgetSetup(initial: initial?.custom, isDemo: isDemo, cancel: { libraryOpen = false }) { spec in
                    apply(OverviewWidgetConfig(custom: spec), for: .custom)
                }
                .id(editingID ?? kind.rawValue)
            } else {
                OverviewWidgetSetup(kind: kind, isDemo: isDemo, initial: initial,
                                    cancel: { libraryOpen = false }) { apply($0, for: kind) }
                    .id(editingID ?? kind.rawValue)
            }
        } else if let draft {
            VStack(alignment: .leading, spacing: HT.row) {
                Text("ADD WIDGET").font(HT.lead).foregroundStyle(HT.inkBright)
                ScrollView {
                    VStack(alignment: .leading, spacing: HT.s2) {
                        HTButton(title: "Custom widget", variant: .primary, block: true) { setupKind = .custom }
                            .modifier(OverviewControlFocus())
                            .accessibilityIdentifier("overview.library.custom")
                        Text("Choose a display and add your own data.")
                            .foregroundStyle(HT.inkMid)
                            .padding(.bottom, HT.s2)
                        catalogGroup("Presets", items: draft.availableWidgets.filter { $0.configurable && $0 != .custom })
                        catalogGroup("Restore a widget", items: draft.availableWidgets.filter { !$0.configurable })
                    }
                }
                HStack {
                    Spacer()
                    HTButton(title: "Close", action: { libraryOpen = false })
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("overview.library.close")
                }
            }
            .font(HT.body)
            .padding(HT.s5)
            .frame(width: 360, height: 430)
            .background(HT.void)
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func catalogGroup(_ label: String, items: [OverviewWidget]) -> some View {
        if !items.isEmpty {
            Text(label).foregroundStyle(HT.inkMid)
            ForEach(items, id: \.rawValue) { item in
                HTButton(title: item.title, block: true) {
                    if item.configurable {
                        setupKind = item
                    } else {
                        draft?.add(item)
                        libraryOpen = false
                    }
                }
                .modifier(OverviewControlFocus())
                .accessibilityIdentifier("overview.library.\(item.rawValue)")
            }
        }
    }

    private func apply(_ configuration: OverviewWidgetConfig, for kind: OverviewWidget) {
        if let editingID {
            draft?.configure(editingID, configuration: configuration)
        } else {
            draft?.add(kind, configuration: configuration)
        }
        libraryOpen = false
    }

    private func beginEditing() {
        dragSession = UUID()
        draft = saved
    }

    private var emptyState: some View {
        Panel(title: "No widgets") {
            if draft == nil {
                HTButton(title: "Add Widget") {
                    beginEditing()
                    openLibrary()
                }
                .modifier(OverviewControlFocus())
                .accessibilityIdentifier("overview.empty.add")
            } else {
                Text("Choose Add Widget to build your Overview.")
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.empty")
    }

    @ViewBuilder
    private func widget(_ entry: OverviewLayout.Entry) -> some View {
        if entry.widget != nil {
            content(entry, draft != nil) { value in updateManualValue(value, for: entry.id) }
        } else {
            Panel(title: "Unavailable widget") {
                Text(verbatim: entry.id)
                    .font(HT.body)
                    .foregroundStyle(HT.inkMid)
                    .lineLimit(2)
            }
        }
    }

    private func updateManualValue(_ value: Double, for id: String) {
        guard draft == nil else { return }
        var latest = store.load()
        guard let entry = latest.entries.first(where: { $0.id == id }),
              entry.widget == .progress, entry.configuration.progressSource == .manual else {
            saved = latest
            return
        }
        var configuration = entry.configuration
        configuration.current = value
        guard configuration.validationError(for: .progress) == nil else { return }
        latest.configure(id, configuration: configuration)
        store.save(latest)
        saved = latest
    }

    private func editingCell(_ entry: OverviewLayout.Entry, in layout: OverviewLayout) -> some View {
        let index = layout.entries.firstIndex { $0.id == entry.id } ?? 0
        return OverviewEditingCell(entry: entry, index: index, count: layout.entries.count,
                                   session: dragSession,
                                   configure: {
                                       editingID = entry.id
                                       setupKind = entry.widget
                                       libraryOpen = true
                                   },
                                   move: { id, destination in draft?.move(id, to: destination) },
                                   remove: { draft?.remove(entry.id) },
                                   resize: { draft?.resize(entry.id, to: $0) }) {
            widget(entry)
        }
    }
}

/// A drop from another window or an older edit session cannot reorder this draft.
private struct OverviewDragItem: Codable, Transferable {
    let session: UUID
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
            .visibility(.ownProcess)
    }
}

private struct OverviewEditingCell<Content: View>: View {
    let entry: OverviewLayout.Entry
    let index: Int
    let count: Int
    let session: UUID
    let configure: () -> Void
    let move: (String, Int) -> Void
    let remove: () -> Void
    let resize: (OverviewSize) -> Void
    @ViewBuilder let content: Content

    @State private var targeted = false
    @FocusState private var gripFocused: Bool
    @State private var sizeOpen = false

    private var title: String { entry.configuration.custom?.title ?? entry.widget?.title ?? "Unavailable widget" }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HT.cw) {
                    heading.fixedSize()
                    Spacer(minLength: HT.cw)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    actions
                }
            }
            .padding(.horizontal, HT.cw)
            .padding(.vertical, HT.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HT.surface3)

            content
        }
        .overlay {
            if targeted {
                Rectangle()
                    .strokeBorder(HT.signal, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: OverviewDragItem.self) { items, _ in
            guard let item = items.first, item.session == session, item.id != entry.id else { return false }
            move(item.id, index)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.widget.\(entry.id)")
    }

    private var heading: some View {
        HStack(spacing: HT.cw) {
            VStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    Rectangle().fill(HT.inkMid).frame(width: 12, height: 2)
                }
            }
            .frame(width: HT.row2, height: HT.row2)
            .contentShape(Rectangle())
            .draggable(OverviewDragItem(session: session, id: entry.id)) {
                Text(title)
                    .font(HT.body).foregroundStyle(HT.inkBright)
                    .padding(HT.cw).background(HT.surface3)
            }
            .focusable()
            .focused($gripFocused)
            .focusEffectDisabled()
            .overlay { if gripFocused { Rectangle().strokeBorder(HT.focus) } }
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                guard key.modifiers.intersection([.option, .command, .control, .shift]) == .option else { return .ignored }
                let next = index + (key.key == .upArrow ? -1 : 1)
                if (0..<count).contains(next) { move(entry.id, next) }
                return .handled
            }
            .help("Drag to another widget, or use Option and the Up or Down arrow.")
            .accessibilityLabel(Text("Reorder \(title)"))
            .accessibilityIdentifier("overview.grip.\(entry.id)")

            Text(title.uppercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .lineLimit(1)
            Text("\(index + 1)/\(count)")
                .font(HT.body)
                .foregroundStyle(HT.inkMid)
                .accessibilityLabel(Text("Position \(index + 1) of \(count)"))
                .accessibilityIdentifier("overview.position.\(entry.id)")
        }
    }

    private var actions: some View {
        HStack(spacing: HT.s1) {
            IconButton(icon: "↑", label: "Move \(title) earlier", disabled: index == 0) {
                move(entry.id, index - 1)
            }
            .modifier(OverviewControlFocus())
            .help("Move earlier")
            .accessibilityIdentifier("overview.earlier.\(entry.id)")
            IconButton(icon: "↓", label: "Move \(title) later", disabled: index + 1 == count) {
                move(entry.id, index + 1)
            }
            .modifier(OverviewControlFocus())
            .help("Move later")
            .accessibilityIdentifier("overview.later.\(entry.id)")

            if let kind = entry.widget {
                if kind.configurable {
                    HTButton(title: "Setup", variant: .ghost, nobracket: true, action: configure)
                        .modifier(OverviewControlFocus())
                        .accessibilityLabel(Text("Configure \(title)"))
                        .accessibilityIdentifier("overview.configure.\(entry.id)")
                }
                HTButton(title: entry.size.title, variant: .ghost, iconAfter: kind.sizes.count > 1 ? "▽" : nil,
                         nobracket: true, disabled: kind.sizes.count < 2) { sizeOpen = true }
                    .modifier(OverviewControlFocus())
                    .help("Widget width")
                    .accessibilityLabel(Text("Width of \(title)"))
                    .accessibilityValue(Text(entry.size.title))
                    .accessibilityIdentifier("overview.size.\(entry.id)")
                    .popover(isPresented: $sizeOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: HT.s2) {
                            Text("WIDGET WIDTH").font(HT.body).foregroundStyle(HT.inkBright)
                            ForEach(kind.sizes, id: \.rawValue) { size in
                                HTButton(title: size.title, variant: size == entry.size ? .primary : .secondary,
                                         block: true) {
                                    resize(size)
                                    sizeOpen = false
                                }
                                .modifier(OverviewControlFocus())
                                .accessibilityAddTraits(size == entry.size ? .isSelected : [])
                                .accessibilityIdentifier("overview.sizeChoice.\(entry.id).\(size.rawValue)")
                            }
                        }
                        .padding(HT.row).background(HT.void)
                    }
            }
            IconButton(icon: "×", label: "Remove \(title)", action: remove)
                .modifier(OverviewControlFocus())
                .help("Remove widget")
                .accessibilityIdentifier("overview.remove.\(entry.id)")
        }
    }
}

/// The standard Halftone buttons suppress the system halo. Give keyboard users
/// the kit's one-pixel focus rule without changing pointer or press feedback.
private struct OverviewControlFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused)
            .overlay {
                if focused {
                    Rectangle().strokeBorder(HT.focus, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}
