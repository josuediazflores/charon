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

    private var journal: DeliveryJournal?
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
        do {
            if journal == nil {
                journal = try DeliveryJournal(file: core.paths.outboxSeenFile)
            }
        } catch {
            await core.note(error: "outbox journal unavailable; sends are paused")
            return
        }
        guard let journal else { return }
        let pending = journal.state.reports
        for (id, report) in pending where isKey(id) {
            await deliver(id, report)
        }

        let reply: JSONValue
        do {
            reply = try await collector.get("/v1/messages/outbox?status=queued")
        } catch {
            log.debug("outbox poll failed: \(error.redacted)")
            return
        }
        let items = (reply["items"]?.arrayValue ?? [])
            .compactMap { try? $0.decode(OutboxItem.self) }
        var handled = Set(pending.keys)
        for item in items where isKey(item.id) && handled.insert(item.id).inserted {
            let previouslySeen = journal.state.ids.contains(item.id)
            guard journal.begin(item.id) else {
                await core.note(error: "cannot record an outbox attempt; sends are paused")
                return
            }
            if previouslySeen {
                // A legacy journal knows the helper was called, but lost its answer.
                await deliver(item.id, DeliveryJournal.interrupted)
            } else {
                await perform(item)
            }
        }
    }

    private func perform(_ item: OutboxItem) async {
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

        let session: RPCSession
        do {
            session = try await supervisor.session()
        } catch {
            await report(item.id, failed: "helper", disposition: "not_started", retrySafe: true)
            return
        }
        do {
            let result = try await session.call(
                "send", ["chat_guid": .string(chatGuid), "text": .string(body)], timeout: 15)
            if result["ok"]?.boolValue != true {
                await report(item.id, failed: "send", disposition: "may_have_completed", retrySafe: false)
                return
            }
            log.info("sent one reply")
            await report(item.id,
                         sent: result["guid"]?.stringValue,
                         messageId: result["id"]?.stringValue ?? result["id"]?.intValue.map(String.init))
        } catch let trouble as RPCError {
            await fail(item, trouble)
        } catch {
            await report(item.id, failed: "send", disposition: "may_have_completed", retrySafe: false)
        }
    }

    private func fail(_ item: OutboxItem, _ trouble: RPCError) async {
        let code = trouble.code
        // -32001: the send may have gone through and may not have. Nothing we
        // can ask will settle it, so it is reported unresolved and the child
        // is replaced -- its mutation lane is poisoned either way.
        let unknown = code == -32001
        let blocked = code == -32004
        let disposition = unknown ? "may_have_completed" : (trouble.disposition ?? "may_have_completed")
        let retrySafe = disposition == "not_started" && trouble.retrySafe == true
        let named = code.map { "rpc\($0)" } ?? "helper"

        log.error("a send failed: \(trouble.description)")
        await report(item.id, failed: named, disposition: disposition, retrySafe: retrySafe)

        if unknown || blocked {
            await supervisor.restart(unknown ? "a send with an unknown outcome"
                                             : "the mutation lane is blocked")
        }
    }

    // MARK: - reporting back

    private func report(_ id: String, sent guid: String?, messageId: String?) async {
        var body: [String: JSONValue] = ["status": .string("sent")]
        if let guid { body["guid"] = .string(guid) }
        if let messageId { body["message_id"] = .string(messageId) }
        await recordAndDeliver(id, .object(body))
    }

    private func report(_ id: String, failed error: String,
                        disposition: String?, retrySafe: Bool?) async {
        var body: [String: JSONValue] = ["status": .string("failed"), "error": .string(error)]
        if let disposition { body["disposition"] = .string(disposition) }
        if let retrySafe { body["retry_safe"] = .bool(retrySafe) }
        await recordAndDeliver(id, .object(body))
    }

    private func recordAndDeliver(_ id: String, _ report: JSONValue) async {
        if journal?.record(id, report: report) != true {
            await core.note(error: "could not save the outbox outcome locally")
        }
        await deliver(id, report)
    }

    /// Retry only the report on the existing poll. An older collector returns
    /// 409 after recording a terminal result when its first response was lost.
    private func deliver(_ id: String, _ report: JSONValue) async {
        var body = report.objectValue ?? [:]
        body["protocol"] = .int(1)
        do {
            let reply = try await collector.post("/v1/messages/outbox/\(id)", .object(body))
            guard reply["ok"]?.boolValue == true else { throw Collector.Failure.malformed }
        } catch Collector.Failure.http(409) {
            log.warn("collector already has a terminal outbox result")
        } catch {
            log.warn("outbox report is pending: \(error.redacted)")
            return
        }
        if journal?.acknowledged(id) != true {
            await core.note(error: "could not save acknowledgment of the outbox report")
        }
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
