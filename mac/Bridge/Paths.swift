import Foundation

/* Where the Bridge keeps its four files and its helper.
 *
 * ~/Library/Application Support/Charon Bridge/
 *   imsg/0.14.1/imsg          the pinned helper, and its licence
 *   state.json                cursor, which database it belongs to, last event
 *   allowlist.json            the collector's config, as last seen
 *   outbox-seen.json          ids already acted on, so a send is attempted once
 *   attachments-seen.json     where the file behind each forwarded attachment
 *                             was, so a want can be answered years later
 *   first-run                 written after the permissions alert has been shown
 *
 * CHARON_BRIDGE_HOME moves the whole directory, log included. It exists for
 * the dry run and the tests: a test that wrote into the real Application
 * Support would be a test that could break the running install.
 */
struct Paths: Sendable {

    let root: URL
    let logFile: URL

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Paths {
        if let override = environment["CHARON_BRIDGE_HOME"], !override.isEmpty {
            let root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return Paths(root: root, logFile: root.appendingPathComponent("bridge.log"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            root: home.appendingPathComponent("Library/Application Support/Charon Bridge",
                                              isDirectory: true),
            logFile: home.appendingPathComponent("Library/Logs/Charon/bridge.log"))
    }

    var helperRoot: URL { root.appendingPathComponent("imsg", isDirectory: true) }
    func helperDirectory(_ version: String) -> URL {
        helperRoot.appendingPathComponent(version, isDirectory: true)
    }
    func helperExecutable(_ version: String) -> URL {
        helperDirectory(version).appendingPathComponent("imsg")
    }

    var stateFile: URL { root.appendingPathComponent("state.json") }
    var allowlistFile: URL { root.appendingPathComponent("allowlist.json") }
    var outboxSeenFile: URL { root.appendingPathComponent("outbox-seen.json") }
    /// Where the file behind each forwarded attachment was. Paths only, and
    /// they never leave this directory.
    var attachmentsSeenFile: URL {
        root.appendingPathComponent("attachments-seen.json")
    }
    var firstRunMarker: URL { root.appendingPathComponent("first-run") }

    /// Staging for a download, beside the destination so the move that
    /// finishes an install is a rename on one volume.
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: helperRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
    }
}
