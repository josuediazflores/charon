import SwiftUI

struct OvernightIntakeView: View {
    let store: ConsoleStore
    let back: () -> Void
    let processed: (OvernightRun) -> Void
    @SceneStorage private var draft: String
    @SceneStorage private var requestID: String
    @State private var sending = false
    @State private var dictation = JarvisDictation()
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
                JarvisDictationButton(dictation: dictation) {
                    dictation.start { phrase in
                        draft = JarvisDictation.appending(phrase, to: draft)
                        requestID = ""
                        error = nil
                    }
                }.disabled(sending)
                Button("Process") { Task { await process() } }
                    .buttonStyle(.borderedProminent).tint(FocusInk.sand).foregroundStyle(.black)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(dictation.active || sending || (store as? DemoStore)?.hasPreviewPlanner == false || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
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
                JarvisDictationFeedback(dictation: dictation)
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
        .onDisappear { dictation.leave() }
    }

    private func process() async {
        guard !sending, !dictation.active else { return }
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

private struct OvernightStartPicker: View {
    @Binding var selection: Date
    @State private var editing = false
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var dateLabel: String {
        var format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if !calendar.isDate(selection, equalTo: .now, toGranularity: .year) {
            format = format.year()
        }
        format.timeZone = timeZone
        return selection.formatted(format)
    }

    private var timeLabel: String {
        var format = Date.FormatStyle.dateTime.hour().minute()
        format.timeZone = timeZone
        return selection.formatted(format)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                caption
                Spacer(minLength: 8)
                scheduleButton
            }
            VStack(alignment: .leading, spacing: 8) {
                caption
                scheduleButton
            }
        }
        .padding(.bottom, 6)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Start tasks").font(.headline)
            Text(timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier)
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var scheduleButton: some View {
        Button { editing = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "calendar").foregroundStyle(FocusInk.sand)
                Text(dateLabel)
                Rectangle().fill(FocusInk.cardLine).frame(width: 1, height: 14)
                Text(timeLabel).monospacedDigit()
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 34)
            .focusCard().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change start date and time")
        .accessibilityValue(selection.formatted(date: .complete, time: .shortened))
        .help("Change start date and time")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            StartTimeEditor(initial: selection) { date in
                selection = date
                editing = false
            }
        }
    }
}


private struct StartTimeEditor: View {
    let initial: Date
    let apply: (Date) -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var day: Date
    @State private var month: Date
    @State private var clockText = ""
    @FocusState private var typing: Bool
    @FocusState private var focusedDay: Date?

    init(initial: Date, apply: @escaping (Date) -> Void) {
        self.initial = initial
        self.apply = apply
        _day = State(initialValue: initial)
        _month = State(initialValue: initial)
    }

    private var clockFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        return formatter
    }

    private var chosenStart: Date? {
        let value = clockText.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = clockFormatter
        let parsed: Date?
        if let date = formatter.date(from: value) {
            parsed = date
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "H:mm"
            parsed = formatter.date(from: value)
        }
        guard let parsed else { return nil }
        let hour = calendar.component(.hour, from: parsed)
        let minute = calendar.component(.minute, from: parsed)
        guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              calendar.isDate(date, inSameDayAs: day),
              calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute else { return nil }
        // Preserve the originally selected occurrence during a repeated DST hour.
        if calendar.isDate(initial, inSameDayAs: date),
           calendar.component(.hour, from: initial) == hour,
           calendar.component(.minute, from: initial) == minute { return initial }
        return date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(month, format: .dateTime.month(.wide).year()).font(FocusInk.heading(24))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                arrow(-1)
                arrow(1)
            }
            monthGrid
            Divider()
            HStack(spacing: 10) {
                Text("Start time").font(.headline)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "clock").foregroundStyle(FocusInk.secondary)
                    TextField("Time", text: $clockText).font(.body.monospacedDigit())
                        .textFieldStyle(.plain).focused($typing)
                        .accessibilityLabel("Start time")
                        .onSubmit { if let date = chosenStart, date > .now { apply(date) } }
                }
                .padding(.horizontal, 10).frame(width: 106, height: 30)
                .background(FocusInk.composer, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(typing ? FocusInk.sand : FocusInk.line) }
            }
            HStack(spacing: 6) {
                preset("Midnight", hour: 0)
                preset("1 AM", hour: 1)
                Spacer()
                Button("Set start") { if let date = chosenStart { apply(date) } }
                    .buttonStyle(.borderedProminent).tint(FocusInk.sand).foregroundStyle(.black)
                    .disabled(chosenStart.map { $0 <= .now } ?? true)
            }
            if chosenStart == nil && !clockText.isEmpty {
                Text("Enter a valid time, such as 01:30.").font(.caption).foregroundStyle(.secondary)
            } else if let date = chosenStart, date <= .now {
                Text("Choose a future start.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 320)
        .background(FocusInk.card)
        .onAppear { clockText = clockFormatter.string(from: initial) }
    }

    private func arrow(_ offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
        } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.caption.weight(.semibold)).frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(offset < 0 && calendar.compare(month, to: .now, toGranularity: .month) != .orderedDescending)
        .accessibilityLabel(offset < 0 ? "Previous month" : "Next month")
    }

    private var monthGrid: some View {
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let padding = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 31
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(0..<7) { index in
                Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                    .font(.caption2.weight(.medium)).foregroundStyle(FocusInk.secondary)
                    .frame(height: 22).accessibilityHidden(true)
            }
            ForEach(0..<(padding + count), id: \.self) { index in
                if index < padding {
                    Color.clear.frame(height: 30).accessibilityHidden(true)
                } else if let date = calendar.date(byAdding: .day, value: index - padding, to: first) {
                    dateButton(date)
                }
            }
        }
    }

    private func dateButton(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: day)
        let past = date < calendar.startOfDay(for: .now)
        return Button { day = date } label: {
            Text(date, format: .dateTime.day()).font(.body.monospacedDigit().weight(selected ? .bold : .regular))
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundStyle(selected ? FocusInk.ground : past ? FocusInk.secondary : FocusInk.text)
                .background(selected ? FocusInk.sand : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(past)
        .focused($focusedDay, equals: date)
        .onMoveCommand { direction in
            let offset: Int
            switch direction {
            case .left: offset = -1
            case .right: offset = 1
            case .up: offset = -7
            case .down: offset = 7
            default: return
            }
            if let next = calendar.date(byAdding: .day, value: offset, to: date),
               next >= calendar.startOfDay(for: .now) {
                day = next
                month = next
                focusedDay = next
            }
        }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func preset(_ title: LocalizedStringKey, hour: Int) -> some View {
        let active = chosenStart.map {
            calendar.component(.hour, from: $0) == hour && calendar.component(.minute, from: $0) == 0
        } ?? false
        return Button {
            // Format a wall-clock shortcut independently of the selected day's DST transition.
            if let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0)) {
                clockText = clockFormatter.string(from: time)
                typing = false
            }
        } label: {
            Text(title).font(.caption.weight(.medium))
                .padding(.horizontal, 9).frame(height: 25)
                .foregroundStyle(active ? FocusInk.sand : FocusInk.text)
                .overlay { Capsule().strokeBorder(active ? FocusInk.sand : FocusInk.line) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
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
                        OvernightStartPicker(selection: Binding(
                            get: { Date(timeIntervalSinceReferenceDate: start) },
                            set: { start = $0.timeIntervalSinceReferenceDate }
                        ))
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
