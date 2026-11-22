import Foundation
import CoreFoundation

enum CustomWidgetStyle: String, Codable, CaseIterable, Hashable {
    case number, progress, gauge, status, trend, list, keyValue

    var title: String {
        switch self {
        case .number: return "Number"
        case .progress: return "Progress bar"
        case .gauge: return "Gauge"
        case .status: return "Status"
        case .trend: return "Trend"
        case .list: return "List"
        case .keyValue: return "Key and value"
        }
    }
}

enum CustomWidgetSource: String, Codable, CaseIterable, Hashable {
    case manual, endpoint

    var title: String { self == .manual ? "Manual" : "JSON URL" }
}

struct CustomWidgetPair: Hashable {
    let key: String
    let value: String
}

enum CustomWidgetValue: Hashable {
    case number(Double)
    case status(String)
    case trend([Double])
    case list([String])
    case keyValue([CustomWidgetPair])

    fileprivate static func numericText(_ value: Double) -> String {
        Int(exactly: value).map { String($0) } ?? String(value)
    }

    // Imported text may contain delimiters or literal newlines. Preserve it as JSON when needed.
    var manualInput: String {
        switch self {
        case let .number(value): return Self.numericText(value)
        case let .status(value): return value
        case let .trend(values): return values.map(Self.numericText).joined(separator: ", ")
        case let .list(values):
            let needsJSON = values.isEmpty || values.first?.hasPrefix("[") == true
                || values.contains { $0.isEmpty || Self.needsQuotedText($0) }
            if needsJSON {
                return Self.jsonText(values)
            }
            return values.joined(separator: "\n")
        case let .keyValue(pairs):
            let needsJSON = pairs.isEmpty || pairs.first?.key.hasPrefix("{") == true
                || pairs.contains {
                    $0.key.isEmpty || $0.key.contains("=")
                        || Self.needsQuotedText($0.key) || Self.needsQuotedText($0.value)
                }
            if needsJSON {
                return Self.jsonText(Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) }))
            }
            return pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private static func needsQuotedText(_ value: String) -> Bool {
        value != value.trimmingCharacters(in: .whitespacesAndNewlines) || value.contains(where: \.isNewline)
    }

    private static func jsonText(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WidgetDataError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct CustomWidgetSpec: Hashable, Codable {
    var style: CustomWidgetStyle = .number
    var source: CustomWidgetSource = .manual
    var title = ""
    var unit = ""
    var target: Double = 100
    var manualInput = ""
    var endpoint = ""
    var pointer = ""

    private enum CodingKeys: String, CodingKey { case style, source, title, unit, target, manualInput, endpoint, pointer }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(CustomWidgetStyle.self, forKey: .style)
        source = try c.decode(CustomWidgetSource.self, forKey: .source)
        title = try c.decode(String.self, forKey: .title)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        target = try c.decodeIfPresent(Double.self, forKey: .target) ?? 100
        switch source {
        case .manual: manualInput = try c.decode(String.self, forKey: .manualInput)
        case .endpoint:
            endpoint = try c.decode(String.self, forKey: .endpoint)
            pointer = try c.decodeIfPresent(String.self, forKey: .pointer) ?? ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(source, forKey: .source)
        try c.encode(title, forKey: .title)
        if !unit.isEmpty { try c.encode(unit, forKey: .unit) }
        if style == .progress || style == .gauge { try c.encode(target, forKey: .target) }
        switch source {
        case .manual: try c.encode(manualInput, forKey: .manualInput)
        case .endpoint:
            _ = try CustomWidgetEndpoint.url(for: endpoint)
            try c.encode(endpoint, forKey: .endpoint)
            try c.encode(pointer, forKey: .pointer)
        }
    }

    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a title for this widget." }
        if title.count > 100 || unit.count > 40 { return "Use up to 100 characters for the title and 40 for the unit." }
        if (style == .progress || style == .gauge) && (!target.isFinite || target <= 0) { return "Enter a target greater than zero." }
        do {
            switch source {
            case .manual: _ = try manualValue()
            case .endpoint:
                _ = try CustomWidgetEndpoint.url(for: endpoint)
                _ = try CustomWidgetDocument.pathComponents(pointer)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func manualValue() throws -> CustomWidgetValue {
        let text = manualInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WidgetDataError("Enter a value to preview this widget.") }
        guard manualInput.utf8.count <= CustomWidgetDocument.byteLimit else { throw WidgetDataError("Use a smaller value.") }
        var lines: [String] { text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }
        switch style {
        case .number, .progress, .gauge:
            guard let value = Double(text), value.isFinite else { throw WidgetDataError("Enter a finite number.") }
            return .number(value)
        case .status:
            guard text.count <= 120 else { throw WidgetDataError("Keep the status within 120 characters.") }
            return .status(text)
        case .trend:
            if text.hasPrefix("[") { return try CustomWidgetDocument(data: Data(text.utf8)).value(at: "", for: style) }
            let items = text.components(separatedBy: CharacterSet(charactersIn: ",").union(.newlines)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let values = items.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == items.count, (2...256).contains(values.count), values.allSatisfy(\.isFinite) else { throw WidgetDataError("Enter 2 to 256 numbers separated by commas or new lines.") }
            return .trend(values)
        case .list:
            if text.hasPrefix("["), let document = try? CustomWidgetDocument(data: Data(text.utf8)) {
                return try document.value(at: "", for: style)
            }
            let rows = lines
            guard rows.count <= 64, rows.allSatisfy({ $0.count <= 512 }) else { throw WidgetDataError("Use up to 64 items, with up to 512 characters per item.") }
            return .list(rows)
        case .keyValue:
            if text.hasPrefix("{"), let document = try? CustomWidgetDocument(data: Data(text.utf8)) {
                return try document.value(at: "", for: style)
            }
            let rows = lines
            guard rows.count <= 64 else { throw WidgetDataError("Use up to 64 pairs.") }
            var seen = Set<String>()
            var result = [CustomWidgetPair]()
            for line in rows {
                guard let separator = line.firstIndex(of: "=") else { throw WidgetDataError("Enter each pair on its own line as key=value.") }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.count <= 256, value.count <= 512, seen.insert(key).inserted else { throw WidgetDataError("Give each pair a unique key of up to 256 characters and a value of up to 512.") }
                result.append(.init(key: key, value: value))
            }
            return .keyValue(result)
        }
    }
}

struct CustomWidgetField: Identifiable, Hashable {
    let pointer: String
    let label: String
    let value: CustomWidgetValue
    var id: String { pointer }
}

struct CustomWidgetDocument {
    static let byteLimit = 512 * 1024
    private let root: Any

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.byteLimit else { throw WidgetDataError("Choose a JSON document between 1 byte and 512 KB.") }
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw WidgetDataError("The source did not return valid JSON.") }
    }

    func fields(for style: CustomWidgetStyle) -> [CustomWidgetField] {
        var result = [CustomWidgetField]()
        var visited = 0
        func visit(_ object: Any, pointer: String, label: String, depth: Int) {
            guard depth <= 24, visited < 4096 else { return }
            visited += 1
            if let value = Self.map(object, for: style) {
                result.append(.init(pointer: pointer, label: label, value: value))
            }
            // Select arrays as whole series or lists. Their indices may move between requests.
            guard depth < 24, let children = object as? [String: Any] else { return }
            for key in children.keys.sorted() {
                if visited >= 4096 { break }
                let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                let next = pointer + "/" + escaped
                guard next.utf8.count <= 4096, let child = children[key] else { continue }
                let pathLabel = key.isEmpty ? "(empty key)" : key
                visit(child, pointer: next, label: depth == 0 ? pathLabel : label + " › " + pathLabel, depth: depth + 1)
            }
        }
        visit(root, pointer: "", label: "Whole response", depth: 0)
        return result
    }

    fileprivate static func pathComponents(_ pointer: String) throws -> [String] {
        if pointer.isEmpty { return [] }
        let parts = pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard pointer.hasPrefix("/"), pointer.utf8.count <= 4096, parts.count <= 24 else { throw WidgetDataError("Choose a valid field from the source.") }
        return try parts.map { part in
            var result = ""
            var iterator = part.makeIterator()
            while let character = iterator.next() {
                if character == "~" {
                    switch iterator.next() {
                    case "0": result += "~"
                    case "1": result += "/"
                    default: throw WidgetDataError("Choose a valid field from the source.")
                    }
                } else { result.append(character) }
            }
            return result
        }
    }

    func value(at pointer: String, for style: CustomWidgetStyle) throws -> CustomWidgetValue {
        var object: Any = root
        for key in try Self.pathComponents(pointer) {
            guard let child = (object as? [String: Any])?[key] else { throw WidgetDataError("The selected field is missing. Test the source and choose a field again.") }
            object = child
        }
        guard let value = Self.map(object, for: style) else { throw WidgetDataError("The selected field does not contain values that fit this widget.") }
        return value
    }

    private static func finiteNumber(_ object: Any) -> Double? {
        guard let n = object as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func scalarText(_ object: Any) -> String? {
        if let string = object as? String, string.count <= 512 { return string }
        if let n = object as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if n.doubleValue.isFinite { return n.stringValue }
        }
        return nil
    }

    private static func map(_ object: Any, for style: CustomWidgetStyle) -> CustomWidgetValue? {
        switch style {
        case .number, .progress, .gauge: return finiteNumber(object).map(CustomWidgetValue.number)
        case .status:
            guard finiteNumber(object) == nil, let text = scalarText(object) else { return nil }
            let status = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !status.isEmpty, status.count <= 120 else { return nil }
            return .status(status)
        case .trend:
            guard let items = object as? [Any], (2...256).contains(items.count) else { return nil }
            let values = items.compactMap(finiteNumber)
            return values.count == items.count ? .trend(values) : nil
        case .list:
            guard let items = object as? [Any], items.count <= 64 else { return nil }
            let values = items.compactMap(scalarText)
            return values.count == items.count ? .list(values) : nil
        case .keyValue:
            guard let items = object as? [String: Any], items.count <= 64 else { return nil }
            var pairs = [CustomWidgetPair]()
            for key in items.keys.sorted() {
                guard key.count <= 256, let item = items[key], let text = scalarText(item) else { return nil }
                pairs.append(.init(key: key, value: text))
            }
            return .keyValue(pairs)
        }
    }
}

private final class WidgetEndpointDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let serverTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(serverTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

enum CustomWidgetEndpoint {
    static func url(for address: String) throws -> URL {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty, let url = parts.url,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw WidgetDataError("Enter the full URL of a JSON source.")
        }
        guard parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw WidgetDataError("Use a URL without a username, password, or fragment.")
        }
        let containsSecret = parts.queryItems?.contains { item in
            let name = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return ["key", "apikey", "accesskey", "appid", "auth", "authorization", "sig", "credential", "pwd"].contains(name)
                || ["token", "password", "signature", "secret", "apikey"].contains(where: name.hasSuffix)
                || name.hasPrefix("xamz") || name.hasPrefix("xgoog")
        } ?? false
        guard !containsSecret else { throw WidgetDataError("Use a source that works without a key, password, or signed URL.") }
        guard scheme == "https" || (scheme == "http" && isLocal(host)) else {
            throw WidgetDataError("Use HTTPS, or HTTP on localhost, a private network address, or a local or Tailscale hostname.")
        }
        return url
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard let byte = UInt8(part), String(byte) == String(part) else { return nil }
            return byte
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || bytes[0] == 127
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }

    static func fetch(_ address: String, configuration: URLSessionConfiguration = .ephemeral) async throws -> CustomWidgetDocument {
        var request = URLRequest(url: try url(for: address))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: WidgetEndpointDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await read(request, with: session)
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw WidgetDataError("The source took too long to respond.") }
            if error.code == .userCancelledAuthentication || error.code == .userAuthenticationRequired { throw WidgetDataError("This source requires authentication. Choose a keyless source.") }
            throw WidgetDataError("Could not reach the JSON source. Check the URL and your connection.")
        }
    }

    private static func read(_ request: URLRequest, with session: URLSession) async throws -> CustomWidgetDocument {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WidgetDataError("The source did not return an HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            if (300..<400).contains(http.statusCode) { throw WidgetDataError("The URL redirects. Enter the final JSON URL.") }
            throw WidgetDataError("The source returned HTTP \(http.statusCode).")
        }
        guard response.expectedContentLength <= CustomWidgetDocument.byteLimit else { throw WidgetDataError("The JSON response exceeds 512 KB.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < CustomWidgetDocument.byteLimit else { throw WidgetDataError("The JSON response exceeds 512 KB.") }
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try CustomWidgetDocument(data: data)
    }
}
