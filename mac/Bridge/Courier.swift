import Foundation

/* The downstream half: the config, the outbox, and one attempt at a send.
 *
 * A send is the only thing the Bridge does that another person can see, so it
 * is the part written most defensively. The collector already refused a chat
 * whose policy is off or unknown; this checks the same thing again against its
 * own cached copy before anything reaches Messages, because "the allowlist is
 * enforced twice" (section 7) means twice on two machines, not twice in one
 * function.
 *
 * Nothing here retries. An item is marked seen before it is attempted, so a
 * crash mid-send cannot turn into a second message, and an uncertain outcome
 * is reported as exactly that rather than resolved by trying again.
 */
actor Courier {

    private let core: Core
    private let supervisor: RPCSupervisor
    private let collector: Collector
    private let log: Log
    private let dryRun: Bool

    private weak var watcher: Watcher?
    /// Held rather than borrowed: nothing in the backfill points back here, so
    /// there is no cycle to break, and the config fetch is the only thing that
    /// ever starts one.
    private var backfill: Backfill?
    /// The uploader, ticked on the same three seconds. One loop rather than
    /// two: an upload and a send both reach the same Pi, and a program with
    /// two independent backoffs against one box would retry twice as hard as
    /// it meant to.
    private var uploader: Attachments?

    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var poked = false
    private var probedAt = Date.distantPast
    private var toldAboutProbe = false

    private static let every: TimeInterval = 3
    private static let probeEvery: TimeInterval = 300
    /// Section 8: a send body is at most four thousand characters.
    private static let bodyLimit = 4_000

    init(core: Core, supervisor: RPCSupervisor, collector: Collector, log: Log, dryRun: Bool) {
        self.core = core
        self.supervisor = supervisor
        self.collector = collector
        self.log = log
        self.dryRun = dryRun
        if let stored = Store.read(OutboxSeen.self, from: core.paths.outboxSeenFile) {
            seenOrder = stored.ids
            seen = Set(stored.ids)
        }
    }

    func pair(with watcher: Watcher) { self.watcher = watcher }

    func pair(with backfill: Backfill) { self.backfill = backfill }

    func pair(with uploader: Attachments) { self.uploader = uploader }

    /// Something upstream happened; look again now rather than in three
    /// seconds. A reply the user just confirmed is worth the interruption.
    func poke() { poked = true }

    // MARK: - the loop

    func run() async {
        while !Task.isCancelled {
            await refreshConfig()
            await probeIfDue()
            await drainOutbox()
            await uploader?.tick()
            await rest()
        }
    }

    private func rest() async {
        let deadline = Date().addingTimeInterval(Self.every)
        while Date() < deadline, !poked, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        poked = false
    }

    // MARK: - the config

    /// The allowlist, mirrored. When the Pi cannot be reached the cached copy
    /// stands: a Bridge that forgot the allowlist would either send nothing or
    /// send everything, and one of those is much worse than the other.
    @discardableResult
    func refreshConfig() async -> Bool {
        do {
            let document = try await collector.get("/v1/messages/config")
            let raw = try? JSONEncoder().encode(document)
            let changed = await core.adopt(config: document, raw: raw)
            if changed {
                log.info("the allowlist changed")
                await watcher?.allowlistChanged()
            }
            // Every fetch, not only the ones that changed something. The
            // question the backfill asks is "is any allowed chat still owed
            // its history", and the answer moves when a page lands as well as
            // when the user edits the list.
            let allowlist = await core.allowlist
            await backfill?.consider(allowlist)
            return true
        } catch {
            log.warn("config fetch failed, using the cached allowlist: \(error.redacted)")
            return false
        }
    }

    // MARK: - the outbox

    private func drainOutbox() async {
        let reply: JSONValue
        do {
            reply = try await collector.get("/v1/messages/outbox?status=queued")
        } catch {
            log.debug("outbox poll failed: \(error.redacted)")
            return
        }
        let items = (reply["items"]?.arrayValue ?? [])
            .compactMap { try? $0.decode(OutboxItem.self) }
        for item in items where !seen.contains(item.id) {
            // Seen first, attempted second. The order is the guarantee.
            remember(item.id)
            await perform(item)
        }
    }

    private func remember(_ id: String) {
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > OutboxSeen.keep {
            let dropped = seenOrder.prefix(seenOrder.count - OutboxSeen.keep)
            for old in dropped { seen.remove(old) }
            seenOrder.removeFirst(seenOrder.count - OutboxSeen.keep)
        }
        Store.write(OutboxSeen(ids: seenOrder), to: core.paths.outboxSeenFile)
    }

    private func perform(_ item: OutboxItem) async {
        guard isKey(item.id) else {
            log.warn("an outbox item arrived with an id this program will not put in a URL")
            return
        }

        let allowlist = await core.allowlist
        let policy = allowlist.policy(guid: item.chatGuid, key: item.chatKey)
        guard let policy, policy.read, policy.send == "confirm" else {
            // off, auto, or a chat we have never heard of. v1 acts on confirm
            // and nothing else, and says so rather than staying quiet.
            log.warn("refusing a send: the chat's policy is not confirm")
            await report(item.id, failed: "policy",
                         disposition: "not_started", retrySafe: false)
            return
        }
        guard let chatGuid = item.chatGuid, !chatGuid.isEmpty else {
            await report(item.id, failed: "chat", disposition: "not_started", retrySafe: false)
            return
        }
        guard let body = item.body, !body.isEmpty else {
            await report(item.id, failed: "empty", disposition: "not_started", retrySafe: false)
            return
        }
        guard body.count <= Self.bodyLimit else {
            await report(item.id, failed: "too_long", disposition: "not_started", retrySafe: false)
            return
        }

        do {
            let session = try await supervisor.session()
            let result = try await session.call(
                "send", ["chat_guid": .string(chatGuid), "text": .string(body)], timeout: 15)
            if result["ok"]?.boolValue == false {
                await report(item.id, failed: "send", disposition: nil, retrySafe: nil)
                return
            }
            log.info("sent one reply")
            await report(item.id,
                         sent: result["guid"]?.stringValue,
                         messageId: result["id"]?.intValue)
        } catch let trouble as RPCError {
            await fail(item, trouble)
        } catch {
            await report(item.id, failed: "send", disposition: nil, retrySafe: nil)
        }
    }

    private func fail(_ item: OutboxItem, _ trouble: RPCError) async {
        let code = trouble.code
        // -32001: the send may have gone through and may not have. Nothing we
        // can ask will settle it, so it is reported unresolved and the child
        // is replaced -- its mutation lane is poisoned either way.
        let unknown = code == -32001
        let blocked = code == -32004
        let disposition = trouble.disposition ?? (unknown ? "may_have_completed" : nil)
        let retrySafe = trouble.retrySafe ?? (unknown ? false : nil)
        let named = code.map { "rpc\($0)" } ?? "helper"

        log.error("a send failed: \(trouble.description)")
        await report(item.id, failed: named, disposition: disposition, retrySafe: retrySafe)

        if unknown || blocked {
            await supervisor.restart(unknown ? "a send with an unknown outcome"
                                             : "the mutation lane is blocked")
        }
    }

    // MARK: - reporting back

    private func report(_ id: String, sent guid: String?, messageId: Int?) async {
        var body: [String: JSONValue] = ["status": .string("sent")]
        if let guid { body["guid"] = .string(guid) }
        if let messageId { body["message_id"] = .int(messageId) }
        await deliver(id, .object(body))
    }

    private func report(_ id: String, failed error: String,
                        disposition: String?, retrySafe: Bool?) async {
        var body: [String: JSONValue] = ["status": .string("failed"), "error": .string(error)]
        if let disposition { body["disposition"] = .string(disposition) }
        if let retrySafe { body["retry_safe"] = .bool(retrySafe) }
        await deliver(id, .object(body))
    }

    /// The one thing worth retrying: telling the Pi what happened. The send is
    /// over either way, and a report that never lands leaves an item queued in
    /// the console with no explanation attached to it.
    private func deliver(_ id: String, _ report: JSONValue) async {
        // Section 2 asks every request with a body to name the protocol it
        // speaks, and section 5's table for this route does not show it. The
        // blanket rule wins: a collector that checks will find it, and one
        // that does not will ignore it.
        var body = report.objectValue ?? [:]
        body["protocol"] = .int(1)
        for attempt in 1...3 {
            do {
                _ = try await collector.post("/v1/messages/outbox/\(id)", .object(body))
                return
            } catch {
                log.warn("outbox report attempt \(attempt) failed: \(error.redacted)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1e9))
                }
            }
        }
        await core.note(error: "an outbox report could not be delivered")
    }

    /// Section 3: check the shape before it goes in a URL.
    private func isKey(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    // MARK: - the other permission

    /// Ask Messages its own name. It is the smallest question that still needs
    /// the Automation grant, so the answer is the grant.
    func probeIfDue() async {
        guard Date().timeIntervalSince(probedAt) >= Self.probeEvery else { return }
        probedAt = Date()
        guard !dryRun else {
            if !toldAboutProbe {
                toldAboutProbe = true
                log.info("dry run: not asking Messages anything")
            }
            return
        }
        let outcome = await Shell.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", "tell application \"Messages\" to return name"],
            timeout: 10)
        if outcome.timedOut { log.warn("the Automation probe timed out") }
        await core.note(automation: outcome.ok)
    }

    /// Used once at first run, while the user is standing there: this is the
    /// call that makes macOS show its Automation prompt.
    func probeNow() async {
        probedAt = .distantPast
        await probeIfDue()
    }
}
