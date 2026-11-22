import SwiftUI

struct OverviewFeedWidget: View {
    let kind: OverviewWidget
    let config: OverviewWidgetConfig
    let isDemo: Bool
    let allowNetwork: Bool

    private struct Identity: Hashable {
        let key: OverviewFeedKey
        let demo: Bool
        let demoLatitude: Double?
        let demoLongitude: Double?
    }

    var body: some View {
        if let latitude = config.latitude, let longitude = config.longitude {
            let key: OverviewFeedKey = kind == .weather ? .forecast(latitude: latitude, longitude: longitude) : .earthquakes
            FeedPanel(key: key, config: config, latitude: latitude, longitude: longitude, demo: isDemo, enabled: allowNetwork)
                .id(Identity(key: key, demo: isDemo, demoLatitude: isDemo ? latitude : nil,
                             demoLongitude: isDemo ? longitude : nil))
        } else {
            Panel(title: kind.title) {
                Text("Choose a place in widget setup.").font(HT.body).foregroundStyle(HT.inkMid)
            }
        }
    }
}

private struct FeedPanel: View {
    let key: OverviewFeedKey
    let config: OverviewWidgetConfig
    let latitude: Double
    let longitude: Double
    let demo: Bool
    let enabled: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var reading: OverviewFeedReading?
    @State private var error: String?
    @State private var loading = false
    @State private var refresh = 0
    @State private var handledRefresh = 0

    private struct Request: Hashable {
        let canRead: Bool
        let refresh: Int
    }

    private var title: String {
        switch key {
        case .forecast: return OverviewWidget.weather.title
        case .earthquakes: return OverviewWidget.quakes.title
        }
    }

    var body: some View {
        Panel(title: title) {
            VStack(alignment: .leading, spacing: HT.s2) {
                HStack {
                    Text(config.place).foregroundStyle(HT.inkBright)
                    Spacer()
                    if !demo, enabled {
                        HTButton(title: error == nil ? "Refresh" : "Retry", size: .sm, disabled: loading) { refresh += 1 }
                            .accessibilityLabel("Refresh \(title)")
                    }
                }

                if let reading {
                    switch reading.data {
                    case let .forecast(hours, zone):
                        forecast(hours, zone: zone)
                    case let .earthquakes(events):
                        earthquakes(events, asOf: reading.checkedAt)
                    }
                    if let issued = reading.issuedAt {
                        DotLeader(label: "source update", value: timestamp(issued))
                        if key == .earthquakes, !demo, reading.checkedAt.timeIntervalSince(issued) > 900 {
                            Text("The USGS feed was already more than 15 minutes old when checked.")
                                .foregroundStyle(HT.caution)
                        }
                    }
                }
                if !enabled, !demo, let reading, reading.expires <= Date() {
                    Text("Cached reading. It can refresh when you leave the editor.")
                        .foregroundStyle(HT.caution)
                }
                if let error {
                    Text((reading == nil ? "" : "Showing the last reading. ") + error)
                        .foregroundStyle(HT.caution)
                } else if loading {
                    Text("Fetching from \(key.source)…").foregroundStyle(HT.inkMid)
                } else if reading == nil {
                    Text(enabled ? "Waiting for the provider." : "Save the layout to load this feed.")
                        .foregroundStyle(HT.inkMid)
                }
                Rule()
                HStack {
                    Text(demo ? "Demo sample" : key.source)
                    Spacer()
                    if let checked = reading?.checkedAt, !demo {
                        Text("Checked \(timestamp(checked))")
                    }
                }
                .foregroundStyle(HT.inkMid)
            }
            .font(HT.body)
        }
        .task(id: Request(canRead: enabled && scenePhase == .active, refresh: refresh)) {
            if demo {
                reading = Self.sample(key, latitude: latitude, longitude: longitude)
                return
            }
            if reading == nil {
                let cached = await OverviewFeedProvider.shared.cached(key)
                guard !Task.isCancelled else { return }
                reading = cached
            }
            // The editor may show an existing cached reading; only the saved card can request another.
            guard enabled, scenePhase == .active else {
                loading = false
                return
            }
            let force = refresh != handledRefresh
            handledRefresh = refresh
            loading = true
            error = nil
            do {
                let next = try await OverviewFeedProvider.shared.read(key, force: force)
                guard !Task.isCancelled else { return }
                reading = next
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    @ViewBuilder
    private func forecast(_ hours: [OverviewForecastHour], zone: TimeZone) -> some View {
        if let first = hours.first {
            HStack(alignment: .center, spacing: HT.row) {
                Image(systemName: weatherSymbol(first.summary))
                    .font(.system(size: 26)).foregroundStyle(HT.signal)
                    .accessibilityHidden(true)
                Metric(label: first.summary, value: String(first.degrees(celsius: config.celsius)),
                       unit: config.celsius ? "°C" : "°F")
            }
            if !first.wind.isEmpty { DotLeader(label: "wind", value: first.wind) }
            if let humidity = first.humidity {
                DotLeader(label: "humidity", value: humidity.formatted(.number.precision(.fractionLength(0))) + "%")
            }
            Rule()
            HStack(spacing: HT.s2) {
                ForEach(hours) { hour in
                    VStack(alignment: .leading, spacing: HT.s1) {
                        Text(hour.start.formatted(Date.FormatStyle(timeZone: zone).hour()))
                            .foregroundStyle(HT.inkMid)
                        Text("\(hour.degrees(celsius: config.celsius))°")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Forecast hours in \(zone.abbreviation(for: first.start) ?? zone.identifier)")
                .foregroundStyle(HT.inkDim)
        }
    }

    private func weatherSymbol(_ summary: String) -> String {
        let text = summary.lowercased()
        if text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") { return "cloud.snow.fill" }
        if text.contains("rain") || text.contains("shower") { return "cloud.rain.fill" }
        if text.contains("partly") || text.contains("mostly sunny") { return "cloud.sun.fill" }
        if text.contains("cloud") { return "cloud.fill" }
        if text.contains("sun") { return "sun.max.fill" }
        return "thermometer.medium"
    }

    @ViewBuilder
    private func earthquakes(_ all: [OverviewQuake], asOf date: Date) -> some View {
        let visible = OverviewQuake.nearby(all, latitude: latitude, longitude: longitude, radius: config.radiusKm,
                                           magnitude: config.minimumMagnitude, asOf: date)
        let threshold = config.minimumMagnitude.formatted(.number.precision(.fractionLength(1)))
        let radius = config.radiusKm.formatted(.number.precision(.fractionLength(0...1)))
        Text("M\(threshold)+ · \(radius) km · past 24 hours").foregroundStyle(HT.inkMid)
        if visible.isEmpty {
            Text("No matching events in this reading.").foregroundStyle(HT.inkMid)
        } else {
            Text("Times in \(TimeZone.current.identifier)").foregroundStyle(HT.inkDim)
            Grid(alignment: .leading, horizontalSpacing: HT.s2, verticalSpacing: HT.s2) {
                ForEach(visible) { event in
                    GridRow {
                        Text("M" + event.magnitude.formatted(.number.precision(.fractionLength(1))))
                            .foregroundStyle(HT.signal)
                        Text(event.place).frame(maxWidth: .infinity, alignment: .leading)
                        Text(event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .foregroundStyle(HT.inkMid)
                    }
                }
            }
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func sample(_ key: OverviewFeedKey, latitude: Double, longitude: Double) -> OverviewFeedReading {
        // Regional names and times in demo mode are fixtures independent of all provider traffic.
        let date = Date(timeIntervalSince1970: 1_795_377_600)
        let data: OverviewFeedReading.DataSet
        switch key {
        case .forecast:
            let temps = [58.0, 59, 60, 61, 59]
            let hours = temps.enumerated().map { index, temperature in
                let start = date.addingTimeInterval(Double(index) * 3600)
                return OverviewForecastHour(start: start, end: start.addingTimeInterval(3600), fahrenheit: temperature,
                                            summary: "Partly cloudy", wind: "8 mph NW", humidity: 74)
            }
            data = .forecast(hours, TimeZone(identifier: "America/Los_Angeles") ?? .gmt)
        case .earthquakes:
            data = .earthquakes([3.1, 2.7, 2.2].enumerated().map { index, magnitude in
                OverviewQuake(id: "sample-\(index)", date: date.addingTimeInterval(-Double(index + 1) * 3600),
                              magnitude: magnitude, place: "Sample location \(index + 1)",
                              latitude: latitude, longitude: longitude)
            })
        }
        return OverviewFeedReading(data: data, checkedAt: date, issuedAt: date, expires: .distantFuture)
    }
}
