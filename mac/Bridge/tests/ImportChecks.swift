import Foundation

// Compile the real import actors with in-memory helper and HTTP transports.
// Nothing in this executable can read Messages or reach a network socket.
private let chat = "iMessage;-;fixture"
private func row(_ id: Int, in guid: String = chat) -> JSONValue {
    .object(["id": .int(id), "guid": .string("fixture-\(id)"), "chat_guid": .string(guid),
             "chat_identifier": .string(guid), "text": .string("fixture")])
}
private func config(_ enabled: Bool) -> JSONValue {
    .object(["chats": .object([chat: .object(["read": .bool(enabled)])])])
}
private func require(_ value: Bool, _ message: String) {
    if !value { print("FAIL: " + message); exit(1) }
}
private func until(_ condition: () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(15))
    }
    require(false, "timed out waiting for test event")
}

struct RPCNotification: Sendable { let method: String; let params: JSONValue }
enum RPCError: Error { case unexpected; var description: String { "unexpected call" } }
actor Helper { var state: HelperState { .missing } }
actor Courier { func poke() {} }


actor RPCSession {
    static let terminatedMethod = "terminated"
    var isAlive: Bool { true }
    let stream = AsyncStream<RPCNotification>.makeStream()
    var subscribed = false
    var subscribedSince: Int?
    var pages = 0
    func claimNotifications() -> AsyncStream<RPCNotification> { stream.stream }
    func emit(_ raw: JSONValue) {
        stream.continuation.yield(.init(method: "message", params: .object(["message": raw])))
    }
    func call(_ method: String, _ params: [String: JSONValue]? = nil,
              timeout: TimeInterval = 15) throws -> JSONValue {
        switch method {
        case "status": return .object(["database": .object(["ready": .bool(true)])])
        case "chats.list": return .object(["chats": .array([])])
        case "watch.subscribe":
            subscribed = true
            subscribedSince = params?["since_rowid"]?.intValue
            return .object(["subscription": .int(1)])
        case "watch.unsubscribe": return .null
        case "messages.after":
            pages += 1
            let start = params?["since_rowid"]?.intValue ?? 0
            let count = start == 0 ? 120 : 1
            let rows = (1...count).map { row(start + $0) }
            return .object(["messages": .array(rows), "next_rowid": .int(start + count),
                            "has_more": .bool(start == 0)])
        default: throw RPCError.unexpected
        }
    }
}
actor RPCSupervisor {
    let rpc = RPCSession()
    func session() throws -> RPCSession { rpc }
}
actor Collector {
    enum Failure: Error { case malformed, http(Int) }
    let scenario: String
    private(set) var calls: [[Int]] = []
    private(set) var uploads = 0
    func put(_ path: String, file: URL, headers: [String: String]) async throws -> JSONValue {
        uploads += 1
        return .object(["ok": .bool(true)])
    }
    func get(_ path: String) async throws -> JSONValue {
        let want = JSONValue.object(["key": .string(Keys.of("fixture-11")), "n": .int(0),
                                     "chat_guid": .string(chat), "guid": .string("fixture-11")])
        return .object(["items": .array(scenario == "revoke-wanted" ? [want] : [])])
    }
    var gate: CheckedContinuation<Void, Never>?
    init(_ scenario: String) { self.scenario = scenario }
    func release() { gate?.resume(); gate = nil }
    func post(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        guard path == "/v1/messages/ingest" else { return .object(["ok": .bool(true)]) }
        let ids = (body["events"]?.arrayValue ?? []).compactMap { $0["rowid"]?.intValue }
        calls.append(ids)
        let call = calls.count
        if call == 1 && ["concurrent", "revoke-history"].contains(scenario) {
            await withCheckedContinuation { gate = $0 }
        }
        var counts = ["ok": JSONValue.bool(true), "stored": .int(ids.count),
                      "duplicates": .int(0), "cursor_ack": body["cursor"] ?? .null]
        if call == 1 {
            switch scenario {
            case "partial-live", "partial-history", "fresh-restart": counts["stored"] = .int(ids.count - 1)
            case "short-cursor": counts["cursor_ack"] = .int(11)
            case "missing-cursor": counts.removeValue(forKey: "cursor_ack")
            case "refused": counts["ok"] = .bool(false)
            case "unavailable": throw Failure.http(503)
            default: break
            }
        } else {
            // A collector may already own every row in a replay.
            counts["stored"] = .int(0)
            counts["duplicates"] = .int(ids.count)
        }
        return .object(counts)
    }
}

@main
enum ImportChecks {
    static func main() async {
        let scenario = CommandLine.arguments[1]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths.resolve(environment: ["CHARON_BRIDGE_HOME": dir.path])
        let log = Log(file: paths.logFile, level: .error)
        let core = Core(paths: paths, log: log)
        _ = await core.adopt(config: config(true), raw: nil)
        if scenario != "fresh-restart" { await core.acked(cursor: 10, lastEventAt: nil) }
        let collector = Collector(scenario)
        let supervisor = RPCSupervisor()
        let rpc = supervisor.rpc
        let state = { Store.read(BridgeState.self, from: paths.stateFile) }
        if ["revoke-photo", "revoke-wanted"].contains(scenario) {
            let attachments = Attachments(core: core, supervisor: supervisor, collector: collector, log: log)
            let picture = dir.appendingPathComponent("fixture.png")
            try! Data([1, 2, 3]).write(to: picture)
            var raw = row(11).objectValue!
            raw["attachments"] = .array([.object(["original_path": .string(picture.path),
                "mime_type": .string("image/png"), "total_bytes": .int(3)])])
            let message = try! JSONValue.object(raw).decode(IMsgMessage.self)
            guard case .event(let event) = Normalise.event(from: message, allowlist: await core.allowlist)
            else { fatalError("invalid fixture") }
            await attachments.forwarded([event], live: scenario == "revoke-photo")
            _ = await core.adopt(config: config(false), raw: nil)
            await attachments.tick()
            require(await collector.uploads == 0, "uploaded attachment after permission was revoked")
            if scenario == "revoke-wanted" {
                _ = await core.adopt(config: config(true), raw: nil)
                await attachments.tick()
                require(await collector.uploads == 1, "authorized attachment could not be fetched")
            }
        } else if scenario.contains("history") {
            await core.adopt(chatIds: [chat: 1])
            let history = Backfill(core: core, supervisor: supervisor, collector: collector, log: log)
            await history.consider(core.allowlist)
            await until { await !collector.calls.isEmpty }
            if scenario == "revoke-history" {
                _ = await core.adopt(config: config(false), raw: nil)
                await history.consider(core.allowlist)
                await collector.release()
            }
            try? await Task.sleep(for: .milliseconds(650))
            require(state()?.backfill?[chat] == nil, "history advanced an unaccepted page")
            require(await collector.calls.count == 1, "posted another history slice")
            require(await rpc.pages == 1, "fetched another history page")
            require(state()?.cursor == 10, "history changed live cursor")
            if scenario == "partial-history" {
                try? await Task.sleep(for: .seconds(6))
                await until { state()?.backfill?[chat]?.done == true }
                let calls = await collector.calls
                require(calls[0] == calls[1], "history retry changed the unaccepted slice")
                require(state()?.backfill?[chat]?.count == 121, "history replay inflated count")
            }
            await history.stop()
        } else {
            let watcher = Watcher(core: core, supervisor: supervisor, collector: collector,
                                  helper: Helper(), log: log)
            let watching = Task { await watcher.run() }
            defer { watching.cancel() }
            await until { await rpc.subscribed }
            await rpc.emit(row(11))
            await rpc.emit(row(12))
            await rpc.emit(row(13, in: "blocked"))
            await until { await core.dropped == 1 }
            if scenario == "revoke-live" {
                _ = await core.adopt(config: config(false), raw: nil)
                await watcher.allowlistChanged()
            }
            if scenario == "disk-full" {
                try! FileManager.default.removeItem(at: paths.stateFile)
                try! FileManager.default.createDirectory(at: paths.stateFile, withIntermediateDirectories: false)
            }
            let first = Task { await watcher.drain() }
            if scenario == "concurrent" {
                await until { await collector.gate != nil }
                let overlapping = Task { await watcher.drain() }
                try? await Task.sleep(for: .milliseconds(100))
                require(await collector.calls.count == 1, "same live prefix submitted concurrently")
                await collector.release()
                await overlapping.value
            }
            await first.value
            if scenario == "fresh-restart" {
                let resumed = Core(paths: paths, log: log)
                let other = RPCSupervisor()
                let replay = Watcher(core: resumed, supervisor: other, collector: collector, helper: Helper(), log: log)
                let task = Task { await replay.run() }
                defer { task.cancel() }
                await until { await other.rpc.subscribed }
                require(await other.rpc.subscribedSince == 10, "first-run restart lost unacknowledged rows")
            } else if scenario == "revoke-live" {
                require((await collector.calls).flatMap { $0 }.isEmpty, "sent revoked buffered rows")
            } else if scenario == "concurrent" {
                require(state()?.cursor == 13, "accepted prefix not checkpointed")
            } else {
                if scenario == "disk-full" {
                    require(await core.cursor == 10, "advanced live cursor on local checkpoint failure")
                    try! FileManager.default.removeItem(at: paths.stateFile)
                } else {
                    require(state()?.cursor == 10, "advanced live cursor after incomplete receipt")
                }
                try? await Task.sleep(for: .seconds(6))
                await watcher.drain()
                let calls = await collector.calls
                require(calls == [[11, 12], [11, 12]], "live retry changed or dropped pending rows")
                require(state()?.cursor == 13, "replayed batch was not checkpointed")
            }
        }
        print("PASS: " + scenario)
    }
}
