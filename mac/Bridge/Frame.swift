import Foundation

/* JSON-RPC 2.0, one object per line.
 *
 * The framing is the whole of the agreement with the helper: a line in, a line
 * out, and the id is what pairs them. Nothing here knows what a message is.
 */

enum RPCFrameError: Error, Equatable {
    /// A line arrived that is not a JSON object, or is not JSON at all.
    case malformed
    /// No newline for four megabytes. The helper is not speaking this protocol
    /// any more and the only safe answer is to stop reading it.
    case lineTooLong
}

/// One outgoing call.
struct RPCRequest: Sendable {
    let id: Int
    let method: String
    let params: [String: JSONValue]?

    /// The line to write, newline included.
    ///
    /// `params` is omitted rather than sent empty: the helper rejects unknown
    /// keys and an empty object is one more thing to be wrong about.
    func line() throws -> Data {
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params, !params.isEmpty { fields["params"] = .object(params) }
        var data = try JSONEncoder().encode(JSONValue.object(fields))
        data.append(0x0A)
        return data
    }
}

/// What one incoming line turned out to be.
enum RPCFrame: Sendable, Equatable {
    case result(id: Int, value: JSONValue)
    case failure(id: Int, code: Int, message: String, data: JSONValue?)
    /// A method with no id. Never answered, only acted on.
    case notification(method: String, params: JSONValue)
    /// Well-formed JSON that pairs with no request we can settle -- a framing
    /// error carrying the required null id, most often.
    case unpaired

    static func decode(_ line: Data) throws -> RPCFrame {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              value.isObject
        else { throw RPCFrameError.malformed }

        let id = value["id"]?.intValue

        // A notification is a method with no id. The test is the presence of
        // the id, not its value: an id of null is a failed frame, not a
        // notification, and answering it as one would lose the error.
        if let method = value["method"]?.stringValue, value["id"] == nil {
            return .notification(method: method, params: value["params"] ?? .null)
        }

        if let error = value["error"], error.isObject {
            guard let id else { return .unpaired }
            return .failure(id: id,
                            code: error["code"]?.intValue ?? 0,
                            message: error["message"]?.stringValue ?? "",
                            data: error["data"])
        }

        if let id, let result = value["result"] { return .result(id: id, value: result) }
        return .unpaired
    }
}

/// Bytes in, whole lines out.
///
/// The cap is on the line, not on the read: a helper that opens a string and
/// never closes it would otherwise be a heap that grows until this process is
/// killed for it.
struct LineSplitter {

    static let cap = 4 * 1024 * 1024

    private var buffer = Data()

    mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        buffer = Data(buffer)
        if buffer.count > Self.cap {
            buffer = Data()
            throw RPCFrameError.lineTooLong
        }
        return lines
    }
}
