import AppKit
import Contacts
import Foundation
import ServiceManagement

/* Start everything, once, and then stay out of the way.
 *
 * The only interface this program has is the alert below, shown the first time
 * it is launched and never again. Everything after that is four loops and a
 * log file.
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let options: Options
    private var tasks: [Task<Void, Never>] = []
    private var log: Log?
    private var watcher: Watcher?
    private var supervisor: RPCSupervisor?
    private var backfill: Backfill?

    /// Nonisolated so main.swift can build one before the run loop exists.
    /// It sets one stored property; there is nothing here to race over.
    nonisolated init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for task in tasks { task.cancel() }
    }

    // MARK: - starting

    private func start() async {
        let paths = Paths.resolve()
        paths.ensure()
        let log = Log(file: paths.logFile, level: options.level)
        self.log = log
        let how = (options.dryRun ? " (dry run)" : "") + (options.once ? " (once)" : "")
        log.info("Charon Bridge \(Core.version) starting" + how)

        guard let base = Wiring.base() else {
            log.error("no collector address — stopping")
            exit(1)
        }
        let token = Wiring.token()
        guard !token.isEmpty else {
            // Idle rather than loud. The token arrives with scripts/connect-live.sh
            // and this process is restarted with it; a Bridge that cannot
            // authenticate has nothing useful to do and no way to ask.
            log.error("no collector token in the Keychain — idle")
            return
        }

        let core = Core(paths: paths, log: log)
        let collector = Collector(base: base, token: token, dryRun: options.dryRun, log: log)
        let helper = Helper(paths: paths, log: log, dryRun: options.dryRun)
        let supervisor = RPCSupervisor(helper: helper, log: log)
        let watcher = Watcher(core: core, supervisor: supervisor,
                              collector: collector, helper: helper, log: log)
        let courier = Courier(core: core, supervisor: supervisor,
                              collector: collector, log: log, dryRun: options.dryRun)
        let heart = Heartbeater(core: core, collector: collector, log: log)
        let backfill = Backfill(core: core, supervisor: supervisor,
                                collector: collector, log: log)
        let uploader = Attachments(core: core, supervisor: supervisor,
                                   collector: collector, log: log)
        await watcher.pair(with: courier)
        await courier.pair(with: watcher)
        await courier.pair(with: backfill)
        // Both upstream paths tell the uploader what went past; only the
        // courier's loop ticks it. Section 7: a history's paths are worth
        // remembering and none of its files is worth sending unasked.
        await watcher.pair(with: uploader)
        await backfill.pair(with: uploader)
        await courier.pair(with: uploader)
        self.watcher = watcher
        self.supervisor = supervisor
        self.backfill = backfill

        // Reading the answer never asks the question, so it is read in every
        // mode. Asking happens once, further down, and only on a real launch.
        await core.note(contacts: Grants.contacts)

        await firstRunIfNeeded(paths: paths, courier: courier, log: log)

        if options.once {
            await once(core: core, supervisor: supervisor, helper: helper,
                       courier: courier, heart: heart, log: log)
            await stop("--once", drain: false)
            return
        }

        // The allowlist before the stream. A subscription that started first
        // would spend its first seconds dropping rows it has no list to check
        // them against.
        await courier.refreshConfig()

        tasks.append(Task { await watcher.run() })
        tasks.append(Task { await courier.run() })
        tasks.append(Task { await heart.run() })
        tasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await watcher.tick()
            }
        })

        if let seconds = options.exitAfter {
            tasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.stop("--exit-after", drain: true)
            })
        }

        // Last, and after the loops are up, because the person answering the
        // dialog may take a while and nothing here should wait on them.
        askAboutContacts(core: core, watcher: watcher, log: log)
    }

    // MARK: - the third permission

    /// Contacts, asked for once and never again.
    ///
    /// It is the difference between a list of phone numbers and a list of
    /// people. The grant belongs to this app, and the helper it spawns
    /// inherits it, which is why the question is asked here rather than left
    /// to a child nobody can see answering it.
    ///
    /// Only when macOS has never been asked. A refusal is a decision and this
    /// program does not argue with it: there is no second prompt, no reminder
    /// and no nagging on the next launch. System Settings is where a person
    /// changes their mind.
    private func askAboutContacts(core: Core, watcher: Watcher, log: Log) {
        guard !options.dryRun, !options.once else { return }
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else {
            return
        }
        Task { @MainActor in
            let granted: Bool
            do {
                granted = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                log.warn("the Contacts prompt returned an error: \(error.redacted)")
                granted = false
            }
            log.info(redact(granted ? "Contacts granted, chats will show names"
                                    : "Contacts denied, chats will show handles"))
            // The directory was read under the old answer, so it is worth
            // reading again under the new one rather than waiting five
            // minutes for the console to learn everybody's name.
            if await core.note(contacts: granted) {
                await watcher.contactsChanged()
            }
        }
    }

    /// One status and one heartbeat, for a person checking whether this thing
    /// works at all.
    private func once(core: Core, supervisor: RPCSupervisor, helper: Helper,
                      courier: Courier, heart: Heartbeater, log: Log) async {
        do {
            let session = try await supervisor.session()
            let status = try await session.call("status")
            let ready = status["database"]?["ready"]?.boolValue ?? false
            await core.note(fda: ready, dbOk: ready)
            await core.note(helper: await helper.state)
            log.info("status: database \(ready ? "readable" : "not readable")"
                + ", imsg \(status["version"]?.stringValue ?? "?")")
        } catch {
            await core.note(helper: await helper.state)
            await core.note(error: error.redacted)
            log.error("status failed: \(error.redacted)")
        }
        await courier.probeNow()
        await heart.beat()
    }

    // MARK: - the one thing the user sees

    private func firstRunIfNeeded(paths: Paths, courier: Courier, log: Log) async {
        guard !options.dryRun, !options.once else { return }
        guard !FileManager.default.fileExists(atPath: paths.firstRunMarker.path) else { return }

        do {
            try SMAppService.mainApp.register()
            log.info("registered as a login item")
        } catch {
            log.error("could not register as a login item: \(error.redacted)")
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Charon Bridge needs two permissions"
        alert.informativeText = """
            It runs on this Mac as a login item, with no window. Only allowlisted \
            chats leave the Mac; they go to the Pi over Tailscale, like mail does.

            Full Disk Access lets it read new messages. Automation for Messages lets \
            it send the replies you confirm, from your own number.

            Add “Charon Bridge” under Full Disk Access, then answer the Messages \
            prompt that follows.
            """
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let settings = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(settings)
        }

        // Asked once, here, so macOS raises its Automation prompt while the
        // person who has to answer it is still looking at the screen.
        await courier.probeNow()

        try? Data().write(to: paths.firstRunMarker)
    }

    // MARK: - stopping

    private func stop(_ why: String, drain: Bool) async {
        log?.info("stopping: \(why)")
        for task in tasks { task.cancel() }
        tasks = []
        await backfill?.stop()
        if drain { await watcher?.drain() }
        await supervisor?.stop()
        exit(0)
    }
}

/// What macOS says about the permissions this program only ever reports on.
enum Grants {

    /// Whether Contacts is granted right now.
    ///
    /// Reading the status never raises a prompt, which is why it is read in
    /// every mode including the dry run: the heartbeat can say what this Mac
    /// will be able to name without anything appearing on screen to ask.
    static var contacts: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }
}
