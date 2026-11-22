import Foundation

/* The bytes: which ones go on their own, which ones wait to be asked for, and
 * how a file that was forwarded weeks ago is found again.
 *
 * Everything else this program sends is something it just read out of the
 * database. An attachment is a file on this disk that the database only points
 * at, which makes this the one part of the Bridge with a memory: a photograph
 * uploaded the moment it arrives needs nothing remembered, and a video
 * somebody taps `fetch` on eight days later needs the path the event carried
 * and no longer has.
 *
 * Three rules hold it, and they are section 7's:
 *
 *   Photographs go by themselves and nothing else does. A live event's images
 *   under ten megabytes are uploaded right after the ingest that carried them.
 *   Video, files, bigger images and every attachment of a backfilled history
 *   wait for a want, which is a person tapping a tile.
 *
 *   One attempt per cycle, with the watcher's backoff. A failure leaves the
 *   want where it is and tries again in three seconds, then six, then twelve;
 *   five failures on one file and it is left alone and said once.
 *
 *   Nothing is logged but counts. Not the filename, which came off somebody's
 *   camera, and not the path, which names this Mac's home directory.
 */
actor Attachments {

    private let core: Core
    private let supervisor: RPCSupervisor
    private let collector: Collector
    private let log: Log

    /// One upload, ready to go.
    private struct Job: Sendable, Equatable {
        var key: String
        var chatGuid: String
        var chatIdentifier: String?
        var n: Int
        var path: String
        var filename: String
        var mime: String?
    }

    /// Live images waiting for their turn, oldest first.
    private var queue: [Job] = []
    /// How many wants the Pi had at the last look, so the heartbeat can say
    /// what is outstanding rather than only what is outstanding here.
    private var outstanding = 0
    /// Attempts per `key-n`, for the wanted half. The automatic half is not
    /// counted: it is dropped on the first refusal, because nobody asked for
    /// it and nobody is waiting on it.
    private var tries: [String: Int] = [:]
    /// Files this run has put on the Pi, and attempts that ended in a refusal.
    private var uploaded = 0
    private var failed = 0
    /// `key-n` that has already had its one line in the log. A file too big
    /// for the route is too big every cycle, and a warning every three seconds
    /// is a log nobody reads.
    private var told: Set<String> = []
    private var blockedUntil = Date.distantPast
    private var backoff: TimeInterval = 0

    /// Where the paths of everything this program has forwarded are kept, so a
    /// want that arrives long after the event can still be answered. Bounded
    /// and pruned oldest-first: it is a convenience, not a record, and the
    /// helper can always be asked again.
    private var seen: [String: [String]] = [:]
    private var seenOrder: [String] = []
    private var seenDirty = false

    /// How many messages' paths are remembered. A thousand messages with
    /// attachments is months of a normal phone and about a hundred kilobytes
    /// of JSON.
    private static let rememberMessages = 1_000
    /// The most live images that may pile up waiting for a cycle. A burst
    /// bigger than this is a backlog, and the ones that fall off can still be
    /// asked for.
    private static let queueMax = 200
    /// How many times one wanted file is attempted before it is left alone.
    private static let triesMax = 5

    init(core: Core, supervisor: RPCSupervisor, collector: Collector, log: Log) {
        self.core = core
        self.supervisor = supervisor
        self.collector = collector
        self.log = log
        if let stored = Store.read(SeenAttachments.self,
                                   from: core.paths.attachmentsSeenFile) {
            seen = stored.paths
            seenOrder = stored.order.filter { stored.paths[$0] != nil }
            // A file written by an older run, or edited: whatever is in the
            // map and not in the order still has to be prunable.
            for key in seen.keys where !seenOrder.contains(key) { seenOrder.append(key) }
        }
    }

    // MARK: - what the stream and the history hand over

    /// Events the collector has just acknowledged.
    ///
    /// Called from both upstream paths, and the `live` flag is the whole of
    /// the difference between them: a history's paths are remembered so a want
    /// can be answered, and none of its files is uploaded. Section 7.
    func forwarded(_ events: [Event], live: Bool) {
        for event in events where !event.attachments.isEmpty {
            remember(event.key, event.attachments.map { $0.originalPath ?? "" })
            guard live else { continue }
            for attachment in event.attachments where Uploads.automatic(attachment) {
                queue.append(Job(key: event.key, chatGuid: event.chatGuid,
                                 chatIdentifier: event.chatIdentifier,
                                 n: attachment.n,
                                 path: attachment.originalPath ?? "",
                                 filename: attachment.filename,
                                 mime: attachment.mimeType))
            }
        }
        if queue.count > Self.queueMax {
            let lost = queue.count - Self.queueMax
            queue.removeFirst(lost)
            log.warn("\(lost) photo(s) fell out of the upload queue; "
                + "they can still be fetched")
        }
        persist()
    }

    private func remember(_ key: String, _ paths: [String]) {
        if seen[key] == nil { seenOrder.append(key) }
        seen[key] = paths
        seenDirty = true
        while seenOrder.count > Self.rememberMessages {
            seen.removeValue(forKey: seenOrder.removeFirst())
        }
    }

    private func persist() {
        guard seenDirty else { return }
        seenDirty = false
        Store.write(SeenAttachments(paths: seen, order: seenOrder),
                    to: core.paths.attachmentsSeenFile)
    }

    // MARK: - the cycle

    /// One pass: the photographs this Mac decided to send, then whatever the
    /// Pi has been asked for. Called from the courier's own loop rather than
    /// from a loop of its own, so an upload and a send never overlap and the
    /// backoff after a failure is one backoff rather than two.
    func tick() async {
        guard Date() >= blockedUntil else { return }
        await sendQueued()
        await sendWanted()
        await core.note(attachments: AttachmentProgress(
            uploaded: uploaded, pending: queue.count + outstanding, failed: failed))
    }

    private func sendQueued() async {
        var sent = 0
        var bytes = 0
        var reachable = true
        while reachable, !queue.isEmpty {
            let job = queue.removeFirst()
            switch await upload(job) {
            case .ok(let size):
                uploaded += 1
                sent += 1
                bytes += size
            case .refused:
                // Nobody asked for this one and nobody is waiting on it, so a
                // refusal is the end of it. It can still be fetched, which is
                // the path with the retries on it.
                failed += 1
            case .revoked:
                continue
            case .unreachable:
                // The queue stays. The Pi being down is the same event the
                // ingest already backs off for, and the photographs are on
                // this disk either way.
                queue.insert(job, at: 0)
                hold()
                reachable = false
            }
        }
        if sent > 0 {
            log.info("uploaded \(sent) photo\(sent == 1 ? "" : "s") "
                + "(\(Uploads.size(bytes)))")
        }
    }

    private func sendWanted() async {
        let reply: JSONValue
        do {
            reply = try await collector.get("/v1/messages/attachments?status=wanted")
        } catch {
            log.debug("the wanted list could not be read: \(error.redacted)")
            return
        }
        let items = (reply["items"]?.arrayValue ?? [])
            .compactMap { try? $0.decode(WantedAttachment.self) }
        outstanding = items.count
        guard !items.isEmpty else { return }

        var sent = 0
        var bytes = 0
        var reachable = true
        for item in items where reachable {
            guard let guid = item.chatGuid, await core.allowlist.mayRead(guid: guid) else { continue }
            let mark = "\(item.key)-\(item.n)"
            guard (tries[mark] ?? 0) < Self.triesMax else { continue }
            guard let path = await resolve(item) else {
                // The event is not in the map and the helper could not find
                // the row. Counted like a failed upload rather than settled on
                // the spot: on a cold start the chat directory has not been
                // read yet, and a want abandoned in the first three seconds of
                // a process would be abandoned for the week the Pi holds it.
                let count = (tries[mark] ?? 0) + 1
                tries[mark] = count
                if count >= Self.triesMax {
                    once(mark, "a wanted attachment could not be found on "
                        + "this Mac and will not be looked for again")
                }
                continue
            }
            let job = Job(key: item.key, chatGuid: guid, chatIdentifier: nil, n: item.n, path: path,
                          filename: item.filename ?? "", mime: item.mimeType)
            switch await upload(job) {
            case .ok(let size):
                uploaded += 1
                sent += 1
                bytes += size
                tries[mark] = nil
                told.remove(mark)
            case .revoked:
                continue
            case .refused:
                failed += 1
                let count = (tries[mark] ?? 0) + 1
                tries[mark] = count
                if count >= Self.triesMax {
                    once(mark, "a wanted attachment was refused \(count) times "
                        + "and will not be tried again")
                }
            case .unreachable:
                hold()
                reachable = false
            }
        }
        if sent > 0 {
            log.info("uploaded \(sent) wanted file\(sent == 1 ? "" : "s") "
                + "(\(Uploads.size(bytes)))")
        }
    }

    // MARK: - one upload

    private enum Outcome {
        case ok(Int)
        case revoked
        /// This file will not go up: too big, not there, or the Pi said no.
        case refused
        /// The Pi could not be reached at all. Nothing is wrong with the file.
        case unreachable
    }

    private func upload(_ job: Job) async -> Outcome {
        guard await core.allowlist.mayRead(guid: job.chatGuid, identifier: job.chatIdentifier) else {
            return .revoked
        }
        guard !job.path.isEmpty else { return .refused }
        let file = URL(fileURLWithPath: job.path)
        guard let (digest, size) = Digest.ofFile(at: file), size > 0 else {
            // Messages aged it out between the row arriving and this cycle, or
            // it was never on this Mac. Nothing to report and nothing to say
            // beyond a debug line: the app already draws `not on this Mac`.
            log.debug("an attachment is not readable on this Mac")
            return .refused
        }
        guard size <= Uploads.wireLimit else {
            once("\(job.key)-\(job.n)",
                 "an attachment of \(Uploads.size(size)) is over the "
                    + "\(Uploads.size(Uploads.wireLimit)) ceiling and was not sent")
            return .refused
        }

        let headers = [
            "Content-Type": job.mime?.isEmpty == false
                ? job.mime! : "application/octet-stream",
            "X-Charon-Filename": Uploads.headerName(job.filename, n: job.n),
            "X-Charon-Protocol": "1",
            "X-Charon-SHA256": digest,
        ]
        do {
            guard await core.allowlist.mayRead(guid: job.chatGuid, identifier: job.chatIdentifier) else {
                return .revoked
            }
            _ = try await collector.put(
                "/v1/messages/attachment/\(job.key)/\(job.n)",
                file: file, headers: headers)
            backoff = 0
            blockedUntil = .distantPast
            return .ok(size)
        } catch Collector.Failure.http(let code) where (400..<500).contains(code) {
            // The Pi answered and said no. A 404 is a message it does not hold,
            // a 413 is a file it will not take, a 400 is a digest that did not
            // match. None of the three is worth another attempt this cycle.
            log.warn("an attachment was refused with \(code)")
            return .refused
        } catch {
            log.debug("an attachment upload failed: \(error.redacted)")
            return .unreachable
        }
    }

    /// Five seconds, doubling, to five minutes -- the watcher's own numbers,
    /// because it is the same Pi and the same outage.
    private func hold() {
        backoff = backoff == 0 ? 5 : min(300, backoff * 2)
        blockedUntil = Date().addingTimeInterval(backoff + Double.random(in: 0...1))
    }

    private func once(_ mark: String, _ line: String) {
        guard !told.contains(mark) else { return }
        // A set that only grows is a leak with a long fuse. Emptied rather
        // than trimmed: the worst a forgotten mark costs is one more line in
        // the log about a file that is still too big.
        if told.count > 500 { told.removeAll() }
        told.insert(mark)
        log.warn(line)
    }

    // MARK: - finding the file again

    /// Where the bytes of a wanted attachment are, or nil.
    ///
    /// The map first, which answers for anything this run or a recent one
    /// forwarded. Then the helper, which is the case that matters: a want is a
    /// person tapping a tile on a conversation whose history was downloaded
    /// weeks ago, in a process that has been restarted since.
    ///
    /// `messages.after` cannot be asked for a guid, so the row is asked for by
    /// the two handles the wanted item carries: one before its own rowid, in
    /// its own conversation, one row deep. The answer is only used when its
    /// guid is the guid that was wanted -- a page that came back with somebody
    /// else's row is a page this does not touch.
    private func resolve(_ item: WantedAttachment) async -> String? {
        if let paths = seen[item.key], item.n < paths.count, !paths[item.n].isEmpty {
            return paths[item.n]
        }
        guard let chatGuid = item.chatGuid, let rowid = item.rowid, rowid > 0,
              let chatId = await core.chatIds[chatGuid]
        else { return nil }

        let page: JSONValue
        do {
            let session = try await supervisor.session()
            page = try await session.call("messages.after", [
                "since_rowid": .int(rowid - 1),
                "chat_id": .int(chatId),
                "limit": .int(1),
                "attachments": .bool(true),
            ], timeout: 30)
        } catch {
            log.debug("the helper could not be asked for a wanted row: \(error.redacted)")
            return nil
        }
        guard let raw = page["messages"]?.arrayValue?.first,
              let row = try? raw.decode(IMsgMessage.self),
              row.guid == item.guid,
              let listed = row.attachments, item.n < listed.count,
              let path = listed[item.n].originalPath, !path.isEmpty
        else { return nil }
        // Worth keeping: a want that has been asked for once tends to be
        // asked for again, and this cost a round trip through the database.
        var paths = seen[item.key] ?? Array(repeating: "", count: listed.count)
        while paths.count < listed.count { paths.append("") }
        paths[item.n] = path
        remember(item.key, paths)
        persist()
        return path
    }
}
