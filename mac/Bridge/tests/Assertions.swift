import Foundation

/* The parts of the Bridge that are pure, checked without a build system.
 *
 * Compiled and run by run-units.sh against the same four source files the app
 * uses -- framing, records, keys, the allowlist decision. Everything else in
 * the program is a loop around one of these, so this is where a wrong field
 * name or a wrong prefix length is caught.
 */

@main
enum Units {

    nonisolated(unsafe) static var failures: [String] = []

    static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        print((passed ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        if !passed { failures.append(name) }
    }

    static func same<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, got == want ? "" : "got \(got), want \(want)")
    }

    // MARK: - fixtures

    static let allowedGuid = "iMessage;-;+14085550142"
    static let otherGuid = "iMessage;+;chat8291"
    static let messageGuid = "5B0A9E5C-1111-4A00-9E11-000000000102"

    /// One row shaped the way docs/json.md says imsg shapes them.
    static let sampleRow = """
        {"id":102,"chat_id":7,"chat_identifier":"+14085550142",
         "chat_guid":"iMessage;-;+14085550142","chat_name":"Nadia Sorin",
         "participants":["+14085550142"],"is_group":false,
         "guid":"5B0A9E5C-1111-4A00-9E11-000000000102","sender":"+14085550142",
         "sender_name":"Nadia Sorin","is_from_me":false,
         "text":"are we still on for 6? I can grab the table",
         "created_at":"2026-08-21T21:02:11Z",
         "attachments":[{"filename":"IMG_0412.heic","transfer_name":"IMG_0412.heic",
                         "uti":"public.heic","mime_type":"image/heic","total_bytes":1820331,
                         "is_sticker":false,"missing":false,
                         "original_path":"/Users/somebody/Library/Messages/Attachments/aa/00/IMG_0412.heic"}],
         "is_read":false}
        """

    static let config = JSONValue.object([
        "updated_at": .string("2026-08-21T21:00:00Z"),
        "chats": .object([
            allowedGuid: .object(["read": .bool(true), "send": .string("confirm"),
                                  "name": .string("Nadia Sorin")]),
            otherGuid: .object(["read": .bool(false), "send": .string("off"),
                                "name": .string("Roommates")]),
        ]),
    ])

    static func row(_ json: String) -> IMsgMessage {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            .decode(IMsgMessage.self)
    }

    /// One conversation, decoded the way a `chats.list` reply is, so the
    /// snake_case in these fixtures is the same trip the helper's answer takes.
    static func chat(_ json: String) -> IMsgChat {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            .decode(IMsgChat.self)
    }

    static func main() {
        framing()
        splitting()
        keys()
        normalising()
        naming()
        backfilling()
        allowlisting()
        uploading()
        heartbeating()
        print()
        print("\(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - framing

    static func framing() {
        print("— JSON-RPC framing")

        let withParams = try! RPCRequest(id: 4, method: "chats.list",
                                         params: ["limit": .int(200)]).line()
        let text = String(decoding: withParams, as: UTF8.self)
        check("a request is one line", text.hasSuffix("\n") && text.dropLast().contains("\n") == false)
        check("it carries jsonrpc, id and method",
              text.contains("\"jsonrpc\":\"2.0\"") && text.contains("\"id\":4")
                  && text.contains("\"method\":\"chats.list\""))
        check("params are carried when there are any", text.contains("\"limit\":200"))

        let bare = try! RPCRequest(id: 5, method: "status", params: nil).line()
        check("params are left out when there are none",
              !String(decoding: bare, as: UTF8.self).contains("params"))
        let empty = try! RPCRequest(id: 6, method: "status", params: [:]).line()
        check("an empty params object is left out too",
              !String(decoding: empty, as: UTF8.self).contains("params"))

        let result = try! RPCFrame.decode(Data(
            #"{"jsonrpc":"2.0","id":4,"result":{"subscription":1}}"#.utf8))
        if case .result(let id, let value) = result {
            same("a result decodes to its id", id, 4)
            same("and its value", value["subscription"]?.intValue ?? 0, 1)
        } else {
            check("a result decodes as a result", false, "\(result)")
        }

        let failure = try! RPCFrame.decode(Data(
            #"{"jsonrpc":"2.0","id":9,"error":{"code":-32001,"message":"uncertain","data":{"disposition":"may_have_completed","retry_safe":false}}}"#.utf8))
        if case .failure(let id, let code, let message, let data) = failure {
            same("an error decodes to its id", id, 9)
            same("its code", code, -32001)
            same("its message", message, "uncertain")
            same("and its disposition", data?["disposition"]?.stringValue ?? "", "may_have_completed")
        } else {
            check("an error decodes as a failure", false, "\(failure)")
        }

        let notification = try! RPCFrame.decode(Data(
            #"{"jsonrpc":"2.0","method":"message","params":{"subscription":1}}"#.utf8))
        if case .notification(let method, let params) = notification {
            same("a method with no id is a notification", method, "message")
            same("with its params", params["subscription"]?.intValue ?? 0, 1)
        } else {
            check("a method with no id is a notification", false, "\(notification)")
        }

        let nullId = try! RPCFrame.decode(Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        same("a framing error with a null id pairs with nothing", nullId, .unpaired)

        let overflow = try! RPCFrame.decode(Data(
            #"{"jsonrpc":"2.0","method":"watch.overflow","params":{"subscription":1,"resume_after_rowid":9000,"terminal":true}}"#.utf8))
        if case .notification(let method, let params) = overflow {
            same("overflow is a notification", method, "watch.overflow")
            same("carrying where to resume", params["resume_after_rowid"]?.intValue ?? 0, 9000)
        } else {
            check("overflow is a notification", false, "\(overflow)")
        }

        var malformed = false
        do { _ = try RPCFrame.decode(Data("not json".utf8)) } catch { malformed = true }
        check("a line that is not JSON is refused", malformed)
    }

    static func splitting() {
        print("— lines")
        var splitter = LineSplitter()
        let two = try! splitter.push(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        same("two whole lines in one chunk", two.count, 2)

        var partial = LineSplitter()
        same("half a line is not a line", try! partial.push(Data("{\"a\":".utf8)).count, 0)
        let joined = try! partial.push(Data("1}\n".utf8))
        same("the other half completes it", joined.count, 1)
        same("and it is the whole line", String(decoding: joined[0], as: UTF8.self), "{\"a\":1}")

        var blank = LineSplitter()
        same("empty lines are not lines", try! blank.push(Data("\n\n".utf8)).count, 0)

        var runaway = LineSplitter()
        var threw = false
        do {
            _ = try runaway.push(Data(repeating: 0x41, count: LineSplitter.cap + 1))
        } catch {
            threw = error as? RPCFrameError == .lineTooLong
        }
        check("a line with no end to it is refused", threw)
    }

    // MARK: - keys

    static func keys() {
        print("— keys")
        same("a message key is sha256(guid)[:16]", Keys.of(messageGuid), "ea7b6b628ef7db77")
        same("a chat key is sha256(chat_guid)[:16]", Keys.of(allowedGuid), "a3ce320ae80d4efe")
        same("the other chat's key", Keys.of(otherGuid), "6c281cb5620022c7")
        let key = Keys.of("anything at all")
        check("a key is sixteen lowercase hex", key.count == 16
            && key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - events

    static func normalising() {
        print("— events")
        let allowlist = Allowlist(config)

        guard case .event(let event) = Normalise.event(from: row(sampleRow),
                                                       allowlist: allowlist) else {
            check("an allowlisted row becomes an event", false)
            return
        }
        check("an allowlisted row becomes an event", true)
        same("key", event.key, "ea7b6b628ef7db77")
        same("guid", event.guid, messageGuid)
        same("rowid", event.rowid, 102)
        same("chat_guid", event.chatGuid, allowedGuid)
        same("chat_key", event.chatKey, "a3ce320ae80d4efe")
        same("chat_identifier", event.chatIdentifier, "+14085550142")
        same("chat_name", event.chatName ?? "", "Nadia Sorin")
        same("is_group", event.isGroup, false)
        same("service, from the chat guid", event.service, "iMessage")
        same("participants", event.participants, ["+14085550142"])
        same("sender", event.sender, "+14085550142")
        same("sender_name", event.senderName ?? "", "Nadia Sorin")
        same("is_from_me", event.isFromMe, false)
        same("text", event.text, "are we still on for 6? I can grab the table")
        same("created_at is UTC with milliseconds", event.createdAt, "2026-08-21T21:02:11.000Z")
        same("one attachment", event.attachments.count, 1)
        same("its position", event.attachments.first?.n ?? -1, 0)
        same("its filename", event.attachments.first?.filename ?? "", "IMG_0412.heic")
        same("its type", event.attachments.first?.mimeType ?? "", "image/heic")
        same("its size", event.attachments.first?.totalBytes ?? 0, 1_820_331)
        same("and whether it is on disk", event.attachments.first?.missing ?? true, false)
        same("the path is kept for the uploader",
             event.attachments.first?.originalPath ?? "",
             "/Users/somebody/Library/Messages/Attachments/aa/00/IMG_0412.heic")

        // And is not on the wire. Section 4: the Pi has no use for a path in
        // somebody's home directory and is never given one.
        let onTheWire = try! JSONValue.of(event)
        let sent = onTheWire["attachments"]?.arrayValue?.first
        same("the wire carries the position", sent?["n"]?.intValue ?? -1, 0)
        same("and the type under its own name",
             sent?["mime_type"]?.stringValue ?? "", "image/heic")
        check("and no path at all", sent?["original_path"] == nil)
        check("nor a sticker flag on something that is not one",
              sent?["is_sticker"] == nil)

        let sticker = row(sampleRow.replacingOccurrences(
            of: "\"is_sticker\":false", with: "\"is_sticker\":true"))
        if case .event(let stuck) = Normalise.event(from: sticker, allowlist: allowlist) {
            same("a sticker says so", stuck.attachments.first?.isSticker ?? false, true)
            same("and says so on the wire",
                 (try! JSONValue.of(stuck))["attachments"]?.arrayValue?
                     .first?["is_sticker"]?.boolValue ?? false, true)
        } else {
            check("a sticker says so", false)
        }

        let pair = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)","text":"two of them",
             "attachments":[{"filename":"a.png","mime_type":"image/png",
                             "total_bytes":10,"original_path":"/tmp/a.png"},
                            {"filename":"b.mov","mime_type":"video/quicktime",
                             "total_bytes":20,"original_path":"/tmp/b.mov"}]}
            """)
        if case .event(let two) = Normalise.event(from: pair, allowlist: allowlist) {
            same("two attachments are numbered by where they are",
                 two.attachments.map(\.n), [0, 1])
        } else {
            check("two attachments are numbered by where they are", false)
        }

        let directory = [allowedGuid: ChatRecord(IMsgChat(guid: allowedGuid,
                                                          identifier: "+14085550142",
                                                          name: "Nadia Sorin",
                                                          isGroup: false,
                                                          service: "SMS",
                                                          participants: ["+14085550142"],
                                                          lastMessageAt: nil))!]
        if case .event(let sms) = Normalise.event(from: row(sampleRow), allowlist: allowlist,
                                                  directory: directory) {
            same("the directory's service wins when there is one", sms.service, "SMS")
        } else {
            check("the directory's service wins when there is one", false)
        }

        let reaction = row(sampleRow.replacingOccurrences(
            of: "\"is_read\":false", with: "\"is_reaction\":true"))
        same("a tapback is not an event",
             Normalise.event(from: reaction, allowlist: allowlist), .skipped(.reaction))

        let noGuid = row(sampleRow.replacingOccurrences(of: messageGuid, with: ""))
        same("a row with no guid is not an event",
             Normalise.event(from: noGuid, allowlist: allowlist), .skipped(.noGuid))

        let hollow = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)","text":"","attachments":[]}
            """)
        same("nothing to say and nothing attached is not an event",
             Normalise.event(from: hollow, allowlist: allowlist), .skipped(.empty))

        let picture = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)","text":"",
             "attachments":[{"filename":"IMG_1.heic","missing":false}]}
            """)
        if case .event(let kept) = Normalise.event(from: picture, allowlist: allowlist) {
            same("a picture with no words is still an event", kept.attachments.count, 1)
        } else {
            check("a picture with no words is still an event", false)
        }

        let shout = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)",
             "text":"\(String(repeating: "a", count: Normalise.textLimit + 1))"}
            """)
        same("more than twenty thousand characters is not an event",
             Normalise.event(from: shout, allowlist: allowlist), .skipped(.tooLong))

        let elsewhere = row(sampleRow.replacingOccurrences(of: allowedGuid, with: otherGuid))
        same("a chat that is not allowlisted is not an event",
             Normalise.event(from: elsewhere, allowlist: allowlist), .skipped(.notAllowlisted))

        let unknown = row(sampleRow.replacingOccurrences(of: allowedGuid,
                                                         with: "iMessage;-;+15550000000"))
        same("a chat nobody has decided about is not an event",
             Normalise.event(from: unknown, allowlist: allowlist), .skipped(.notAllowlisted))
    }

    // MARK: - what a conversation is called

    /// The name chain in section 4: a group's own title, then any display
    /// name, then the Contacts match, then nothing at all.
    ///
    /// The last rung matters as much as the first. The helper's own `name`
    /// falls back to the raw handle, and a conversation called +14085550142 is
    /// precisely what the Contacts grant exists to prevent, so nothing is
    /// better than a number wearing a person's slot.
    static func naming() {
        print("— what a conversation is called")

        let named = ChatRecord(chat("""
            {"id":7,"guid":"\(allowedGuid)","identifier":"+14085550142",
             "name":"Nadia Sorin","display_name":"","contact_name":"Nadia Sorin",
             "is_group":false,"service":"iMessage","participants":["+14085550142"]}
            """))!
        same("Contacts names a chat with no title of its own",
             named.name ?? "", "Nadia Sorin")
        same("and the match is carried in its own right",
             named.contactName ?? "", "Nadia Sorin")

        let group = ChatRecord(chat("""
            {"id":12,"guid":"\(otherGuid)","identifier":"chat8291",
             "name":"Roommates","display_name":"Roommates","is_group":true,
             "service":"iMessage","participants":["+14085550188"]}
            """))!
        same("a group is called what the group is called", group.name ?? "", "Roommates")
        check("and has no Contacts match to carry", group.contactName == nil,
              group.contactName ?? "nil")

        let titled = ChatRecord(chat("""
            {"id":8,"guid":"\(allowedGuid)","identifier":"+14085550142",
             "display_name":"Dinner plans","contact_name":"Nadia Sorin",
             "is_group":false,"service":"iMessage"}
            """))!
        same("a title the user set beats the address book",
             titled.name ?? "", "Dinner plans")
        same("which does not stop the match being carried",
             titled.contactName ?? "", "Nadia Sorin")

        let bare = ChatRecord(chat("""
            {"id":9,"guid":"\(allowedGuid)","identifier":"+14085550142",
             "name":"+14085550142","display_name":"","contact_name":"",
             "is_group":false,"service":"iMessage"}
            """))!
        check("with nothing to go on a chat is nameless rather than a number",
              bare.name == nil, bare.name ?? "nil")
        check("and an empty match is no match", bare.contactName == nil,
              bare.contactName ?? "nil")

        let wire = try! JSONValue.of(named)
        same("the match travels as contact_name",
             wire["contact_name"]?.stringValue ?? "", "Nadia Sorin")
    }

    // MARK: - reading a history

    /// The page arithmetic, and the one rule the history does not share with
    /// the stream.
    static func backfilling() {
        print("— reading a history")

        let first = BackfillMark.after(nil, sent: 2, nextRowid: 43, hasMore: true,
                                       at: "2026-08-21T00:00:00.000Z")
        same("a first page starts the count", first.count, 2)
        same("and resumes from the helper's cursor", first.rowid, 43)
        check("a page with more behind it is not done", !first.done)
        check("and has no finish to record", first.at == nil, first.at ?? "nil")

        let last = BackfillMark.after(first, sent: 2, nextRowid: 45, hasMore: false,
                                      at: "2026-08-21T00:00:01.000Z")
        same("the next page adds to the count rather than replacing it",
             last.count, 4)
        same("the cursor moves on", last.rowid, 45)
        check("no more pages is done", last.done)
        same("and the moment is kept", last.at ?? "", "2026-08-21T00:00:01.000Z")

        // A resumed backfill never sees the pages an earlier run sent, so the
        // count has to accumulate onto what the file already held.
        let held = BackfillMark(rowid: 45, count: 1_240, done: false, at: nil)
        let resumed = BackfillMark.after(held, sent: 60, nextRowid: 105,
                                         hasMore: true, at: "x")
        same("a resume adds to what the file already held", resumed.count, 1_300)
        same("and carries on from where the helper is now", resumed.rowid, 105)

        // A helper that answered with a cursor behind the one we asked from
        // would otherwise have this loop reading the same page until the
        // ceiling stopped it.
        let backwards = BackfillMark.after(held, sent: 0, nextRowid: 12,
                                           hasMore: true, at: "x")
        same("a cursor that went backwards is not taken", backwards.rowid, 45)

        // The rules the stream drops rows by are the same rules here. The
        // allowlist is the only one that is not, because a page is asked for
        // by chat and asking is what checked it.
        let reaction = row(sampleRow.replacingOccurrences(
            of: "\"is_read\":false", with: "\"is_reaction\":true"))
        same("a tapback in a history page is still not an event",
             Normalise.event(from: reaction, allowlist: nil), .skipped(.reaction))

        let hollow = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)","text":"","attachments":[]}
            """)
        same("an empty history row is still not an event",
             Normalise.event(from: hollow, allowlist: nil), .skipped(.empty))

        let shout = row("""
            {"id":9,"guid":"G","chat_guid":"\(allowedGuid)",
             "text":"\(String(repeating: "a", count: Normalise.textLimit + 1))"}
            """)
        same("and the ceiling still applies",
             Normalise.event(from: shout, allowlist: nil), .skipped(.tooLong))

        let noGuid = row(sampleRow.replacingOccurrences(of: messageGuid, with: ""))
        same("a history row with no guid is still not an event",
             Normalise.event(from: noGuid, allowlist: nil), .skipped(.noGuid))

        // The exception, and the whole reason the parameter is optional: this
        // row is from the chat the allowlist refuses, and a history page of it
        // is only ever asked for because the chat was allowed.
        let elsewhere = row(sampleRow.replacingOccurrences(of: allowedGuid,
                                                          with: otherGuid))
        same("a row the stream would drop for its chat is kept in a page",
             Normalise.event(from: elsewhere, allowlist: Allowlist(config)),
             .skipped(.notAllowlisted))
        if case .event(let kept) = Normalise.event(from: elsewhere, allowlist: nil) {
            same("because the page itself is the permission", kept.chatGuid, otherGuid)
        } else {
            check("because the page itself is the permission", false)
        }
    }

    // MARK: - the allowlist

    static func allowlisting() {
        print("— the allowlist")
        let allowlist = Allowlist(config)
        same("it remembers when it was written", allowlist.updatedAt ?? "",
             "2026-08-21T21:00:00Z")
        same("two chats", allowlist.byGuid.count, 2)
        check("read is read", allowlist.mayRead(guid: allowedGuid))
        check("and off is off", !allowlist.mayRead(guid: otherGuid))
        check("a chat it has never heard of may not be read",
              !allowlist.mayRead(guid: "iMessage;-;+15550000000"))
        same("the policy comes back whole",
             allowlist.policy(guid: allowedGuid)?.send ?? "", "confirm")
        same("and can be found by chat key",
             allowlist.policy(guid: nil, key: Keys.of(allowedGuid))?.send ?? "", "confirm")
        check("a guid with an underscore survives being parsed",
              Allowlist(.object(["chats": .object(["iMessage;+;chat_a_b":
                  .object(["read": .bool(true), "send": .string("confirm")])])]))
                  .mayRead(guid: "iMessage;+;chat_a_b"))
    }

    // MARK: - the bytes

    /// One attachment, as the helper describes it, with whatever this test
    /// wants to say about it.
    static func attached(mime: String? = "image/heic", bytes: Int? = 1_000,
                         missing: Bool = false, path: String? = "/tmp/x.heic",
                         name: String = "IMG_0412.heic") -> Attachment {
        Attachment(n: 0, filename: name, mimeType: mime, totalBytes: bytes,
                   missing: missing, isSticker: nil, originalPath: path)
    }

    static func uploading() {
        print("— uploading")

        // The digest, against an answer that does not come from this program.
        same("sha256 of \"abc\"", Digest.hex(Data("abc".utf8)),
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        same("and of nothing at all", Digest.hex(Data()),
             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        // The same answer read off a disk, in pieces bigger than one chunk, so
        // the loop that keeps a video out of memory is the loop under test.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("charon-units-\(UUID().uuidString).bin")
        let blob = Data(repeating: 0x61, count: Digest.chunk * 2 + 17)
        try? blob.write(to: scratch)
        let read = Digest.ofFile(at: scratch)
        same("a file hashes to the same thing its bytes do", read?.hex ?? "",
             Digest.hex(blob))
        same("and is counted while it is read", read?.bytes ?? 0, blob.count)
        try? FileManager.default.removeItem(at: scratch)
        check("a file that is not there has no digest",
              Digest.ofFile(at: scratch) == nil)

        // What goes without being asked. Section 7, one clause at a time.
        check("a small photograph goes on its own",
              Uploads.automatic(attached()))
        check("a video does not", !Uploads.automatic(attached(mime: "video/quicktime")))
        check("nor a file", !Uploads.automatic(attached(mime: "application/pdf")))
        check("nor an image with no type on it", !Uploads.automatic(attached(mime: nil)))
        check("an image at the ceiling still goes",
              Uploads.automatic(attached(bytes: Uploads.automaticLimit)))
        check("and one byte over it does not",
              !Uploads.automatic(attached(bytes: Uploads.automaticLimit + 1)))
        check("a size nobody stated is not under the ceiling",
              !Uploads.automatic(attached(bytes: nil)))
        check("a file Messages has aged out is not sent",
              !Uploads.automatic(attached(missing: true)))
        check("nor one with no path to read it from",
              !Uploads.automatic(attached(path: "")))
        check("the type is read without regard to case",
              Uploads.automatic(attached(mime: "IMAGE/HEIC")))
        same("the wire's own ceiling is two and a half times it",
             Uploads.wireLimit, 25 * 1024 * 1024)

        // The name that goes in a header. The collector rebuilds it again from
        // the same alphabet; this is the copy that keeps the header legal.
        same("an ordinary name is left alone",
             Uploads.headerName("IMG_0412.heic", n: 0), "IMG_0412.heic")
        same("a path is not a name", Uploads.headerName("../../etc/passwd", n: 0),
             "etc-passwd")
        same("a quote cannot end the parameter early",
             Uploads.headerName("she said \"hi\".png", n: 0), "she-said-hi-.png")
        same("a newline cannot start a second header",
             Uploads.headerName("one\r\nX-Evil: yes.png", n: 0), "one-X-Evil-yes.png")
        same("anything outside ASCII becomes a hyphen",
             Uploads.headerName("café ☕.png", n: 3), "caf-.png")
        same("a run of them becomes one hyphen",
             Uploads.headerName("a???????b.png", n: 0), "a-b.png")
        same("nothing survives, so it is called what the far end would call it",
             Uploads.headerName("☕☕☕", n: 4), "attachment-4")
        same("and an absent name the same way",
             Uploads.headerName(nil, n: 2), "attachment-2")
        same("a very long name is cut, not refused",
             Uploads.headerName(String(repeating: "a", count: 300), n: 0).count,
             Uploads.nameLimit)

        // What one cycle is allowed to say about all of it.
        same("bytes", Uploads.size(512), "512 B")
        same("kilobytes", Uploads.size(4_096), "4 KB")
        same("megabytes", Uploads.size(3_250_586), "3.1 MB")

        // The list the Bridge is handed back, as section 5 writes it.
        let item = try! JSONDecoder().decode(JSONValue.self, from: Data("""
            {"key":"ea7b6b628ef7db77","n":1,"guid":"G","rowid":184220,
             "chat_guid":"\(allowedGuid)","filename":"IMG_0413.mov",
             "mime_type":"video/quicktime","total_bytes":12000000}
            """.utf8)).decode(WantedAttachment.self)
        same("a wanted item names the message", item.key, "ea7b6b628ef7db77")
        same("and which of its files", item.n, 1)
        same("and the row to find it by", item.rowid ?? 0, 184_220)
        same("and the conversation that row is in", item.chatGuid ?? "", allowedGuid)
        same("and what it is", item.mimeType ?? "", "video/quicktime")
    }

    // MARK: - the heartbeat

    static func heartbeating() {
        print("— the heartbeat")
        let beat = Heartbeat(version: "0.1.0", host: "example-mbp",
                             helper: .init(version: "0.14.1", state: .verified),
                             fda: true, automation: false, dbOk: true,
                             cursor: nil, lastEventAt: nil,
                             droppedNotAllowlisted: 31, lastError: nil)
        let encoded = try! JSONValue.of(beat)
        same("it says which protocol it speaks", encoded["protocol"]?.intValue ?? 0, 1)
        same("the helper is nested", encoded["helper"]?["state"]?.stringValue ?? "", "verified")
        same("db_ok keeps its name", encoded["db_ok"]?.boolValue ?? false, true)
        same("dropped keeps its name", encoded["dropped_not_allowlisted"]?.intValue ?? 0, 31)
        same("no cursor is written as null", encoded["cursor"] ?? .string("missing"), .null)
        same("and no error is null rather than absent",
             encoded["last_error"] ?? .string("missing"), .null)

        // The two newer fields go the other way. They are additions to
        // section 4, so a collector that has no row for them should see the
        // heartbeat it already knows rather than two nulls it cannot place.
        check("nothing to say about Contacts leaves the field out",
              encoded["contacts"] == nil)
        check("and nothing to say about a history leaves that one out",
              encoded["backfill"] == nil)

        check("and nothing to say about the uploads leaves that one out too",
              encoded["attachments"] == nil)

        var telling = beat
        telling.contacts = true
        telling.backfill = BackfillProgress(pending: 2, done: 1, rows: 1_240)
        telling.attachments = AttachmentProgress(uploaded: 2, pending: 1, failed: 0)
        let full = try! JSONValue.of(telling)
        same("a granted Contacts is reported", full["contacts"]?.boolValue ?? false, true)
        same("with the chats still owed a history",
             full["backfill"]?["pending"]?.intValue ?? 0, 2)
        same("the ones that are done", full["backfill"]?["done"]?.intValue ?? 0, 1)
        same("and every row they have sent",
             full["backfill"]?["rows"]?.intValue ?? 0, 1_240)
        same("the uploads are counted too",
             full["attachments"]?["uploaded"]?.intValue ?? 0, 2)
        same("with what is still owed", full["attachments"]?["pending"]?.intValue ?? 0, 1)
        same("and what was refused", full["attachments"]?["failed"]?.intValue ?? -1, 0)
    }
}
