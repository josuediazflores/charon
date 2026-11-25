import SwiftUI

struct OvernightIntakeView: View {
    let store: ConsoleStore
    let accepted: (OvernightRun) -> Void
    @Environment(\.dismiss) private var dismiss
    @SceneStorage private var draft: String
    @SceneStorage private var startTime: Double
    @SceneStorage private var requestID: String
    @State private var sending = false
    @State private var error: String?
    @FocusState private var editing: Bool

    init(store: ConsoleStore, scope: String, accepted: @escaping (OvernightRun) -> Void) {
        self.store = store
        self.accepted = accepted
        let key = "jarvis.overnight.\(scope)"
        _draft = SceneStorage(wrappedValue: "", "\(key).draft")
        _startTime = SceneStorage(wrappedValue: OvernightIntake.nextStart().timeIntervalSinceReferenceDate,
                                  "\(key).start")
        _requestID = SceneStorage(wrappedValue: "", "\(key).request")
    }

    private var runAt: Date { Date(timeIntervalSinceReferenceDate: startTime) }
    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { text.unicodeScalars.count > OvernightIntake.textLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set overnight tasks").font(FocusInk.heading(31)).foregroundStyle(FocusInk.text)
            Text("Write everything you want done. Jarvis will split it into tasks now and start the work on the Pi at the time you choose.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text("What would you like done?").font(.headline)
                TextEditor(text: Binding(get: { draft }, set: { draft = $0; edited() }))
                    .scrollContentBackground(.hidden).padding(8)
                    .frame(height: 132).background(FocusInk.composer, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(FocusInk.cardLine, lineWidth: 1) }
                    .focused($editing).accessibilityLabel("Task description")
                if tooLong { Text("Use up to 12,000 characters.").foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 6) {
                DatePicker("Start tasks", selection: Binding(get: { runAt }, set: {
                    startTime = $0.timeIntervalSinceReferenceDate
                    edited()
                }), displayedComponents: [.date, .hourAndMinute])
                Text(TimeZone.autoupdatingCurrent.localizedName(for: .generic, locale: .current)
                     ?? TimeZone.autoupdatingCurrent.identifier)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if sending { ProgressView().controlSize(.small).accessibilityLabel("Sending tasks") }
                    else { Text("Schedule tasks") }
                }
                .buttonStyle(.borderedProminent).tint(FocusInk.sand).foregroundStyle(.black)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.isEmpty || tooLong)
            }
        }
        .padding(26).frame(width: 472)
        .disabled(sending).interactiveDismissDisabled(sending)
        .onAppear {
            if startTime == 0 || (draft.isEmpty && runAt <= Date()) {
                startTime = OvernightIntake.nextStart().timeIntervalSinceReferenceDate
            }
            editing = true
        }
    }

    private func edited() {
        requestID = ""
        error = nil
    }

    private func submit() async {
        guard !sending, !text.isEmpty, !tooLong else { return }
        // Reuse the same request after an unknown network outcome, including if
        // the selected time passed while the collector's receipt was in transit.
        guard runAt > Date() || !requestID.isEmpty else {
            error = "Choose a start time in the future."
            return
        }
        let key = UUID(uuidString: requestID) ?? UUID()
        requestID = key.uuidString
        let time = runAt
        sending = true
        error = nil
        defer { sending = false }
        do {
            let id = try await store.submitOvernightTasks(requestID: key, text: text, runAt: time)
            draft = ""
            startTime = 0
            requestID = ""
            accepted(OvernightRun(id: id, title: "Plan overnight tasks", status: "queued",
                                  createdAt: "", updatedAt: "", kind: "intake",
                                  runAt: ISO8601DateFormatter().string(from: time)))
        } catch {
            self.error = "\(error.localizedDescription) You can retry this request."
        }
    }
}
