import Darwin
import Foundation

/// A send crosses into Messages only after its conservative recovery report is on disk.
/// Older Bridges read the same 'ids' list and will skip outstanding attempts.
final class DeliveryJournal {
    struct State: Codable {
        var ids: [String] = []
        var reports: [String: JSONValue] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            ids = try fields.decode([String].self, forKey: .ids)
            reports = try fields.decodeIfPresent([String: JSONValue].self, forKey: .reports) ?? [:]
        }
    }

    static let interrupted = JSONValue.object([
        "status": .string("failed"), "error": .string("interrupted"),
        "disposition": .string("may_have_completed"), "retry_safe": .bool(false),
    ])

    private let file: URL
    private let lock: FileHandle
    private(set) var state: State

    init(file: URL) throws {
        self.file = file
        // Atomic writes replace the data inode. Lock a stable neighbor so another
        // Bridge launched with the same home cannot claim the same outbox item.
        let fd = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        lock = handle
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = State()
        }
    }

    /// The fallback is also what a restart reports if the helper never answered.
    func begin(_ id: String) -> Bool {
        var next = state
        if !next.ids.contains(id) { next.ids.append(id) }
        next.reports[id] = Self.interrupted
        guard Store.write(next, to: file) else { return false }
        state = next
        return true
    }

    /// Keep the exact answer in memory even if the disk has filled since begin().
    /// A process loss in that window still leaves the safe fallback on disk.
    func record(_ id: String, report: JSONValue) -> Bool {
        state.reports[id] = report
        return Store.write(state, to: file)
    }

    func acknowledged(_ id: String) -> Bool {
        var next = state
        next.reports.removeValue(forKey: id)
        let finished = next.ids.filter { next.reports[$0] == nil }
        let expired = Set(finished.dropLast(500))
        next.ids.removeAll { expired.contains($0) }
        guard Store.write(next, to: file) else { return false }
        state = next
        return true
    }
}
