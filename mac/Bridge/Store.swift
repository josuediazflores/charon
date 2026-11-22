import Foundation

/* The four small files, read and written whole.
 *
 * None of them is worth a database and all four have to survive a power cut
 * mid-write, so each is written to a temporary neighbour and renamed over the
 * old one. A file that will not parse is treated as a file that is not there:
 * losing a cursor costs a gap in the stream, and refusing to start costs the
 * whole channel.
 */

/// What survives a restart. The cursor here is only ever one the collector has
/// acknowledged -- section 7.
struct BridgeState: Codable, Sendable, Equatable {
    var cursor: Int?
    /// Resume here if the first live batch has yet to be acknowledged.
    var firstLiveResume: Int?
    /// Which Messages database that cursor belongs to. A rowid from another
    /// database is not a smaller number, it is a different question.
    var dbIdentity: String?
    var lastEventAt: String?
    var updatedAt: String?
    /// How far each allowlisted chat's history has been read, by chat GUID.
    /// Section 7: a chat is backfilled once, and a Bridge that stopped halfway
    /// through one carries on from here rather than starting again.
    var backfill: [String: BackfillMark]?

    /// Spelled out because one of these keys is a map keyed by chat GUID.
    ///
    /// A key strategy converts every key an encoder is given, dictionary keys
    /// included, so `iMessage;-;+1408…` would be written as `i_message;-;+1408…`
    /// and read back as something that matches no chat. The four names below
    /// are the price of not letting that happen; they are also exactly what
    /// the file has always held.
    enum CodingKeys: String, CodingKey {
        case cursor
        case firstLiveResume = "first_live_resume"
        case dbIdentity = "db_identity"
        case lastEventAt = "last_event_at"
        case updatedAt = "updated_at"
        case backfill
    }
}

/// `attachments-seen.json`: where the file behind each forwarded attachment
/// was, by message key and position.
///
/// Paths only, inside this program's own Application Support directory, and
/// never sent anywhere. It exists because a want can arrive long after the
/// event that named the file, and asking the database again costs a round trip
/// through a helper that may be busy with the live stream.
struct SeenAttachments: Codable, Sendable, Equatable {
    var paths: [String: [String]] = [:]
    /// Insertion order, so the oldest message is the one that falls off.
    var order: [String] = []
}

enum Store {

    /// No key strategy, in either direction. The two documents that go through
    /// here name their own fields, because one of them holds a map keyed by
    /// chat GUID and a strategy would rewrite those GUIDs on the way past.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    static func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to file: URL) -> Bool {
        guard let data = try? encoder.encode(value) else { return false }
        return writeData(data, to: file)
    }

    @discardableResult
    static func writeData(_ data: Data, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    static func readData(from file: URL) -> Data? { try? Data(contentsOf: file) }
}
