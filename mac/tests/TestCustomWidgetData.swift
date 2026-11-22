import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message) }
}

private func reject(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(message)
}

private func document(_ json: String) throws -> CustomWidgetDocument {
    try CustomWidgetDocument(data: Data(json.utf8))
}

private final class WidgetSourceFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        if path == "pending" { return }
        let status = path == "unavailable" ? 503 : path == "redirect" ? 302 : 200
        let data: Data
        switch path {
        case "oversized": data = Data(repeating: 32, count: CustomWidgetDocument.byteLimit + 1)
        case "invalid": data = Data("not json".utf8)
        default:
            let keyless = request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil
            data = Data((keyless ? #"{"watts":42}"# : "null").utf8)
        }
        let headers = ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct TestCustomWidgetData {
    static func main() async throws {
        try testFields()
        try testManual()
        try testStorage()
        try testURLPolicy()
        try await testResponses()
        print("Custom widget data tests passed.")
    }

    static func testFields() throws {
        let doc = try document(#"{"stats":{"a/b~c":12,"available":false,"name":"ok"},"series":[1,-2.5,0],"rows":["one",2,true],"complex":[{"foo":4}],"mixed":[1,null],"empty":{},"emptyList":[]}"#)
        let numbers = doc.fields(for: .number)
        try expect(numbers.map(\.pointer) == ["/stats/a~1b~0c"], "numbers include only numeric object fields")
        try expect(try doc.value(at: numbers[0].pointer, for: .gauge) == .number(12), "RFC 6901 field")
        try expect(try doc.value(at: "/stats/available", for: .status) == .status("false"), "boolean status")
        try expect(try doc.value(at: "/series", for: .trend) == .trend([1, -2.5, 0]), "negative trend values")
        try expect(try doc.value(at: "/rows", for: .list) == .list(["one", "2", "true"]), "scalar array")
        try expect(try doc.value(at: "/empty", for: .keyValue) == .keyValue([]), "empty pairs")
        try expect(try doc.value(at: "/emptyList", for: .list) == .list([]), "empty list")
        try expect(try document("0").fields(for: .progress).first?.pointer == "", "root numeric choice")
        try expect(try document(#"{ "":"zero" }"#).value(at: "/", for: .status) == .status("zero"), "empty-key pointer")
        try expect(try document(#"{"0":"as key"}"#).value(at: "/0", for: .status) == .status("as key"), "numeric object key")
        for path in ["/stats/a~2", "stats", "/stats/missing", "/series/0", "/complex/0/foo"] {
            try reject("invalid or unstable pointer \(path)") { _ = try doc.value(at: path, for: .number) }
        }
        try reject("mixed array treated as a trend") { _ = try doc.value(at: "/mixed", for: .trend) }
        try reject("numeric strings must stay strings") { _ = try document(#""100""#).value(at: "", for: .number) }
        try reject("malformed JSON") { _ = try document("not-json") }
        try reject("document size bound") { _ = try CustomWidgetDocument(data: Data(repeating: 32, count: CustomWidgetDocument.byteLimit + 1)) }
        let deep = String(repeating: #"{"child":"#, count: 26) + "3" + String(repeating: "}", count: 26)
        try expect(try document(deep).fields(for: .number).isEmpty, "field discovery depth bound")
        let tooMany = "[" + Array(repeating: "1", count: 257).joined(separator: ",") + "]"
        try expect(try document(tooMany).fields(for: .trend).isEmpty, "sample bound")
    }

    static func testManual() throws {
        var spec = CustomWidgetSpec()
        spec.title = "Test"
        let examples: [(CustomWidgetStyle, String, CustomWidgetValue)] = [
            (.number, "-2.75", .number(-2.75)), (.progress, "42", .number(42)),
            (.gauge, "0", .number(0)), (.status, "Online", .status("Online")),
            (.trend, "0, 1.2\n3", .trend([0, 1.2, 3])),
            (.list, "Pump\nValve", .list(["Pump", "Valve"])),
            (.keyValue, "Pump=Ready\nQueue=0", .keyValue([.init(key: "Pump", value: "Ready"), .init(key: "Queue", value: "0")]))
        ]
        for (style, input, expected) in examples {
            spec.style = style
            spec.manualInput = input
            try expect(try spec.manualValue() == expected && spec.validationError == nil, "\(style) manual example")
        }
        let importedList = try document(#"["[a", "", "  spaced", "embedded\nnewline"]"#).value(at: "", for: .list)
        spec.style = .list
        spec.manualInput = importedList.manualInput
        try expect(try spec.manualValue() == importedList, "imported strings preserved")
        let importedPairs = try document(#"{"":"empty key","x=y":"line\nbreak"}"#).value(at: "", for: .keyValue)
        spec.style = .keyValue
        spec.manualInput = importedPairs.manualInput
        try expect(try spec.manualValue() == importedPairs, "imported pairs preserved")
        spec.manualInput = "x=first\nx=second"
        try expect(spec.validationError != nil, "duplicate manual key")
        spec.style = .number
        for invalid in ["", "NaN", "inf", "not a number"] {
            spec.manualInput = invalid
            try expect(spec.validationError != nil, "invalid manual number")
        }
        spec.style = .gauge
        spec.manualInput = "42"
        spec.target = 0
        try expect(spec.validationError != nil, "positive target required")
    }

    static func testStorage() throws {
        var spec = CustomWidgetSpec()
        spec.title = "Temperature"
        spec.manualInput = "private draft"
        spec.endpoint = "https://example.test/feed.json"
        spec.pointer = "/temperature"
        let encoder = JSONEncoder()
        spec.source = .endpoint
        let endpoint = try encoder.encode(spec)
        let savedURL = try JSONDecoder().decode(CustomWidgetSpec.self, from: endpoint)
        try expect(savedURL.manualInput.isEmpty && savedURL.endpoint == spec.endpoint && savedURL.pointer == spec.pointer, "endpoint storage")
        try expect(!String(decoding: endpoint, as: UTF8.self).contains("private draft"), "manual payload persisted in endpoint")
        spec.source = .manual
        let manual = try encoder.encode(spec)
        let savedManual = try JSONDecoder().decode(CustomWidgetSpec.self, from: manual)
        try expect(savedManual.endpoint.isEmpty && savedManual.pointer.isEmpty && savedManual.manualInput == "private draft", "manual storage")
        spec.source = .endpoint
        spec.endpoint = "https://example.test/feed?api_key=private"
        try reject("credential persisted") { _ = try encoder.encode(spec) }
    }

    static func testURLPolicy() throws {
        for allowed in ["https://example.test/feed?units=metric", "http://localhost:9090/data", "http://127.0.0.1", "http://[::1]:8000", "http://192.168.1.1", "http://10.5.3.2", "http://172.31.2.1", "http://100.99.1.1", "http://device.local", "http://device.example.ts.net"] {
            _ = try CustomWidgetEndpoint.url(for: allowed)
        }
        for invalid in ["", "ftp://example.test", "file:///tmp/data.json", "http://example.test", "http://172.32.1.1", "http://100.128.1.1", "http://010.0.0.1", "https://user:pass@example.test", "https://example.test/?api_key=s", "https://example.test/?access_token=s", "https://example.test/?X-Amz-Credential=s", "https://example.test/#secret"] {
            try reject("accepted \(invalid)") { _ = try CustomWidgetEndpoint.url(for: invalid) }
        }
    }

    static func testResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetSourceFixture.self]
        let good = try await CustomWidgetEndpoint.fetch("https://widget.test/read", configuration: configuration)
        try expect(try good.value(at: "/watts", for: .number) == .number(42), "keyless GET fixture")
        let pending = Task { try await CustomWidgetEndpoint.fetch("https://widget.test/pending", configuration: configuration) }
        pending.cancel()
        do {
            _ = try await pending.value
            throw TestFailure("cancelled request accepted")
        } catch is CancellationError {
            // Closing setup must release the request.
        }
        for path in ["unavailable", "redirect", "invalid", "oversized"] {
            do { _ = try await CustomWidgetEndpoint.fetch("https://widget.test/" + path, configuration: configuration) }
            catch { continue }
            throw TestFailure("accepted \(path) response")
        }
    }
}
