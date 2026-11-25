import AppKit
import QuickLook
import SwiftUI

struct OvernightTasksView: View {
    let model: MailModel

    var body: some View {
        OvernightRunList(store: model.store, draftScope: model.connection.mode.rawValue + model.connection.baseURL)
            .id(ObjectIdentifier(model.store))
    }
}

private struct PageRequest: Equatable {
    var before: String?
    let revision = UUID()
}

private struct OvernightRunList: View {
    let store: ConsoleStore
    let draftScope: String
    @State private var runs: [OvernightRun] = []
    @State private var route: [OvernightRun] = []
    @State private var composing = false
    @State private var cursor: String?
    @State private var query = PageRequest()
    @State private var loading = true
    @State private var legacy = false
    @State private var error: String?
    @State private var filter = OvernightRunFilter.all
    @AppStorage("overnightTaskDateOrder") private var dateOrder = OvernightRunDateOrder.newestFirst

    var body: some View {
        VStack(spacing: 0) {
            if composing {
                OvernightIntakeView(store: store, scope: draftScope, back: { composing = false }) { plan in
                    composing = false
                    route = [plan]
                }
            } else if let selected = route.last, selected.kind == "brain_dump", selected.status != "done" {
                BrainDumpReview(store: store, scope: draftScope, plan: selected, back: {
                    route.removeLast()
                    query = PageRequest()
                }, confirmed: { plan in route = [plan] })
                .id(selected.id)
            } else if let selected = route.last {
                RunReader(store: store, summary: selected, legacy: legacy,
                          backTitle: route.dropLast().last?.name ?? "Overnight tasks",
                          openChild: { route.append($0) }) {
                    route.removeLast()
                    if route.isEmpty { query = PageRequest() }
                }
                    .id(selected.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Overnight tasks").font(FocusInk.heading(38)).foregroundStyle(FocusInk.text)
                            Spacer()
                            Button { composing = true } label: {
                                ViewThatFits {
                                    Label("Set overnight tasks", systemImage: "plus")
                                    Image(systemName: "plus")
                                }
                            }
                            .accessibilityLabel("Set overnight tasks")
                            Button { query = PageRequest() } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel("Refresh overnight tasks").disabled(loading)
                        }
                        if legacy {
                            Text("Recent job records from the Pi. The older collector provides result excerpts and web links.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let error {
                            Text(error).foregroundStyle(.secondary)
                            Button("Try again") { query = PageRequest(before: query.before) }
                        }
                        if runs.isEmpty && !loading && error == nil {
                            Text("No overnight tasks yet.").foregroundStyle(.secondary)
                        }
                        if !runs.isEmpty {
                            listControls
                            taskRows
                        }
                        if loading { ProgressView().controlSize(.small).accessibilityLabel("Loading overnight tasks") }
                        if let cursor, !loading, error == nil {
                            Button("Show earlier tasks") { query = PageRequest(before: cursor) }
                        }
                    }
                    .frame(maxWidth: 690, alignment: .leading).padding(32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: query) {
            loading = true
            error = nil
            do {
                let page = try await store.overnightRuns(before: query.before)
                try Task.checkCancellation()
                if query.before == nil { runs = [] }
                var seen = Set(runs.map(\.id))
                runs.append(contentsOf: page.runs.filter { seen.insert($0.id).inserted })
                cursor = page.nextCursor
                legacy = page.legacy
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private var listControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                filterButtons
                Spacer(minLength: 12)
                dateMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                filterButtons
                dateMenu
            }
        }
    }

    private var filterButtons: some View {
        HStack(spacing: 4) {
            ForEach(OvernightRunFilter.allCases, id: \.self) { option in
                let selected = option == filter
                let count = runs.count(where: option.matches)
                Button { filter = option } label: {
                    HStack(spacing: 5) {
                        Text(option.rawValue).fontWeight(selected ? .semibold : .regular)
                        Text(count.formatted()).monospacedDigit().foregroundStyle(FocusInk.secondary)
                    }
                    .font(.callout)
                    .fixedSize()
                    .foregroundStyle(selected ? FocusInk.sand : FocusInk.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selected ? HT.surface3 : HT.void, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.rawValue), \(count) tasks")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var dateMenu: some View {
        Menu {
            Picker("Sort by date", selection: $dateOrder) {
                ForEach(OvernightRunDateOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        } label: {
            Label(dateOrder.rawValue, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort by date")
        .accessibilityValue(dateOrder.rawValue)
        .help("Sort loaded tasks by the date shown in each row")
    }

    @ViewBuilder
    private var taskRows: some View {
        let visible = dateOrder.sorted(runs.filter(filter.matches))
        if visible.isEmpty {
            Text(filter == .inFlight ? "No in-flight tasks in this list." : "No task history in this list.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(visible) { run in
                    Button { route.append(run) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.name).font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(FocusInk.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 7) {
                                    let tone = statusColor(run)
                                    Circle().fill(tone).frame(width: 5, height: 5).accessibilityHidden(true)
                                    Text(run.statusLabel).foregroundStyle(tone)
                                    let date = dateLabel(run.listTimestamp)
                                    if !date.isEmpty {
                                        Text("·").accessibilityHidden(true)
                                        Text(date).monospacedDigit()
                                    }
                                }
                                .font(.callout)
                                .foregroundStyle(FocusInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(FocusInk.secondary).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if run.id != visible.last?.id {
                        Rectangle().fill(FocusInk.cardLine).frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .focusCard()
        }
    }

    private func statusColor(_ run: OvernightRun) -> Color {
        switch run.status {
        case "review", "needs-input", "stopped": return FocusInk.sand
        case "done": return HT.c10
        case "error": return HT.c9
        case "running": return HT.c12
        default: return FocusInk.secondary
        }
    }
}

private func dateLabel(_ raw: String) -> String {
    Fmt.date(raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
}

private func statusLine(_ run: OvernightRun) -> String {
    [run.statusLabel, dateLabel(run.listTimestamp)].filter { !$0.isEmpty }.joined(separator: " · ")
}

private struct RunColumn<Content: View>: View {
    @ViewBuilder let content: (ScrollViewProxy) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content(proxy) }
                    .frame(maxWidth: 660, alignment: .leading).padding(32)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct RunReader: View {
    let store: ConsoleStore
    let summary: OvernightRun
    let legacy: Bool
    let backTitle: String
    let openChild: (OvernightRun) -> Void
    let back: () -> Void
    @State private var report: OvernightRun?
    @State private var error: String?
    @State private var request = UUID()
    @State private var attachments: [RunFileLocation] = []
    @State private var stopping = false

    var body: some View {
        if let report, let current = attachments.last {
            RunFileReader(store: store, run: report, location: current,
                          follow: { attachments.append($0) },
                          back: { attachments.removeLast() })
                .id(current)
        } else {
            RunColumn { scroll in
                Button(action: back) { Label(backTitle, systemImage: "arrow.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Text(summary.name).font(FocusInk.heading(38)).foregroundStyle(FocusInk.text)
                if let report {
                    Text(statusLine(report))
                        .font(.callout).foregroundStyle(.secondary)
                    if report.isPlanning, let start = report.runAt {
                        Text("Tasks start \(dateLabel(start))").foregroundStyle(.secondary)
                    }
                    if report.status == "scheduled", report.parentId != nil {
                        Button(stopping ? "Stopping…" : "Stop scheduled task") {
                            Task { await stopScheduledTask() }
                        }
                        .disabled(stopping)
                    }
                    if let message = report.error, !message.isEmpty { Text(message).textSelection(.enabled) }
                    if let markdown = report.markdown, !markdown.isEmpty {
                        RunMarkdown(markdown: markdown, run: report, scroll: scroll, follow: { attachments.append($0) })
                    } else if report.isPlanning && report.active {
                        Text("Jarvis is preparing your tasks.").foregroundStyle(.secondary)
                    } else if report.kind != "brain_dump" && report.status != "scheduled" && report.status != "stopped" {
                        Text("This run has no saved report yet.").foregroundStyle(.secondary)
                    }
                    if let children = report.children, !children.isEmpty {
                        Text("Tasks").font(.title2.weight(.semibold))
                        ForEach(children) { child in
                            Button { openChild(child) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(child.name).font(.headline)
                                        Text(statusLine(child)).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(12).focusCard().contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    if let prompt = report.request, !prompt.isEmpty {
                        DisclosureGroup("Original request") { Text(prompt).textSelection(.enabled) }
                    }
                    let sources = (report.sources ?? []).filter { OvernightRun.webLink($0.url) != nil }
                    if !sources.isEmpty {
                        Text("Sources").font(.title2.weight(.semibold))
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                            if let url = OvernightRun.webLink(source.url) {
                                Link(source.label.isEmpty ? url.absoluteString : source.label, destination: url)
                                    .help(url.absoluteString)
                            }
                        }
                    }
                    if let files = report.files, !files.isEmpty {
                        Text("Files").font(.title2.weight(.semibold))
                        ForEach(files) { file in
                            Button { attachments.append(RunFileLocation(file: file)) } label: {
                                Label(file.label.isEmpty ? file.path : file.label, systemImage: "doc")
                            }
                            .buttonStyle(.link).help(file.path)
                        }
                    }
                    if legacy {
                        Text("This collector supplies the saved job excerpt. Run files require the run reader on the Pi.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    ProgressView().controlSize(.small)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { request = UUID() }
                }
            }
            .task(id: request) {
                error = nil
                do {
                    while !Task.isCancelled {
                        let value: OvernightRun?
                        if summary.fromJobList { value = summary }
                        else { value = try await store.overnightRun(id: summary.id) }
                        try Task.checkCancellation()
                        guard let value else { error = "This run is no longer available on the Pi."; return }
                        report = value
                        guard !summary.fromJobList else { return }
                        let related = [value] + (value.children ?? [])
                        let delay: TimeInterval
                        if related.contains(where: \.active) {
                            delay = 3
                        } else if let start = related.filter({ $0.status == "scheduled" })
                            .compactMap({ Fmt.date($0.runAt) }).min() {
                            delay = max(3, min(60, start.timeIntervalSinceNow))
                        } else { return }
                        try await Task.sleep(for: .seconds(delay))
                    }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func stopScheduledTask() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        if case .ok = await store.jarvisJobStop(id: summary.id) {
            request = UUID()
        } else {
            error = "Couldn’t stop this task. Check your connection and try again."
        }
    }
}

private struct RunFileLocation: Hashable {
    let file: OvernightRun.File
    var fragment: String?
}

private struct RunFileReader: View {
    let store: ConsoleStore
    let run: OvernightRun
    let location: RunFileLocation
    let follow: (RunFileLocation) -> Void
    let back: () -> Void
    @State private var markdown: String?
    @State private var localFile: URL?
    @State private var preview: URL?
    @State private var error: String?
    @State private var request = UUID()

    var body: some View {
        RunColumn { scroll in
            Button(action: back) { Label("Back", systemImage: "arrow.left") }.buttonStyle(.plain)
            Text(location.file.label.isEmpty ? location.file.name : location.file.label)
                .font(FocusInk.heading(38)).foregroundStyle(FocusInk.text)
            if let markdown {
                RunMarkdown(markdown: markdown, run: run, scroll: scroll, location: location, follow: follow)
            } else if let localFile {
                Text(location.file.path).foregroundStyle(.secondary)
                HStack {
                    Button("Quick Look") { preview = localFile }
                    Button("Save a copy…") { save(localFile) }
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { request = UUID() }
            } else { ProgressView().controlSize(.small) }
        }
        .quickLookPreview($preview)
        .task(id: request) {
            error = nil
            do {
                guard let downloaded = try await store.overnightFile(run: run.id, file: location.file.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try Task.checkCancellation()
                if location.file.isMarkdown {
                    markdown = try String(contentsOf: downloaded, encoding: .utf8)
                } else {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let name = location.file.name
                    guard !["", ".", "..", "/"].contains(name) else { throw CocoaError(.fileReadInvalidFileName) }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    let url = folder.appendingPathComponent(name)
                    do { try FileManager.default.moveItem(at: downloaded, to: url) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    localFile = url
                    preview = url
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear {
            preview = nil
            if let localFile { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        }
    }

    private func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = location.file.name
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let manager = FileManager.default
            let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: target, create: true)
            defer { try? manager.removeItem(at: staging) }
            let copy = staging.appendingPathComponent(target.lastPathComponent)
            try manager.copyItem(at: url, to: copy)
            if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: copy) }
            else { try manager.moveItem(at: copy, to: target) }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

/// Render the console's Markdown blocks with the wider, proportional task-reader type.
private struct RunMarkdown: View {
    let scroll: ScrollViewProxy
    let run: OvernightRun
    let location: RunFileLocation?
    let follow: (RunFileLocation) -> Void
    private let nodes: [MdNode]

    init(markdown: String, run: OvernightRun, scroll: ScrollViewProxy, location: RunFileLocation? = nil,
         follow: @escaping (RunFileLocation) -> Void) {
        self.scroll = scroll
        self.run = run
        self.location = location
        self.follow = follow
        self.nodes = Markdown.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(nodes) { node in
                switch node.block {
                case .h1(let title):
                    inline(title).font(.title.weight(.semibold)).id("md-" + Markdown.slug(title))
                case .head(let level, let title, let anchor):
                    inline(title).font(level == 2 ? .title2.weight(.semibold) : .headline)
                        .padding(.top, 8).id(anchor)
                case .p(let paragraph): inline(paragraph)
                case .ul(let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline) { Text("•"); inline(item) }
                        }
                    }
                case .hr: Divider()
                case .code(let code): Text(verbatim: code).font(.body.monospaced()).textSelection(.enabled)
                case .quote(let quote): inline(quote).italic().padding(.leading)
                }
            }
        }
        .font(.system(size: 16)).lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let anchor = location?.fragment, !anchor.isEmpty {
                scroll.scrollTo("md-" + Markdown.slug(anchor), anchor: .top)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if OvernightRun.webLink(url.absoluteString) != nil { return .systemAction }
            guard url.scheme == "jarvis-reader",
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let target = parts.queryItems?.first(where: { $0.name == "target" })?.value else { return .discarded }
            if parts.path == "/heading" {
                scroll.scrollTo("md-" + Markdown.slug(target), anchor: .top)
                return .handled
            }
            if let file = run.linkedFile(target, from: location?.file) {
                follow(.init(file: file, fragment: URLComponents(string: target)?.fragment))
                return .handled
            }
            return .discarded
        })
    }

    private func inline(_ source: String) -> Text {
        var body = (try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for span in body.runs where span.link != nil {
            guard let url = span.link else { continue }
            let href = url.relativeString
            if OvernightRun.webLink(href) != nil { continue }
            var parts = URLComponents()
            parts.scheme = "jarvis-reader"
            if href.hasPrefix("#"), let anchor = URLComponents(string: href)?.fragment {
                parts.path = "/heading"
                parts.queryItems = [URLQueryItem(name: "target", value: anchor)]
            } else if run.linkedFile(href, from: location?.file) != nil {
                parts.path = "/file"
                parts.queryItems = [URLQueryItem(name: "target", value: href)]
            } else {
                body[span.range].link = nil
                continue
            }
            body[span.range].link = parts.url
        }
        return Text(body)
    }
}
