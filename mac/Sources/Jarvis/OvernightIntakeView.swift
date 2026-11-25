import SwiftUI

struct OvernightIntakeView: View {
    let store: ConsoleStore
    let back: () -> Void
    let processed: (OvernightRun) -> Void
    @SceneStorage private var draft: String
    @SceneStorage private var requestID: String
    @State private var sending = false
    @State private var error: String?
    @FocusState private var editing: Bool

    init(store: ConsoleStore, scope: String, back: @escaping () -> Void,
         processed: @escaping (OvernightRun) -> Void) {
        self.store = store
        self.back = back
        self.processed = processed
        _draft = SceneStorage(wrappedValue: "", "jarvis.overnight.\(scope).draft")
        _requestID = SceneStorage(wrappedValue: "", "jarvis.overnight.\(scope).processRequest")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: back) { Label("Overnight tasks", systemImage: "arrow.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(sending)
            HStack {
                Text("Brain Dump").font(FocusInk.heading(38))
                Spacer()
                Button("Process") { Task { await process() } }
                    .buttonStyle(.borderedProminent).tint(FocusInk.sand).foregroundStyle(.black)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || (store as? DemoStore)?.hasPreviewPlanner == false || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              draft.unicodeScalars.count > OvernightIntake.textLimit)
            }
            Divider()
            if let demo = store as? DemoStore {
                Text(demo.hasPreviewPlanner
                     ? "Process uses Codex on this Mac. Reviewed tasks stay in this demo."
                     : "Connect to your Pi in Live mode to process notes with Codex.").font(.callout).foregroundStyle(.secondary)
            }
            if sending {
                SeparatingTasks()
            } else {
                TextEditor(text: Binding(get: { draft }, set: { draft = $0; requestID = ""; error = nil }))
                    .font(.system(size: 17)).lineSpacing(6).scrollContentBackground(.hidden)
                    .accessibilityLabel("Brain Dump Markdown").focused($editing)
                    .task {
                        // Let the shell finish its navigation focus change before placing the caret.
                        try? await Task.sleep(for: .milliseconds(100))
                        if !Task.isCancelled { editing = true }
                    }
                if draft.unicodeScalars.count > OvernightIntake.textLimit {
                    Text("Use up to 12,000 characters.").foregroundStyle(.red)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(32).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    private func process() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        error = nil
        let key = UUID(uuidString: requestID) ?? UUID()
        requestID = key.uuidString
        do {
            let id = try await store.processBrainDump(requestID: key, text: draft)
            draft = ""
            requestID = ""
            processed(OvernightRun(id: id, title: "Brain Dump", status: "queued",
                                   createdAt: "", updatedAt: "", kind: "brain_dump"))
        } catch { self.error = error.localizedDescription }
    }
}

private struct SeparatingTasks: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
                Canvas { canvas, size in
                    let phase = timeline.date.timeIntervalSinceReferenceDate / 2.8
                    let spread = reduceMotion ? 1 : (1 - cos(phase * .pi * 2)) / 2
                    for row in 0..<3 {
                        let y = 22 + CGFloat(row) * (7 + 17 * spread)
                        let x = (size.width - 96) / 2
                        let box = CGRect(x: x, y: y - 6, width: 96, height: 17)
                        canvas.stroke(Path(roundedRect: box, cornerRadius: 4),
                                      with: .color(FocusInk.sand.opacity(spread * 0.7)), lineWidth: 1)
                        let line = CGRect(x: x + 9, y: y + 1, width: CGFloat(65 - row * 10), height: 2)
                        canvas.fill(Path(roundedRect: line, cornerRadius: 1), with: .color(FocusInk.sand))
                    }
                }
            }
            .frame(width: 130, height: 94).accessibilityHidden(true)
            Text("Separating tasks…").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReviewCard: Codable, Identifiable {
    var id = UUID()
    var task: ProposedTask
}

struct BrainDumpReview: View {
    let store: ConsoleStore
    let plan: OvernightRun
    let back: () -> Void
    let confirmed: (OvernightRun) -> Void
    @SceneStorage private var savedCards: Data?
    @SceneStorage private var start: Double
    @State private var cards: [ReviewCard] = []
    @State private var expanded: Set<UUID> = []
    @State private var loaded = false
    @State private var note = ""
    @State private var original = ""
    @State private var attempt = UUID()
    @State private var saving = false
    @State private var locked = false
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: ConsoleStore, scope: String, plan: OvernightRun, back: @escaping () -> Void,
         confirmed: @escaping (OvernightRun) -> Void) {
        self.store = store
        self.plan = plan
        self.back = back
        self.confirmed = confirmed
        let key = "jarvis.review.\(scope).\(plan.id)"
        _savedCards = SceneStorage("\(key).cards")
        _start = SceneStorage(wrappedValue: OvernightIntake.nextStart().timeIntervalSinceReferenceDate,
                              "\(key).start")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: back) { Label("Overnight tasks", systemImage: "arrow.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(saving)
            HStack {
                Text(loaded ? "Review tasks" : "Brain Dump").font(FocusInk.heading(38))
                Spacer()
                if loaded {
                    Button("Done") { Task { await finish() } }
                        .buttonStyle(.borderedProminent).tint(FocusInk.sand).foregroundStyle(.black)
                        .disabled(saving || cards.isEmpty || !cards.allSatisfy { $0.task.valid })
                }
            }
            Divider()
            if loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("Start tasks", selection: Binding(get: { Date(timeIntervalSinceReferenceDate: start) },
                            set: { start = $0.timeIntervalSinceReferenceDate }), displayedComponents: [.date, .hourAndMinute])
                        Text(TimeZone.autoupdatingCurrent.localizedName(for: .generic, locale: .current)
                             ?? TimeZone.autoupdatingCurrent.identifier).font(.caption).foregroundStyle(.secondary)
                        if locked { Text("Your schedule was saved. Click Done to finish queuing these tasks.") }
                        if !note.isEmpty { Text(note).textSelection(.enabled) }
                        ForEach($cards) { $card in
                            cardView($card)
                        }
                        if cards.isEmpty { Text("No tasks to queue.").foregroundStyle(.secondary) }
                        if !original.isEmpty {
                            DisclosureGroup("Original brain dump") {
                                Text(original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.top, 8)
                        }
                    }.padding(2).disabled(saving || locked)
                }
                .transition(.offset(y: reduceMotion ? 0 : 10).combined(with: .opacity))
            } else if error == nil {
                SeparatingTasks()
            } else { Spacer() }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if !loaded { Button("Reload") { attempt = UUID() } }
            }
        }
        .padding(32).frame(maxWidth: 760).frame(maxWidth: .infinity)
        .task(id: attempt) { await fetchProposal() }
    }

    private func cardView(_ binding: Binding<ReviewCard>) -> some View {
        let id = binding.wrappedValue.id
        let task = binding.task
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        if !expanded.insert(id).inserted { expanded.remove(id) }
                    }
                } label: {
                    HStack {
                        Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right").font(.caption)
                        Text(task.title.wrappedValue.isEmpty ? "Untitled task" : task.title.wrappedValue)
                            .font(.headline)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button {
                    cards.removeAll { $0.id == id }
                    persist()
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Delete \(task.title.wrappedValue)")
            }
            if expanded.contains(id) {
                Divider()
                field("Title", text: task.title)
                field("Goal", text: task.goal)
                field("Context", text: task.context)
                if !task.wrappedValue.valid {
                    Text("Enter a title of up to 80 characters and a goal. Goal and context allow 4,000 characters each.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).focusCard()
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; persist() }),
                      axis: .vertical).textFieldStyle(.plain).accessibilityLabel(label)
        }
    }

    private func persist() {
        savedCards = try? JSONEncoder().encode(cards)
    }

    private func fetchProposal() async {
        error = nil
        do {
            while !Task.isCancelled {
                guard let run = try await store.overnightRun(id: plan.id) else { throw MailError.http(404) }
                try Task.checkCancellation()
                if run.status == "done" { confirmed(run); return }
                if run.status == "review", let proposal = run.proposal {
                    note = run.planningNote ?? ""
                    original = run.request ?? ""
                    locked = run.confirmationStarted == true
                    if locked {
                        savedCards = nil
                        if let date = Fmt.date(run.runAt) { start = date.timeIntervalSinceReferenceDate }
                    }
                    cards = savedCards.flatMap { try? JSONDecoder().decode([ReviewCard].self, from: $0) }
                        ?? proposal.map { ReviewCard(task: $0) }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { loaded = true }
                    return
                }
                guard run.active else {
                    throw OvernightSubmissionError(message: run.error ?? "Jarvis could not prepare these tasks.")
                }
                try await Task.sleep(for: .seconds(1.5))
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func finish() async {
        guard !saving, !cards.isEmpty, cards.allSatisfy({ $0.task.valid }) else { return }
        saving = true
        defer { saving = false }
        error = nil
        do {
            try await store.confirmBrainDump(id: plan.id, tasks: cards.map(\.task),
                                             runAt: Date(timeIntervalSinceReferenceDate: start))
            var result = plan
            result.status = "done"
            savedCards = nil
            confirmed(result)
        } catch {
            self.error = error.localizedDescription
            if let latest = try? await store.overnightRun(id: plan.id) {
                if latest.status == "done" {
                    savedCards = nil
                    confirmed(latest)
                } else if latest.confirmationStarted == true {
                    attempt = UUID()
                }
            }
        }
    }
}
