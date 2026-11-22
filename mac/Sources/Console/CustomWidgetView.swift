import SwiftUI

/// The builder preview and saved dashboard share a single card face.
struct CustomWidgetPresentation: View {
    let spec: CustomWidgetSpec
    let value: CustomWidgetValue

    var body: some View {
        Panel(title: spec.title) {
            CustomWidgetReading(spec: spec, value: value)
        }
    }
}

struct CustomWidgetView: View {
    let spec: CustomWidgetSpec
    let isEditing: Bool
    let isDemo: Bool

    private struct EndpointIdentity: Hashable {
        let address: String
        let pointer: String
        let style: CustomWidgetStyle
        let isDemo: Bool
    }

    var body: some View {
        if let issue = spec.validationError {
            issuePanel(issue)
        } else if spec.source == .manual {
            switch Result(catching: spec.manualValue) {
            case .success(let value):
                CustomWidgetPresentation(spec: spec, value: value)
            case .failure(let error):
                issuePanel(error.localizedDescription)
            }
        } else {
            CustomEndpointCard(spec: spec, isEditing: isEditing, isDemo: isDemo)
                .id(EndpointIdentity(address: spec.endpoint, pointer: spec.pointer,
                                     style: spec.style, isDemo: isDemo))
        }
    }

    private func issuePanel(_ issue: String) -> some View {
        Panel(title: spec.title) {
            Text(issue).font(HT.body).foregroundStyle(HT.caution)
        }
    }
}

private struct CustomWidgetReading: View {
    let spec: CustomWidgetSpec
    let value: CustomWidgetValue
    @State private var expanded = false
    private let collapsedRows = 5

    @ViewBuilder var body: some View {
        switch (spec.style, value) {
        case (.number, .number(let number)):
            numberLabel(number)
        case (.progress, .number(let number)):
            VStack(alignment: .leading, spacing: HT.s1) {
                numberLabel(number)
                SegBar(value: fraction(number), max: 1, segments: 12,
                       readout: "of \(formattedTarget)", brackets: true, block: true)
            }
        case (.gauge, .number(let number)):
            HStack(spacing: HT.s3) {
                ZStack {
                    Circle().trim(from: 0, to: 0.75).stroke(HT.lineBright, lineWidth: 5)
                    Circle().trim(from: 0, to: CGFloat(0.75 * fraction(number)))
                        .stroke(HT.inkBright, lineWidth: 5)
                }
                .rotationEffect(.degrees(135))
                .frame(width: HT.row3, height: HT.row3)
                .padding(3)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HT.s1) {
                    numberLabel(number)
                    Text("Scale 0 to \(formattedTarget)").font(HT.body).foregroundStyle(HT.inkMid)
                }
            }
        case (.status, .status(let status)):
            Text(verbatim: status)
                .font(HT.lead).foregroundStyle(HT.inkBright).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, HT.s3)
                .overlay(alignment: .leading) {
                    Rectangle().fill(HT.inkMid).frame(width: 3).accessibilityHidden(true)
                }
        case (.trend, .trend(let samples)):
            if let last = samples.last {
                VStack(alignment: .leading, spacing: HT.s2) {
                    numberLabel(last)
                    CustomTrendPlot(samples: samples)
                    Text("\(samples.count) \(samples.count == 1 ? "sample" : "samples")")
                        .font(HT.body).foregroundStyle(HT.inkMid)
                }
            } else { empty("No samples") }
        case (.list, .list(let rows)):
            if rows.isEmpty { empty("No items") } else {
                collection(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
                        Text("•").foregroundStyle(HT.inkMid).accessibilityHidden(true)
                        Text(verbatim: row).foregroundStyle(HT.inkBright)
                    }
                }
            }
        case (.keyValue, .keyValue(let pairs)):
            if pairs.isEmpty { empty("No fields") } else {
                collection(pairs) { pair in
                    DotLeader(label: pair.key, value: pair.value)
                        .help("\(pair.key): \(pair.value)")
                }
            }
        default:
            empty("The selected field does not match this display.")
        }
    }

    private func numberLabel(_ value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HT.cw) {
            Text(verbatim: formatReading(value))
                .font(HT.metric).foregroundStyle(HT.inkBright)
                .lineLimit(1).minimumScaleFactor(0.6)
            if !spec.unit.isEmpty {
                Text(verbatim: spec.unit).font(HT.body).foregroundStyle(HT.inkMid)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func empty(_ message: String) -> some View {
        Text(message).font(HT.body).foregroundStyle(HT.inkMid)
    }

    private var formattedTarget: String {
        [formatReading(spec.target), spec.unit].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func fraction(_ number: Double) -> Double {
        guard spec.target.isFinite, spec.target > 0, number.isFinite, number > 0 else { return 0 }
        return number >= spec.target ? 1 : number / spec.target
    }

    private func collection<Element, Row: View>(_ items: [Element], @ViewBuilder row: @escaping (Element) -> Row) -> some View {
        VStack(alignment: .leading, spacing: HT.s1) {
            ForEach(0..<(expanded ? items.count : min(collapsedRows, items.count)), id: \.self) { index in
                row(items[index])
            }
            if items.count > collapsedRows {
                HTButton(title: expanded ? "Show fewer" : "Show all \(items.count)", size: .sm) {
                    expanded.toggle()
                }
            }
        }
        .font(HT.body)
    }
}

private func formatReading(_ number: Double) -> String {
    let magnitude = abs(number)
    let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6))
    if magnitude >= 1e9 || (magnitude > 0 && magnitude < 0.001) {
        return number.formatted(style.notation(.scientific))
    }
    return number.formatted(style)
}

private struct CustomTrendPlot: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard let low = samples.min(), let high = samples.max() else { return }
            let inset: CGFloat = 2
            let width = max(0, size.width - 2 * inset)
            let height = max(0, size.height - 2 * inset)
            let span = high - low
            var trace = Path()
            var last = CGPoint.zero
            for (index, value) in samples.enumerated() {
                let fraction: Double
                if high == low { fraction = 0.5 }
                else if span.isFinite { fraction = (value - low) / span }
                else { fraction = (value / 2 - low / 2) / (high / 2 - low / 2) }
                let x = samples.count == 1 ? width / 2 : width * CGFloat(index) / CGFloat(samples.count - 1)
                last = CGPoint(x: inset + x, y: inset + height * CGFloat(1 - fraction))
                if index == 0 { trace.move(to: last) } else { trace.addLine(to: last) }
            }
            context.stroke(trace, with: .color(HT.inkMid), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: last.x - inset, y: last.y - inset, width: 4, height: 4)),
                         with: .color(HT.inkBright))
        }
        .frame(height: HT.row2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(samples.map(formatReading).joined(separator: ", "))
    }
}

private struct CustomEndpointCard: View {
    let spec: CustomWidgetSpec
    let isEditing: Bool
    let isDemo: Bool

    @Environment(\.scenePhase) private var phase
    @State private var reading: CustomWidgetValue?
    @State private var checkedAt: Date?
    @State private var failure: String?
    @State private var loading = false
    @State private var refresh = 0
    @State private var handledRefresh = 0

    private struct Request: Hashable {
        let active: Bool
        let refresh: Int
    }

    var body: some View {
        Panel(title: spec.title, footer: AnyView(controls)) {
            VStack(alignment: .leading, spacing: HT.s2) {
                if let reading {
                    CustomWidgetReading(spec: spec, value: reading)
                }
                if let failure {
                    Text((reading == nil ? "" : "Showing the last reading. ") + failure)
                        .foregroundStyle(HT.caution)
                } else if loading {
                    Text("Loading source…").foregroundStyle(HT.inkMid)
                } else if reading == nil {
                    Text(emptyPrompt).foregroundStyle(HT.inkMid)
                }
            }
            .font(HT.body)
        }
        .task(id: Request(active: !isEditing && phase == .active, refresh: refresh)) {
            guard !isEditing, phase == .active else {
                loading = false
                return
            }
            let requested = refresh != handledRefresh
            guard requested || (!isDemo && reading == nil && failure == nil) else {
                loading = false
                return
            }
            handledRefresh = refresh
            loading = true
            failure = nil
            do {
                let document = try await CustomWidgetEndpoint.fetch(spec.endpoint)
                try Task.checkCancellation()
                let next = try document.value(at: spec.pointer, for: spec.style)
                try Task.checkCancellation()
                reading = next
                checkedAt = Date()
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private var emptyPrompt: String {
        if isEditing { return "Save the layout to load this source." }
        if isDemo { return "Choose Refresh to load your source in Demo." }
        return "Waiting for source."
    }

    private var controls: some View {
        HStack(spacing: HT.cw) {
            if let checkedAt {
                Text("Checked \(checkedAt, format: .dateTime.month().day().hour().minute())")
            } else {
                Text("JSON source")
            }
            Spacer(minLength: 0)
            if !isEditing {
                HTButton(title: failure == nil ? "Refresh" : "Retry", size: .sm, disabled: loading) {
                    refresh += 1
                }
                .accessibilityLabel("Refresh \(spec.title)")
            }
        }
    }
}
