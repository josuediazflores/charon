import Foundation

/* The collector, over the tailnet -- the same one the app talks to.
 *
 * Address and credential are deliberately not new: the base URL is the
 * `baseURL` preference Charon.app writes (Sources/Settings.swift,
 * `Connection.defaultBase`) and the token is the Keychain item
 * Sources/Keychain.swift already owns. Installing the Bridge is therefore
 * copying an app and launching it; there is no second setup to get wrong, and
 * rotating the token is still rotate-and-restart for both halves at once.
 */

enum Wiring {

    /// The same constant as `Connection.defaultBase`. It is repeated rather
    /// than shared because Settings.swift is a SwiftUI file with the whole
    /// console behind it; the string is the contract, not the file.
    static let defaultBase = "http://100.64.0.2:8788"

    /// The app's preferences domain, which is also where its address lives.
    static let appDomain = "com.example.charon"

    static func base(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL? {
        if let raw = environment["CHARON_COLLECTOR_URL"], !raw.isEmpty {
            return URL(string: raw.trimmingCharacters(in: .whitespaces))
        }
        if let raw = UserDefaults(suiteName: appDomain)?.string(forKey: "baseURL"),
           !raw.isEmpty {
            return URL(string: raw.trimmingCharacters(in: .whitespaces))
        }
        // The app is sandboxed, so its preferences may only exist inside its
        // container. Read that file directly rather than make the user set the
        // address twice.
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(appDomain)/Data/Library/Preferences/\(appDomain).plist")
        if let plist = NSDictionary(contentsOf: container),
           let raw = plist["baseURL"] as? String, !raw.isEmpty {
            return URL(string: raw.trimmingCharacters(in: .whitespaces))
        }
        return URL(string: defaultBase)
    }

    static func token(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        if let raw = environment["CHARON_COLLECTOR_TOKEN"], !raw.isEmpty { return raw }
        return TokenStore.read()
    }
}

/// One request, one answer. Nothing here retries: the callers know what a
/// failed post means for them, and they are the ones holding the backoff.
actor Collector {

    enum Failure: Error, Sendable {
        case http(Int)
        case transport(String)
        case malformed
    }

    private let base: URL
    private let token: String
    private let dryRun: Bool
    private let log: Log
    private let session: URLSession
    /// A second session for the one request that carries a file.
    ///
    /// Not a second connection to a second place: the same address and the
    /// same credential, with the two clocks moved. `timeoutIntervalForResource`
    /// is the ceiling on a whole transfer and it is thirty seconds below,
    /// which is right for a JSON round trip and is a hard stop halfway through
    /// a video. A request's own `timeoutInterval` cannot lift it, so the
    /// upload needs a configuration rather than a parameter.
    private let uploads: URLSession

    init(base: URL, token: String, dryRun: Bool, log: Log) {
        self.base = base
        self.token = token
        self.dryRun = dryRun
        self.log = log
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        let big = URLSessionConfiguration.ephemeral
        big.timeoutIntervalForRequest = 60
        big.timeoutIntervalForResource = 300
        big.waitsForConnectivity = false
        big.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.uploads = URLSession(configuration: big)
    }

    func get(_ path: String) async throws -> JSONValue {
        try await perform("GET", path, nil)
    }

    @discardableResult
    func post(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await perform("POST", path, body)
    }

    /// One file, uploaded. The only request this program makes whose body is
    /// not JSON, and the only one that does not hold its body in memory.
    ///
    /// `session.upload(fromFile:)` streams the file off the disk into the
    /// socket, so a twenty-five megabyte video is read a buffer at a time by
    /// URLSession rather than assembled here first. Its own timeout, because
    /// the fifteen seconds that is generous for a JSON round trip is not
    /// generous for a video going up a domestic uplink.
    @discardableResult
    func put(_ path: String, file: URL, headers: [String: String],
             timeout: TimeInterval = 60) async throws -> JSONValue {

        guard let url = Self.url(base, path) else { throw Failure.malformed }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size]
            as? Int
        if dryRun { trace(path, bytes: size ?? 0) }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await uploads.upload(for: request, fromFile: file)
        } catch {
            throw Failure.transport(error.redacted)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        if data.isEmpty { return .null }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure.malformed
        }
        return value
    }

    /// The address, built by hand. `appendingPathComponent` would escape the
    /// question mark in `?status=queued` into a path, and the collector would
    /// answer the console's own HTML with a 200 -- section 3's warning about
    /// unknown paths, arrived at from the other direction.
    nonisolated static func url(_ base: URL, _ path: String) -> URL? {
        var head = base.absoluteString
        while head.hasSuffix("/") { head.removeLast() }
        return URL(string: head + path)
    }

    private func perform(_ method: String, _ path: String, _ body: JSONValue?) async throws
        -> JSONValue {

        if dryRun { trace(method, path, body) }

        guard let url = Self.url(base, path) else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.redacted)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        if data.isEmpty { return .null }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure.malformed
        }
        return value
    }

    /// The upload's line in the same trace. A count and never the bytes:
    /// there is no shorn form of a photograph, and the trace exists to prove
    /// which requests happen rather than to carry what they carried.
    private func trace(_ path: String, bytes: Int) {
        let line = JSONValue.object([
            "would": .string("PUT"),
            "path": .string(path),
            "bytes": .int(bytes),
        ])
        guard let data = try? JSONEncoder().encode(line) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// The dry run's whole output: one line per request, as JSON, with every
    /// body a body could be hiding in taken out first. The request is still
    /// made -- against whatever CHARON_COLLECTOR_URL points at -- because a
    /// rehearsal nobody answers proves nothing.
    private func trace(_ method: String, _ path: String, _ body: JSONValue?) {
        var line: [String: JSONValue] = [
            "would": .string(method),
            "path": .string(path),
        ]
        if let body { line["body"] = Trace.shorn(body) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(line)) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

/// What a request looks like once the words people wrote are out of it.
enum Trace {

    /// Message text and draft bodies are replaced by their length. The trace
    /// exists to prove which requests happen and in what shape; it is not
    /// worth reading somebody's evening off a terminal to do that.
    static func shorn(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, field) in fields {
                if key == "text" || key == "body", let words = field.stringValue {
                    out[key] = .string("<\(words.count) chars>")
                } else {
                    out[key] = shorn(field)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(shorn))
        default:
            return value
        }
    }
}
