import SwiftUI

// The same telemetry document drives Hardware and these cards. Moving or adding
// a widget never starts a second collector request.
extension OverviewMetric {
    func envelope(in payload: TelemetryPayload?) -> (any SourceEnvelopeShape)? {
        switch self {
        case .nodesConnected, .load1, .temperature: return payload?.nodes
        case .blockRate, .blockedToday: return payload?.pihole
        }
    }

    func value(in payload: TelemetryPayload?) -> Double? {
        let number: Double?
        switch self {
        case .nodesConnected: number = payload?.nodes?.data.map { Double($0.connected) }
        case .blockedToday: number = payload?.pihole?.data?.blockedToday.map(Double.init)
        case .blockRate: number = payload?.pihole?.data?.blockRatePct
        case .temperature, .load1:
            let node = payload?.nodes?.data?.nodes.first { $0.probe == "self" && $0.connected }
            number = self == .load1 ? node?.load1 : node?.tempC
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    var unitLabel: String? {
        switch self {
        case .blockRate: return "%"
        case .temperature: return "°C"
        default: return nil
        }
    }
}

struct OverviewMetricHistory {
    struct Sample: Equatable {
        let time: Date
        let value: Double
    }

    private var readings: [OverviewMetric: [Sample]] = [:]

    mutating func observe(_ payload: TelemetryPayload?, feedDown: Bool) {
        for metric in OverviewMetric.allCases {
            guard let env = metric.envelope(in: payload),
                  !HealthRule.health(env, feedDown: feedDown).hideDelta,
                  let value = metric.value(in: payload), let time = Fmt.date(env.fetchedAt) else {
                readings[metric] = nil
                continue
            }
            if let last = readings[metric]?.last, time <= last.time { continue }
            var samples = readings[metric] ?? []
            samples.append(Sample(time: time, value: value))
            if samples.count > 32 { samples.removeFirst() }
            readings[metric] = samples
        }
    }

    func points(for metric: OverviewMetric) -> [Int] {
        let values = (readings[metric] ?? []).map(\.value)
        guard let low = values.min(), let high = values.max(), high > low else {
            return Array(repeating: 0, count: values.count)
        }
        // Normalize first so fractional load and temperature readings keep their shape.
        let scale = max(abs(low), abs(high))
        let floor = low / scale
        let range = high / scale - floor
        guard range > 0 else { return Array(repeating: 0, count: values.count) }
        return values.map { Int((($0 / scale - floor) / range * 1000).rounded()) }
    }
}

struct OverviewTelemetryMetric: View {
    let config: OverviewWidgetConfig
    let payload: TelemetryPayload?
    let feedDown: Bool
    let history: OverviewMetricHistory

    var body: some View {
        let source = config.metric
        let points = history.points(for: source)
        SourcePanel(env: source.envelope(in: payload), feedDown: feedDown,
                    title: config.title.isEmpty ? source.title : config.title) { health in
            if let value = source.value(in: payload) {
                Metric(label: source.title, value: value.formatted(.number.precision(.fractionLength(0...2))),
                       unit: source.unitLabel, dim: health.dim)
                if !health.hideDelta {
                    if points.count > 1 {
                        Sparkline(data: points, tone: .signal, cap: true, label: "Last \(points.count) readings")
                        Text("Last \(points.count) readings").font(HT.body).foregroundStyle(HT.inkMid)
                    } else {
                        Text("Waiting for a second reading.").font(HT.body).foregroundStyle(HT.inkMid)
                    }
                }
            } else {
                Text("Waiting for \(source.title.lowercased()) from the collector.")
                    .font(HT.body).foregroundStyle(HT.inkMid)
            }
        }
    }
}

struct OverviewProgressWidget: View {
    let config: OverviewWidgetConfig
    let payload: TelemetryPayload?
    let feedDown: Bool

    let isEditing: Bool
    let updateManualValue: (Double) -> Void

    @State private var updateOpen = false
    @State private var newValue = ""

    private var editedNumber: Double? {
        guard let value = try? Double(newValue, format: .number, lenient: false), value.isFinite else { return nil }
        var updated = config
        updated.current = value
        return updated.validationError(for: .progress) == nil ? value : nil
    }

    var body: some View {
        let title = config.title.isEmpty ? config.progressSource.title : config.title
        switch config.progressSource {
        case .manual:
            Panel(title: title) {
                bar(label: "Manual goal", current: config.current, target: config.target, unit: config.unit)
                if !isEditing {
                    HTButton(title: "Update", size: .sm) {
                        newValue = config.current.formatted(.number.grouping(.never).precision(.significantDigits(1...15)))
                        updateOpen = true
                    }
                    .accessibilityLabel("Update " + title)
                    .accessibilityIdentifier("overview.progress.update")
                    .popover(isPresented: $updateOpen) {
                        VStack(alignment: .leading, spacing: HT.s2) {
                            Text(title).font(HT.body).foregroundStyle(HT.inkBright)
                            TextField(config.unit.isEmpty ? "Current value" : "Current value (\(config.unit))",
                                      text: $newValue)
                                .accessibilityIdentifier("overview.progress.value")
                            HStack {
                                HTButton(title: "Cancel") { updateOpen = false }
                                HTButton(title: "Save", variant: .primary, disabled: editedNumber == nil) {
                                    guard let value = editedNumber else { return }
                                    updateManualValue(value)
                                    updateOpen = false
                                }
                                .accessibilityIdentifier("overview.progress.save")
                            }
                        }
                        .padding(HT.row).frame(minWidth: 240)
                    }
                }
            }
        case .nodes:
            SourcePanel(env: payload?.nodes, feedDown: feedDown, title: title) { health in
                bar(label: "Connected nodes", current: payload?.nodes?.data.map { Double($0.connected) },
                    target: payload?.nodes?.data.map { Double($0.total) }, unit: "nodes", dim: health.dim)
            }
        case .blockRate:
            SourcePanel(env: payload?.pihole, feedDown: feedDown, title: title) { health in
                bar(label: "Blocked queries today", current: payload?.pihole?.data?.blockedToday.map(Double.init),
                    target: payload?.pihole?.data?.queriesToday.map(Double.init), unit: "queries", dim: health.dim)
            }
        }
    }

    @ViewBuilder
    private func bar(label: String, current: Double?, target: Double?, unit: String, dim: Bool = false) -> some View {
        if let current, let target, current.isFinite, target.isFinite, target > 0,
           (current / target * 100).isFinite {
            let pct = (current / target).formatted(.percent.precision(.fractionLength(0...1)))
            VStack(alignment: .leading, spacing: HT.s2) {
                let fmt = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
                Metric(label: label, value: pct, dim: dim)
                SegBar(value: current, max: target, segments: 16, tone: dim ? .standby : .signal,
                       showReadout: false, brackets: true)
                Text([current.formatted(fmt) + " / " + target.formatted(fmt), unit]
                    .filter { !$0.isEmpty }.joined(separator: " ")).font(HT.body).foregroundStyle(HT.inkMid)
            }
        } else {
            Text("\(label) unavailable. A current value and a positive total are needed.")
                .font(HT.body).foregroundStyle(HT.inkMid)
        }
    }
}
