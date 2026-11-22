import Foundation

/* The upstream half: rows out of Messages, events into the collector.
 *
 * One session is status → subscribe → stream, and it ends when the helper
 * does. Everything that can go wrong in it is a reason to wait and start
 * another one, never a reason to exit: the Mac sleeps, the Pi reboots, the
 * database gets replaced by a restore, and all three of those are Tuesday.
 *
 * Two cursors, on purpose (section 7). The one in memory advances past every
 * row the helper hands us, kept or dropped, because a row we chose not to send
 * is still a row we have seen. The one on disk only ever moves to a rowid the
 * collector has acknowledged, so a crash re-sends what was in flight and the
 * collector drops what it already holds.
 */
actor Watcher {

    private let core: Core
    private let supervisor: RPCSupervisor
    private let collector: Collector
    private let helper: Helper
    private let log: Log

    private weak var courier: Courier?
    /// Held rather than borrowed: nothing in the uploader points back here.
    private var uploader: Attachments?

    /// Events waiting for a flush, and the newest rowid seen for any reason.
    private var batch: [Event] = []
    private var streamCursor: Int?
    private var flushing = false
    private var lastFlush = Date()
    private var blockedUntil = Date.distantPast
    private var backoff: TimeInterval = 0

    private var live: RPCSession?
    private var subscription: Int?
    private var chatsListedAt = Date.distantPast

    /// How often the batch goes out, and how big it is allowed to get first.
    private static let flushEvery: TimeInterval = 2
    private static let flushAt = 20
    /// Section 8: no more than a hundred events in one post.
    private static let perPost = 100
    private static let chatsEvery: TimeInterval = 300

    init(core: Core, supervisor: RPCSupervisor, collector: Collector, helper: Helper, log: Log) {
        self.core = core
        self.supervisor = supervisor
        self.collector = collector
        self.helper = helper
        self.log = log
    }

    func pair(with courier: Courier) { self.courier = courier }

    func pair(with uploader: Attachments) { self.uploader = uploader }

    /// The config changed, so the chat directory is worth re-reading: a chat
    /// just allowed is a chat the console wants named.
    func allowlistChanged() { chatsListedAt = .distantPast }

    /// Contacts was granted or taken away. The same directory read, for the
    /// other reason: every name in the list was resolved by the helper under
    /// the permission it had at the time, so the answer to "who is this" has
    /// just changed for all of them. Without this the console would keep
    /// showing phone numbers until the five-minute refresh came round.
    func contactsChanged() { chatsListedAt = .distantPast }

    // MARK: - the loop

    func run() async {
        while !Task.isCancelled {
            do {
                try await session()
                backoff = 0
            } catch let trouble as RPCError {
                await core.note(error: trouble.description)
                await core.note(helper: await helper.state)
                log.warn("watch session ended: \(trouble.description)")
                await wait()
            } catch {
                await core.note(error: error.redacted)
                log.warn("watch session ended: \(error.redacted)")
                await wait()
            }
            live = nil
            subscription = nil
        }
    }

    /// Five seconds, doubling, to five minutes, with a little jitter so a Pi
    /// coming back does not meet every retry in the house at once.
    private func wait() async {
        backoff = backoff == 0 ? 5 : min(300, backoff * 2)
        try? await Task.sleep(nanoseconds: UInt64((backoff + Double.random(in: 0...1)) * 1e9))
    }

    private func session() async throws {
        let session = try await supervisor.session()
        live = session
        await core.note(helper: await helper.state)
        let notifications = await session.claimNotifications()

        let status = try await session.call("status")
        let database = status["database"]
        let ready = database?["ready"]?.boolValue ?? false
        await core.note(fda: ready, dbOk: ready)

        guard ready else {
            // No subscription without a database. The child stays up and is
            // asked again in a minute; spawning a new one per attempt would be
            // a spawn loop with a permission dialog at the end of it.
            await core.note(error: "the Messages database is not readable")
            log.warn("the helper cannot open the Messages database — waiting")
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return
        }
        await core.note(error: nil)

        if let path = database?["path"]?.stringValue {
            await core.adopt(database: identity(of: path))
        }
        streamCursor = await core.resumeCursor

        try await listChats(session)

        subscription = try await subscribe(session, since: streamCursor, first: true)

        for await notification in notifications {
            switch notification.method {
            case "message":
                await accept(notification.params, from: subscription)

            case "watch.overflow":
                let params = notification.params
                guard params["subscription"]?.intValue == subscription else { continue }
                let resume = params["resume_after_rowid"]?.intValue ?? streamCursor ?? 0
                log.warn("the watch buffer overflowed — catching up from \(resume)")
                try await backfill(session, from: resume)
                subscription = try await subscribe(session, since: streamCursor, first: false)

            case RPCSession.terminatedMethod:
                return

            default:
                continue
            }
        }
    }

    private func subscribe(_ session: RPCSession, since: Int?, first: Bool) async throws -> Int? {
        // No cursor means no `since_rowid`: a first run starts at now, and
        // enabling the channel never replays a history nobody asked for.
        var params: [String: JSONValue] = ["attachments": .bool(true)]
        if let since { params["since_rowid"] = .int(since) }
        let result = try await session.call("watch.subscribe", params, timeout: first ? 60 : 15)
        let id = result["subscription"]?.intValue
        log.info("watching from \(since.map(String.init) ?? "now")")
        return id
    }

    // MARK: - rows

    private func accept(_ params: JSONValue, from subscription: Int?) async {
        if let subscription, let carried = params["subscription"]?.intValue,
           carried != subscription { return }
        guard let raw = params["message"] else { return }
        await accept(raw)
    }

    private func accept(_ raw: JSONValue) async {
        guard let row = try? raw.decode(IMsgMessage.self) else {
            log.warn("a row from the helper would not decode")
            return
        }
        if streamCursor == nil, let id = row.id { await core.rememberFirstRow(id) }
        let decision = Normalise.event(from: row,
                                       allowlist: await core.allowlist,
                                       directory: await core.directory)
        // No suspension between including a row in the cursor and buffering it.
        if let rowid = row.id { streamCursor = max(streamCursor ?? 0, rowid) }
        switch decision {
        case .event(let event):
            batch.append(event)
            if batch.count >= Self.flushAt { await flush() }
        case .skipped(let why):
            // The reason, and never the chat. A count is what the console is
            // owed; a name would be the thing the allowlist exists to prevent.
            if why == .notAllowlisted { await core.countDropped(1) }
            log.debug("row skipped: \(why.rawValue)")
        }
    }

    /// Everything past a cursor, a page at a time. Used after an overflow,
    /// which is the one case where the stream is known to have lost rows.
    private func backfill(_ session: RPCSession, from rowid: Int) async throws {
        var since = rowid
        var pages = 0
        while pages < 200 {
            pages += 1
            let page = try await session.call(
                "messages.after",
                ["since_rowid": .int(since), "limit": .int(500), "attachments": .bool(true)],
                timeout: 60)
            for raw in page["messages"]?.arrayValue ?? [] { await accept(raw) }
            let next = page["next_rowid"]?.intValue ?? since
            streamCursor = max(streamCursor ?? 0, next)
            // The page is flushed as it is read, so the acknowledged cursor
            // follows next_rowid down the backfill rather than jumping to the
            // end of it if this process dies halfway.
            await flush(force: true)
            since = next
            if !(page["has_more"]?.boolValue ?? false) { break }
        }
    }

    // MARK: - the flush

    /// Called on a tick by the runner: two seconds is the longest an event
    /// waits, and twenty is the most that wait together.
    func tick() async {
        if !batch.isEmpty, Date().timeIntervalSince(lastFlush) >= Self.flushEvery {
            await flush()
        }
        if let live, Date().timeIntervalSince(chatsListedAt) >= Self.chatsEvery,
           await live.isAlive {
            try? await listChats(live)
        }
    }

    private func flush(force: Bool = false) async {
        guard !flushing, force || !batch.isEmpty, Date() >= blockedUntil else { return }
        flushing = true
        defer { flushing = false }

        let policy = await core.allowlist
        let pending = batch.prefix(Self.perPost)
        let count = pending.count
        let slice = pending.filter { policy.mayRead(guid: $0.chatGuid, identifier: $0.chatIdentifier) }
        let whole = count == batch.count
        // When the batch does not fit in one post, the cursor sent is the
        // newest rowid actually in it. Acknowledging further than we have
        // delivered would turn a crash into a gap.
        let cursor = whole ? (streamCursor ?? slice.last?.rowid ?? 0)
                           : (pending.map(\.rowid).max() ?? 0)

        do {
            try await collector.ingest(slice, cursor: cursor, history: false)
            guard await core.acked(cursor: cursor, lastEventAt: slice.last?.createdAt) else {
                throw CocoaError(.fileWriteUnknown)
            }
            batch.removeFirst(count)
            lastFlush = Date()
            backoff = 0
            blockedUntil = .distantPast
            log.info("ingest: \(slice.count) event(s), cursor \(cursor)")
            // After the ack and not before it. An attachment belongs to a
            // message the Pi holds; uploading bytes for a row the collector
            // has not accepted would be a 404 and a wasted read of the disk.
            await uploader?.forwarded(slice, live: true)
            await courier?.poke()
        } catch {
            // The batch stays. Nothing is dropped for a collector being down;
            // it arrives late, which is the whole bargain in section 1.
            backoff = backoff == 0 ? 5 : min(300, backoff * 2)
            blockedUntil = Date().addingTimeInterval(backoff + Double.random(in: 0...1))
            await core.note(error: "ingest failed: \(error.redacted)")
            log.warn("ingest failed, holding \(self.batch.count) event(s): \(error.redacted)")
        }
    }

    // MARK: - the directory

    private func listChats(_ session: RPCSession) async throws {
        let result = try await session.call("chats.list", ["limit": .int(200)], timeout: 60)
        let listed = (result["chats"]?.arrayValue ?? [])
            .compactMap { try? $0.decode(IMsgChat.self) }
        let chats = listed.compactMap(ChatRecord.init)
        // The helper's own rowids travel no further than this process: they
        // are how a history page names a conversation, and nothing else.
        var ids: [String: Int] = [:]
        for chat in listed {
            guard let guid = chat.guid, !guid.isEmpty, let id = chat.id else { continue }
            ids[guid] = id
        }
        await core.adopt(directory: chats, ids: ids)
        chatsListedAt = Date()
        do {
            let body = JSONValue.object([
                "protocol": .int(1),
                "chats": try JSONValue.of(chats),
            ])
            _ = try await collector.post("/v1/messages/chats", body)
            log.info("chats: \(chats.count) posted")
        } catch {
            log.warn("chats post failed: \(error.redacted)")
        }
    }

    /// Which database file this is, as well as we can tell it.
    ///
    /// The path alone is not enough -- a restore puts a different database at
    /// the same path -- so the inode and the birth time go in with it. Without
    /// Full Disk Access we cannot stat the file at all, and the path is then
    /// the whole of the answer.
    private func identity(of path: String) -> String {
        var parts = [path]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            if let inode = attributes[.systemFileNumber] as? Int { parts.append("i\(inode)") }
            if let born = attributes[.creationDate] as? Date {
                parts.append("b\(Int(born.timeIntervalSince1970))")
            }
        }
        return parts.joined(separator: "|")
    }

    /// Last words before the process goes: whatever is in hand, and a polite
    /// end to the subscription.
    func drain() async {
        if !batch.isEmpty { await flush() }
        if let live, let subscription, await live.isAlive {
            _ = try? await live.call("watch.unsubscribe", ["subscription": .int(subscription)],
                                     timeout: 5)
        }
    }
}
