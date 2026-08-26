import CryptoKit
import Foundation

/* The records on the wire, and the one function that makes an Event out of a
 * row. Everything here is a value, and one function here reads a file -- the
 * digest of an attachment, which is deliberately in this file rather than in
 * the actor that uses it so the units can check it against a known answer.
 * Everything else does no I/O, which is why this is also the part with tests.
 *
 * Field names follow MESSAGES-PROTOCOL.md section 4 exactly. The Swift names
 * are camelCase and the encoders convert; the two places that cannot be
 * converted mechanically -- `protocol`, and a config keyed by chat GUID --
 * are spelled out by hand below.
 */

// MARK: - keys

enum Keys {
    /// The first sixteen hex of the SHA-256 of a GUID. Section 3.
    static func of(_ guid: String) -> String {
        SHA256.hash(data: Data(guid.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .lowercased()
    }
}

// MARK: - time

enum Stamp {

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func now() -> String { withFraction.string(from: Date()) }

    /// The same instant, said the way section 3 says it: UTC, `Z`, milliseconds.
    ///
    /// A stamp we cannot parse is passed through rather than dropped or
    /// invented. It came from the database; being unable to read it is our
    /// problem, and a wrong timestamp is worse than an odd one.
    static func normalise(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let date = withFraction.date(from: text) ?? plain.date(from: text) {
            return withFraction.string(from: date)
        }
        return text
    }
}

// MARK: - what imsg hands us

/// One row, as imsg's JSON describes it (docs/json.md, "Message"). Only the
/// fields this program uses are listed; the rest are ignored on purpose, so a
/// helper that grows a field does not fail to decode here.
struct IMsgMessage: Decodable, Sendable {
    var id: Int?
    var guid: String?
    var chatGuid: String?
    var chatIdentifier: String?
    var chatName: String?
    var participants: [String]?
    var isGroup: Bool?
    var sender: String?
    var senderName: String?
    var isFromMe: Bool?
    var text: String?
    var createdAt: String?
    var attachments: [IMsgAttachment]?
    var isReaction: Bool?
}

struct IMsgAttachment: Decodable, Sendable {
    var filename: String?
    var transferName: String?
    var mimeType: String?
    var totalBytes: Int?
    var missing: Bool?
    var isSticker: Bool?
    /// Where the file actually is, under `~/Library/Messages/Attachments`.
    ///
    /// The one field the helper hands over that never leaves this Mac. It is
    /// how the uploader finds the bytes, and it is a path in somebody's home
    /// directory, which is exactly the kind of string section 8 says is not
    /// the Pi's business. Empty on a row Messages has aged the file out of.
    var originalPath: String?
}

/// One conversation, as imsg's `chats.list` describes it.
///
/// `id` is the helper's own chat rowid. It never goes on the wire -- the
/// collector knows conversations by GUID and by key -- but it is the handle
/// `messages.after` pages a single conversation with, so it is decoded here
/// and kept beside the directory.
struct IMsgChat: Decodable, Sendable {
    var id: Int?
    var guid: String?
    var identifier: String?
    var name: String?
    var displayName: String?
    var contactName: String?
    var isGroup: Bool?
    var service: String?
    var participants: [String]?
    var lastMessageAt: String?
}

// MARK: - what the collector is told

/// One attachment, as section 4 has it: metadata on the ingest route, and
/// bytes on a route of its own.
///
/// `n` is the position in the row's own list, and it is the whole of how the
/// two sides agree which file they mean -- the event names it, the upload puts
/// it in a URL, the app asks for it back by it. `originalPath` is on this
/// record and is deliberately not in `CodingKeys`: the uploader needs it and
/// the Pi must never see it, and leaving it out of the key list is the only
/// way to make "never sent" a property of the type rather than a rule somebody
/// has to remember at each of the three places an Event is encoded.
struct Attachment: Codable, Sendable, Equatable {
    var n: Int
    var filename: String
    var mimeType: String?
    var totalBytes: Int?
    var missing: Bool
    /// Only when it is true. A sticker is a kind of image and the app draws it
    /// as one; a false on every ordinary photograph would be noise.
    var isSticker: Bool?
    var originalPath: String?

    enum CodingKeys: String, CodingKey {
        case n, filename, mimeType, totalBytes, missing, isSticker
    }
}

struct Event: Codable, Sendable, Equatable {
    var key: String
    var guid: String
    var rowid: Int
    var chatGuid: String
    var chatKey: String
    var chatIdentifier: String
    var chatName: String?
    var isGroup: Bool
    var service: String
    var participants: [String]
    var sender: String
    var senderName: String?
    var isFromMe: Bool
    var text: String
    var createdAt: String
    var attachments: [Attachment]
}

struct ChatRecord: Codable, Sendable, Equatable {
    var chatGuid: String
    var chatKey: String
    var chatIdentifier: String
    var name: String?
    var contactName: String?
    var isGroup: Bool
    var service: String
    var participants: [String]
    var lastMessageAt: String?

    /// The name chain, in the order section 4 gives it: a group's own title,
    /// then any display name, then the Contacts match, then nothing.
    ///
    /// The helper's `name` is deliberately not in it. That field falls back to
    /// the raw handle when nothing else is known, and a conversation called
    /// +14085550142 is the thing the Contacts grant exists to prevent: better
    /// no name at all, which the console draws as the identifier, than a
    /// number wearing a person's slot.
    init?(_ chat: IMsgChat) {
        guard let guid = chat.guid, !guid.isEmpty else { return nil }
        chatGuid = guid
        chatKey = Keys.of(guid)
        chatIdentifier = chat.identifier ?? guid
        isGroup = chat.isGroup ?? guid.contains(";+;")
        let groupTitle = isGroup ? chat.displayName : nil
        name = [groupTitle, chat.displayName, chat.contactName]
            .compactMap { $0 }.first { !$0.isEmpty }
        contactName = (chat.contactName?.isEmpty ?? true) ? nil : chat.contactName
        service = Service.of(guid, fallback: chat.service)
        participants = chat.participants ?? []
        lastMessageAt = Stamp.normalise(chat.lastMessageAt)
    }
}

/// The service a chat runs on.
///
/// A message row does not carry one -- only the chat directory does -- so the
/// GUID answers when the directory has not been read yet. Every chat GUID is
/// `<service>;<-|+>;<identifier>`, which makes the prefix the service by
/// construction rather than by guess.
enum Service {
    static func of(_ chatGuid: String, fallback: String? = nil) -> String {
        if let fallback, !fallback.isEmpty { return fallback }
        let head = chatGuid.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return head.isEmpty ? "iMessage" : head
    }
}

// MARK: - the bytes

/// SHA-256, of some bytes or of a file full of them.
///
/// The upload carries a digest so the Pi can check that what it wrote is what
/// left this Mac, and it is computed here rather than inside the uploader for
/// one reason: it is arithmetic with a known answer, and the units can check
/// it against one. The file form reads in pieces because the largest thing
/// this program ever hashes is twenty-five megabytes of somebody's video, and
/// holding that whole to hash it and again to send it is fifty megabytes of a
/// laptop's memory spent on a checksum.
enum Digest {

    static let chunk = 256 * 1024

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest and the length of a file, in one pass, or nil if it cannot
    /// be opened. A file that stops being readable halfway through comes back
    /// short, the Pi's own count disagrees, and the upload is refused -- which
    /// is the right end for a half-read photograph.
    static func ofFile(at url: URL) -> (hex: String, bytes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let piece = try? handle.read(upToCount: chunk), !piece.isEmpty {
            hasher.update(data: piece)
            total += piece.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}

/// The rules about uploading, as values: what goes without being asked, what
/// a filename is allowed to be, and how a size is said in a log line.
enum Uploads {

    /// What the Bridge sends on its own, in bytes. Deliberately below the
    /// wire's own ceiling: ten megabytes is a photograph, and the twenty-five
    /// the route accepts is there for the video somebody actually asked to
    /// see. Section 7.
    static let automaticLimit = 10 * 1024 * 1024
    /// What the route accepts at all. Section 8.
    static let wireLimit = 25 * 1024 * 1024

    /// Whether this attachment goes up without anybody asking for it.
    ///
    /// Four things have to be true and each of them is a different no. A file
    /// Messages has aged out cannot be sent at all. A file with no path is the
    /// same fact said by the helper's other field. Anything that is not an
    /// image waits for a tap, because a conversation switched on today should
    /// not spend the evening pushing video up a home connection. And a size
    /// the row does not state is a size this rule will not guess at: the
    /// ceiling is the whole point of the rule, and an unknown is not under it.
    static func automatic(_ attachment: Attachment) -> Bool {
        guard !attachment.missing else { return false }
        guard let path = attachment.originalPath, !path.isEmpty else { return false }
        guard attachment.mimeType?.lowercased().hasPrefix("image/") == true
        else { return false }
        guard let bytes = attachment.totalBytes, bytes > 0,
              bytes <= automaticLimit else { return false }
        return true
    }

    /// The name that goes in `X-Charon-Filename`, rebuilt rather than passed
    /// through.
    ///
    /// The collector rebuilds it again on arrival from the same alphabet, and
    /// this is the copy that keeps the header legal in the first place: a CR
    /// in a header value is a second header, and a byte over 127 is a string
    /// two HTTP stacks will disagree about. A name that survives nothing at
    /// all becomes its own position, which is what the far end would have
    /// called it anyway.
    static let nameLimit = 100

    static func headerName(_ raw: String?, n: Int) -> String {
        var out = ""
        var dashed = false
        for character in raw ?? "" {
            if character.isASCII,
               character.isLetter || character.isNumber
                   || character == "." || character == "_" || character == "-" {
                out.append(character)
                dashed = false
            } else if !dashed {
                out.append("-")
                dashed = true
            }
        }
        while let first = out.first, first == "-" || first == "." { out.removeFirst() }
        while let last = out.last, last == "-" || last == "." { out.removeLast() }
        if out.count > nameLimit { out = String(out.prefix(nameLimit)) }
        return out.isEmpty ? "attachment-\(n)" : out
    }

    /// A byte count, for the one line a cycle of uploads writes. Never a
    /// filename and never a path -- section 7's rule about what an attachment
    /// is allowed to say in a log.
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - the allowlist, as the collector keeps it

struct ChatPolicy: Sendable, Equatable {
    var read: Bool
    /// `off` · `confirm` · `auto`. v1 acts on `confirm` and nothing else.
    var send: String
    var name: String?
}

/// The mirrored config document, section 4.
///
/// Parsed by hand rather than through Codable: the `chats` object is keyed by
/// chat GUID, and a key-decoding strategy applied to a document like that
/// would rewrite the GUIDs on their way in.
struct Allowlist: Sendable, Equatable {

    var updatedAt: String?
    var byGuid: [String: ChatPolicy] = [:]
    /// The same policies under their chat keys, so an outbox item that carries
    /// only the key can still be checked.
    var byKey: [String: ChatPolicy] = [:]

    static let empty = Allowlist()

    init() {}

    init(_ document: JSONValue) {
        updatedAt = document["updated_at"]?.stringValue
        for (guid, entry) in document["chats"]?.objectValue ?? [:] {
            let policy = ChatPolicy(read: entry["read"]?.boolValue ?? false,
                                    send: entry["send"]?.stringValue ?? "off",
                                    name: entry["name"]?.stringValue)
            byGuid[guid] = policy
            byKey[Keys.of(guid)] = policy
        }
    }

    /// The policy for a chat, by whichever handle the caller has.
    func policy(guid: String?, identifier: String? = nil, key: String? = nil) -> ChatPolicy? {
        if let guid, let found = byGuid[guid] { return found }
        if let identifier, let found = byGuid[identifier] { return found }
        if let key, let found = byKey[key] { return found }
        return nil
    }

    /// Whether a chat's rows may leave this Mac at all.
    func mayRead(guid: String?, identifier: String? = nil) -> Bool {
        policy(guid: guid, identifier: identifier)?.read ?? false
    }
}

// MARK: - the outbox

struct OutboxItem: Decodable, Sendable, Equatable {
    var id: String
    var chatKey: String?
    var chatGuid: String?
    var body: String?
}

// MARK: - what the app has asked for

/// One row of `GET /v1/messages/attachments?status=wanted`, section 5.
///
/// `rowid` and `chat_guid` are on it for the one case the map cannot answer: a
/// tap on a photograph in a conversation whose history was downloaded weeks
/// ago, in a process that has been restarted since. They are the two handles
/// `messages.after` can be asked by.
struct WantedAttachment: Decodable, Sendable, Equatable {
    var key: String
    var n: Int
    var guid: String?
    var rowid: Int?
    var chatGuid: String?
    var filename: String?
    var mimeType: String?
    var totalBytes: Int?
}

// MARK: - the heartbeat

enum HelperState: String, Codable, Sendable {
    case verified, missing, mismatch
}

/// How far the history backfill has got, across every allowlisted chat.
/// Counts only: which conversations they belong to is not the console's
/// business and is not in this record.
struct BackfillProgress: Codable, Sendable, Equatable {
    /// Allowlisted chats whose history is not finished yet.
    var pending: Int
    /// Allowlisted chats whose history is finished.
    var done: Int
    /// Rows sent by the backfill in total, over every chat and every run.
    var rows: Int
}

/// How the uploads are going, across every conversation. Counts only, for
/// `BackfillProgress`'s reason: which photographs they were is not the
/// console's business and is not in this record.
struct AttachmentProgress: Codable, Sendable, Equatable {
    /// Files this run has put on the Pi.
    var uploaded: Int
    /// Files queued here or wanted there and not yet sent.
    var pending: Int
    /// Attempts that ended in a refusal rather than a retry.
    var failed: Int
}

struct Heartbeat: Sendable, Equatable {

    struct Helper: Sendable, Equatable {
        var version: String
        var state: HelperState
    }

    var version: String
    var host: String
    var helper: Helper
    var fda: Bool
    var automation: Bool
    var dbOk: Bool
    var cursor: Int?
    var lastEventAt: String?
    var droppedNotAllowlisted: Int
    var lastError: String?
    /// Whether this Mac has granted Contacts. Reported, never asked for here.
    var contacts: Bool?
    var backfill: BackfillProgress?
    var attachments: AttachmentProgress?
}

extension Heartbeat: Encodable {

    private enum Key: String, CodingKey {
        case proto = "protocol"
        case version, host, helper, fda, automation
        case dbOk = "db_ok"
        case cursor
        case lastEventAt = "last_event_at"
        case droppedNotAllowlisted = "dropped_not_allowlisted"
        case lastError = "last_error"
        case contacts, backfill, attachments
    }

    private enum HelperKey: String, CodingKey { case version, state }

    /// The three fields that can be absent are written as null rather than
    /// left out: the console draws "no cursor yet" and "no error" as facts,
    /// and a missing key would make it draw nothing at all.
    ///
    /// The three newer ones are the other way round. `contacts`, `backfill`
    /// and `attachments` are additions to section 4, and a collector that
    /// predates them should see a heartbeat it recognises rather than three
    /// nulls it has no row for, so they are left out entirely when there is
    /// nothing to say.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(1, forKey: .proto)
        try c.encode(version, forKey: .version)
        try c.encode(host, forKey: .host)
        var h = c.nestedContainer(keyedBy: HelperKey.self, forKey: .helper)
        try h.encode(helper.version, forKey: .version)
        try h.encode(helper.state, forKey: .state)
        try c.encode(fda, forKey: .fda)
        try c.encode(automation, forKey: .automation)
        try c.encode(dbOk, forKey: .dbOk)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(lastEventAt, forKey: .lastEventAt)
        try c.encode(droppedNotAllowlisted, forKey: .droppedNotAllowlisted)
        try c.encode(lastError, forKey: .lastError)
        try c.encodeIfPresent(contacts, forKey: .contacts)
        try c.encodeIfPresent(backfill, forKey: .backfill)
        try c.encodeIfPresent(attachments, forKey: .attachments)
    }
}

// MARK: - what a backfill remembers

/// Where one chat's history got to, as `state.json` keeps it.
///
/// A value with no I/O in it, like everything else in this file, which is why
/// the page arithmetic that moves it lives here and is tested rather than
/// buried in the loop that calls it.
struct BackfillMark: Codable, Sendable, Equatable {
    /// The next `since_rowid` to ask for. `next_rowid` from the last page,
    /// which is the helper's own scan cursor and may sit past the last row it
    /// actually returned.
    var rowid: Int
    /// Rows this chat has contributed so far, over every run.
    var count: Int
    var done: Bool
    /// When it finished, if it has.
    var at: String?

    /// The mark after one page: the helper's cursor, the rows this page added,
    /// and whether the helper says there is more.
    ///
    /// `count` accumulates rather than being recounted, because a resumed
    /// backfill never sees the pages an earlier run already sent. The cursor
    /// never goes backwards either: a helper that answered with a smaller
    /// `next_rowid` than we asked from would otherwise re-read the same page
    /// forever.
    static func after(_ previous: BackfillMark?,
                      sent: Int,
                      nextRowid: Int,
                      hasMore: Bool,
                      at finished: @autoclosure () -> String = Stamp.now()) -> BackfillMark {
        BackfillMark(rowid: max(nextRowid, previous?.rowid ?? nextRowid),
                     count: (previous?.count ?? 0) + sent,
                     done: !hasMore,
                     at: hasMore ? nil : finished())
    }
}

// MARK: - the one decision

/// Why a row did not become an Event. Counted, never logged with a chat on it.
enum Skip: String, Sendable, Equatable {
    case reaction, noGuid, empty, tooLong, notAllowlisted
}

enum Kept: Sendable, Equatable {
    case event(Event)
    case skipped(Skip)
}

enum Normalise {

    /// The most text one event may carry, in UTF-16 units -- section 8.
    static let textLimit = 20_000

    /// One row from the helper, decided and shaped.
    ///
    /// The order of the tests is the order of the reasons: a tapback is not a
    /// message at all, a row with nothing in it is not worth a round trip, and
    /// the allowlist is last because it is the only test whose failure is
    /// counted and reported.
    ///
    /// `allowlist: nil` is the backfill's case, and the only one. A history
    /// page is asked for by chat, and it is asked for because that chat is
    /// allowlisted, so the list has already been consulted by the time a row
    /// gets here. Every other rule still applies: the same tapbacks, the same
    /// empty rows and the same ceiling, decided by the same function rather
    /// than by a second copy of it that could drift.
    static func event(from row: IMsgMessage,
                      allowlist: Allowlist?,
                      directory: [String: ChatRecord] = [:]) -> Kept {

        if row.isReaction == true { return .skipped(.reaction) }

        guard let guid = row.guid, !guid.isEmpty else { return .skipped(.noGuid) }

        let text = row.text ?? ""
        let attachments = (row.attachments ?? []).enumerated().map { at, item in
            Attachment(n: at,
                       filename: item.filename ?? item.transferName ?? "",
                       mimeType: item.mimeType,
                       totalBytes: item.totalBytes,
                       missing: item.missing ?? false,
                       isSticker: item.isSticker == true ? true : nil,
                       originalPath: item.originalPath)
        }
        if text.isEmpty && attachments.isEmpty { return .skipped(.empty) }
        if text.utf16.count > textLimit { return .skipped(.tooLong) }

        let chatGuid = row.chatGuid ?? ""
        let identifier = row.chatIdentifier ?? chatGuid
        if let allowlist,
           !allowlist.mayRead(guid: chatGuid.isEmpty ? nil : chatGuid,
                              identifier: identifier.isEmpty ? nil : identifier) {
            return .skipped(.notAllowlisted)
        }

        let known = directory[chatGuid]
        let name = [row.chatName, known?.name].compactMap { $0 }.first { !$0.isEmpty }

        return .event(Event(
            key: Keys.of(guid),
            guid: guid,
            rowid: row.id ?? 0,
            chatGuid: chatGuid,
            chatKey: Keys.of(chatGuid),
            chatIdentifier: identifier,
            chatName: name,
            isGroup: row.isGroup ?? known?.isGroup ?? chatGuid.contains(";+;"),
            service: Service.of(chatGuid, fallback: known?.service),
            participants: row.participants ?? known?.participants ?? [],
            sender: row.sender ?? "",
            senderName: (row.senderName?.isEmpty ?? true) ? nil : row.senderName,
            isFromMe: row.isFromMe ?? false,
            text: text,
            createdAt: Stamp.normalise(row.createdAt) ?? Stamp.now(),
            attachments: attachments))
    }
}
