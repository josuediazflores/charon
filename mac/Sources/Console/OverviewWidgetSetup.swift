import AppKit
import MapKit
import SwiftUI

struct OverviewWidgetSetup: View {
    let kind: OverviewWidget
    let isDemo: Bool
    let cancel: () -> Void
    let apply: (OverviewWidgetConfig) -> Void
    private let existing: Bool

    @State private var config: OverviewWidgetConfig
    @State private var latitude: String
    @State private var longitude: String
    @State private var radius: String
    @State private var magnitude: String
    @State private var current: String
    @State private var target: String
    @State private var copied = false

    init(kind: OverviewWidget, isDemo: Bool, initial: OverviewWidgetConfig?,
         cancel: @escaping () -> Void, apply: @escaping (OverviewWidgetConfig) -> Void) {
        self.kind = kind
        self.isDemo = isDemo
        self.existing = initial != nil
        self.cancel = cancel
        self.apply = apply
        var start = initial ?? OverviewWidgetConfig()
        if isDemo && initial == nil && (kind == .weather || kind == .quakes) {
            start.place = "Monterey, CA"
            start.latitude = 36.60
            start.longitude = -121.89
        }
        _config = State(initialValue: start)
        _latitude = State(initialValue: start.latitude.map(Self.format) ?? "")
        _longitude = State(initialValue: start.longitude.map(Self.format) ?? "")
        _radius = State(initialValue: Self.format(start.radiusKm))
        _magnitude = State(initialValue: Self.format(start.minimumMagnitude))
        _current = State(initialValue: Self.format(start.current))
        _target = State(initialValue: Self.format(start.target))
    }

    // Keep invalid or half-typed inputs visible until corrected. Numeric TextField
    // bindings can silently keep the last valid number when the user clears one.
    private static func format(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func number(_ text: String) -> Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: "."))
    }

    private var candidate: OverviewWidgetConfig {
        var result = config
        switch kind {
        case .weather, .quakes:
            result.latitude = Self.number(latitude)
            result.longitude = Self.number(longitude)
            if kind == .quakes {
                result.radiusKm = Self.number(radius) ?? .nan
                result.minimumMagnitude = Self.number(magnitude) ?? .nan
            }
        case .progress where config.progressSource == .manual:
            result.current = Self.number(current) ?? .nan
            result.target = Self.number(target) ?? .nan
        default: break
        }
        return result
    }

    var body: some View {
        let problem = candidate.validationError(for: kind)
        VStack(alignment: .leading, spacing: HT.row) {
            Text(kind.title.uppercased()).font(HT.lead).foregroundStyle(HT.inkBright)
            ScrollView {
                VStack(alignment: .leading, spacing: HT.s3) {
                    note(sourceDescription)
                    fields
                    if let problem { note(problem).foregroundStyle(HT.caution) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                HTButton(title: copied ? "Request copied" : "Copy setup request", variant: .ghost) {
                    let board = NSPasteboard.general
                    board.clearContents()
                    copied = board.setString(agentRequest, forType: .string)
                }
                .help("Copy a question to paste into an agent. Includes the supported choices for this widget.")
                .accessibilityIdentifier("overview.setup.copy")
                Spacer()
                HTButton(title: "Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("overview.setup.cancel")
                HTButton(title: existing ? "Apply" : "Add", variant: .primary, disabled: problem != nil) {
                    apply(candidate)
                }
                .accessibilityIdentifier("overview.setup.apply")
            }
        }
        .font(HT.body)
        .foregroundStyle(HT.ink)
        .padding(HT.s5)
        .frame(width: 485, height: 445)
        .background(HT.void)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .weather, .quakes:
            if isDemo {
                LabeledContent("Sample location", value: config.place)
                    .accessibilityIdentifier("overview.setup.samplePlace")
            } else {
                OverviewPlaceField(place: $config.place, latitude: $latitude, longitude: $longitude)
            }
            if kind == .weather {
                Picker("Temperature", selection: $config.celsius) {
                    Text("Fahrenheit (°F)").tag(false)
                    Text("Celsius (°C)").tag(true)
                }
                .accessibilityIdentifier("overview.setup.temperature")
            } else {
                field("Radius (km)", hint: "150", text: $radius, id: "radius")
                field("Minimum magnitude", hint: "2", text: $magnitude, id: "magnitude")
            }
        case .metric:
            Picker("Reading", selection: $config.metric) {
                ForEach(OverviewMetric.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("overview.setup.metric")
            field("Display name (optional)", hint: config.metric.title,
                  text: $config.title, id: "title")
        case .progress:
            Picker("Measure", selection: $config.progressSource) {
                ForEach(OverviewProgressSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("overview.setup.source")
            field(config.progressSource == .manual ? "Goal name" : "Display name (optional)",
                  hint: config.progressSource == .manual ? "Archive backup" : config.progressSource.title,
                  text: $config.title, id: "title")
            if config.progressSource == .manual {
                HStack {
                    field("Current", hint: "72", text: $current, id: "current")
                    field("Target", hint: "100", text: $target, id: "target")
                }
                field("Unit (optional)", hint: "GB", text: $config.unit, id: "unit")
            }
        default: EmptyView()
        }
    }

    private func field(_ label: String, hint: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: HT.s1) {
            Text(label)
            TextField(label, text: text, prompt: Text(hint))
                .accessibilityIdentifier("overview.setup." + id)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private var sourceDescription: String {
        switch kind {
        case .weather:
            return isDemo ? "Demo uses a sample hourly forecast." :
                "Choose a U.S. town. After you save, Charon requests its hourly forecast from the National Weather Service using the chosen coordinates."
        case .quakes:
            return isDemo ? "Demo filters a sample catalog of recorded earthquakes." :
                "Choose the center of your search. Charon filters the past day of USGS earthquake reports on this Mac."
        case .metric:
            return isDemo ? "Choose a sample collector reading to chart." :
                "Choose a reading from your connected collector. The chart grows as fresh readings arrive."
        case .progress:
            if config.progressSource == .manual { return "Give your goal a name and target. Once saved, update its current value directly on the card." }
            return isDemo ? "Demo uses sample collector readings." : "The collector supplies both the current value and its scale."
        default: return ""
        }
    }

    private var agentRequest: String {
        let choices: String
        switch kind {
        case .weather: choices = "It uses NWS hourly forecasts for U.S. towns. I can find a town or enter coordinates, and choose Celsius or Fahrenheit."
        case .quakes: choices = "It uses the USGS past-day earthquake catalog. I can find a place or enter coordinates, then set a radius in km and a minimum magnitude."
        case .metric: choices = "I can give the reading an optional display name. Available collector readings include " + OverviewMetric.allCases.map(\.title).joined(separator: ", ") + "."
        case .progress: choices = "Available sources include " + OverviewProgressSource.allCases.map(\.title).joined(separator: ", ") + ". A manual goal takes a name, current value, target and optional unit."
        default: choices = ""
        }
        let profile = isDemo ? "demo" : "live"
        let request = "Help me set up the \(kind.title) widget in Charon on my Mac. I am using the \(profile) profile. \(choices) Ask what I want to track, then suggest the values and steps in Overview > Edit Overview > Add Widget. I will review the result and save the layout. Use only non-secret setup information."
        return WidgetSetupGuide.appending(to: request)
    }
}

private struct OverviewPlaceField: View {
    @Binding var place: String
    @Binding var latitude: String
    @Binding var longitude: String

    @State private var manual = false
    @State private var search: MKLocalSearch?
    @State private var choices: [MKMapItem] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HT.s2) {
            Picker("Location", selection: $manual) {
                Text("Find a place").tag(false)
                Text("Enter coordinates").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("overview.setup.locationMode")
            if manual {
                TextField("Place name", text: $place)
                    .accessibilityIdentifier("overview.setup.place")
                HStack {
                    coordinateField("Latitude", prompt: "36.60", text: $latitude, id: "latitude")
                    coordinateField("Longitude", prompt: "-121.89", text: $longitude, id: "longitude")
                }
            } else {
                HStack {
                    TextField("City, state or region", text: Binding(get: { place }, set: {
                        resetSearch()
                        place = $0
                        latitude = ""
                        longitude = ""
                    }))
                    .onSubmit(find)
                    .accessibilityIdentifier("overview.setup.place")
                    HTButton(title: search == nil ? "Find" : "Searching", disabled: !canFind, action: find)
                        .accessibilityIdentifier("overview.setup.find")
                }
                if !choices.isEmpty {
                    Text("Choose a result").foregroundStyle(HT.inkMid)
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        HTButton(title: Self.name(choice), block: true) { select(choice) }
                            .accessibilityIdentifier("overview.setup.placeResult.\(index)")
                    }
                } else if let message {
                    Text(message).foregroundStyle(HT.caution)
                } else if !latitude.isEmpty && !longitude.isEmpty {
                    Text("Coordinates  \(latitude), \(longitude)").foregroundStyle(HT.inkMid)
                } else {
                    Text("Find searches Apple Maps for the place you enter.").foregroundStyle(HT.inkMid)
                }
            }
        }
        .onChange(of: manual) { _, _ in resetSearch() }
        .onDisappear { resetSearch() }
    }

    private func coordinateField(_ name: String, prompt: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: HT.s1) {
            Text(name)
            TextField(name, text: text, prompt: Text(prompt))
                .accessibilityIdentifier("overview.setup." + id)
        }
    }

    private var canFind: Bool {
        search == nil && !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetSearch() {
        search?.cancel()
        search = nil
        choices = []
        message = nil
    }

    private func find() {
        guard canFind else { return }
        resetSearch()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        request.resultTypes = .address
        let lookup = MKLocalSearch(request: request)
        search = lookup
        Task { @MainActor in
            do {
                let response = try await lookup.start()
                guard search === lookup else { return }
                choices = Array(response.mapItems.prefix(5))
                if choices.isEmpty { message = "No matching places. Add the state or enter coordinates." }
            } catch {
                guard search === lookup else { return }
                message = "Place search could not finish. Try again or enter coordinates."
            }
            search = nil
        }
    }

    private static func name(_ item: MKMapItem) -> String {
        if #available(macOS 26.0, *) { return item.address?.fullAddress ?? item.name ?? "Place" }
        return item.placemark.title ?? item.name ?? "Place"
    }

    private func select(_ item: MKMapItem) {
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26.0, *) { coordinate = item.location.coordinate }
        else { coordinate = item.placemark.coordinate }
        place = Self.name(item)
        latitude = String(coordinate.latitude)
        longitude = String(coordinate.longitude)
        resetSearch()
    }
}
