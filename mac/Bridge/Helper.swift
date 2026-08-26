import CryptoKit
import Foundation

/* The pinned helper: fetched once, hashed twice, and hashed again every time
 * it is about to be run.
 *
 * The reason for the third hash is the directory it lives in. Application
 * Support belongs to the user, so anything the user runs can write there --
 * which means a digest checked at install time says nothing about the file
 * this process is about to exec. Checking at spawn costs one read of ten
 * megabytes on a path taken only when a child dies.
 *
 * Three states, and only one of them spawns anything:
 *   verified  the file is there and is the file we pinned
 *   missing   nothing installed yet, or the install failed
 *   mismatch  something is there and it is not ours
 */
actor Helper {

    private let paths: Paths
    private let log: Log
    private let dryRun: Bool
    private let override: URL?

    private(set) var state: HelperState = .missing
    private var nextAttempt = Date.distantPast
    private var announcedOverride = false

    let version = Pins.version

    init(paths: Paths, log: Log, dryRun: Bool,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.log = log
        self.dryRun = dryRun
        #if DEBUG
        // A debug build may be pointed at a stand-in helper. This is how the
        // dry run drives a fake one, and it is the only path that skips the
        // digest -- because the file it names was chosen by whoever set the
        // variable, not fetched over the network.
        if let raw = environment["CHARON_IMSG_PATH"], !raw.isEmpty {
            override = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            override = nil
        }
        #else
        override = nil
        #endif
    }

    /// The helper to run, or nil when there is nothing safe to run.
    func executable() async -> URL? {
        if let override {
            let usable = FileManager.default.isExecutableFile(atPath: override.path)
            state = usable ? .verified : .missing
            if !announcedOverride {
                announcedOverride = true
                log.warn("helper is the override at \(override.path) — digest not checked")
            }
            return usable ? override : nil
        }

        let executable = paths.helperExecutable(version)
        if FileManager.default.fileExists(atPath: executable.path) {
            if digest(of: executable) == Pins.executableDigest {
                state = .verified
                return executable
            }
            state = .mismatch
            log.error("helper at \(executable.path) does not match the pinned digest")
        } else {
            state = .missing
        }

        // Not verified: nothing is spawned, and the fetch is attempted at most
        // once every five minutes so a release that will never arrive cannot
        // turn into a download loop.
        guard Date() >= nextAttempt else { return nil }
        nextAttempt = Date().addingTimeInterval(300)

        if dryRun {
            log.warn("dry run: would fetch imsg \(self.version) — refusing to download")
            return nil
        }

        do {
            try await install()
            state = .verified
            log.info("installed imsg \(self.version)")
            return paths.helperExecutable(version)
        } catch {
            log.error("helper install failed: \(error.redacted)")
            return nil
        }
    }

    // MARK: - install

    private enum Trouble: Error, CustomStringConvertible {
        case tooBig(Int)
        case archiveDigest
        case executableDigest
        case unpack(Int32)
        case missingExecutable

        var description: String {
            switch self {
            case .tooBig(let bytes): return "archive is \(bytes) bytes"
            case .archiveDigest: return "archive digest does not match the pin"
            case .executableDigest: return "executable digest does not match the pin"
            case .unpack(let status): return "ditto exited \(status)"
            case .missingExecutable: return "no imsg in the archive"
            }
        }
    }

    private func install() async throws {
        let fm = FileManager.default
        paths.ensure()
        try? fm.removeItem(at: paths.staging)
        try fm.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: paths.staging) }

        let archive = paths.staging.appendingPathComponent("imsg-macos.zip")
        let data = try await download(Pins.archiveURL)
        guard data.count <= Pins.archiveLimit else { throw Trouble.tooBig(data.count) }
        try data.write(to: archive)

        guard hex(SHA256.hash(data: data)) == Pins.archiveDigest else {
            throw Trouble.archiveDigest
        }

        let unpacked = paths.staging.appendingPathComponent("out", isDirectory: true)
        let ditto = await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                    ["-x", "-k", archive.path, unpacked.path],
                                    timeout: 120)
        guard ditto.ok else { throw Trouble.unpack(ditto.status) }

        let executable = unpacked.appendingPathComponent("imsg")
        guard fm.fileExists(atPath: executable.path) else { throw Trouble.missingExecutable }
        guard digest(of: executable) == Pins.executableDigest else {
            throw Trouble.executableDigest
        }

        // The archive also carries the dylib imsg injects into Messages for
        // its private lane. The Bridge calls six read-and-AppleScript methods
        // and none that need it, so it does not get installed: a capability
        // that is not on disk is one nothing can reach for by accident.
        try? fm.removeItem(at: unpacked.appendingPathComponent("imsg-bridge-helper.dylib"))

        // Only now. Clearing quarantine is the step that makes a downloaded
        // file runnable, so it happens after both digests and not before.
        _ = await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                            ["-dr", "com.apple.quarantine", unpacked.path],
                            timeout: 30)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try Pins.license.write(to: unpacked.appendingPathComponent("LICENSE-imsg.txt"),
                               atomically: true, encoding: .utf8)

        let destination = paths.helperDirectory(version)
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: unpacked, to: destination)
    }

    /// The asset, with a ceiling. Content-Length is checked first so an
    /// enormous body is refused before it is read, and the bytes are counted
    /// again afterwards because a header is a claim.
    private func download(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw Collector.Failure.http(http.statusCode)
            }
        }
        if response.expectedContentLength > Int64(Pins.archiveLimit) {
            throw Trouble.tooBig(Int(response.expectedContentLength))
        }
        return data
    }

    // MARK: - digests

    private func digest(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
