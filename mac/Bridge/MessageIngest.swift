import Foundation

extension Collector {
    /// A version-one collector can return 200 after a partial disk write, even
    /// for history where the echoed cursor says nothing about row delivery.
    /// Retrying the entire slice is safe because message keys are stable.
    func ingest(_ events: [Event], cursor: Int?, history: Bool) async throws {
        let sentCursor = cursor.map(JSONValue.int) ?? .null
        var body: [String: JSONValue] = [
            "protocol": .int(1), "events": try JSONValue.of(events), "cursor": sentCursor
        ]
        if history { body["backfill"] = .bool(true) }
        let receipt = try await post("/v1/messages/ingest", .object(body))
        guard receipt["ok"] == .bool(true), receipt["cursor_ack"] == sentCursor,
              case let .int(stored)? = receipt["stored"], (0...events.count).contains(stored),
              case let .int(duplicates)? = receipt["duplicates"],
              (0...(events.count - stored)).contains(duplicates),
              (receipt["rejected"] ?? .int(0)) == .int(events.count - stored - duplicates)
        else { throw Failure.malformed }
    }
}
