import Foundation

/* Running one short-lived tool and coming back with an answer either way.
 *
 * Three things get run this way: ditto and xattr while installing the helper,
 * and osascript to ask Messages its name. All three can hang -- Messages in
 * particular can sit behind a permission dialog forever -- so every one of
 * them is on a watchdog, and a tool that outlives its watchdog is killed
 * rather than waited for.
 */
enum Shell {

    struct Outcome: Sendable {
        var status: Int32
        var timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
    }

    /// A latch, so a process that exits just as its watchdog fires resumes the
    /// caller exactly once.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) async -> Outcome {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        // Output is not wanted and an unread pipe is a place to get stuck.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let latch = Latch()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                guard latch.claim() else { return }
                continuation.resume(returning: Outcome(status: finished.terminationStatus,
                                                       timedOut: false))
            }
            do {
                try process.run()
            } catch {
                guard latch.claim() else { return }
                continuation.resume(returning: Outcome(status: -1, timedOut: false))
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                guard latch.claim() else { return }
                continuation.resume(returning: Outcome(status: -1, timedOut: true))
            }
        }
    }
}
