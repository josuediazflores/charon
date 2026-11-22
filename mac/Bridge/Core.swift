import Foundation

/* Everything the Bridge knows about itself, in one place.
 *
 * Four things write here -- the watcher, the courier, the helper's state and
 * the permissions probe -- and one thing reads it, the heartbeat. Keeping it
 * an actor rather than four fields in four objects means the heartbeat is
 * always one consistent answer rather than a photograph taken during a move.
 *
 * The cursor here is the persisted one, and it only ever moves to a rowid the
 * collector has acknowledged (section 7). The watcher keeps its own, further
 * along, in memory.
 */
actor Core {

    static let version = "0.1.0"

    let paths: Paths
    let log: Log
    let host: String

    private(set) var fda = false
    private(set) var automation = false
    private(set) var contacts = false
    private(set) var dbOk = false
    private(set) var helperState: HelperState = .missing
    private(set) var cursor: Int?
    private var firstLiveResume: Int?
    var resumeCursor: Int? { cursor ?? firstLiveResume }
    private(set) var dbIdentity: String?
    private(set) var lastEventAt: String?
    private(set) var dropped = 0
    private(set) var lastError: String?
    private(set) var allowlist = Allowlist.empty
    /// The chat directory as last listed, so an event can be given the service
    /// and the name its own row does not carry.
    private(set) var directory: [String: ChatRecord] = [:]
    /// The helper's own chat rowids, by GUID. Not part of any record: it is
    /// the handle a history page is asked for by, and nothing else.
    private(set) var chatIds: [String: Int] = [:]
    /// How far each chat's history has been read, by chat GUID.
    private(set) var backfill: [String: BackfillMark] = [:]
    /// How the uploads are going, as the uploader last reported them. Pushed
    /// here rather than pulled from there: the heartbeat asks this actor one
    /// question and gets one consistent answer, and a Core that had to await
    /// another actor to answer it would be a Core with a second lock in it.
    private(set) var attachments: AttachmentProgress?

    /// Set by anything worth telling the Pi about before the next beat.
    private var dirty = true

    init(paths: Paths, log: Log) {
        self.paths = paths
        self.log = log
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        self.host = name

        if let state = Store.read(BridgeState.self, from: paths.stateFile) {
            cursor = state.cursor
            firstLiveResume = state.firstLiveResume
            dbIdentity = state.dbIdentity
            lastEventAt = state.lastEventAt
            backfill = state.backfill ?? [:]
        }
        if let cached = Store.readData(from: paths.allowlistFile),
           let document = try? JSONDecoder().decode(JSONValue.self, from: cached) {
            allowlist = Allowlist(document)
        }
    }

    // MARK: - what the console is told

    func snapshot() -> Heartbeat {
        Heartbeat(version: Self.version,
                  host: host,
                  helper: .init(version: Pins.version, state: helperState),
                  fda: fda,
                  automation: automation,
                  dbOk: dbOk,
                  cursor: cursor,
                  lastEventAt: lastEventAt,
                  droppedNotAllowlisted: dropped,
                  lastError: lastError,
                  contacts: contacts,
                  backfill: progress(),
                  attachments: attachments)
    }

    /// The backfill's three numbers, counted from the two things that decide
    /// them: which chats are allowlisted now, and what the marks say about
    /// them. Nothing keeps a running total, so nothing can disagree with the
    /// file after a restart.
    ///
    /// Nil while there is nothing to say at all -- no chat allowed to be read
    /// and no history ever read -- so a collector that has no row for this
    /// field is not handed one for a channel that has not started.
    private func progress() -> BackfillProgress? {
        var pending = 0
        var done = 0
        for (guid, policy) in allowlist.byGuid where policy.read {
            if backfill[guid]?.done == true { done += 1 } else { pending += 1 }
        }
        let rows = backfill.values.reduce(0) { $0 + $1.count }
        if pending == 0 && done == 0 && rows == 0 { return nil }
        return BackfillProgress(pending: pending, done: done, rows: rows)
    }

    /// Whether anything has changed since the last beat, and clears the flag.
    func takeDirty() -> Bool {
        defer { dirty = false }
        return dirty
    }

    // MARK: - state, as it moves

    func note(fda: Bool, dbOk: Bool) {
        if self.fda != fda || self.dbOk != dbOk { dirty = true }
        self.fda = fda
        self.dbOk = dbOk
    }

    func note(automation: Bool) {
        if self.automation != automation { dirty = true }
        self.automation = automation
    }

    /// Whether Contacts is granted. Reported for the same reason the other two
    /// are: the console shows what this Mac will and will not be able to do,
    /// and a channel full of phone numbers has an explanation.
    ///
    /// Returns whether the answer changed, which is what makes the chat
    /// directory worth reading again.
    @discardableResult
    func note(contacts: Bool) -> Bool {
        let changed = self.contacts != contacts
        if changed { dirty = true }
        self.contacts = contacts
        return changed
    }

    /// What the uploader has done since this process started. Nil until it
    /// has done anything at all, so a collector with no row for the field is
    /// not handed one for a channel that has uploaded nothing.
    func note(attachments progress: AttachmentProgress) {
        let empty = progress.uploaded == 0 && progress.pending == 0
            && progress.failed == 0
        let fresh = empty ? nil : progress
        if attachments != fresh { dirty = true }
        attachments = fresh
    }

    func note(helper: HelperState) {
        if helperState != helper { dirty = true }
        helperState = helper
    }

    /// The last thing that went wrong, redacted, or nil to clear it.
    func note(error: String?) {
        let cleaned = error.map(redact)
        if lastError != cleaned { dirty = true }
        lastError = cleaned
    }

    func countDropped(_ n: Int) {
        guard n > 0 else { return }
        dropped += n
    }

    // MARK: - the cursor

    /// Which database the cursor belongs to. A different one and the cursor is
    /// meaningless: rowids are scoped to the file that minted them.
    func adopt(database identity: String) {
        guard dbIdentity != identity else { return }
        if dbIdentity != nil {
            log.warn("the Messages database changed — the cursor is being discarded")
            cursor = nil
            firstLiveResume = nil
            lastEventAt = nil
            // And the backfill's marks with it. Those are rowids too, and a
            // resume point from the old file would skip the start of the new
            // one and call the chat finished.
            backfill = [:]
        }
        dbIdentity = identity
        dirty = true
        persist()
    }

    /// A first subscription starts at now. Remember its starting point before
    /// the first network post, so a restart can replay that first batch too.
    func rememberFirstRow(_ rowid: Int) {
        guard resumeCursor == nil, rowid > 0 else { return }
        firstLiveResume = rowid - 1
        if !persist() { log.warn("could not checkpoint the start of the live stream") }
    }

    /// A rowid the collector has acknowledged, and the time of the newest
    /// event in that batch.
    @discardableResult
    func acked(cursor rowid: Int, lastEventAt stamp: String?) -> Bool {
        if let current = cursor, rowid <= current, stamp == nil { return true }
        let previous = (cursor, lastEventAt, firstLiveResume)
        firstLiveResume = nil
        cursor = max(rowid, cursor ?? rowid)
        if let stamp { lastEventAt = stamp }
        guard persist() else {
            (cursor, lastEventAt, firstLiveResume) = previous
            return false
        }
        dirty = true
        return true
    }

    /// Where one chat's history got to, after a page landed.
    ///
    /// Written straight through to disk rather than at the end of the run: a
    /// backfill can be thousands of rows long, and the whole point of the mark
    /// is that a Bridge which stops in the middle of one resumes instead of
    /// starting again.
    @discardableResult
    func mark(backfill chatGuid: String, _ mark: BackfillMark) -> Bool {
        let prior = backfill.updateValue(mark, forKey: chatGuid)
        guard persist() else {
            backfill[chatGuid] = prior
            return false
        }
        dirty = true
        return true
    }

    @discardableResult
    private func persist() -> Bool {
        Store.write(BridgeState(cursor: cursor,
                                firstLiveResume: firstLiveResume,
                                dbIdentity: dbIdentity,
                                lastEventAt: lastEventAt,
                                updatedAt: Stamp.now(),
                                backfill: backfill.isEmpty ? nil : backfill),
                    to: paths.stateFile)
    }

    // MARK: - the allowlist and the directory

    /// The config as the collector last served it. Cached verbatim so a
    /// restart with the Pi unreachable still enforces the same list.
    func adopt(config document: JSONValue, raw: Data?) -> Bool {
        let fresh = Allowlist(document)
        let changed = fresh != allowlist
        allowlist = fresh
        if let raw { Store.writeData(raw, to: paths.allowlistFile) }
        return changed
    }

    func adopt(directory chats: [ChatRecord], ids: [String: Int] = [:]) {
        var byGuid: [String: ChatRecord] = [:]
        for chat in chats { byGuid[chat.chatGuid] = chat }
        directory = byGuid
        adopt(chatIds: ids)
    }

    /// The helper's chat rowids, merged rather than replaced: a list that came
    /// back short is a list that is missing rowids, not one that revoked them,
    /// and the worst a stale id can cost is a refused page.
    func adopt(chatIds ids: [String: Int]) {
        for (guid, id) in ids { chatIds[guid] = id }
    }
}
