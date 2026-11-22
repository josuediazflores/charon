import AppKit
import SwiftUI

/// Owns a draft until Add or Apply. Only Test URL makes a network request.
struct CustomWidgetSetup: View {
    private enum Step: String, CaseIterable {
        case style = "Display", data = "Data source", preview = "Preview"
    }

    let isDemo: Bool
    let cancel: () -> Void
    let apply: (CustomWidgetSpec) -> Void
    private let editing: Bool
    @State private var step: Step
    @State private var spec: CustomWidgetSpec
    @State private var targetText: String
    @State private var snapshotMode = false
    @State private var pastedJSON = ""
    @State private var copiedRequest: String?
    @State private var fields: [CustomWidgetField] = []
    // nil means no selection. The empty string selects the JSON root.
    @State private var selectedPointer: String?
    @State private var testTask: Task<Void, Never>?
    @State private var testError: String?

    init(initial: CustomWidgetSpec?, isDemo: Bool = false,
         cancel: @escaping () -> Void, apply: @escaping (CustomWidgetSpec) -> Void) {
        self.isDemo = isDemo
        self.cancel = cancel
        self.apply = apply
        editing = initial != nil
        var draft = initial ?? CustomWidgetSpec()
        if initial == nil {
            draft.title = draft.style.title
            draft.manualInput = ""
        }
        _step = State(initialValue: initial == nil ? .style : .data)
        _spec = State(initialValue: draft)
        let target = String(draft.target)
        _targetText = State(initialValue: target.hasSuffix(".0") ? String(target.dropLast(2)) : target)
        _selectedPointer = State(initialValue: initial?.source == .endpoint ? initial?.pointer : nil)
    }

    private var result: CustomWidgetSpec {
        var value = spec
        if showsTarget {
            let separator = Locale.current.decimalSeparator ?? "."
            let text = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            value.target = Double(text.replacingOccurrences(of: separator, with: ".")) ?? .nan
        }
        if snapshotMode {
            value.manualInput = selectedField?.value.manualInput ?? ""
        } else if spec.source == .endpoint {
            value.pointer = selectedPointer ?? ""
        }
        return value
    }

    private var selectedField: CustomWidgetField? {
        fields.first { $0.pointer == selectedPointer }
    }

    private var sourceValue: CustomWidgetValue? {
        if snapshotMode { return selectedField?.value }
        switch spec.source {
        case .manual: return try? spec.manualValue()
        case .endpoint: return selectedField?.value
        }
    }

    private var showsTarget: Bool { spec.style == .progress || spec.style == .gauge }
    private var showsUnit: Bool { showsTarget || spec.style == .number || spec.style == .trend }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.s3) {
            Text(editing ? "EDIT CUSTOM WIDGET" : "CUSTOM WIDGET")
                .font(HT.lead).foregroundStyle(HT.inkBright)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: HT.s3) {
                ForEach(Step.allCases, id: \.self) { item in
                    if item != .style { Text("/").foregroundStyle(HT.inkDim) }
                    Text(item.rawValue)
                        .foregroundStyle(item == step ? HT.signal : HT.inkMid)
                        .accessibilityAddTraits(item == step ? .isSelected : [])
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: HT.s3) {
                    switch step {
                    case .style: gallery
                    case .data: dataEditor
                    case .preview: preview
                    }
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if step != .style {
                    HTButton(title: "Back", action: goBack)
                        .accessibilityIdentifier("custom.setup.back")
                }
                if step == .data {
                    HTButton(title: copiedRequest == setupRequest ? "Request copied" : "Copy setup request",
                             variant: .ghost) {
                        let request = setupRequest
                        let board = NSPasteboard.general
                        board.clearContents()
                        if board.setString(WidgetSetupGuide.appending(to: request), forType: .string) {
                            copiedRequest = request
                        }
                    }
                    .help("Copy a setup question and the widget guide. Includes only the display, source type and profile.")
                    .accessibilityIdentifier("custom.setup.copy")
                }
                Spacer()
                HTButton(title: "Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("custom.setup.cancel")
                if step == .preview {
                    HTButton(title: editing ? "Apply" : "Add widget", variant: .primary,
                             disabled: sourceValue == nil || result.validationError != nil) {
                        apply(result)
                    }
                    .accessibilityIdentifier("custom.setup.apply")
                } else {
                    HTButton(title: step == .style ? "Choose data source" : "Preview",
                             variant: .primary, disabled: step == .data && sourceValue == nil) {
                        step = step == .style ? .data : .preview
                    }
                    .accessibilityIdentifier("custom.setup.next")
                }
            }
        }
        .onDisappear { testTask?.cancel() }
        .font(HT.body)
        .foregroundStyle(HT.ink)
        .padding(HT.s5)
        .frame(width: 630, height: 465)
        .background(HT.void)
        .preferredColorScheme(.dark)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: HT.s3) {
            Text("Choose how to display your data.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HT.s2), count: 3),
                      spacing: HT.s2) {
                ForEach(CustomWidgetStyle.allCases, id: \.self) { style in
                    Button { chooseStyle(style) } label: {
                        VStack(alignment: .leading, spacing: HT.s1) {
                            WidgetStyleSample(style: style)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 28)
                                .accessibilityHidden(true)
                            Text(style.title)
                                .foregroundStyle(style == spec.style ? HT.signal : HT.inkBright)
                        }
                        .padding(.horizontal, HT.s3).padding(.vertical, HT.s2)
                        .background(HT.surface2)
                        .overlay(Rectangle().strokeBorder(style == spec.style ? HT.signal : HT.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(style.title))
                    .accessibilityAddTraits(style == spec.style ? .isSelected : [])
                    .accessibilityIdentifier("custom.setup.type." + style.rawValue)
                }
            }
        }
    }

    private func chooseStyle(_ style: CustomWidgetStyle) {
        guard style != spec.style else { return }
        if spec.title == spec.style.title { spec.title = style.title }
        spec.style = style
        clearTest()
    }

    @ViewBuilder private var dataEditor: some View {
        Text("Where does the data come from?")
        HStack(spacing: HT.s2) {
            sourceButton(.manual, title: "Enter values")
            sourceButton(.endpoint, title: "Connect a JSON URL")
            HTButton(title: "Paste JSON", variant: snapshotMode ? .primary : .secondary) {
                guard !snapshotMode else { return }
                clearTest()
                snapshotMode = true
                spec.source = .manual
            }
            .accessibilityAddTraits(snapshotMode ? .isSelected : [])
            .accessibilityIdentifier("custom.setup.source.paste")
        }
        if snapshotMode {
            snapshotEditor
        } else if spec.source == .manual {
            manualEditor
        } else {
            endpointEditor
        }
    }

    private func sourceButton(_ source: CustomWidgetSource, title: String) -> some View {
        let selected = !snapshotMode && spec.source == source
        return HTButton(title: title, variant: selected ? .primary : .secondary) {
            guard !selected else { return }
            clearTest()
            snapshotMode = false
            spec.source = source
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("custom.setup.source." + source.rawValue)
    }

    private var setupRequest: String {
        let method = snapshotMode ? "Paste JSON" : (spec.source == .manual ? "Enter values" : "Connect a JSON URL")
        let profile = isDemo ? "Demo" : "Live"
        return "Help me set up a Charon custom widget on my Mac. I selected \(spec.style.title), \(method), and the \(profile) profile. Ask what I want to track and help me choose a compatible field or enter the values. Use examples with invented data. I will enter my own data on my Mac and review the preview before saving."
    }

    @ViewBuilder private var manualEditor: some View {
        let input = manualPrompt
        Text(input.label).foregroundStyle(HT.inkBright)
        if spec.style == .list || spec.style == .keyValue || spec.style == .trend {
            Text(input.example).foregroundStyle(HT.inkMid)
            TextEditor(text: $spec.manualInput)
                .font(HT.body)
                .frame(height: 95)
                .overlay(Rectangle().strokeBorder(HT.line).allowsHitTesting(false))
                .accessibilityLabel(Text(input.label))
                .accessibilityIdentifier("custom.setup.manual")
        } else {
            TextField(input.label, text: $spec.manualInput, prompt: Text(input.example))
                .accessibilityIdentifier("custom.setup.manual")
        }
        if !spec.manualInput.isEmpty, let message = manualError { notice(message) }
    }

    private var manualPrompt: (label: String, example: String) {
        switch spec.style {
        case .number, .gauge, .progress: return ("Current value", "72")
        case .status: return ("Status", "Online")
        case .trend: return ("Readings, oldest first", "Separate numbers with commas or new lines, e.g. 12, 18, 16, 23.")
        case .list: return ("List items", "Enter one item per line.")
        case .keyValue: return ("Labels and values", "Enter one pair per line, e.g. Storage = 72 GB.")
        }
    }

    private var manualError: String? {
        do {
            _ = try spec.manualValue()
            return nil
        } catch { return error.localizedDescription }
    }

    @ViewBuilder private var endpointEditor: some View {
        Text("JSON URL").foregroundStyle(HT.inkBright)
        HStack {
            TextField("JSON URL", text: Binding(get: { spec.endpoint }, set: { address in
                guard spec.endpoint != address else { return }
                clearTest()
                spec.endpoint = address
            }), prompt: Text("https://example.com/readings.json"))
            .accessibilityIdentifier("custom.setup.url")
            HTButton(title: testTask == nil ? "Test URL" : "Testing…",
                     disabled: testTask != nil || spec.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     action: testURL)
                .accessibilityIdentifier("custom.setup.test")
        }
        Text("Use a keyless HTTPS URL or a local HTTP URL. " + (isDemo
             ? "Test URL makes one request. Click Refresh on the saved demo card to read it again."
             : "Test URL reads the source on this Mac. Charon saves the address to refresh your widget."))
            .foregroundStyle(HT.inkMid)
            .fixedSize(horizontal: false, vertical: true)
        fieldChoice
    }

    @ViewBuilder private var snapshotEditor: some View {
        Text("Paste a JSON response. The widget saves a copy of the field you choose.")
            .foregroundStyle(HT.inkMid)
        TextEditor(text: Binding(get: { pastedJSON }, set: { text in
            clearTest()
            pastedJSON = text
        }))
        .font(HT.body)
        .frame(height: 62)
        .overlay(Rectangle().strokeBorder(HT.line).allowsHitTesting(false))
        .accessibilityLabel("JSON response")
        .accessibilityIdentifier("custom.setup.json")
        HTButton(title: "Find fields", disabled: pastedJSON.isEmpty) {
            clearTest()
            do {
                let document = try CustomWidgetDocument(data: Data(pastedJSON.utf8))
                showFields(document, for: spec.style, restoring: nil)
            } catch { testError = error.localizedDescription }
        }
        .accessibilityIdentifier("custom.setup.parse")
        fieldChoice
    }

    @ViewBuilder private var fieldChoice: some View {
        if let testError { notice(testError) }
        if !fields.isEmpty {
            Picker("Data field", selection: $selectedPointer) {
                Text("Choose a field…").tag(Optional<String>.none)
                ForEach(fields, id: \.pointer) { field in
                    Text(field.label).tag(Optional(field.pointer))
                }
            }
            .accessibilityIdentifier("custom.setup.field")
            if let value = sourceValue {
                Text(value.manualInput).lineLimit(3).foregroundStyle(HT.inkMid)
                    .accessibilityLabel("Selected value")
                    .accessibilityValue(Text(value.manualInput))
            }
        }
    }

    private func clearTest() {
        testTask?.cancel()
        testTask = nil
        fields = []
        testError = nil
        selectedPointer = nil
    }

    private func testURL() {
        let oldSelection = selectedPointer
        clearTest()
        let address = spec.endpoint
        let style = spec.style
        testTask = Task { @MainActor in
            do {
                let document = try await CustomWidgetEndpoint.fetch(address)
                guard !Task.isCancelled else { return }
                showFields(document, for: style, restoring: oldSelection)
            } catch {
                guard !Task.isCancelled else { return }
                testError = error.localizedDescription
            }
            testTask = nil
        }
    }

    private func showFields(_ document: CustomWidgetDocument, for style: CustomWidgetStyle, restoring pointer: String?) {
        fields = document.fields(for: style)
        if let pointer, fields.contains(where: { $0.pointer == pointer }) {
            selectedPointer = pointer
        }
        if fields.isEmpty {
            let expected: String
            switch style {
            case .number, .progress, .gauge: expected = "a number such as 72"
            case .status: expected = "short text or a true/false value"
            case .trend: expected = "an array of 2 to 256 numbers"
            case .list: expected = "an array of up to 64 text, number or true/false values"
            case .keyValue: expected = "an object with up to 64 labels and simple values"
            }
            testError = "\(style.title) needs \(expected). Choose another display or data source."
        }
    }

    @ViewBuilder private var preview: some View {
        field("Widget title", hint: spec.style.title, text: $spec.title, id: "title")
        if showsUnit {
            HStack(alignment: .top, spacing: HT.s3) {
                if showsTarget { field("Target", hint: "100", text: $targetText, id: "target") }
                field("Unit (optional)", hint: "GB", text: $spec.unit, id: "unit")
            }
        }
        if let problem = result.validationError {
            notice(problem)
        } else if let value = sourceValue {
            CustomWidgetPresentation(spec: result, value: value)
                .accessibilityIdentifier("custom.setup.preview")
        }
    }

    private func field(_ label: String, hint: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: HT.s1) {
            Text(label)
            TextField(label, text: text, prompt: Text(hint))
                .accessibilityIdentifier("custom.setup." + id)
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message).foregroundStyle(HT.caution)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("custom.setup.notice")
    }

    private func goBack() {
        testTask?.cancel()
        testTask = nil
        step = step == .preview ? .data : .style
    }
}

enum WidgetSetupGuide {
    static func appending(to request: String) -> String {
        guard let url = Bundle.main.url(forResource: "AGENTS", withExtension: "md", subdirectory: "WidgetHelp"),
              let guide = try? String(contentsOf: url, encoding: .utf8) else { return request }
        return request + "\n\n" + guide
    }
}

/// Fixed miniature examples make the layout recognizable before connecting data.
private struct WidgetStyleSample: View {
    let style: CustomWidgetStyle

    @ViewBuilder var body: some View {
        switch style {
        case .number:
            Text("64.8").font(HT.lead).foregroundStyle(HT.inkBright)
        case .progress:
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { index in
                    Rectangle().fill(index < 8 ? HT.nominal : HT.line).frame(width: 5, height: 9)
                }
            }
        case .gauge:
            ZStack {
                Circle().trim(from: 0.5, to: 1).stroke(HT.line, lineWidth: 3)
                Circle().trim(from: 0.5, to: 0.84).stroke(HT.nominal, lineWidth: 3)
            }
            .frame(width: 44, height: 44).offset(y: 10)
        case .status:
            HStack(spacing: HT.s2) {
                Rectangle().fill(HT.nominal).frame(width: 7, height: 7)
                Text("Online")
            }
        case .trend:
            Path { path in
                let samples = [16, 12, 15, 7, 11, 4, 9, 3]
                for (index, y) in samples.enumerated() {
                    let point = CGPoint(x: index * 9, y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(HT.nominal, lineWidth: 2)
            .frame(width: 65, height: 20)
        case .list:
            VStack(alignment: .leading, spacing: 2) {
                ForEach([38, 55, 47], id: \.self) { width in
                    HStack(spacing: HT.s1) {
                        Rectangle().fill(HT.nominal).frame(width: 3, height: 3)
                        Rectangle().fill(HT.inkMid).frame(width: CGFloat(width), height: 3)
                    }
                }
            }
        case .keyValue:
            VStack(spacing: 0) {
                HStack { Text("CPU"); Spacer(); Text("18%") }
                HStack { Text("RAM"); Spacer(); Text("42%") }
            }
            .frame(width: 88)
        }
    }
}
