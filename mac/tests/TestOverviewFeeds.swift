import Foundation

private final class FeedURLProtocol: URLProtocol {
    typealias Reply = (Int, String, String)
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var seen: [URLRequest] = []

    static func set(_ path: String, _ status: Int, _ body: String, cache: String = "max-age=30") {
        lock.withLock { replies[path] = (status, body, cache) }
    }
    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let (status, body, cache) = Self.lock.withLock {
            Self.seen.append(request)
            return Self.replies[url.path] ?? (404, "", "no-store")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/geo+json", "Cache-Control": cache])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct TestOverviewFeeds {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let provider = OverviewFeedProvider(session: URLSession(configuration: configuration))
        let now = ISO8601DateFormatter().date(from: "2026-11-22T20:00:00Z")!
        let weather = OverviewFeedKey.forecast(latitude: 38.1234567, longitude: -122.1758967)
        let point = "/points/38.1235,-122.1759"
        let hourly = "/gridpoints/MTR/72,98/forecast/hourly"
        let pointDoc = #"{"properties":{"timeZone":"America/Los_Angeles","forecastHourly":"https://api.weather.gov/gridpoints/MTR/72,98/forecast/hourly"}}"#
        FeedURLProtocol.set(point, 200, pointDoc)
        let periods = (11...18).map { hour in
            """
            {"startTime":"2026-11-22T\(hour):00:00-08:00","endTime":"2026-11-22T\(hour + 1):00:00-08:00","temperature":10,"temperatureUnit":"C","shortForecast":"Cloudy","relativeHumidity":{"value":74},"windSpeed":"8 mph","windDirection":"NW"}
            """
        }.joined(separator: ",")
        FeedURLProtocol.set(hourly, 200, """
            {"properties":{"updateTime":"2026-11-22T19:30:00.123Z","periods":[\(periods)]}}
            """)
        let coldPreview = await provider.cached(weather)
        expect(coldPreview == nil && FeedURLProtocol.requests.isEmpty, "cold editor preview makes no provider request")
        async let a = provider.read(weather, now: now)
        async let b = provider.read(weather, now: now)
        let (first, second) = try await (a, b)
        guard case let .forecast(hours, zone) = first.data else { fatalError("Missing forecast") }
        expect(hours.count == 5 && hours[0].start == now, "five upcoming hourly periods")
        expect(hours[0].degrees(celsius: true) == 10 && hours[0].degrees(celsius: false) == 50, "unit conversions")
        expect(hours[0].humidity == 74 && hours[0].wind == "8 mph NW", "provider units")
        expect(zone.identifier == "America/Los_Angeles" && first.issuedAt != nil, "source timestamps and time zone")
        expect(first.expires == now.addingTimeInterval(30) && second.checkedAt == first.checkedAt, "source TTL")
        var requests = FeedURLProtocol.requests
        expect(requests.map { $0.url!.path } == [point, hourly], "coalesce concurrent requests")
        expect(requests.allSatisfy { $0.url?.scheme == "https" && $0.value(forHTTPHeaderField: "User-Agent")?.contains("Charon") == true }, "NWS user agent and HTTPS")
        _ = try await provider.read(weather, now: now.addingTimeInterval(25))
        expect(FeedURLProtocol.requests.count == 2, "cache hit")
        FeedURLProtocol.set(point, 404, "")
        do {
            _ = try await provider.read(weather, force: true, now: now)
            fatalError("Missing coverage error")
        } catch {
            expect(error.localizedDescription.contains("coverage"), "explain forecast coverage")
        }
        let beforePreview = FeedURLProtocol.requests.count
        let retained = await provider.cached(weather)
        expect(retained?.checkedAt == now && retained?.expires == now.addingTimeInterval(30)
               && FeedURLProtocol.requests.count == beforePreview, "editor can read dated last success without traffic")
        FeedURLProtocol.set(point, 200, #"{"properties":{"forecastHourly":"https://example.invalid/other"}}"#)
        do {
            _ = try await provider.read(weather, now: now.addingTimeInterval(31))
            fatalError("Unexpected off-provider forecast")
        } catch {
            expect(FeedURLProtocol.requests.last?.url?.path == point, "validate discovered URL before fetching")
        }

        FeedURLProtocol.set(point, 200, pointDoc, cache: "no-store")
        _ = try await provider.read(weather, force: true, now: now)
        let oldWeather = await provider.cached(weather)
        expect(oldWeather == nil, "no-store from either NWS request invalidates the prior forecast")
        FeedURLProtocol.set(point, 200, pointDoc, cache: "no-cache")
        _ = try await provider.read(weather, now: now)
        let revalidateWeather = await provider.cached(weather)
        expect(revalidateWeather?.expires == now, "no-cache keeps the reading for display but requires revalidation")

        let ms = Int(now.timeIntervalSince1970 * 1000)
        func event(_ id: String, _ mag: Double, _ lon: Double, _ lat: Double, delta: Int = -1000, revision: Int = 0, kind: String = "earthquake") -> String {
            """
            {"id":"\(id)","properties":{"mag":\(mag),"place":"Site","type":"\(kind)","time":\(ms + delta),"updated":\(ms + revision)},"geometry":{"type":"Point","coordinates":[\(lon),\(lat),2]}}
            """
        }
        let feed = [
            event("near", 2, 179.98, 2, revision: -7000),
            event("near", 3.7, 179.98, 2, revision: -2000),
            event("far", 3.8, 10, 24),
            event("small", 1, 179.99, 2),
            event("old", 4, 179.99, 2, delta: -90_000_000),
            event("quarry", 5, 179.99, 2, kind: "quarry blast"),
            event("future", 5, 179.99, 2, delta: 600_000)
        ].joined(separator: ",")
        let quakePath = "/earthquakes/feed/v1.0/summary/all_day.geojson"
        FeedURLProtocol.set(quakePath, 200, """
            {"metadata":{"generated":\(ms)},"features":[\(feed)]}
            """)
        let quake = try await provider.read(.earthquakes, now: now)
        guard case let .earthquakes(events) = quake.data else { fatalError("Missing earthquake data") }
        expect(quake.issuedAt == now, "USGS feed timestamp in milliseconds")
        let matching = OverviewQuake.nearby(events, latitude: 2, longitude: -179.98, radius: 8, magnitude: 2, asOf: now)
        expect(matching.count == 1 && matching[0].magnitude == 3.7, "filter and use latest revision across date line")
        let empty = OverviewQuake.nearby(events, latitude: 0, longitude: 0, radius: 5, magnitude: 4, asOf: now)
        expect(empty.isEmpty, "empty region")
        requests = FeedURLProtocol.requests
        expect(requests.last?.url?.query == nil && requests.last?.url?.path == quakePath, "region stays on device")
        FeedURLProtocol.set(quakePath, 429, "")
        do {
            _ = try await provider.read(.earthquakes, force: true, now: now)
            fatalError("Missing rate limit failure")
        } catch {
            expect(error.localizedDescription.contains("too many requests"), "rate limit state")
        }
        FeedURLProtocol.set(quakePath, 200, #"{"features":[]}"#, cache: "max-age=45, no-store")
        _ = try await provider.read(.earthquakes, force: true, now: now)
        let oldQuakes = await provider.cached(.earthquakes)
        expect(oldQuakes == nil, "USGS no-store invalidates a prior result and overrides max-age")
        print("Overview public feed checks passed.")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
