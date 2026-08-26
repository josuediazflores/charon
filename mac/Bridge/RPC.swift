import Foundation

/* One `imsg rpc` child, spoken to over a pipe.
 *
 * The child is long-lived on purpose: it holds the open database handle and
 * the watch subscription, and starting a new one per request would mean a new
 * subscription per request. It is also the only place in the Bridge where a
 * hang is possible, so three things guard it:
 *
 *   Every call is on a clock. A helper that stops answering is killed rather
 *   than waited on, because the read lane is sequential from our side and one
 *   unanswered call would wedge the stream for good.
 *
 *   Stderr is drained and thrown away. The child writes diagnostics there --
 *   Contacts framework noise, mostly -- and a pipe nobody reads fills up and
 *   stops the process that is writing to it.
 *
 *   A line has a ceiling. Four megabytes without a newline is not a protocol
 *   any more, and the buffer is dropped and the child ended.
 *
 * Nothing here logs a line's contents: every line from a watch subscription is
 * somebody's message.
 */

struct RPCNotification: Sendable {
    let method: String
    let params: JSONValue
}

enum RPCError: Error, Sendable, CustomStringConvertible {
    /// The child is gone. Delivered to every call still waiting, and to the
    /// notification stream as a local `helperTerminated`, so a consumer ends
    /// on the same news whichever side it was listening to.
    case helperTerminated
    case timeout(String)
    case remote(code: Int, message: String, data: JSONValue?)
    case notVerified
    case spawnFailed(String)

    var description: String {
        switch self {
        case .helperTerminated: return "helper ended"
        case .timeout(let method): return "\(method) timed out"
        case .remote(let code, let message, _): return "imsg \(code): \(message)"
        case .notVerified: return "helper not verified"
        case .spawnFailed(let why): return "helper would not start: \(why)"
        }
    }

    /// imsg's delivery disposition, when it sent one. Section 5's outbox
    /// report carries it through to the console unchanged.
    var disposition: String? {
        if case .remote(_, _, let data) = self { return data?["disposition"]?.stringValue }
        return nil
    }

    var retrySafe: Bool? {
        if case .remote(_, _, let data) = self { return data?["retry_safe"]?.boolValue }
        return nil
    }

    var code: Int? {
        if case .remote(let code, _, _) = self { return code }
        return nil
    }
}

/// Splitting bytes into lines off the actor, in order.
private final class SplitterBox: @unchecked Sendable {
    private var splitter = LineSplitter()
    func push(_ chunk: Data) throws -> [Data] { try splitter.push(chunk) }
}

actor RPCSession {

    /// The notification method the Bridge makes up for itself. imsg never
    /// sends it; it is how the end of the child reaches a consumer that is
    /// waiting on notifications rather than on a call.
    static let terminatedMethod = "helperTerminated"

    private let log: Log
    private var process: Process?
    private var input: FileHandle?
    private var alive = false
    private var overlong = false

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]

    private var notifications: AsyncStream<RPCNotification>?
    private var notify: AsyncStream<RPCNotification>.Continuation?
    private var claimed = false

    init(log: Log) {
        self.log = log
    }

    var isAlive: Bool { alive }

    // MARK: - the child

    func start(executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["rpc"]
        let toChild = Pipe()
        let fromChild = Pipe()
        let diagnostics = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = diagnostics

        let (lines, lineSink) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let splitter = SplitterBox()
        let tooLong = Flag()

        fromChild.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lineSink.finish()
                return
            }
            do {
                for line in try splitter.push(chunk) { lineSink.yield(line) }
            } catch {
                tooLong.raise()
                handle.readabilityHandler = nil
                lineSink.finish()
            }
        }

        // Read and discard. The child is entitled to be chatty.
        diagnostics.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        let (stream, sink) = AsyncStream<RPCNotification>.makeStream(bufferingPolicy: .unbounded)
        notifications = stream
        notify = sink

        do {
            try process.run()
        } catch {
            sink.finish()
            throw RPCError.spawnFailed(error.redacted)
        }

        self.process = process
        self.input = toChild.fileHandleForWriting
        self.alive = true

        Task { [weak self] in
            for await line in lines { await self?.received(line) }
            await self?.ended(overlongLine: tooLong.raised)
        }
    }

    /// The notification stream, handed to whoever asks first. One child, one
    /// consumer: the watcher.
    func claimNotifications() -> AsyncStream<RPCNotification> {
        guard !claimed, let notifications else {
            return AsyncStream { $0.finish() }
        }
        claimed = true
        return notifications
    }

    // MARK: - calls

    /// One request, one answer, on a clock.
    ///
    /// The long timeout belongs to the two calls that touch the whole
    /// database on a cold cache -- the first subscribe and the chat list --
    /// and to nothing else.
    func call(_ method: String,
              _ params: [String: JSONValue]? = nil,
              timeout: TimeInterval = 15) async throws -> JSONValue {

        guard alive, let input else { throw RPCError.helperTerminated }
        let id = nextID
        nextID += 1
        let line = try RPCRequest(id: id, method: method, params: params).line()

        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.expire(id: id, method: method)
        }
        timers[id] = timer

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                settle(id, .failure(RPCError.helperTerminated))
            }
        }
    }

    /// Ends the child and everything waiting on it.
    func shutdown() {
        guard alive else { return }
        alive = false
        process?.terminate()
        input = nil
    }

    // MARK: - the reader

    private func received(_ line: Data) {
        guard let frame = try? RPCFrame.decode(line) else {
            log.warn("unreadable line from the helper (\(line.count) bytes)")
            return
        }
        switch frame {
        case .result(let id, let value):
            settle(id, .success(value))
        case .failure(let id, let code, let message, let data):
            settle(id, .failure(RPCError.remote(code: code,
                                                message: redact(message),
                                                data: data)))
        case .notification(let method, let params):
            notify?.yield(RPCNotification(method: method, params: params))
        case .unpaired:
            log.warn("a frame from the helper matched no request")
        }
    }

    private func ended(overlongLine: Bool) {
        if overlongLine {
            log.error("the helper sent a line with no end to it — ending the child")
        }
        alive = false
        process?.terminate()
        input = nil
        for (id, timer) in timers { timer.cancel(); timers[id] = nil }
        let waiting = pending
        pending = [:]
        for (_, continuation) in waiting {
            continuation.resume(throwing: RPCError.helperTerminated)
        }
        notify?.yield(RPCNotification(method: Self.terminatedMethod, params: .null))
        notify?.finish()
    }

    private func expire(id: Int, method: String) {
        guard pending[id] != nil else { return }
        log.error("the helper did not answer \(method) in time — killing it")
        settle(id, .failure(RPCError.timeout(method)))
        // A sequential reader with one unanswered call is a reader that never
        // reads again, so the whole session goes rather than the one call.
        shutdown()
    }

    private func settle(_ id: Int, _ outcome: Result<JSONValue, Error>) {
        timers[id]?.cancel()
        timers[id] = nil
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: outcome)
    }
}

/// A one-way flag, set on one queue and read on another.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.lock(); value = true; lock.unlock() }
    var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/* One child at a time, shared by the three things that need it.
 *
 * The watcher, the courier and the history reader all talk to the same helper
 * because imsg runs reads and mutations in separate lanes inside one process
 * -- a send does not hold up the stream. It also means a send that poisons the
 * mutation lane takes the stream with it when the child is restarted, which is
 * why the restart is here and not in any caller.
 *
 * **Being an actor is not enough to make "one child" true**, and that is the
 * whole design of what follows. An actor serialises steps, not calls: every
 * `await` inside a method is a point where another call gets a turn. The first
 * version of `session()` read `current`, awaited the digest check, awaited the
 * spawn, and only then assigned -- so two callers arriving together both saw
 * no child, both waited on the same digest, and both started one. On a cold
 * start that is exactly what happens: the watcher opens its subscription and
 * the history reader asks for its first page in the same millisecond. The
 * result was two `imsg rpc` processes on one database, two watch
 * subscriptions, and one extra line in the log as the only sign of it.
 *
 * So the slot holds the *attempt* rather than the result. A caller that finds
 * a task in the slot awaits that task; a caller that finds the slot empty puts
 * its own task in and awaits that. Finding it empty and filling it happens in
 * one actor step with no `await` between, which is what makes a second spawn
 * impossible rather than merely unlikely.
 *
 * The teardown takes the same slot, for the same reason: a restart that simply
 * cleared it would let the next caller spawn while the old child was still
 * being killed. It installs a task that ends the child and then throws, so
 * anybody who asks mid-kill waits for the old one to be dead and is then told
 * to try again.
 */
actor RPCSupervisor {

    private let helper: Helper
    private let log: Log

    /// The child, or the attempt to make one, or the attempt to end one. One
    /// slot for all three, because "is there a helper" and "is somebody making
    /// one" have to be the same question or the answer races.
    private var live: Task<RPCSession, Error>?

    /// How many times one caller will look before giving up. It cannot spin:
    /// each round either returns, or retires a task that has already finished,
    /// and only one round in any caller's life installs a new one.
    private static let rounds = 4

    init(helper: Helper, log: Log) {
        self.helper = helper
        self.log = log
    }

    /// The live child, spawning one if the last is gone. The digest is checked
    /// on the way through, every time.
    func session() async throws -> RPCSession {
        for _ in 0..<Self.rounds {
            guard let inFlight = live else {
                // Nothing in the slot, and nothing between reading that and
                // filling it. This is the single-flight.
                let started = Task { try await self.spawn() }
                live = started
                return try await started.value
            }
            if let session = try? await inFlight.value, await session.isAlive {
                return session
            }
            // It failed, or the child it made has since died. Retired by
            // whoever notices first; a caller still holding the old task finds
            // whatever replaced it on the next round.
            if live == inFlight { live = nil }
        }
        throw RPCError.spawnFailed("the helper would not stay up")
    }

    private func spawn() async throws -> RPCSession {
        guard let executable = await helper.executable() else { throw RPCError.notVerified }
        let session = RPCSession(log: log)
        try await session.start(executable: executable)
        log.info("helper started")
        return session
    }

    /// Ends the child. The next caller gets a new one.
    func restart(_ why: String) async {
        log.warn("restarting the helper: \(why)")
        await end()
    }

    func stop() async {
        await end()
    }

    /// The kill, in the slot, so nothing starts a replacement over the top of
    /// a child that is still being ended.
    private func end() async {
        guard let inFlight = live else { return }
        let closing = Task<RPCSession, Error> {
            // Cancelled first so a spawn still waiting on a download gives up
            // rather than being waited for. A spawn that has already run the
            // child cannot be interrupted -- there is no suspension point left
            // in it -- so its session still comes back here to be shut down,
            // which is what keeps a kill from orphaning a process.
            inFlight.cancel()
            if let session = try? await inFlight.value { await session.shutdown() }
            throw RPCError.helperTerminated
        }
        live = closing
        _ = try? await closing.value
        if live == closing { live = nil }
    }
}
