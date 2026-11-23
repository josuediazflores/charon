import Foundation
import Observation
import SwiftUI

/* The app's state: the last payload, which message is open, and what this copy
 * has done to the mailbox that the payload has not caught up to yet.
 *
 * **`selection` is the single source of truth for which message is open**, and
 * it is the moral equivalent of the web's `#mail/<key>` hash route: the list
 * highlights off it, the pane draws off it, and the walk keys move it. Nothing
 * else holds an opinion about what is open.
 *
 * **The payload is the truth and the pending sets are the minute before it
 * agrees.** A click files a request; a worker on the Pi acts on it; the poller
 * notices on its own cadence and the collector re-reads its files on another,
 * so a message marked read is confirmed in about a minute rather than in a
 * tick. What a click needs is for the row to change NOW. Pending entries are
 * dropped the moment the payload agrees, which is what keeps this from becoming
 * a second source of truth.
 */

@MainActor
@Observable
final class MailModel {

    /// How often the mailbox is re-read. The collector re-reads its own files
    /// on a 60s cadence and this route is always current.
    private static let pollInterval: Duration = .seconds(10)

    // MARK: - the document

    private(set) var payload: TelemetryPayload?

    /// Whether the last fetch reached the collector at all.
    private(set) var reachable = false

    /// Whether the payload on screen came off disk rather than off the wire.
    /// Cleared by the first live answer and never set again.
    private(set) var hydrated = false

    /// When the payload arrived, for the rail's `last sync` line. For a
    /// rehydrated document this is when it *originally* arrived, which is the
    /// only honest reading of it.
    private(set) var fetchedAt: Date?

    /// What went wrong, in the collector's or URLSession's own words. Drawn on
    /// the Connecting panel in place of the waiting line.
    private(set) var error: String?

    /// The clock every relative time in the console is measured from, moved
    /// once per poll tick. Baking a "4m" into a payload makes it wrong the
    /// moment that payload is cached or a poll runs late, and reading
    /// `Date()` inside a view makes the number depend on when SwiftUI happened
    /// to redraw. One clock, moved on purpose.
    private(set) var now = Date()

    /// True until a fetch has landed, and again whenever one fails, and for as
    /// long as what is on screen came out of the cache. When the collector
    /// itself is unreachable no individual source has failed -- they are all
    /// merely unknown, which is why this is one flag over the whole console and
    /// not a status per source.
    var feedDown: Bool { !reachable || hydrated }

    var selection: String?

    // MARK: - what this copy has done

    /// Marked read here, not confirmed there.
    private(set) var readHere: Set<String> = []
    /// Marked unread here, not confirmed there.
    private(set) var freshHere: Set<String> = []
    /// Archived here, not confirmed there.
    private(set) var goneHere: Set<String> = []

    /// The chats this copy has marked read, not confirmed there. Chat keys, and
    /// the mailbox's rule word for word: a chat the payload does not list
    /// confirms nothing.
    private(set) var readHereChats: Set<String> = []

    private(set) var messageDelivery = MessageDeliveryLedger()
    private var featureRevision = 0

    func confirmFeature(_ enabled: Bool, for feature: ConsoleFeature) {
        featureRevision += 1
        if ConsoleSettings.shared.isEnabled(feature) != enabled {
            ConsoleSettings.shared.setEnabled(enabled, for: feature)
        }
    }

    private var messageTimers: [String: Task<Void, Never>] = [:]

    // MARK: - wiring

    private(set) var connection: Connection
    private(set) var store: MailStore

    /// Set by the reader whenever a field takes focus. Every bare-letter
    /// binding in the app checks it: a shortcut that did not would eat the j
    /// out of a sentence.
    var textFocused = false

    /// Bumped by the r key. The reader watches it rather than being handed a
    /// closure, which keeps the key handler in one place and the reader free to
    /// be remounted per message without re-registering anything.
    private(set) var replyRequests = 0

    var showingConnection = false

    /// Whether the window is in front and on screen. The poll stands down when
    /// it is not, and refetches the moment it comes back.
    var active = true {
        didSet {
            guard active, active != oldValue else { return }
            Task { await refresh() }
        }
    }

    private var pollTask: Task<Void, Never>?

    init() {
        let connection = Connection.load()
        self.connection = connection
        self.store = MailModel.makeStore(connection)

        // A cold start against a sleeping Pi draws last night's console rather
        // than a Connecting panel -- dimmed and labelled offline the whole
        // time, because `hydrated` keeps `feedDown` true until a live payload
        // lands. Demo mode is deliberately excluded: a fixture is not a
        // reading and rehydrating one would open the app offline over numbers
        // that were invented anyway.
        if connection.mode == .live, let cached = TelemetryCache.load() {
            payload = cached.payload
            fetchedAt = cached.at
            hydrated = true
        }
    }

    private static func makeStore(_ c: Connection) -> MailStore {
        guard c.mode == .live, let url = c.url else { return DemoStore() }
        return LiveClient(baseURL: url, token: c.token)
    }

    // MARK: - reading the mailbox

    var env: SourceEnvelope<MailData>? { payload?.mail }
    var data: MailData? { payload?.mail?.data }
    var messages: [MailMessageSummary] { payload?.mail?.data?.messages ?? [] }
    var counts: MailCounts? { payload?.mail?.data?.counts }
    var health: Health { HealthRule.health(env, feedDown: feedDown) }

    // ── the iMessage channel ──

    var messagesEnv: SourceEnvelope<MessagesData>? { payload?.messages }
    /// `messagesData` and not `messages`: `messages` is already the mailbox's
    /// own list on this model, and one word for two channels is a bug waiting
    /// for somebody in a hurry.
    var messagesData: MessagesData? { payload?.messages?.data }
    var messageChats: [MessageChatSummary] { payload?.messages?.data?.chats ?? [] }
    var messagesCounts: MessagesCounts? { payload?.messages?.data?.counts }
    var messagesHealth: Health { HealthRule.health(messagesEnv, feedDown: feedDown) }

    /// What a chat row should draw. The pending mark wins over the payload.
    func unreadCount(_ chat: MessageChatSummary) -> Int {
        readHereChats.contains(chat.chatKey) ? 0 : chat.unread
    }

    @discardableResult
    func markChatRead(_ chatKey: String) async -> Bool {
        if !readHereChats.contains(chatKey) { readHereChats.insert(chatKey) }
        let ok = await store.markRead(chatKey: chatKey)
        // Rolled back rather than left hopeful, exactly as the mailbox does.
        if !ok { readHereChats.remove(chatKey) }
        return ok
    }

    /// The undo window belongs to the model so switching chats cannot stop an authorized send.
    func holdMessage(_ request: MessageSendRequest) {
        guard messageDelivery.hold(request) else { return }
        let target = store
        messageTimers[request.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            guard ConsoleSettings.shared.isEnabled(.messages) else {
                _ = undoMessage(request.id)
                return
            }
            guard messageDelivery.begin(request) else { return }
            let outcome = await target.send(request)
            guard !Task.isCancelled else { return }
            messageDelivery.complete(request, with: outcome)
            messageTimers[request.id] = nil
        }
    }

    func cancelHeldMessages() {
        for id in Array(messageTimers.keys) { _ = undoMessage(id) }
    }

    func undoMessage(_ id: String) -> Bool {
        guard messageDelivery.undo(id) else { return false }
        messageTimers.removeValue(forKey: id)?.cancel()
        return true
    }

    func reconcileDelivery(chatKey: String, thread: MessageThread) {
        let outboundKeys = Set(thread.messages.filter(\.isFromMe).map(\.key))
        messageDelivery.reconcile(chatKey: chatKey, outbox: thread.outbox, outboundKeys: outboundKeys)
    }

    func refresh() async {
        // Moved before the request, not after it: every relative time on screen
        // is measured from this, and measuring them from the instant a slow
        // fetch returned would make an eight-second poll read as eight seconds
        // of staleness that never happened.
        now = Date()
        let source = store
        let revision = featureRevision
        do {
            let got = try await source.telemetry()
            // A connection change can complete while the previous collector is answering.
            guard source === store else { return }
            let at = Date()
            if revision == featureRevision, connection.mode == .live, let access = got.featureAccess {
                for (name, enabled) in access {
                    guard let feature = ConsoleFeature(rawValue: name),
                          ConsoleSettings.shared.isEnabled(feature) != enabled else { continue }
                    ConsoleSettings.shared.setEnabled(enabled, for: feature)
                }
            }
            payload = got
            reachable = true
            hydrated = false
            fetchedAt = at
            error = nil
            now = at
            if let raw = store.lastRawTelemetry { TelemetryCache.save(raw, at: at) }
            reconcile()
        } catch {
            guard source === store else { return }
            // The last known payload is kept and demoted rather than dropped. A
            // list that empties itself the first time a poll misses is a worse
            // lie than a list that says it is old.
            reachable = false
            self.error = MailModel.describe(error)
        }
    }

    /// The failure in the words its own layer used. `LocalizedError` carries
    /// the collector's status code; URLSession carries the transport's
    /// sentence. Neither is rewritten here -- a console that paraphrases its
    /// errors is a console you have to guess at.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.active { await self.refresh() }
                try? await Task.sleep(for: MailModel.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Point the app somewhere else. The pending sets are cleared with the
    /// store: they are claims about one mailbox, and carrying them across a
    /// switch would draw a demo row dim because a live one was archived.
    func apply(_ c: Connection) {
        c.save()
        connection = c
        store = MailModel.makeStore(c)
        payload = nil
        // The cache goes with them, and for the same reason: it is a claim
        // about one collector, and a rehydrated document under a new address
        // would be the old Pi's numbers wearing the new Pi's name.
        TelemetryCache.clear()
        reachable = false
        hydrated = false
        fetchedAt = nil
        error = nil
        selection = nil
        readHere = []
        freshHere = []
        goneHere = []
        readHereChats = []
        for timer in messageTimers.values { timer.cancel() }
        messageTimers.removeAll()
        messageDelivery = MessageDeliveryLedger()
        Task { await refresh() }
    }

    // MARK: - the pending contract
    //
    // Ported verbatim from `state/mailPending.ts`. Only a message the payload
    // actually lists can confirm anything: a key that fell off the end of the
    // list -- older than the fifty the collector carries -- has not been
    // confirmed read, it has merely gone quiet, and dropping the entry there
    // would let the reader file the same request again on every poll.

    private func reconcile() {
        reconcileMessages()
        guard let listed = payload?.mail?.data?.messages else { return }
        let byKey = Dictionary(listed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        // A pending read clears only when the payload lists the key AND says it
        // is no longer unread. A key the payload does not list confirms
        // nothing: `byKey[k]?.unread` is nil there, and nil != false keeps it.
        readHere = readHere.filter { byKey[$0]?.unread != false }

        // The mirror: an unread mark is confirmed when the payload says unread,
        // and an absent key again confirms nothing.
        freshHere = freshHere.filter { byKey[$0]?.unread != true }

        // Archiving is the other way round: the collector lists the inbox, so a
        // key it no longer names is the confirmation.
        goneHere = goneHere.filter { byKey[$0] != nil }
    }

    /// The same contract for the chats, and the one place it differs said out
    /// loud: a read mark is confirmed when the payload lists the chat AND says
    /// it has nothing unread, and a chat the payload does not list confirms
    /// nothing.
    private func reconcileMessages() {
        if let chats = payload?.messages?.data?.chats {
            let byKey = Dictionary(chats.map { ($0.chatKey, $0) },
                                   uniquingKeysWith: { a, _ in a })
            readHereChats = readHereChats.filter { byKey[$0]?.unread != 0 }
        }
    }

    func isRead(_ key: String) -> Bool { readHere.contains(key) }
    func isFresh(_ key: String) -> Bool { freshHere.contains(key) }
    func isArchived(_ key: String) -> Bool { goneHere.contains(key) }

    /// What a row should draw. The pending marks win over the payload, and the
    /// two of them cannot both be set.
    func unread(_ m: MailMessageSummary) -> Bool {
        (m.unread || freshHere.contains(m.key)) && !readHere.contains(m.key)
    }

    // MARK: - writes
    //
    // All three show the answer first and take it back if the collector refused.

    @discardableResult
    func markRead(_ key: String) async -> Bool {
        if !readHere.contains(key) {
            readHere.insert(key)
            // The two sets are one fact with two directions, so joining one is
            // leaving the other: a key in both would be a row that cannot
            // decide.
            freshHere.remove(key)
        }
        let ok = await store.markRead(key: key)
        if !ok {
            // Rolled back rather than left hopeful. The row goes back to
            // unread, which is what the mailbox still believes.
            readHere.remove(key)
        }
        return ok
    }

    @discardableResult
    func markUnread(_ key: String) async -> Bool {
        if !freshHere.contains(key) {
            freshHere.insert(key)
            readHere.remove(key)
        }
        let ok = await store.markUnread(key: key)
        if !ok { freshHere.remove(key) }
        return ok
    }

    @discardableResult
    func archive(_ key: String) async -> Bool {
        if !goneHere.contains(key) { goneHere.insert(key) }
        let ok = await store.archive(key: key)
        if !ok { goneHere.remove(key) }
        return ok
    }

    // MARK: - the walk
    //
    // Derived from the payload rather than held anywhere: the list is the thing
    // that decides the order, and reading its own array back is what keeps the
    // arrows walking the inbox in the order somebody actually saw it in. A key
    // the payload does not carry has no position and therefore no walk, which
    // is the honest answer rather than a guess at one.

    struct Walk {
        var prev: String?
        var next: String?
        /// `2/8`, or nil when this message is not in the list at all.
        var position: String?
    }

    func walk(from key: String) -> Walk {
        let keys = messages.map(\.key)
        guard let at = keys.firstIndex(of: key) else { return Walk() }
        return Walk(
            prev: at > 0 ? keys[at - 1] : nil,
            next: at < keys.count - 1 ? keys[at + 1] : nil,
            position: "\(at + 1)/\(keys.count)"
        )
    }

    // MARK: - the keymap
    //
    // j is down the list, which is older, which is `next` -- the list is newest
    // first and this is the only reading of j that agrees with it.

    /// Every binding is refused while a field has focus, and Escape is refused
    /// with them: a half-written reply may never be navigated out from under.
    var keysLive: Bool { !textFocused }

    func walkForward() {
        guard keysLive else { return }
        if let open = selection {
            if let next = walk(from: open).next { selection = next }
        } else {
            selection = messages.first?.key
        }
    }

    func walkBack() {
        guard keysLive else { return }
        if let open = selection {
            if let prev = walk(from: open).prev { selection = prev }
        } else {
            selection = messages.last?.key
        }
    }

    func requestReply() {
        guard keysLive, selection != nil else { return }
        replyRequests += 1
    }

    func closeMessage() {
        guard keysLive else { return }
        selection = nil
    }
}
