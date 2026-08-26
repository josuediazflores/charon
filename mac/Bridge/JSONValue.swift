import Foundation

/* One JSON document, held as a value.
 *
 * The Bridge talks to two counterparties that both speak JSON and neither of
 * which is ours to change: imsg over a pipe, the collector over HTTP. A
 * dictionary of `Any` would carry either one, but it is not `Sendable`, and
 * every one of those documents crosses an actor boundary at least once. So the
 * documents are values: they can be held, passed, compared and matched without
 * a lock and without a cast that can fail at the wrong moment.
 */
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        // Integers first: a rowid read back as a Double is a rowid that
        // stops being exact somewhere past 2^53, and the cursor is the one
        // number in this program that has to be the same number it was.
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "not JSON this program can hold")
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let v): try single.encode(v)
        case .int(let v): try single.encode(v)
        case .double(let v): try single.encode(v)
        case .string(let v): try single.encode(v)
        case .array(let v): try single.encode(v)
        case .object(let v): try single.encode(v)
        }
    }
}

extension JSONValue {

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    var isObject: Bool { objectValue != nil }

    /// This value, read as one of our own records.
    ///
    /// The round trip through bytes is deliberate: it is the only place the
    /// snake_case both counterparties speak is turned into Swift names, and
    /// doing it in one place means a field renamed upstream fails to decode
    /// rather than quietly arriving as nil in three of them.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// The value a record makes, for the outgoing side of the same trip.
    static func of<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}
