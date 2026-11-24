import AppKit
import QuickLook
import SwiftUI

struct OvernightTasksView: View {
    let model: MailModel

    var body: some View {
        OvernightRunList(store: model.store)
            .id(ObjectIdentifier(model.store))
    }
}

private struct PageRequest: Equatable {
    var before: String?
    let revision = UUID()
}

private struct OvernightRunList: View {
    let store: ConsoleStore
    @State private var runs: [OvernightRun] = []
    @State private var selected: OvernightRun?
    @State private var cursor: String?
    @State private var query = PageRequest()
    @State private var loading = true
    @State private var legacy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let selected {
                RunReader(store: store, summary: selected, legacy: legacy) { self.selected = nil }
                    .id(selected.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Overnight tasks").font(FocusInk.heading(38)).foregroundStyle(FocusInk.text)
                            Spacer()
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
                        ForEach(runs) { run in
                            Button { selected = run } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(run.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(FocusInk.text)
                                    Text([run.statusLabel, dateLabel(run.updatedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .focusCard().contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
}

private func dateLabel(_ raw: String) -> String {
    Fmt.date(raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
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

private struct RunReader: View {
    let store: ConsoleStore
    let summary: OvernightRun
    let legacy: Bool
    let back: () -> Void
    @State private var report: OvernightRun?
    @State private var error: String?
    @State private var request = UUID()
    @State private var attachments: [RunFileLocation] = []

    var body: some View {
        if let report, let current = attachments.last {
            RunFileReader(store: store, run: report, location: current,
                          follow: { attachments.append($0) },
                          back: { attachments.removeLast() })
                .id(current)
        } else {
            RunColumn { scroll in
                Button(action: back) { Label("Overnight tasks", systemImage: "arrow.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Text(summary.name).font(FocusInk.heading(38)).foregroundStyle(FocusInk.text)
                if let report {
                    Text([report.statusLabel, dateLabel(report.updatedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    if let message = report.error, !message.isEmpty { Text(message).textSelection(.enabled) }
                    if let markdown = report.markdown, !markdown.isEmpty {
                        RunMarkdown(markdown: markdown, run: report, scroll: scroll, follow: { attachments.append($0) })
                    } else {
                        Text("This run has no saved report yet.").foregroundStyle(.secondary)
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
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { request = UUID() }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: request) {
                // On returning from a linked file, keep the report and its manifest together.
                if report != nil { return }
                error = nil
                do {
                    let value: OvernightRun?
                    if summary.fromJobList { value = summary }
                    else { value = try await store.overnightRun(id: summary.id) }
                    try Task.checkCancellation()
                    guard let value else { error = "This run is no longer available on the Pi."; return }
                    report = value
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
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
