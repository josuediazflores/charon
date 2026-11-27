import AVFoundation
import Speech
import SwiftUI

/// Holds one utterance outside the editor until it can be appended to the current draft.
/// Users can keep typing while Apple's partial transcription is being revised.
@MainActor
@Observable
final class JarvisDictation {
    enum Phase { case idle, authorizing, recording, finishing }

    private(set) var phase: Phase = .idle
    private(set) var partial = ""
    private(set) var issue: String?
    var active: Bool { phase != .idle }

    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var insert: ((String) -> Void)?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var inputChange: NSObjectProtocol?

    func start(insert: @escaping (String) -> Void) {
        guard !active else { return }
        let id = UUID()
        session = id
        self.insert = insert
        partial = ""
        issue = nil
        phase = .authorizing
        Task { await authorizeAndStart(id) }
    }

    private func authorizeAndStart(_ id: UUID) async {
        guard session == id else { return }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.supportsOnDeviceRecognition else {
            complete(message: "On-device dictation is unavailable for your Mac’s current language.")
            return
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard session == id else { return }
        guard mic else {
            complete(message: "Allow Charon in System Settings › Privacy & Security › Microphone to dictate.")
            return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard session == id else { return }
        guard speech == .authorized else {
            complete(message: "Allow Charon in System Settings › Privacy & Security › Speech Recognition to dictate.")
            return
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            complete(message: "On-device speech recognition is unavailable right now.")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            complete(message: "Select a microphone in System Settings › Sound › Input, then try again.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.engine = engine
        self.recognizer = recognizer
        self.request = request
        Self.installTap(input, format, request)
        inputChange = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == id else { return }
                self.complete(message: "Your audio input changed. Start dictation again to continue.")
            }
        }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.session == id else { return }
                if let text, !text.isEmpty { self.partial = text }
                if final {
                    self.complete(message: self.partial.isEmpty ? "No speech was recognized. Try again." : nil)
                } else if failed {
                    let message = self.phase == .finishing && !self.partial.isEmpty
                        ? nil : "Dictation ended. Check your microphone and try again."
                    self.complete(message: message)
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            phase = .recording
        } catch {
            complete(message: "Couldn’t start the microphone. Check your sound input and try again.")
        }
    }

    // AVAudioEngine calls its tap on the audio thread, not the UI actor.
    nonisolated private static func installTap(_ input: AVAudioInputNode, _ format: AVAudioFormat,
                                               _ request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    func finish() {
        guard phase == .recording, let id = session else { return }
        phase = .finishing
        closeInput()
        request?.endAudio()
        // Some audio devices never deliver a final callback after their tap stops.
        deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, session == id else { return }
            complete(message: partial.isEmpty ? "No speech was recognized. Try again." : nil)
        }
    }

    /// Discard only the in-progress utterance. The editor's existing text is untouched.
    func discard() { complete(keepPartial: false) }

    /// Preserve the words already visible if the user navigates away.
    func leave() { complete() }

    private func closeInput() {
        if let inputChange {
            NotificationCenter.default.removeObserver(inputChange)
            self.inputChange = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
    }

    private func complete(keepPartial: Bool = true, message: String? = nil) {
        guard session != nil else { return }
        session = nil
        deadline?.cancel()
        deadline = nil
        closeInput()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let write = insert
        insert = nil
        partial = ""
        phase = .idle
        issue = message
        if keepPartial && !text.isEmpty { write?(text) }
    }

    nonisolated static func appending(_ text: String, to draft: String) -> String {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return draft }
        let separator = draft.last.map { $0.isWhitespace ? "" : " " } ?? ""
        return draft + separator + phrase
    }
}

struct JarvisDictationButton: View {
    let dictation: JarvisDictation
    let start: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch dictation.phase {
            case .idle:
                Button(action: start) { Label("Dictate", systemImage: "mic") }
                    .help("Dictate on this Mac")
            case .recording:
                Button(action: dictation.finish) { Label("Stop dictation", systemImage: "stop.fill") }
                discardButton
            case .authorizing, .finishing:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(dictation.phase == .authorizing ? "Preparing microphone" : "Finishing dictation")
                discardButton
            }
        }
        .buttonStyle(.plain)
    }

    private var discardButton: some View {
        Button(action: dictation.discard) { Image(systemName: "xmark") }
            .accessibilityLabel("Discard dictation").help("Discard this utterance")
    }
}

struct JarvisDictationFeedback: View {
    let dictation: JarvisDictation

    var body: some View {
        if let issue = dictation.issue {
            Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        } else if dictation.phase == .recording || dictation.phase == .finishing {
            Text(dictation.partial.isEmpty ? "Listening…" : dictation.partial)
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                .accessibilityLabel("Dictation preview")
                .accessibilityValue(dictation.partial)
        }
    }
}
