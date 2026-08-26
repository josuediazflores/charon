import Foundation

/* Thirty seconds, or sooner if anything changed.
 *
 * The console decides the channel is degraded after two minutes without one of
 * these (section 6), so the beat is the one request the Bridge makes whether
 * or not it has anything to say. It is also the only way a missing permission
 * reaches the Pi: the Bridge reports the two grants, it never asks for them.
 */
actor Heartbeater {

    private let core: Core
    private let collector: Collector
    private let log: Log
    private var last = Date.distantPast

    private static let every: TimeInterval = 30

    init(core: Core, collector: Collector, log: Log) {
        self.core = core
        self.collector = collector
        self.log = log
    }

    func run() async {
        while !Task.isCancelled {
            await beatIfDue()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func beatIfDue() async {
        let due = Date().timeIntervalSince(last) >= Self.every
        // Asking clears the flag, so a change is beaten exactly once.
        let changed = await core.takeDirty()
        guard due || changed else { return }
        await beat()
    }

    /// One beat, now.
    func beat() async {
        last = Date()
        let snapshot = await core.snapshot()
        do {
            _ = try await collector.post("/v1/messages/bridge", try JSONValue.of(snapshot))
        } catch {
            log.warn("heartbeat failed: \(error.redacted)")
        }
    }
}
