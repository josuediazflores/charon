import CryptoKit
import Foundation

enum OverviewWidget: String, CaseIterable {
    case identity, date, pihole, nodes, stillness, commits, camera, blocking, artwork, status

    case weather, quakes, metric, progress, custom

    var configurable: Bool {
        switch self {
        case .weather, .quakes, .metric, .progress, .custom: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .identity: return "Identity"
        case .date: return "Date"
        case .pihole: return "Pi-hole"
        case .nodes: return "Nodes"
        case .stillness: return "Stillness"
        case .commits: return "Recent commits"
        case .camera: return "Dog camera"
        case .blocking: return "Blocking"
        case .artwork: return "Artwork"
        case .status: return "Status"
        case .weather: return "Weather forecast"
        case .quakes: return "Recent earthquakes"
        case .metric: return "Metric with sparkline"
        case .progress: return "Progress bar"
        case .custom: return "Custom widget"
        }
    }

    var defaultSpans: (span: Int, spanMd: Int) {
        switch self {
        case .identity, .date, .status: return (12, 12)
        case .pihole, .nodes: return (4, 6)
        case .stillness: return (4, 12)
        case .commits, .artwork: return (7, 12)
        case .camera, .blocking: return (5, 12)
        case .weather, .quakes, .custom: return (6, 12)
        case .metric, .progress: return (4, 6)
        }
    }

    var sizes: [OverviewSize] {
        OverviewSize.allCases.filter { size in
            if size == .standard { return true }
            // The identity readout and the four-column table need room for text.
            if size == .compact && (self == .identity || self == .commits) { return false }
            return size.spans(for: self) != defaultSpans
        }
    }
}

enum OverviewMetric: String, Codable, CaseIterable {
    case nodesConnected, blockRate, blockedToday, load1, temperature

    var title: String {
        switch self {
        case .nodesConnected: return "Connected nodes"
        case .blockRate: return "Pi-hole block rate"
        case .blockedToday: return "Requests blocked today"
        case .load1: return "Collector load (1 min)"
        case .temperature: return "Collector temperature"
        }
    }
}

enum OverviewProgressSource: String, Codable, CaseIterable {
    case manual, nodes, blockRate

    var title: String {
        switch self {
        case .manual: return "Manual goal"
        case .nodes: return "Connected nodes"
        case .blockRate: return "Pi-hole block rate"
        }
    }
}

struct OverviewWidgetConfig: Codable, Equatable, Hashable {
    var place = ""
    var latitude: Double?
    var longitude: Double?
    var celsius = false
    var radiusKm: Double = 150
    var minimumMagnitude: Double = 2
    var metric: OverviewMetric = .nodesConnected
    var progressSource: OverviewProgressSource = .manual
    var title = ""
    var current: Double = 0
    var target: Double = 100
    var unit = ""
    var custom: CustomWidgetSpec?

    func validationError(for widget: OverviewWidget) -> String? {
        if widget == .custom {
            guard let custom else { return "Choose a display and a data source." }
            return custom.validationError
        }
        if widget == .weather || widget == .quakes {
            guard !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let latitude, (-90...90).contains(latitude),
                  let longitude, (-180...180).contains(longitude) else {
                return "Choose a place with valid coordinates."
            }
        }
        if widget == .quakes {
            guard (1...2000).contains(radiusKm) else { return "Use a radius between 1 and 2,000 km." }
            guard (-2...10).contains(minimumMagnitude) else { return "Use a magnitude between -2 and 10." }
        }
        if widget == .progress && progressSource == .manual {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Name the goal." }
            guard current.isFinite, current >= 0 else { return "Enter a current value of zero or more." }
            guard target.isFinite, target > 0 else { return "Enter a target greater than zero." }
            guard ((current / target) * 100).isFinite else { return "Use a smaller value or a larger target." }
        }
        return nil
    }

    // Only the inputs used by this widget travel with its instance.
    fileprivate func options(for widget: OverviewWidget) -> [String: Any] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch widget {
        case .custom:
            guard let custom else { return [:] }
            return OverviewLayout.unpack(try? JSONEncoder().encode(custom))
        case .weather, .quakes:
            var fields: [String: Any] = ["place": place.trimmingCharacters(in: .whitespacesAndNewlines),
                                         "latitude": latitude as Any, "longitude": longitude as Any]
            if widget == .weather {
                fields["celsius"] = celsius
            } else {
                fields["radiusKm"] = radiusKm
                fields["minimumMagnitude"] = minimumMagnitude
            }
            return fields
        case .metric:
            return ["metric": metric.rawValue, "title": trimmedTitle]
        case .progress:
            var fields: [String: Any] = ["progressSource": progressSource.rawValue, "title": trimmedTitle]
            if progressSource == .manual {
                fields["current"] = current
                fields["target"] = target
                fields["unit"] = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return fields
        default: return [:]
        }
    }

    private static let defaultsDocument = try? JSONEncoder().encode(Self())

    fileprivate static func read(_ options: [String: Any], for widget: OverviewWidget) -> Self? {
        if widget == .custom {
            guard let data = OverviewLayout.pack(options),
                  let spec = try? JSONDecoder().decode(CustomWidgetSpec.self, from: data),
                  spec.validationError == nil else { return nil }
            return Self(custom: spec)
        }
        var fields = OverviewLayout.unpack(defaultsDocument)
        for key in Self().options(for: widget).keys {
            if let value = options[key] { fields[key] = value }
        }
        guard let data = OverviewLayout.pack(fields),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.validationError(for: widget) == nil else { return nil }
        return decoded
    }
}

enum OverviewSize: String, CaseIterable {
    case standard, compact, wide, full

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact"
        case .wide: return "Wide"
        case .full: return "Full width"
        }
    }

    fileprivate func spans(for widget: OverviewWidget?) -> (span: Int, spanMd: Int) {
        switch self {
        case .standard: return widget?.defaultSpans ?? (12, 12)
        case .compact: return (4, 6)
        case .wide: return (8, 12)
        case .full: return (12, 12)
        }
    }
}

struct OverviewLayout: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let widget: OverviewWidget?
        private(set) var configuration = OverviewWidgetConfig()
        fileprivate var storedSize: String
        fileprivate var extraFields: Data?

        var size: OverviewSize { OverviewSize(rawValue: storedSize) ?? .standard }
        var span: Int { size.spans(for: widget).span }
        var spanMd: Int { size.spans(for: widget).spanMd }

        fileprivate init(_ widget: OverviewWidget) {
            id = widget.configurable ? UUID().uuidString : widget.rawValue
            self.widget = widget
            storedSize = OverviewSize.standard.rawValue
            extraFields = nil
        }

        fileprivate init?(document: [String: Any]) {
            var fields = document
            guard let id = fields.removeValue(forKey: "id") as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.id = id
            let kind = fields.removeValue(forKey: "type") as? String ?? id
            storedSize = fields.removeValue(forKey: "size") as? String ?? OverviewSize.standard.rawValue
            if let known = OverviewWidget(rawValue: kind), known.configurable,
               let options = fields["options"] as? [String: Any],
               let config = OverviewWidgetConfig.read(options, for: known) {
                widget = known
                configuration = config
            } else if let known = OverviewWidget(rawValue: kind), !known.configurable, id == kind {
                widget = known
            } else {
                widget = nil
            }
            // Preserve complete unknown entries, including unsupported source types.
            extraFields = OverviewLayout.pack(widget == nil ? document : fields)
        }

        fileprivate mutating func configure(_ config: OverviewWidgetConfig) -> Bool {
            guard let widget, widget.configurable, config.validationError(for: widget) == nil else { return false }
            let options = config.options(for: widget)
            guard let normalized = OverviewWidgetConfig.read(options, for: widget) else { return false }
            var fields = OverviewLayout.unpack(extraFields)
            var merged = fields["options"] as? [String: Any] ?? [:]
            // Drop obsolete known options when switching between manual and collector progress.
            for key in configuration.options(for: widget).keys { merged.removeValue(forKey: key) }
            merged.merge(options) { _, replacement in replacement }
            fields["options"] = merged
            extraFields = OverviewLayout.pack(fields)
            configuration = normalized
            return true
        }

        fileprivate var document: [String: Any] {
            var fields = OverviewLayout.unpack(extraFields)
            guard let widget else { return fields }
            fields["id"] = id
            fields["type"] = widget.rawValue
            fields["size"] = storedSize
            return fields
        }
    }

    private(set) var entries: [Entry]
    fileprivate var version = 1
    fileprivate var extraFields: Data?

    static let standard = OverviewLayout(entries: OverviewWidget.allCases.filter { !$0.configurable }.map(Entry.init))

    var availableWidgets: [OverviewWidget] {
        OverviewWidget.allCases.filter { candidate in
            candidate.configurable || !entries.contains { $0.widget == candidate || $0.id == candidate.rawValue }
        }
    }

    mutating func add(_ widget: OverviewWidget) {
        guard !widget.configurable, availableWidgets.contains(widget) else { return }
        entries.append(Entry(widget))
    }

    @discardableResult
    mutating func add(_ widget: OverviewWidget, configuration: OverviewWidgetConfig) -> String? {
        var entry = Entry(widget)
        guard entry.configure(configuration) else { return nil }
        entries.append(entry)
        return entry.id
    }

    @discardableResult
    mutating func configure(_ id: String, configuration: OverviewWidgetConfig) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return entries[index].configure(configuration)
    }

    mutating func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// The index is the widget's final position, including when moving it forward.
    mutating func move(_ id: String, to index: Int) {
        guard let current = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: current)
        entries.insert(entry, at: min(max(0, index), entries.count))
    }

    mutating func resize(_ id: String, to size: OverviewSize) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let widget = entries[index].widget, widget.sizes.contains(size) else { return }
        entries[index].storedSize = size.rawValue
    }

    // Keep unrecognized widget options and document fields intact across an edit by this app.
    fileprivate static func pack(_ fields: [String: Any]) -> Data? {
        guard !fields.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
    }

    fileprivate static func unpack(_ data: Data?) -> [String: Any] {
        guard let data, let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return fields
    }

    fileprivate init(entries: [Entry], version: Int = 1, extraFields: Data? = nil) {
        self.entries = entries
        self.version = version
        self.extraFields = extraFields
    }
}

struct OverviewLayoutStore {
    let key: String
    let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    static func profileKey(isDemo: Bool, collectorURL: URL?) -> String {
        let prefix = "charon.overview.layout."
        if isDemo { return prefix + "demo" }
        guard let collectorURL,
              var parts = URLComponents(url: collectorURL, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty else { return prefix + "unconfigured" }
        parts.scheme = scheme
        parts.host = host
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        var path = parts.percentEncodedPath
        while path.last == "/" { path.removeLast() }
        parts.percentEncodedPath = path
        guard let canonical = parts.string else { return prefix + "unconfigured" }
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + "live." + hash
    }

    func load() -> OverviewLayout {
        var fields = OverviewLayout.unpack(defaults.data(forKey: key))
        guard let version = fields.removeValue(forKey: "version") as? Int, version > 0,
              let widgets = fields.removeValue(forKey: "widgets") as? [Any] else { return .standard }
        var ids = Set<String>()
        let entries = widgets.compactMap { item -> OverviewLayout.Entry? in
            guard let fields = item as? [String: Any], let entry = OverviewLayout.Entry(document: fields),
                  ids.insert(entry.id).inserted else { return nil }
            return entry
        }
        if !widgets.isEmpty && entries.isEmpty { return .standard }
        return OverviewLayout(entries: entries, version: version, extraFields: OverviewLayout.pack(fields))
    }

    func save(_ layout: OverviewLayout) {
        var fields = OverviewLayout.unpack(layout.extraFields)
        fields["version"] = layout.version
        fields["widgets"] = layout.entries.map(\.document)
        if let data = OverviewLayout.pack(fields) {
            defaults.set(data, forKey: key)
        }
    }
}
