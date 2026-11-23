import Foundation

/* The CMO's own shapes, plus the two conversation features beside it --
 * ported from the web console's model layer.
 *
 * Everything here decodes by hand for `Models.swift`'s reason: a collector
 * older or newer than this build should render what it can rather than throw
 * the whole telemetry document away over one field. Every list is `?? []` and
 * every scalar has a default, which is the same rule the mail models follow.
 *
 * The chat and jarvis types are here in full even though Stage B1 draws none of
 * them. They are what `LiveClient`'s routes return, and a route whose answer has
 * no type is a route that gets typed twice.
 */

// MARK: - what a write came back as

/// Three outcomes rather than a boolean.
///
/// 409 is a real answer on these routes and not an error: it means a turn is
/// already in flight, which the view already knows how to draw and must not
/// draw as a failure. Everything else -- refused, unreachable, malformed -- is
/// one FAILED line, 401 included and deliberately not singled out.
enum WriteResult: Equatable {
    case ok, busy, failed
}

// MARK: - the run

/// The wrapper's vocabulary, verbatim. `no_new_items` is a success: the sweep
/// ran, found nothing new, and said so -- a different fact from a run that
/// failed, and the two must not draw the same.
enum CmoRunStatus: String, Equatable {
    case running, ok
    case noNewItems = "no_new_items"
    case failedTimeout = "failed_timeout"
    case authExpired = "auth_expired"
    case failedNoBriefing = "failed_no_briefing"
    case failedClaudeError = "failed_claude_error"
    /// A word this build has never heard of. Not a throw: an unrecognised run
    /// status is still a run, and the page head has a sentence for it.
    case unknown
}

extension CmoRunStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = CmoRunStatus(rawValue: raw) ?? .unknown
    }
}

/// Written by the shell wrapper, not by the agent, which is why it survives
/// every way the agent can fail.
struct CmoHeartbeat: Equatable {
    var source: String
    var schemaVersion: Int
    var status: CmoRunStatus
    /// The full sentence about this run. Panel body material; the short phrase
    /// that becomes the status pill is the envelope's `stale_reason`.
    var detail: String?
    var runDate: String
    var startedAt: String?
    /// Null while a run is in flight, which is how "running" is told apart from
    /// "finished" without trusting a clock.
    var finishedAt: String?
    var durationSec: Double?
    var attempt: Int?
    var newItems: Int?
    /// Repo-relative path, `briefings/YYYY-MM-DD.md`.
    var briefing: String?
    var commit: String?
    var nextRun: String?

    init(source: String = "cmo", schemaVersion: Int = 1,
         status: CmoRunStatus = .unknown, detail: String? = nil,
         runDate: String = "", startedAt: String? = nil, finishedAt: String? = nil,
         durationSec: Double? = nil, attempt: Int? = nil, newItems: Int? = nil,
         briefing: String? = nil, commit: String? = nil, nextRun: String? = nil) {
        self.source = source
        self.schemaVersion = schemaVersion
        self.status = status
        self.detail = detail
        self.runDate = runDate
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSec = durationSec
        self.attempt = attempt
        self.newItems = newItems
        self.briefing = briefing
        self.commit = commit
        self.nextRun = nextRun
    }
}

extension CmoHeartbeat: Decodable {
    private enum K: String, CodingKey {
        case source, schemaVersion, status, detail, runDate, startedAt, finishedAt
        case durationSec, attempt, newItems, briefing, commit, nextRun
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "cmo"
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        status = (try? c.decode(CmoRunStatus.self, forKey: .status)) ?? .unknown
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        runDate = (try? c.decodeIfPresent(String.self, forKey: .runDate)) ?? ""
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(String.self, forKey: .finishedAt)
        durationSec = try? c.decodeIfPresent(Double.self, forKey: .durationSec)
        attempt = try? c.decodeIfPresent(Int.self, forKey: .attempt)
        newItems = try? c.decodeIfPresent(Int.self, forKey: .newItems)
        briefing = try? c.decodeIfPresent(String.self, forKey: .briefing)
        commit = try? c.decodeIfPresent(String.self, forKey: .commit)
        nextRun = try? c.decodeIfPresent(String.self, forKey: .nextRun)
    }
}

// MARK: - what the run found

/// One line of the briefing, at the priority the agent assigned it. `pri` is
/// 1 to 3, 1 meaning act today.
struct CmoItem: Equatable {
    var pri: Int
    var lane: String
    var title: String
    /// The item's first_seen date. Optional: runs before 2026-08-15 did not
    /// emit it, and the view falls back to the run's own day -- which is what
    /// `added` means for a brand-new item anyway.
    var added: String?

    init(pri: Int = 3, lane: String = "", title: String = "", added: String? = nil) {
        self.pri = pri
        self.lane = lane
        self.title = title
        self.added = added
    }
}

extension CmoItem: Decodable {
    private enum K: String, CodingKey { case pri, lane, title, added }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        pri = (try? c.decodeIfPresent(Int.self, forKey: .pri)) ?? 3
        lane = (try? c.decodeIfPresent(String.self, forKey: .lane)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        added = try? c.decodeIfPresent(String.self, forKey: .added)
    }
}

struct CmoPipeline: Equatable {
    var new: Int
    var drafted: Int
    var contacted: Int
    var dead: Int

    init(new: Int = 0, drafted: Int = 0, contacted: Int = 0, dead: Int = 0) {
        self.new = new
        self.drafted = drafted
        self.contacted = contacted
        self.dead = dead
    }
}

extension CmoPipeline: Decodable {
    private enum K: String, CodingKey { case new, drafted, contacted, dead }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        new = (try? c.decodeIfPresent(Int.self, forKey: .new)) ?? 0
        drafted = (try? c.decodeIfPresent(Int.self, forKey: .drafted)) ?? 0
        contacted = (try? c.decodeIfPresent(Int.self, forKey: .contacted)) ?? 0
        dead = (try? c.decodeIfPresent(Int.self, forKey: .dead)) ?? 0
    }
}

struct CmoDraft: Equatable {
    var title: String
    /// Who it is waiting on -- "operator", "sam review".
    var target: String

    init(title: String = "", target: String = "") {
        self.title = title
        self.target = target
    }
}

extension CmoDraft: Decodable {
    private enum K: String, CodingKey { case title, target }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
    }
}

struct CmoLane: Equatable {
    var lane: String
    var ready: Int

    init(lane: String = "", ready: Int = 0) {
        self.lane = lane
        self.ready = ready
    }
}

extension CmoLane: Decodable {
    private enum K: String, CodingKey { case lane, ready }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        lane = (try? c.decodeIfPresent(String.self, forKey: .lane)) ?? ""
        ready = (try? c.decodeIfPresent(Int.self, forKey: .ready)) ?? 0
    }
}

struct CmoWatch: Equatable {
    var name: String
    /// Both nullable, and routinely null together: a competitor with no news
    /// keeps its entry and gains nothing, because quiet is the normal state of
    /// a watchlist and not a gap to be filled.
    var event: String?
    var when: String?

    init(name: String = "", event: String? = nil, when: String? = nil) {
        self.name = name
        self.event = event
        self.when = when
    }
}

extension CmoWatch: Decodable {
    private enum K: String, CodingKey { case name, event, when }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        event = try? c.decodeIfPresent(String.self, forKey: .event)
        when = try? c.decodeIfPresent(String.self, forKey: .when)
    }
}

struct CmoMemory: Equatable {
    var seen: Int?
    var leads: Int?
    var dedupedToday: Int?
    /// The date of the last compaction, or nil if it has never run. A date
    /// rather than a flag: "compacted" is only useful as "when".
    var compacted: String?

    init(seen: Int? = nil, leads: Int? = nil, dedupedToday: Int? = nil,
         compacted: String? = nil) {
        self.seen = seen
        self.leads = leads
        self.dedupedToday = dedupedToday
        self.compacted = compacted
    }
}

extension CmoMemory: Decodable {
    private enum K: String, CodingKey { case seen, leads, dedupedToday, compacted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        seen = try? c.decodeIfPresent(Int.self, forKey: .seen)
        leads = try? c.decodeIfPresent(Int.self, forKey: .leads)
        dedupedToday = try? c.decodeIfPresent(Int.self, forKey: .dedupedToday)
        compacted = try? c.decodeIfPresent(String.self, forKey: .compacted)
    }
}

/// The agent's own account of its run, written as its last action. Every field
/// is nullable because a partial run still writes this file.
struct CmoAgentResult: Equatable {
    var newItems: Int?
    var briefing: String?
    var leadsUpdated: Int?
    var summary: String?
    var items: [CmoItem]
    var pipeline: CmoPipeline?
    var drafts: [CmoDraft]
    var memory: CmoMemory?
    var lanes: [CmoLane]
    var watchlist: [CmoWatch]

    init(newItems: Int? = nil, briefing: String? = nil, leadsUpdated: Int? = nil,
         summary: String? = nil, items: [CmoItem] = [], pipeline: CmoPipeline? = nil,
         drafts: [CmoDraft] = [], memory: CmoMemory? = nil, lanes: [CmoLane] = [],
         watchlist: [CmoWatch] = []) {
        self.newItems = newItems
        self.briefing = briefing
        self.leadsUpdated = leadsUpdated
        self.summary = summary
        self.items = items
        self.pipeline = pipeline
        self.drafts = drafts
        self.memory = memory
        self.lanes = lanes
        self.watchlist = watchlist
    }
}

extension CmoAgentResult: Decodable {
    private enum K: String, CodingKey {
        case newItems, briefing, leadsUpdated, summary, items, pipeline
        case drafts, memory, lanes, watchlist
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        newItems = try? c.decodeIfPresent(Int.self, forKey: .newItems)
        briefing = try? c.decodeIfPresent(String.self, forKey: .briefing)
        leadsUpdated = try? c.decodeIfPresent(Int.self, forKey: .leadsUpdated)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        items = (try? c.decodeIfPresent([CmoItem].self, forKey: .items)) ?? []
        pipeline = try? c.decodeIfPresent(CmoPipeline.self, forKey: .pipeline)
        drafts = (try? c.decodeIfPresent([CmoDraft].self, forKey: .drafts)) ?? []
        memory = try? c.decodeIfPresent(CmoMemory.self, forKey: .memory)
        lanes = (try? c.decodeIfPresent([CmoLane].self, forKey: .lanes)) ?? []
        watchlist = (try? c.decodeIfPresent([CmoWatch].self, forKey: .watchlist)) ?? []
    }
}

/// One day of the fortnight strip. The collector zero-fills the quiet days
/// rather than omitting them: a strip built only from the days that had items
/// draws a flat line over a dead fortnight and reads as steady.
struct CmoDay: Equatable {
    var date: String
    var count: Int

    init(date: String = "", count: Int = 0) {
        self.date = date
        self.count = count
    }
}

extension CmoDay: Decodable {
    private enum K: String, CodingKey { case date, count }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
    }
}

// MARK: - curation

enum CmoDismissKind: String, Equatable {
    case item, draft
}

extension CmoDismissKind: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = CmoDismissKind(rawValue: raw) ?? .item
    }
}

/// One thing the user has waved off.
///
/// A curation act on his view, not a deletion: the item stays in the agent's
/// memory -- which is exactly what stops it being rediscovered as new next week
/// -- and the console dims its row rather than removing it. Identity is
/// `kind` + `title` + `date`, the same key the collector matches on; `lane` is
/// a label that rides along for the archive table.
struct CmoDismissed: Equatable {
    var kind: CmoDismissKind
    /// Verbatim as the console showed it, which is what the collector stores.
    var title: String
    /// The item's lane. Always nil for a draft, which has no lane.
    var lane: String?
    /// The briefing day it came from.
    var date: String
    /// Local ISO seconds, written by the collector. Never rendered as an age.
    var dismissedAt: String

    init(kind: CmoDismissKind, title: String, lane: String? = nil,
         date: String, dismissedAt: String = "") {
        self.kind = kind
        self.title = title
        self.lane = lane
        self.date = date
        self.dismissedAt = dismissedAt
    }
}

extension CmoDismissed: Decodable {
    private enum K: String, CodingKey { case kind, title, lane, date, dismissedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = (try? c.decode(CmoDismissKind.self, forKey: .kind)) ?? .item
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        lane = try? c.decodeIfPresent(String.self, forKey: .lane)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        dismissedAt = (try? c.decodeIfPresent(String.self, forKey: .dismissedAt)) ?? ""
    }
}

/// A dismissal as the collector wants it stated. `dismissed_at` is the
/// server's to write: a client clock is the wrong authority for when something
/// happened on the Pi.
struct Dismissal: Equatable, Hashable {
    var kind: CmoDismissKind
    var title: String
    var lane: String?
    var date: String

    /// Identity, as one string. NUL as the separator because it is the one
    /// character a title the agent wrote cannot contain, so no two different
    /// dismissals can collide on a key.
    var key: String { Dismissal.key(kind, title, date) }

    static func key(_ kind: CmoDismissKind, _ title: String, _ date: String) -> String {
        "\(kind.rawValue)\u{0}\(title)\u{0}\(date)"
    }
}

extension CmoDismissed {
    var asDismissal: Dismissal {
        Dismissal(kind: kind, title: title, lane: lane, date: date)
    }
    var key: String { Dismissal.key(kind, title, date) }
}

/// One of the operator's reference documents on the Pi, under `docs/`.
struct CmoDoc: Equatable {
    /// The filename without `.md`, which is also the route's last segment.
    var slug: String
    /// Local ISO seconds, the file's mtime. The unseen dot keys on this, so it
    /// is a fact about the copy on disk rather than a claim about how old the
    /// writing is.
    var updated: String

    init(slug: String = "", updated: String = "") {
        self.slug = slug
        self.updated = updated
    }
}

extension CmoDoc: Decodable {
    private enum K: String, CodingKey { case slug, updated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        updated = (try? c.decodeIfPresent(String.self, forKey: .updated)) ?? ""
    }
}

// MARK: - ask the cmo

enum CmoAskStatus: String, Equatable {
    case thinking, idle
}

extension CmoAskStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = CmoAskStatus(rawValue: raw) ?? .idle
    }
}

/// One thread as the payload lists it: enough to name it and to know whether
/// it is still working.
struct CmoAskThreadSummary: Equatable, Identifiable {
    /// `YYYY-MM-DD-HHMM-xxxx`, minted by the collector. Also the route.
    var id: String
    /// The opening question, truncated by the collector to 80 characters. The
    /// thread's name, since a conversation does not have one.
    var firstQ: String
    /// Questions and answers together, which is what "3 turns" means on screen.
    var turns: Int
    /// Local ISO seconds. Moves when a question is asked and again when it is
    /// answered.
    var updated: String
    var status: CmoAskStatus

    init(id: String, firstQ: String = "", turns: Int = 0,
         updated: String = "", status: CmoAskStatus = .idle) {
        self.id = id
        self.firstQ = firstQ
        self.turns = turns
        self.updated = updated
        self.status = status
    }
}

extension CmoAskThreadSummary: Decodable {
    private enum K: String, CodingKey { case id, firstQ, turns, updated, status }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        firstQ = (try? c.decodeIfPresent(String.self, forKey: .firstQ)) ?? ""
        turns = (try? c.decodeIfPresent(Int.self, forKey: .turns)) ?? 0
        updated = (try? c.decodeIfPresent(String.self, forKey: .updated)) ?? ""
        status = (try? c.decode(CmoAskStatus.self, forKey: .status)) ?? .idle
    }
}

enum CmoAskRole: String, Equatable { case q, a }

extension CmoAskRole: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = CmoAskRole(rawValue: raw) ?? .a
    }
}

/// One turn. A question carries only its text; an answer carries the receipts.
///
/// `error` and `text` are not exclusive: a session that failed after producing
/// something says both what it managed and what went wrong.
struct CmoAskTurn: Equatable {
    var role: CmoAskRole
    var text: String
    var at: String
    /// The files the session says it opened. Nil means it did not say -- a
    /// different claim from "read nothing", and the meta line draws them
    /// differently.
    var reads: [String]?
    var durationS: Double?
    var error: String?

    init(role: CmoAskRole, text: String = "", at: String = "",
         reads: [String]? = nil, durationS: Double? = nil, error: String? = nil) {
        self.role = role
        self.text = text
        self.at = at
        self.reads = reads
        self.durationS = durationS
        self.error = error
    }
}

extension CmoAskTurn: Decodable {
    private enum K: String, CodingKey { case role, text, at, reads, durationS, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        role = (try? c.decode(CmoAskRole.self, forKey: .role)) ?? .a
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        reads = try? c.decodeIfPresent([String].self, forKey: .reads)
        durationS = try? c.decodeIfPresent(Double.self, forKey: .durationS)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// One thread, whole. Fetched by id; never part of the telemetry payload.
struct CmoAskThread: Equatable, Identifiable {
    var id: String
    var created: String
    var updated: String
    /// The claude session this thread resumes. Nil until the first answer, and
    /// left alone when an answer fails.
    var sessionId: String?
    var status: CmoAskStatus
    var turns: [CmoAskTurn]

    init(id: String, created: String = "", updated: String = "",
         sessionId: String? = nil, status: CmoAskStatus = .idle,
         turns: [CmoAskTurn] = []) {
        self.id = id
        self.created = created
        self.updated = updated
        self.sessionId = sessionId
        self.status = status
        self.turns = turns
    }
}

extension CmoAskThread: Decodable {
    private enum K: String, CodingKey { case id, created, updated, sessionId, status, turns }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        created = (try? c.decodeIfPresent(String.self, forKey: .created)) ?? ""
        updated = (try? c.decodeIfPresent(String.self, forKey: .updated)) ?? ""
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        status = (try? c.decode(CmoAskStatus.self, forKey: .status)) ?? .idle
        turns = (try? c.decodeIfPresent([CmoAskTurn].self, forKey: .turns)) ?? []
    }
}

// MARK: - the source body

struct CmoData: Equatable {
    var heartbeat: CmoHeartbeat
    /// May describe an EARLIER run than the heartbeat does. The wrapper deletes
    /// this file when a run starts and the agent writes it last, so a failed run
    /// leaves the previous success in place -- worth having, but only if the
    /// view says which day it is showing, which is what `agentDate` is for.
    var agent: CmoAgentResult?
    var agentDate: String?
    var itemsDaily: [CmoDay]
    /// Briefing dates on disk, newest first, capped at 90 by the collector.
    var briefings: [String]
    var dismissed: [CmoDismissed]
    /// Watchlist companies with a research dossier on disk, as slugs. A company
    /// on the watchlist with no entry here simply is not a link yet.
    var dossiers: [String]
    var docs: [CmoDoc]
    var ask: [CmoAskThreadSummary]

    init(heartbeat: CmoHeartbeat = CmoHeartbeat(), agent: CmoAgentResult? = nil,
         agentDate: String? = nil, itemsDaily: [CmoDay] = [], briefings: [String] = [],
         dismissed: [CmoDismissed] = [], dossiers: [String] = [], docs: [CmoDoc] = [],
         ask: [CmoAskThreadSummary] = []) {
        self.heartbeat = heartbeat
        self.agent = agent
        self.agentDate = agentDate
        self.itemsDaily = itemsDaily
        self.briefings = briefings
        self.dismissed = dismissed
        self.dossiers = dossiers
        self.docs = docs
        self.ask = ask
    }
}

extension CmoData: Decodable {
    private enum K: String, CodingKey {
        case heartbeat, agent, agentDate, itemsDaily, briefings, dismissed
        case dossiers, docs, ask
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        heartbeat = (try? c.decodeIfPresent(CmoHeartbeat.self, forKey: .heartbeat))
            ?? CmoHeartbeat()
        agent = try? c.decodeIfPresent(CmoAgentResult.self, forKey: .agent)
        agentDate = try? c.decodeIfPresent(String.self, forKey: .agentDate)
        itemsDaily = (try? c.decodeIfPresent([CmoDay].self, forKey: .itemsDaily)) ?? []
        briefings = (try? c.decodeIfPresent([String].self, forKey: .briefings)) ?? []
        dismissed = (try? c.decodeIfPresent([CmoDismissed].self, forKey: .dismissed)) ?? []
        dossiers = (try? c.decodeIfPresent([String].self, forKey: .dossiers)) ?? []
        docs = (try? c.decodeIfPresent([CmoDoc].self, forKey: .docs)) ?? []
        ask = (try? c.decodeIfPresent([CmoAskThreadSummary].self, forKey: .ask)) ?? []
    }
}

// MARK: - chat
//
// Stage B2 draws these. They are here because `LiveClient` returns them, and a
// route whose answer has no type is a route that gets typed twice.

enum ChatModelName: String, Equatable, CaseIterable {
    case sonnet, opus
}

extension ChatModelName: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ChatModelName(rawValue: raw) ?? .sonnet
    }
}

/// `running` is the runner's word for "a session is producing this turn right
/// now". There is no `queued` here on purpose -- see `ChatThreadSummary.queued`.
enum ChatStatus: String, Equatable { case idle, running, error }

extension ChatStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ChatStatus(rawValue: raw) ?? .idle
    }
}

/// How hard a session thinks, mirroring the CLI's own `--effort` levels, in the
/// CLI's order.
enum JarvisEffort: String, Equatable, CaseIterable {
    case low, medium, high, xhigh, max
}

extension JarvisEffort: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = JarvisEffort(rawValue: raw) ?? .high
    }
}

struct ChatThreadSummary: Equatable, Identifiable {
    var id: String
    /// Empty on a thread nobody has typed into yet, which the view draws in its
    /// own voice rather than as a blank row.
    var title: String
    var preview: String?
    var updatedAt: String
    var status: ChatStatus
    var model: ChatModelName
    var turnCount: Int
    /// **Not a status.** A turn is on disk and the runner has not picked it up
    /// yet. The UI reads `queued || status == .running` as "in flight".
    var queued: Bool
    /// Put away rather than gone. Optional because an older collector does not
    /// send the field at all, and absent means the same thing as false: the list
    /// shows the row.
    var archived: Bool?

    init(id: String, title: String = "", preview: String? = nil,
         updatedAt: String = "", status: ChatStatus = .idle,
         model: ChatModelName = .sonnet, turnCount: Int = 0,
         queued: Bool = false, archived: Bool? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.status = status
        self.model = model
        self.turnCount = turnCount
        self.queued = queued
        self.archived = archived
    }
}

extension ChatThreadSummary: Decodable {
    private enum K: String, CodingKey {
        case id, title, preview, updatedAt, status, model, turnCount, queued, archived
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        status = (try? c.decode(ChatStatus.self, forKey: .status)) ?? .idle
        model = (try? c.decode(ChatModelName.self, forKey: .model)) ?? .sonnet
        turnCount = (try? c.decodeIfPresent(Int.self, forKey: .turnCount)) ?? 0
        queued = (try? c.decodeIfPresent(Bool.self, forKey: .queued)) ?? false
        archived = try? c.decodeIfPresent(Bool.self, forKey: .archived)
    }
}

enum ChatRole: String, Equatable { case user, assistant }

extension ChatRole: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ChatRole(rawValue: raw) ?? .assistant
    }
}

struct ChatTurn: Equatable {
    var role: ChatRole
    var text: String
    var at: String
    /// Tool calls, already summarised by the runner into one line each.
    var tools: [String]?
    /// What answered this turn, which is not necessarily the thread's model now.
    var model: ChatModelName?
    var elapsedS: Double?

    init(role: ChatRole, text: String = "", at: String = "", tools: [String]? = nil,
         model: ChatModelName? = nil, elapsedS: Double? = nil) {
        self.role = role
        self.text = text
        self.at = at
        self.tools = tools
        self.model = model
        self.elapsedS = elapsedS
    }
}

extension ChatTurn: Decodable {
    private enum K: String, CodingKey { case role, text, at, tools, model, elapsedS }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        role = (try? c.decode(ChatRole.self, forKey: .role)) ?? .assistant
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        tools = try? c.decodeIfPresent([String].self, forKey: .tools)
        model = try? c.decodeIfPresent(ChatModelName.self, forKey: .model)
        elapsedS = try? c.decodeIfPresent(Double.self, forKey: .elapsedS)
    }
}

struct ChatThread: Equatable, Identifiable {
    var id: String
    var title: String
    var createdAt: String
    var updatedAt: String
    var model: ChatModelName
    var effort: JarvisEffort?
    var status: ChatStatus
    var error: String?
    var claudeSessionId: String?
    var turns: [ChatTurn]
    /// The in-flight turn's text as it streams, or nil between turns. The one
    /// field here that is deliberately a partial truth.
    var partial: String?
    var queued: Bool

    init(id: String, title: String = "", createdAt: String = "", updatedAt: String = "",
         model: ChatModelName = .sonnet, effort: JarvisEffort? = nil,
         status: ChatStatus = .idle, error: String? = nil,
         claudeSessionId: String? = nil, turns: [ChatTurn] = [],
         partial: String? = nil, queued: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.effort = effort
        self.status = status
        self.error = error
        self.claudeSessionId = claudeSessionId
        self.turns = turns
        self.partial = partial
        self.queued = queued
    }
}

extension ChatThread: Decodable {
    private enum K: String, CodingKey {
        case id, title, createdAt, updatedAt, model, effort, status, error
        case claudeSessionId, turns, partial, queued
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        model = (try? c.decode(ChatModelName.self, forKey: .model)) ?? .sonnet
        effort = try? c.decodeIfPresent(JarvisEffort.self, forKey: .effort)
        status = (try? c.decode(ChatStatus.self, forKey: .status)) ?? .idle
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        claudeSessionId = try? c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        turns = (try? c.decodeIfPresent([ChatTurn].self, forKey: .turns)) ?? []
        partial = try? c.decodeIfPresent(String.self, forKey: .partial)
        queued = (try? c.decodeIfPresent(Bool.self, forKey: .queued)) ?? false
    }
}

// MARK: - jarvis

typealias JarvisModelName = ChatModelName
typealias JarvisStatus = ChatStatus

/// Where one job has got to.
///
/// **`stopped` is deliberately not `error`.** A job you cancelled did what you
/// asked; drawing it red would put a fault on screen that nobody has to look
/// into.
enum JarvisJobState: String, Equatable {
    case queued, running, done, error, stopped
}

extension JarvisJobState: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = JarvisJobState(rawValue: raw) ?? .queued
    }
}

struct JarvisSayTurn: Equatable {
    var role: ChatRole
    var text: String
    var at: String
    var tools: [String]?
    var model: JarvisModelName?
    var elapsedS: Double?
}

struct JarvisJobTurn: Equatable {
    var jobId: String
    var title: String
    /// When the job was filed. It never moves: a card that slid to the bottom
    /// of the day when its job finished would put the work somewhere the
    /// conversation did not happen.
    var at: String
    /// Rewritten in place by the collector as the job record moves.
    var state: JarvisJobState
}

struct JarvisNoticeTurn: Equatable {
    /// The only notice the collector mints.
    var notice: String
    var text: String
    var at: String
    /// The reading at the crossing, frozen. Not today's.
    var pct: Double
    var action: String
}

/// One turn. Three kinds share one array and `kind` tells them apart.
///
/// **A kind this console does not recognise renders nothing, and never
/// throws.** The collector ships separately from this app and will grow a
/// fourth kind while a window is open; a transcript that refused to draw
/// because one line in it was new would lose the whole day to something purely
/// additive.
enum JarvisTurn: Equatable {
    case say(JarvisSayTurn)
    case job(JarvisJobTurn)
    case notice(JarvisNoticeTurn)
    case unknown(at: String)

    /// The sort key every kind has. The merge is stable on this.
    var at: String {
        switch self {
        case .say(let t): return t.at
        case .job(let t): return t.at
        case .notice(let t): return t.at
        case .unknown(let at): return at
        }
    }
}

extension JarvisTurn: Decodable {
    private enum K: String, CodingKey {
        case kind, role, text, at, tools, model, elapsedS
        case jobId, title, state, notice, pct, action
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        switch (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "" {
        case "say":
            self = .say(JarvisSayTurn(
                role: (try? c.decode(ChatRole.self, forKey: .role)) ?? .assistant,
                text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? "",
                at: at,
                tools: try? c.decodeIfPresent([String].self, forKey: .tools),
                model: try? c.decodeIfPresent(ChatModelName.self, forKey: .model),
                elapsedS: try? c.decodeIfPresent(Double.self, forKey: .elapsedS)))
        case "job":
            self = .job(JarvisJobTurn(
                jobId: (try? c.decodeIfPresent(String.self, forKey: .jobId)) ?? "",
                title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
                at: at,
                state: (try? c.decode(JarvisJobState.self, forKey: .state)) ?? .queued))
        case "notice":
            self = .notice(JarvisNoticeTurn(
                notice: (try? c.decodeIfPresent(String.self, forKey: .notice)) ?? "context",
                text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? "",
                at: at,
                pct: (try? c.decodeIfPresent(Double.self, forKey: .pct)) ?? 0,
                action: (try? c.decodeIfPresent(String.self, forKey: .action)) ?? "compact"))
        default:
            self = .unknown(at: at)
        }
    }
}

/// How much of the window the last turn sent.
///
/// **It lags by exactly one turn**, so it is a floor and never a ceiling --
/// which is why the console says "context 52%" and never "52% remaining".
struct JarvisContext: Equatable {
    var tokens: Int
    var window: Int
    var pct: Double
    var at: String
    /// True when no turn has run since the last compaction. The console draws
    /// an em dash, not the old number dimmed: a dim number is still a number.
    var stale: Bool

    init(tokens: Int = 0, window: Int = 0, pct: Double = 0,
         at: String = "", stale: Bool = false) {
        self.tokens = tokens
        self.window = window
        self.pct = pct
        self.at = at
        self.stale = stale
    }
}

extension JarvisContext: Decodable {
    private enum K: String, CodingKey { case tokens, window, pct, at, stale }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        tokens = (try? c.decodeIfPresent(Int.self, forKey: .tokens)) ?? 0
        window = (try? c.decodeIfPresent(Int.self, forKey: .window)) ?? 0
        pct = (try? c.decodeIfPresent(Double.self, forKey: .pct)) ?? 0
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        stale = (try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
    }
}

struct JarvisCompaction: Equatable {
    var at: String
    var beforeTokens: Int
    /// The digest the next session is seeded with.
    var kept: String
    /// How many turns are behind the digest. Not how many were deleted: none
    /// were.
    var turnsFolded: Int

    init(at: String = "", beforeTokens: Int = 0, kept: String = "", turnsFolded: Int = 0) {
        self.at = at
        self.beforeTokens = beforeTokens
        self.kept = kept
        self.turnsFolded = turnsFolded
    }
}

extension JarvisCompaction: Decodable {
    private enum K: String, CodingKey { case at, beforeTokens, kept, turnsFolded }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? ""
        beforeTokens = (try? c.decodeIfPresent(Int.self, forKey: .beforeTokens)) ?? 0
        kept = (try? c.decodeIfPresent(String.self, forKey: .kept)) ?? ""
        turnsFolded = (try? c.decodeIfPresent(Int.self, forKey: .turnsFolded)) ?? 0
    }
}

struct JarvisDay: Equatable, Identifiable {
    /// `YYYY-MM-DD` in local time. The id and the route's last segment at once.
    var day: String
    var createdAt: String
    var updatedAt: String
    var model: JarvisModelName
    var effort: JarvisEffort?
    /// The TALK lane only. A day is idle when nothing is being said, however
    /// many jobs are working.
    var status: JarvisStatus
    var error: String?
    /// Cleared by compaction, which is the entire mechanism rather than a side
    /// effect of it.
    var claudeSessionId: String?
    var partial: String?
    /// Oldest first, all three kinds in one array.
    var turns: [JarvisTurn]
    /// Nil on a day nothing has been asked on. Nil draws an em dash, never 0%.
    var context: JarvisContext?
    var compactions: [JarvisCompaction]
    var queued: Bool

    var id: String { day }

    init(day: String, createdAt: String = "", updatedAt: String = "",
         model: JarvisModelName = .sonnet, effort: JarvisEffort? = nil,
         status: JarvisStatus = .idle, error: String? = nil,
         claudeSessionId: String? = nil, turns: [JarvisTurn] = [],
         context: JarvisContext? = nil, compactions: [JarvisCompaction] = [],
         queued: Bool = false) {
        self.day = day
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.effort = effort
        self.status = status
        self.error = error
        self.claudeSessionId = claudeSessionId
        self.turns = turns
        self.context = context
        self.compactions = compactions
        self.queued = queued
    }
}

extension JarvisDay: Decodable {
    private enum K: String, CodingKey {
        case day, createdAt, updatedAt, model, effort, status, error
        case claudeSessionId, partial, turns, context, compactions, queued
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        model = (try? c.decode(ChatModelName.self, forKey: .model)) ?? .sonnet
        effort = try? c.decodeIfPresent(JarvisEffort.self, forKey: .effort)
        status = (try? c.decode(ChatStatus.self, forKey: .status)) ?? .idle
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        claudeSessionId = try? c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        partial = try? c.decodeIfPresent(String.self, forKey: .partial)
        turns = (try? c.decodeIfPresent([JarvisTurn].self, forKey: .turns)) ?? []
        context = try? c.decodeIfPresent(JarvisContext.self, forKey: .context)
        compactions = (try? c.decodeIfPresent([JarvisCompaction].self, forKey: .compactions)) ?? []
        queued = (try? c.decodeIfPresent(Bool.self, forKey: .queued)) ?? false
    }
}

/// One day as the list route names it.
///
/// Note what a row does NOT get: `stale`. A list cannot tell that a reading has
/// been left behind by a compaction, so it must not present these as where the
/// day stands.
struct JarvisDaySummary: Equatable, Identifiable {
    var day: String
    var updatedAt: String
    var turnCount: Int
    var jobCount: Int
    var status: JarvisStatus
    var queued: Bool
    var model: JarvisModelName
    var contextTokens: Int?
    var contextPct: Double?
    var preview: String

    var id: String { day }

    init(day: String, updatedAt: String = "", turnCount: Int = 0, jobCount: Int = 0,
         status: JarvisStatus = .idle, queued: Bool = false,
         model: JarvisModelName = .sonnet, contextTokens: Int? = nil,
         contextPct: Double? = nil, preview: String = "") {
        self.day = day
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.jobCount = jobCount
        self.status = status
        self.queued = queued
        self.model = model
        self.contextTokens = contextTokens
        self.contextPct = contextPct
        self.preview = preview
    }
}

extension JarvisDaySummary: Decodable {
    private enum K: String, CodingKey {
        case day, updatedAt, turnCount, jobCount, status, queued, model, context, preview
    }
    private enum C: String, CodingKey { case tokens, pct }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        turnCount = (try? c.decodeIfPresent(Int.self, forKey: .turnCount)) ?? 0
        jobCount = (try? c.decodeIfPresent(Int.self, forKey: .jobCount)) ?? 0
        status = (try? c.decode(ChatStatus.self, forKey: .status)) ?? .idle
        queued = (try? c.decodeIfPresent(Bool.self, forKey: .queued)) ?? false
        model = (try? c.decode(ChatModelName.self, forKey: .model)) ?? .sonnet
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        if let ctx = try? c.nestedContainer(keyedBy: C.self, forKey: .context) {
            contextTokens = try? ctx.decodeIfPresent(Int.self, forKey: .tokens)
            contextPct = try? ctx.decodeIfPresent(Double.self, forKey: .pct)
        }
    }
}

/// One job: work filed from the conversation and run beside it, by a second
/// runner under a second lock.
struct JarvisJob: Equatable, Identifiable {
    var id: String
    /// What it was filed as, and what the card shows.
    var title: String
    /// The prompt as filed. Not the title.
    var text: String
    var state: JarvisJobState
    var createdAt: String
    var updatedAt: String
    /// What the job produced. Nil until `done`, and nil on a `stopped` job too:
    /// work you cancelled and work that came back empty are different facts.
    var result: String?
    var error: String?
    var tools: [String]?
    var model: JarvisModelName?
    var elapsedS: Double?

    init(id: String, title: String = "", text: String = "",
         state: JarvisJobState = .queued, createdAt: String = "", updatedAt: String = "",
         result: String? = nil, error: String? = nil, tools: [String]? = nil,
         model: JarvisModelName? = nil, elapsedS: Double? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
        self.error = error
        self.tools = tools
        self.model = model
        self.elapsedS = elapsedS
    }
}

extension JarvisJob: Decodable {
    private enum K: String, CodingKey {
        case id, title, text, state, createdAt, updatedAt, result, error
        case tools, model, elapsedS
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        state = (try? c.decode(JarvisJobState.self, forKey: .state)) ?? .queued
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        tools = try? c.decodeIfPresent([String].self, forKey: .tools)
        model = try? c.decodeIfPresent(ChatModelName.self, forKey: .model)
        elapsedS = try? c.decodeIfPresent(Double.self, forKey: .elapsedS)
    }
}

struct CmoRoutineStatus: Decodable {
    let enabled: Bool?
    let retryEnabled: Bool?
}
