import Foundation

/// One public request per location for NWS, one worldwide feed for all USGS cards.
enum OverviewFeedKey: Hashable {
    case forecast(latitude: Double, longitude: Double)
    case earthquakes

    var source: String {
        switch self {
        case .forecast: return "National Weather Service"
        case .earthquakes: return "USGS"
        }
    }
}

struct OverviewForecastHour: Identifiable {
    let start: Date
    let end: Date
    let fahrenheit: Double
    let summary: String
    let wind: String
    let humidity: Double?
    var id: Date { start }
    func degrees(celsius: Bool) -> Int {
        Int((celsius ? (fahrenheit - 32) * 5 / 9 : fahrenheit).rounded())
    }
}

struct OverviewQuake: Identifiable {
    let id: String
    let date: Date
    let magnitude: Double
    let place: String
    let latitude: Double
    let longitude: Double

    func distanceKm(from latitude: Double, longitude: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (self.latitude - latitude) * radians
        let dLon = (self.longitude - longitude) * radians
        let a = pow(sin(dLat / 2), 2) + cos(latitude * radians) * cos(self.latitude * radians) * pow(sin(dLon / 2), 2)
        return 12_742 * asin(sqrt(min(1, max(0, a))))
    }

    static func nearby(_ events: [Self], latitude: Double, longitude: Double, radius: Double,
                       magnitude: Double, asOf now: Date) -> [Self] {
        let start = now.addingTimeInterval(-86_400)
        return Array(events.lazy.filter {
            $0.date >= start && $0.date <= now && $0.magnitude >= magnitude
                && $0.distanceKm(from: latitude, longitude: longitude) <= radius
        }.sorted { $0.date > $1.date }.prefix(5))
    }
}

struct OverviewFeedReading {
    enum DataSet {
        case forecast([OverviewForecastHour], TimeZone)
        case earthquakes([OverviewQuake])
    }

    let data: DataSet
    let checkedAt: Date
    let issuedAt: Date?
    let expires: Date
}

struct OverviewFeedFailure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

actor OverviewFeedProvider {
    static let shared = OverviewFeedProvider()
    private let session: URLSession
    private var cache: [OverviewFeedKey: OverviewFeedReading] = [:]
    private typealias Fetched = (reading: OverviewFeedReading, canStore: Bool)
    private var pending: [OverviewFeedKey: Task<Fetched, Error>] = [:]

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func cached(_ key: OverviewFeedKey) -> OverviewFeedReading? { cache[key] }

    func read(_ key: OverviewFeedKey, force: Bool = false, now: Date = Date()) async throws -> OverviewFeedReading {
        if let task = pending[key] { return try await task.value.reading }
        if !force, let previous = cache[key], now < previous.expires { return previous }

        let task = Task { try await Self.fetch(key, using: session, now: now, force: force) }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        let result = try await task.value
        // A no-store response is available to its current callers only. It also
        // invalidates an older cache entry so a later failure cannot revive it.
        cache[key] = result.canStore ? result.reading : nil
        if cache.count > 64, let oldest = cache.keys.filter({ $0 != key }).min(by: {
            (cache[$0]?.checkedAt ?? .distantPast) < (cache[$1]?.checkedAt ?? .distantPast)
        }) { cache.removeValue(forKey: oldest) }
        return result.reading
    }

    private struct Point: Decodable {
        struct Properties: Decodable { let forecastHourly: URL?; let timeZone: String? }
        let properties: Properties
    }
    private struct Forecast: Decodable {
        struct Quantity: Decodable { let value: Double? }
        struct Hour: Decodable {
            let startTime, endTime: String
            let temperature: Double?
            let temperatureUnit, shortForecast, windSpeed, windDirection: String?
            let relativeHumidity: Quantity?
        }
        struct Properties: Decodable {
            let updateTime: String?
            let periods: [Hour]
        }
        let properties: Properties
    }
    private struct Earthquakes: Decodable {
        struct Metadata: Decodable { let generated: Double? }
        struct Feature: Decodable {
            struct Properties: Decodable {
                let mag, time, updated: Double?
                let place, type: String?
            }
            struct Geometry: Decodable { let coordinates: [Double]? }
            let id: String?
            let properties: Properties
            let geometry: Geometry?
        }
        let metadata: Metadata?
        let features: [Feature]
    }

    private static func request<T: Decodable>(_ type: T.Type, url: URL, source: String,
                                               session: URLSession, force: Bool) async throws -> (T, TimeInterval?, Bool) {
        var req = URLRequest(url: url, cachePolicy: force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: 15)
        req.setValue("Charon-Overview/1.0 (https://github.com/josuediazflores/charon)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OverviewFeedFailure("\(source) did not send an HTTP response.") }
        switch http.statusCode {
        case 200..<300: break
        case 404 where source == "National Weather Service":
            throw OverviewFeedFailure("An hourly forecast is unavailable here. Choose a location within US National Weather Service coverage.")
        case 429: throw OverviewFeedFailure("\(source) is receiving too many requests. Try again later.")
        default: throw OverviewFeedFailure("\(source) returned HTTP \(http.statusCode).")
        }
        let content: T
        do { content = try JSONDecoder().decode(T.self, from: data) }
        catch { throw OverviewFeedFailure("\(source) returned an unreadable feed.") }
        let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if directives.contains("no-store") { return (content, 0, false) }
        if directives.contains("no-cache") { return (content, 0, true) }
        let age = Double(http.value(forHTTPHeaderField: "Age") ?? "") ?? 0
        let maxAge = directives.first(where: { $0.hasPrefix("max-age=") }).flatMap { Double($0.dropFirst(8)) }
        return (content, maxAge.map { max(0, $0 - age) }, true)
    }

    private static func fetch(_ key: OverviewFeedKey, using session: URLSession, now: Date, force: Bool) async throws -> Fetched {
        switch key {
        case let .forecast(latitude, longitude):
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw OverviewFeedFailure("Choose a valid forecast location.")
            }
            let coords = String(format: "%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
            let pointURL = URL(string: "https://api.weather.gov/points/\(coords)")!
            let (point, pointAge, storePoint) = try await request(Point.self, url: pointURL, source: key.source, session: session, force: force)
            guard let hourly = point.properties.forecastHourly, hourly.scheme == "https", hourly.host == "api.weather.gov",
                  hourly.port == nil, hourly.user == nil, hourly.password == nil else {
                throw OverviewFeedFailure("No NWS hourly forecast is available here. Choose a nearby town on land.")
            }
            let (forecast, ttl, storeForecast) = try await request(Forecast.self, url: hourly, source: key.source, session: session, force: force)
            let iso = ISO8601DateFormatter()
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func date(_ string: String) -> Date? { iso.date(from: string) ?? precise.date(from: string) }
            let hours = forecast.properties.periods.compactMap { row -> OverviewForecastHour? in
                guard let start = date(row.startTime), let end = date(row.endTime), end > start, end > now,
                      let temperature = row.temperature, (-200...300).contains(temperature),
                      let unit = row.temperatureUnit, ["C", "F"].contains(unit) else { return nil }
                return OverviewForecastHour(start: start, end: end, fahrenheit: unit == "C" ? temperature * 9 / 5 + 32 : temperature,
                                            summary: row.shortForecast ?? "Forecast", wind: [row.windSpeed, row.windDirection].compactMap { $0 }.joined(separator: " "),
                                            humidity: row.relativeHumidity?.value)
            }.sorted { $0.start < $1.start }
            guard let first = hours.first else { throw OverviewFeedFailure("NWS supplied no current hourly forecast periods for this location.") }
            let expiry = min(first.end, now.addingTimeInterval(min(900, pointAge ?? 900, ttl ?? 900)))
            let reading = OverviewFeedReading(data: .forecast(Array(hours.prefix(5)), point.properties.timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt),
                                              checkedAt: now, issuedAt: forecast.properties.updateTime.flatMap(date), expires: expiry)
            return (reading, storePoint && storeForecast)
        case .earthquakes:
            let url = URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson")!
            let (feed, ttl, storeFeed) = try await request(Earthquakes.self, url: url, source: key.source, session: session, force: force)
            var records: [String: (updated: Double, event: OverviewQuake)] = [:]
            for row in feed.features {
                let p = row.properties
                guard p.type == "earthquake", let id = row.id, !id.isEmpty, let time = p.time, let mag = p.mag,
                      let geo = row.geometry?.coordinates, geo.count >= 2,
                      (-180...180).contains(geo[0]), (-90...90).contains(geo[1]) else { continue }
                let updated = p.updated ?? time
                if let existing = records[id], existing.updated >= updated { continue }
                records[id] = (updated, OverviewQuake(id: id, date: Date(timeIntervalSince1970: time / 1000), magnitude: mag,
                                                      place: p.place ?? "Location unreported", latitude: geo[1], longitude: geo[0]))
            }
            let reading = OverviewFeedReading(data: .earthquakes(records.values.map(\.event)), checkedAt: now,
                                              issuedAt: feed.metadata?.generated.map { Date(timeIntervalSince1970: $0 / 1000) },
                                              expires: now.addingTimeInterval(min(ttl ?? 60, 60)))
            return (reading, storeFeed)
        }
    }
}
