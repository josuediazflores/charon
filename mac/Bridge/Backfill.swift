import Foundation

/* The history of a chat the user has just allowed, read once, in pages.
 *
 * The stream starts at now (section 7) and that is still true: turning the
 * channel on does not replay anything by itself. Allowing one conversation
 * does, for that conversation only, and exactly once. The rows arrive on the
 * Pi already read and are never queued for triage, because a verdict on a text
 * from March is a model telling somebody about their own past.
 *
 * Three rules hold this apart from the live stream:
 *
 *   The cursor is not touched. Not the one on disk, not the one in the
 *   watcher's memory, and not the `cursor_ack` a history post comes back with.
 *   A page of old rows says nothing about where the present is.
 *
 *   The live watch is not starved. Pages go through the same RPC child as the
 *   stream, which interleaves notifications with answers on its own, and a
 *   pause between posts keeps a long history from becoming the only thing the
 *   collector hears.
 *
 *   Progress is written after every page. A backfill can be tens of thousands
 *   of rows; a Bridge that stops in the middle of one resumes from the mark
 *   rather than starting the conversation again.
 */
actor Backfill {

    private let core: Core
    private let supervisor: RPCSupervisor
    private let collector: Collector
    private let log: Log
    /// The uploader, told what went past so a want on a nine-year-old
    /// photograph can be answered without asking the database again. Nothing
    /// of a history is uploaded on its own -- section 7.
    private var uploader: Attachments?

    /// Chats still owed a history, quietest first, and the one being read now.
    private var queue: [String] = []
    private var current: String?
    private var running = false
    private var runner: Task<Void, Never>?
    private var blockedUntil = Date.distantPast

    /// The most rows one page may carry, and the most events one post may
    /// (section 8).
    private static let pageLimit = 500
    private static let perPost = 100
    /// A breath between posts, so a long history stays a background noise
    /// rather than a flood the live stream has to queue behind.
    private static let betweenPosts: UInt64 = 150_000_000
    /// Two million rows is more history than the database holds. A ceiling
    /// here is not a limit, it is the promise that this loop ends.
    private static let pageCeiling = 4_000
    /// How long a chat that failed or stalled is left alone before the next
    /// attempt. The config is fetched every few seconds and every fetch asks
    /// this actor again; without a pause, a helper that is down would be a
    /// warning in the log every three seconds.
    private static let coolOff: TimeInterval = 300

    init(core: Core, supervisor: RPCSupervisor, collector: Collector, log: Log) {
        self.core = core
        self.supervisor = supervisor
        self.collector = collector
        self.log = log
    }

    func pair(with uploader: Attachments) { self.uploader = uploader }

    // MARK: - what the config asks for

    /// The allowlist as the collector last served it.
    ///
    /// Called after every config fetch, which is what makes a chat switched on
    /// in Charon start arriving here within seconds rather than at the next
    /// launch. Chats already marked done are not candidates; the mark is the
    /// only record that a history has been read, and it outlives the process.
    func consider(_ allowlist: Allowlist) async {
        let marks = await core.backfill
        let directory = await core.directory

        var waiting: [(guid: String, quiet: String)] = []
        for (guid, policy) in allowlist.byGuid where policy.read {
            if marks[guid]?.done == true { continue }
            waiting.append((guid, directory[guid]?.lastMessageAt ?? ""))
        }
        // Oldest conversation first. One chat at a time either way, and the
        // one nobody has written in for a year is the one whose history is
        // least likely to be wanted this minute.
        queue = waiting
            .sorted { $0.quiet == $1.quiet ? $0.guid < $1.guid : $0.quiet < $1.quiet }
            .map(\.guid)
            .filter { $0 != current }

        guard !queue.isEmpty, !running, Date() >= blockedUntil else { return }
        running = true
        runner = Task { await self.drain() }
    }

    /// The process is going. Whatever page is in flight is abandoned; the mark
    /// on disk is the last one that landed, which is where the next run picks
    /// the conversation up.
    func stop() {
        runner?.cancel()
        runner = nil
    }

    // MARK: - the loop

    private func drain() async {
        defer { running = false }
        while !Task.isCancelled, !queue.isEmpty {
            let guid = queue.removeFirst()
            current = guid
            do {
                try await history(of: guid)
            } catch is CancellationError {
                current = nil
                continue
            } catch {
                log.warn("backfill \(Keys.of(guid)) stopped: \(error.redacted)")
            }
            current = nil
            // Finished chats leave through their mark. Anything else waits,
            // so a conversation that cannot be read is not read again in three
            // seconds, and again three seconds after that.
            if await core.backfill[guid]?.done != true {
                blockedUntil = Date().addingTimeInterval(Self.coolOff)
                return
            }
        }
    }

    /// One conversation, from its mark to the end of it.
    private func history(of chatGuid: String) async throws {
        var mark = await core.backfill[chatGuid]
        if mark?.done == true { return }

        try await requireRead(chatGuid)
        let key = Keys.of(chatGuid)
        guard let chatId = try await chatId(of: chatGuid) else {
            log.warn("backfill \(key): the helper does not list this chat")
            return
        }

        var since = mark?.rowid ?? 0
        var pages = 0
        var sent = 0
        var backoff: TimeInterval = 0

        while !Task.isCancelled, pages < Self.pageCeiling {
            let session = try await supervisor.session()
            try await requireRead(chatGuid)
            let page = try await session.call("messages.after", [
                "since_rowid": .int(since),
                "chat_id": .int(chatId),
                "limit": .int(Self.pageLimit),
                "include_reactions": .bool(false),
            ], timeout: 60)

            let next = page["next_rowid"]?.intValue ?? since
            let more = page["has_more"]?.boolValue ?? false
            let events = await shape(page["messages"]?.arrayValue ?? [], for: chatGuid)

            do {
                try await deliver(events, for: chatGuid)
                backoff = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The page stays unacknowledged and is asked for again. The
                // collector dedupes by key, so a post that half landed costs
                // duplicates rather than a gap.
                backoff = backoff == 0 ? 5 : min(300, backoff * 2)
                log.warn("backfill \(key): a page did not land, holding: \(error.redacted)")
                try? await Task.sleep(
                    nanoseconds: UInt64((backoff + Double.random(in: 0...1)) * 1e9))
                continue
            }

            pages += 1
            sent += events.count
            let moved = BackfillMark.after(mark, sent: events.count,
                                           nextRowid: next, hasMore: more)
            try await requireRead(chatGuid)
            guard await core.mark(backfill: chatGuid, moved) else {
                throw CocoaError(.fileWriteUnknown)
            }
            mark = moved

            if !more { break }
            if next <= since {
                // The helper's scan cursor is authoritative and is supposed to
                // move. One that does not would be this loop asking the same
                // question until the ceiling, so it stops and the next run
                // asks again from the same place.
                log.warn("backfill \(key): the helper's cursor stopped moving, "
                    + "leaving the rest for the next run")
                break
            }
            since = next
        }

        log.info("backfill \(key): \(Self.grouped(sent)) rows in \(pages) page(s)")
    }

    // MARK: - rows

    private func requireRead(_ guid: String) async throws {
        guard !Task.isCancelled, await core.allowlist.mayRead(guid: guid) else {
            throw CancellationError()
        }
    }

    /// Only rows belonging to the requested chat can be part of this history.
    private func shape(_ rows: [JSONValue], for guid: String) async -> [Event] {
        let directory = await core.directory
        var events: [Event] = []
        events.reserveCapacity(rows.count)
        for raw in rows {
            guard let row = try? raw.decode(IMsgMessage.self) else {
                log.warn("a history row from the helper would not decode")
                continue
            }
            guard row.chatGuid == guid else { continue }
            switch Normalise.event(from: row, allowlist: nil, directory: directory) {
            case .event(let event): events.append(event)
            case .skipped(let why): log.debug("history row skipped: \(why.rawValue)")
            }
        }
        return events
    }

    /// One page's events, in posts of at most a hundred.
    private func deliver(_ events: [Event], for guid: String) async throws {
        guard !events.isEmpty else { return }
        var rest = events[...]
        while !rest.isEmpty {
            let slice = Array(rest.prefix(Self.perPost))
            rest = rest.dropFirst(slice.count)
            // The live cursor exactly as it stands, or null when there is not
            // one yet. It is sent so the collector has something to echo and
            // is never advanced by anything on this path.
            let cursor = await core.cursor
            try await requireRead(guid)
            try await collector.ingest(slice, cursor: cursor, history: true)
            try await requireRead(guid)
            await uploader?.forwarded(slice, live: false)
            try? await Task.sleep(nanoseconds: Self.betweenPosts)
        }
    }

    // MARK: - the handle a page is asked for by

    /// The helper's chat rowid for a GUID, from the last directory read or
    /// from a fresh one. Only the rowids are taken from it: the directory the
    /// collector is told about belongs to the watcher, which posts it.
    private func chatId(of guid: String) async throws -> Int? {
        if let known = await core.chatIds[guid] { return known }
        let session = try await supervisor.session()
        let result = try await session.call("chats.list", ["limit": .int(200)], timeout: 60)
        var ids: [String: Int] = [:]
        for raw in result["chats"]?.arrayValue ?? [] {
            guard let chat = try? raw.decode(IMsgChat.self),
                  let listed = chat.guid, !listed.isEmpty, let id = chat.id
            else { continue }
            ids[listed] = id
        }
        await core.adopt(chatIds: ids)
        return ids[guid]
    }

    /// A count with thousands separators, the same in every locale a log might
    /// be read in.
    private static func grouped(_ count: Int) -> String {
        let digits = String(count)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (place, digit) in digits.enumerated() {
            if place > 0, (digits.count - place) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }
}
