import AppKit
import Foundation

/* Charon Bridge — the Mac half of the Messages channel.
 *
 * No window, no menu, no dock tile: an NSApplication only because a program
 * that has to show one permissions alert and send Apple events needs a run
 * loop and an app identity to be granted them against.
 */

/// A child that dies mid-write should be an error we handle, not a signal that
/// takes this process down with it.
signal(SIGPIPE, SIG_IGN)

struct Options: Sendable {
    var dryRun = false
    var once = false
    var level: Log.Level = .info
    var exitAfter: TimeInterval?

    static let usage = """
        Charon Bridge \(Core.version)

          --dry-run            drive the helper named by CHARON_IMSG_PATH and the
                               collector at CHARON_COLLECTOR_URL, print every request
                               as a JSON line, and refuse to download the real helper,
                               register a login item, or run osascript
          --once               one status and one heartbeat, then exit
          --exit-after <secs>  run normally and stop after this long
          --log-level <level>  error · warn · info · debug   (default: info)
        """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var rest = arguments.dropFirst().makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--dry-run": options.dryRun = true
            case "--once": options.once = true
            case "--log-level":
                guard let name = rest.next(), let level = Log.Level.named(name) else {
                    return nil
                }
                options.level = level
            case "--exit-after":
                guard let raw = rest.next(), let seconds = TimeInterval(raw) else { return nil }
                options.exitAfter = seconds
            case "--help", "-h":
                return nil
            default:
                // A flag Xcode adds when it launches a scheme is not an
                // argument this program should refuse to start over.
                if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                    _ = rest.next()
                    continue
                }
                return nil
            }
        }
        return options
    }
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(Options.usage)
    exit(0)
}

guard let options = Options.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}

/* The dry run needs somewhere safe to point. Without both overrides it would
 * either reach for the real helper or the real collector, and refusing to
 * guess is the whole reason the flag exists.
 */
if options.dryRun {
    let environment = ProcessInfo.processInfo.environment
    let helper = environment["CHARON_IMSG_PATH"] ?? ""
    let collector = environment["CHARON_COLLECTOR_URL"] ?? ""
    if helper.isEmpty || collector.isEmpty {
        let plan = JSONValue.object([
            "would": .string("nothing"),
            "why": .string("a dry run needs CHARON_IMSG_PATH and CHARON_COLLECTOR_URL"),
            "with_them_it_would": .array([
                .string("spawn that helper and call status, chats.list, watch.subscribe"),
                .string("POST /v1/messages/ingest, /v1/messages/chats, /v1/messages/bridge"),
                .string("GET /v1/messages/config and /v1/messages/outbox?status=queued"),
                .string("call send for a queued item and POST /v1/messages/outbox/<id>"),
            ]),
            "would_not": .array([
                .string("download the pinned helper"),
                .string("register a login item"),
                .string("run osascript against Messages"),
            ]),
        ])
        if let line = try? JSONEncoder().encode(plan) {
            FileHandle.standardOutput.write(line + Data("\n".utf8))
        }
        exit(0)
    }
}

/* Top-level code is not on the main actor unless it awaits something, and
 * every one of these calls is. This is main.swift: it is running on the main
 * thread, so saying so costs nothing and is true.
 */
let delegate = AppDelegate(options: options)
MainActor.assumeIsolated {
    let application = NSApplication.shared
    // Accessory, not regular: no dock tile and no menu bar. The delegate is
    // held by the constant above because NSApplication keeps its delegate
    // weakly.
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}
