import Foundation

/* One log, written in order.
 *
 * ~/Library/Logs/Charon/bridge.log, rotated at five megabytes, three kept.
 * Four writers reach it -- the watcher, the courier, the heartbeat and the
 * helper -- and they are four different actors, so the file is guarded by a
 * serial queue rather than by an actor: a log call that had to be awaited
 * would put the log in the middle of every piece of control flow it exists to
 * describe.
 */
final class Log: @unchecked Sendable {

    enum Level: Int, Comparable, Sendable {
        case error = 0, warn = 1, info = 2, debug = 3

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        static func named(_ name: String) -> Level? {
            switch name.lowercased() {
            case "error": return .error
            case "warn", "warning": return .warn
            case "info": return .info
            case "debug": return .debug
            default: return nil
            }
        }

        var tag: String {
            switch self {
            case .error: return "ERROR"
            case .warn: return "WARN "
            case .info: return "INFO "
            case .debug: return "DEBUG"
            }
        }
    }

    static let rotateAt = 5 * 1024 * 1024
    static let keep = 3

    private let file: URL
    private let level: Level
    private let queue = DispatchQueue(label: "charon.bridge.log")
    private let stamp: DateFormatter

    init(file: URL, level: Level) {
        self.file = file
        self.level = level
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        self.stamp = f
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    func error(_ line: @autoclosure @escaping () -> String) { write(.error, line) }
    func warn(_ line: @autoclosure @escaping () -> String) { write(.warn, line) }
    func info(_ line: @autoclosure @escaping () -> String) { write(.info, line) }
    func debug(_ line: @autoclosure @escaping () -> String) { write(.debug, line) }

    private func write(_ level: Level, _ line: @escaping () -> String) {
        guard level <= self.level else { return }
        let at = Date()
        queue.async { [self] in
            let text = "\(stamp.string(from: at)) \(level.tag) \(redact(line()))\n"
            FileHandle.standardError.write(Data(text.utf8))
            rotateIfBig()
            append(Data(text.utf8))
        }
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotateIfBig() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int,
              size >= Self.rotateAt
        else { return }
        // bridge.log.3 falls off the end; the rest shift down one.
        let oldest = file.appendingPathExtension(String(Self.keep))
        try? fm.removeItem(at: oldest)
        for n in stride(from: Self.keep - 1, through: 1, by: -1) {
            let from = file.appendingPathExtension(String(n))
            let to = file.appendingPathExtension(String(n + 1))
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
        }
        try? fm.moveItem(at: file, to: file.appendingPathExtension("1"))
    }
}
