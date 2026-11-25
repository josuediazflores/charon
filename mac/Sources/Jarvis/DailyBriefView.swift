import SwiftUI
import UniformTypeIdentifiers

struct DailyBriefView: View {
    let store: ConsoleStore
    let today: Date
    @State private var selectedDay: Date?
    @State private var brief: DailyBrief?
    @State private var opened: [OvernightRun] = []
    @State private var revision = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var transcriptVisible = false
    @State private var exporting = false
    @State private var exportError: String?

    private var day: Date { selectedDay ?? today }
    private var dayKey: String { DailyBrief.dayKey(day) }
    private var currentBrief: DailyBrief? { brief?.date == dayKey ? brief : nil }

    var body: some View {
        Group {
            if let run = opened.last {
                RunReader(store: store, summary: run, legacy: false,
                          backTitle: opened.dropLast().last?.name ?? "Daily Brief",
                          openChild: { opened.append($0) }, back: { opened.removeLast() })
                    .id(run.id)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(spacing: 20) {
                            dayNavigation
                            if let failure {
                                Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Try again") { revision += 1 }
                            } else if let brief = currentBrief {
                                content(brief)
                            } else {
                                ProgressView().accessibilityLabel("Loading Daily Brief")
                            }
                        }
                        .frame(maxWidth: 620).padding(32).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(FocusInk.ground)
        .task(id: "\(dayKey)/\(revision)") { await load() }
        .fileExporter(isPresented: $exporting,
                      document: currentBrief.map { BriefMarkdown(text: $0.markdown) },
                      contentType: BriefMarkdown.type, defaultFilename: "Daily Brief \(dayKey).md") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn’t save the brief", isPresented: Binding(get: { exportError != nil },
                                                              set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkle").foregroundStyle(FocusInk.sand)
            Text("Jarvis").foregroundStyle(FocusInk.secondary)
            Text("/").foregroundStyle(FocusInk.line)
            Text("Daily Brief")
            Spacer()
            Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                .disabled(loading).accessibilityLabel("Refresh Daily Brief").help("Refresh Daily Brief")
            Menu {
                Button("Save Markdown…") { exporting = true }.disabled(currentBrief == nil)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).menuIndicator(.hidden).accessibilityLabel("Brief options")
        }
        .font(.callout).buttonStyle(.plain)
        .padding(.horizontal, 22).frame(height: 46)
    }

    private var dayNavigation: some View {
        HStack(spacing: 16) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Text(day, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.custom("Departure Mono", size: 11)).foregroundStyle(FocusInk.sand)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(dayKey >= DailyBrief.dayKey(today)).accessibilityLabel("Next day")
        }.buttonStyle(.plain).padding(.top, 8)
    }

    private func move(_ count: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: count, to: day) else { return }
        transcriptVisible = false
        failure = nil
        selectedDay = DailyBrief.dayKey(next) == DailyBrief.dayKey(today) ? nil : next
    }

    @ViewBuilder
    private func content(_ brief: DailyBrief) -> some View {
        Text(headline(brief)).font(FocusInk.heading(34)).multilineTextAlignment(.center)
            .foregroundStyle(FocusInk.text).accessibilityAddTraits(.isHeader)
        LiquidOrbView(activity: 0.12, ink: FocusInk.sand, label: "Jarvis")
            .accessibilityHidden(true)
        BriefPlaybackView(store: store, brief: brief)
            .id([brief.date, brief.spokenText])
        Button(transcriptVisible ? "Hide transcript" : "Transcript") { transcriptVisible.toggle() }
            .buttonStyle(.plain).foregroundStyle(FocusInk.secondary)
        if transcriptVisible {
            Text(brief.spokenText).font(.body).textSelection(.enabled).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16).focusCard()
        }
        if !brief.runs.isEmpty {
            VStack(spacing: 0) {
                ForEach(brief.runs) { run in
                    Divider()
                    Button { opened = [run] } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.name).font(.headline).foregroundStyle(FocusInk.text)
                                Text(run.outcome ?? run.statusLabel)
                                    .font(.callout).foregroundStyle(FocusInk.secondary)
                                    .multilineTextAlignment(.leading).lineLimit(4)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(FocusInk.secondary)
                        }.padding(.vertical, 15).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 12)
        }
    }

    private func headline(_ brief: DailyBrief) -> String {
        if brief.runs.isEmpty { return "No overnight updates." }
        if brief.runs.allSatisfy({ $0.status == "done" }) {
            return brief.runs.count == 1 ? "One report is ready." : "\(brief.runs.count) reports are ready."
        }
        return brief.runs.count == 1 ? "One overnight update." : "\(brief.runs.count) overnight updates."
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            let result = try await store.dailyBrief(for: day)
            try Task.checkCancellation()
            brief = result
        } catch {
            if Task.isCancelled { return }
            failure = error.localizedDescription
        }
        loading = false
    }
}

private struct BriefMarkdown: FileDocument {
    static let type = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [type] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
