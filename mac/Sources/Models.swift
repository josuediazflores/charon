import Foundation

/* Types mirroring the collector's /v1/telemetry payload and its mail routes.
 *
 * Ported from the web console's model layer, and the two facts that file
 * calls load-bearing are load-bearing here:
 *
 *   `urgency` is `Int?`. Null and 0 are different facts -- one is "triage has
 *   not looked at this yet" and the other is "looked at, and it wants nothing"
 *   -- and nothing in the model or the rendering may collapse them.
 *
 *   `body` is `String?`. "" is a body the poller kept and that is empty; nil is
 *   a body it never had. The reader says different things about the two.
 *
 * Decoding is deliberately lenient. Every `init(from:)` below is written by
 * hand with defaults, so a payload from a collector older or newer than this
 * app renders what it can rather than throwing the whole document away. The
 * memberwise initialisers survive because the decoders live in extensions,
 * which is what lets the demo store build these values directly.
 */

// MARK: - envelope

struct SourceError: Decodable, Equatable {
    var kind: String?
    var message: String?
    var at: String?
}

/// The collector's vocabulary, verbatim. `dormant` is the load-bearing one: a
/// source that was never configured is not a source in trouble.
enum SourceStatus: String, Decodable, Equatable {
    case ok, stale, degraded, dormant, error
}

/// The design system's tone vocabulary, verbatim.
///
/// `standby` is deliberately not assignable to a `Panel`'s tone in the design
/// system -- that constraint is what enforces "a source you never set up does
/// not get a coloured frame" -- and the Swift port keeps the rule in
/// `SourcePanel` rather than in the type, because one enum spelled twice would
/// be worse than one comment.
enum Tone: String, Equatable, CaseIterable {
    case `default`, nominal, caution, fault, standby, signal
}

extension Tone: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        // A word this build has never heard of is `default`: an unknown tone is
        // a colour opinion, and dropping the whole source over one is worse
        // than drawing it in plain ink.
        self = Tone(rawValue: raw) ?? .default
    }
}

/// The parts of an envelope the staleness rule reads.
///
/// `health()` cares about five fields and nothing about the body behind them,
/// so it takes this rather than a generic envelope -- which is what lets one
/// `SourcePanel` accept the camera, the nodes and the mailbox without the view
/// being generic over a phantom type it never mentions.
protocol SourceEnvelopeShape {
    var status: SourceStatus { get }
    var fetchedAt: String? { get }
    var ageS: Double? { get }
    var staleReason: String? { get }
    var error: SourceError? { get }
}

struct SourceEnvelope<T: Decodable & Equatable>: Equatable {
    var status: SourceStatus
    var fetchedAt: String?
    var ageS: Double?
    var staleReason: String?
    var intervalS: Double?
    var nextAttemptInS: Int? = nil
    var consecutiveFailures: Int
    var error: SourceError?
    var data: T?
}

extension SourceEnvelope: SourceEnvelopeShape {}

extension SourceEnvelope: Decodable {
    private enum K: String, CodingKey {
        case status, fetchedAt, ageS, staleReason, intervalS, nextAttemptInS
        case consecutiveFailures, error, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        // An unknown status is `error` rather than a throw: a collector that
        // grew a sixth word should degrade this one source, not the payload.
        status = (try? c.decode(SourceStatus.self, forKey: .status)) ?? .error
        fetchedAt = try? c.decodeIfPresent(String.self, forKey: .fetchedAt)
        ageS = try? c.decodeIfPresent(Double.self, forKey: .ageS)
        staleReason = try? c.decodeIfPresent(String.self, forKey: .staleReason)
        intervalS = try? c.decodeIfPresent(Double.self, forKey: .intervalS)
        nextAttemptInS = try? c.decodeIfPresent(Int.self, forKey: .nextAttemptInS)
        consecutiveFailures = (try? c.decodeIfPresent(Int.self, forKey: .consecutiveFailures)) ?? 0
        error = try? c.decodeIfPresent(SourceError.self, forKey: .error)
        data = try? c.decodeIfPresent(T.self, forKey: .data)
    }
}

/// The document, flattened.
///
/// `sources` is a nested object on the wire and eight properties here: the
/// views ask for `payload.pihole`, not for `payload.sources.pihole`, and the
/// one place that shape matters is the decoder below.
///
/// **Every envelope is optional**, including `healthchecks`, which the
/// TypeScript model types as required. A collector older than the field simply
/// does not send it, and a strict `Decodable` would throw the whole payload
/// away over a source this app can perfectly well draw as absent.
struct TelemetryPayload: Equatable {
    var schema: Int?
    var serverTime: String?
    var collector: CollectorInfo?
    var health: HealthCounts?

    var camera: SourceEnvelope<CameraData>?
    var pihole: SourceEnvelope<PiholeData>?
    var nodes: SourceEnvelope<NodesData>?
    var commits: SourceEnvelope<CommitsData>?
    var healthchecks: SourceEnvelope<HealthchecksData>?
    var cmo: SourceEnvelope<CmoData>?
    var mail: SourceEnvelope<MailData>?
    var messages: SourceEnvelope<MessagesData>?

    init(schema: Int? = nil,
         serverTime: String? = nil,
         collector: CollectorInfo? = nil,
         health: HealthCounts? = nil,
         camera: SourceEnvelope<CameraData>? = nil,
         pihole: SourceEnvelope<PiholeData>? = nil,
         nodes: SourceEnvelope<NodesData>? = nil,
         commits: SourceEnvelope<CommitsData>? = nil,
         healthchecks: SourceEnvelope<HealthchecksData>? = nil,
         cmo: SourceEnvelope<CmoData>? = nil,
         mail: SourceEnvelope<MailData>? = nil,
         messages: SourceEnvelope<MessagesData>? = nil) {
        self.schema = schema
        self.serverTime = serverTime
        self.collector = collector
        self.health = health
        self.camera = camera
        self.pihole = pihole
        self.nodes = nodes
        self.commits = commits
        self.healthchecks = healthchecks
        self.cmo = cmo
        self.mail = mail
        self.messages = messages
    }
}

extension TelemetryPayload: Decodable {
    private enum K: String, CodingKey { case schema, serverTime, collector, health, sources }
    private enum S: String, CodingKey {
        case camera, pihole, nodes, commits, healthchecks, cmo, mail, messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        schema = try? c.decodeIfPresent(Int.self, forKey: .schema)
        serverTime = try? c.decodeIfPresent(String.self, forKey: .serverTime)
        collector = try? c.decodeIfPresent(CollectorInfo.self, forKey: .collector)
        health = try? c.decodeIfPresent(HealthCounts.self, forKey: .health)

        guard let s = try? c.nestedContainer(keyedBy: S.self, forKey: .sources) else { return }
        camera = try? s.decodeIfPresent(SourceEnvelope<CameraData>.self, forKey: .camera)
        pihole = try? s.decodeIfPresent(SourceEnvelope<PiholeData>.self, forKey: .pihole)
        nodes = try? s.decodeIfPresent(SourceEnvelope<NodesData>.self, forKey: .nodes)
        commits = try? s.decodeIfPresent(SourceEnvelope<CommitsData>.self, forKey: .commits)
        healthchecks = try? s.decodeIfPresent(
            SourceEnvelope<HealthchecksData>.self, forKey: .healthchecks)
        cmo = try? s.decodeIfPresent(
            SourceEnvelope<CmoData>.self, forKey: .cmo)
        mail = try? s.decodeIfPresent(SourceEnvelope<MailData>.self, forKey: .mail)
        messages = try? s.decodeIfPresent(
            SourceEnvelope<MessagesData>.self, forKey: .messages)
    }
}

/// The collector's own process.
struct CollectorInfo: Equatable {
    var version: String?
    var startedAt: String?
    var uptimeS: Double?

    init(version: String? = nil, startedAt: String? = nil, uptimeS: Double? = nil) {
        self.version = version
        self.startedAt = startedAt
        self.uptimeS = uptimeS
    }
}

extension CollectorInfo: Decodable {
    private enum K: String, CodingKey { case version, startedAt, uptimeS }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        uptimeS = try? c.decodeIfPresent(Double.self, forKey: .uptimeS)
    }
}

/// The collector's tally of its own sources, and the worst word among them.
struct HealthCounts: Equatable {
    var worst: SourceStatus
    var ok: Int
    var degraded: Int
    var stale: Int
    var dormant: Int
    var error: Int

    init(worst: SourceStatus = .ok, ok: Int = 0, degraded: Int = 0,
         stale: Int = 0, dormant: Int = 0, error: Int = 0) {
        self.worst = worst
        self.ok = ok
        self.degraded = degraded
        self.stale = stale
        self.dormant = dormant
        self.error = error
    }

    var total: Int { ok + degraded + stale + dormant + error }
}

extension HealthCounts: Decodable {
    private enum K: String, CodingKey { case worst, ok, degraded, stale, dormant, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        worst = (try? c.decode(SourceStatus.self, forKey: .worst)) ?? .ok
        ok = (try? c.decodeIfPresent(Int.self, forKey: .ok)) ?? 0
        degraded = (try? c.decodeIfPresent(Int.self, forKey: .degraded)) ?? 0
        stale = (try? c.decodeIfPresent(Int.self, forKey: .stale)) ?? 0
        dormant = (try? c.decodeIfPresent(Int.self, forKey: .dormant)) ?? 0
        error = (try? c.decodeIfPresent(Int.self, forKey: .error)) ?? 0
    }
}

// MARK: - camera

/// What the dog monitor on the Pi 5 saw, and what it made of it.
///
/// The wording is resolved by the collector, not here: `display.verdict` is a
/// label, a value and a tone, so the one sentence about a dog that is still
/// rather than asleep lives in one process. The app renders the words it is
/// handed.
struct CameraData: Equatable {
    var state: String
    var since: String?
    var elapsedS: Double?
    var lastSample: String?
    var lastScore: Double?
    var monitorStale: Bool
    var monitorStaleForS: Double?
    var monitor: CameraMonitor
    var frame: CameraFrameInfo
    var display: CameraDisplay

    init(state: String = "unknown", since: String? = nil, elapsedS: Double? = nil,
         lastSample: String? = nil, lastScore: Double? = nil,
         monitorStale: Bool = false, monitorStaleForS: Double? = nil,
         monitor: CameraMonitor = CameraMonitor(),
         frame: CameraFrameInfo = CameraFrameInfo(),
         display: CameraDisplay = CameraDisplay()) {
        self.state = state
        self.since = since
        self.elapsedS = elapsedS
        self.lastSample = lastSample
        self.lastScore = lastScore
        self.monitorStale = monitorStale
        self.monitorStaleForS = monitorStaleForS
        self.monitor = monitor
        self.frame = frame
        self.display = display
    }
}

struct CameraMonitor: Equatable {
    var alive: Bool
    var reason: String?
    var pid: Int?
    var beatAgeS: Double?
    /// Whether the RTSP feed behind the monitor is answering. Null on a monitor
    /// too old to report it, which is not the same fact as `false`.
    var feedOk: Bool?
    var feedDownForS: Double?
    var uptimeS: Double?

    init(alive: Bool = false, reason: String? = nil, pid: Int? = nil,
         beatAgeS: Double? = nil, feedOk: Bool? = nil,
         feedDownForS: Double? = nil, uptimeS: Double? = nil) {
        self.alive = alive
        self.reason = reason
        self.pid = pid
        self.beatAgeS = beatAgeS
        self.feedOk = feedOk
        self.feedDownForS = feedDownForS
        self.uptimeS = uptimeS
    }
}

struct CameraFrameInfo: Equatable {
    var available: Bool
    var ts: String?
    var ageS: Double?
    /// A path on the collector, not a public URL. The monitor's own route wants
    /// a bearer header, so this is fetched rather than handed to an image view.
    var url: String?

    init(available: Bool = false, ts: String? = nil, ageS: Double? = nil, url: String? = nil) {
        self.available = available
        self.ts = ts
        self.ageS = ageS
        self.url = url
    }
}

enum CameraState: String, Decodable, Equatable { case live, stale, offline }

struct CameraDisplay: Equatable {
    var cameraState: CameraState
    var stamp: String?
    var verdict: CameraVerdict

    init(cameraState: CameraState = .offline, stamp: String? = nil,
         verdict: CameraVerdict = CameraVerdict()) {
        self.cameraState = cameraState
        self.stamp = stamp
        self.verdict = verdict
    }
}

struct CameraVerdict: Equatable {
    var label: String
    var value: String
    var tone: Tone

    init(label: String = "stillness", value: String = "no reading", tone: Tone = .standby) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

extension CameraData: Decodable {
    private enum K: String, CodingKey {
        case state, since, elapsedS, lastSample, lastScore, monitorStale
        case monitorStaleForS, monitor, frame, display
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "unknown"
        since = try? c.decodeIfPresent(String.self, forKey: .since)
        elapsedS = try? c.decodeIfPresent(Double.self, forKey: .elapsedS)
        lastSample = try? c.decodeIfPresent(String.self, forKey: .lastSample)
        lastScore = try? c.decodeIfPresent(Double.self, forKey: .lastScore)
        monitorStale = (try? c.decodeIfPresent(Bool.self, forKey: .monitorStale)) ?? false
        monitorStaleForS = try? c.decodeIfPresent(Double.self, forKey: .monitorStaleForS)
        monitor = (try? c.decodeIfPresent(CameraMonitor.self, forKey: .monitor)) ?? CameraMonitor()
        frame = (try? c.decodeIfPresent(CameraFrameInfo.self, forKey: .frame)) ?? CameraFrameInfo()
        display = (try? c.decodeIfPresent(CameraDisplay.self, forKey: .display)) ?? CameraDisplay()
    }
}

extension CameraMonitor: Decodable {
    private enum K: String, CodingKey {
        case alive, reason, pid, beatAgeS, feedOk, feedDownForS, uptimeS
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        alive = (try? c.decodeIfPresent(Bool.self, forKey: .alive)) ?? false
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
        beatAgeS = try? c.decodeIfPresent(Double.self, forKey: .beatAgeS)
        // decodeIfPresent on purpose: null is "this monitor does not say",
        // which the Hardware panel draws differently from a feed that is down.
        feedOk = try? c.decodeIfPresent(Bool.self, forKey: .feedOk)
        feedDownForS = try? c.decodeIfPresent(Double.self, forKey: .feedDownForS)
        uptimeS = try? c.decodeIfPresent(Double.self, forKey: .uptimeS)
    }
}

extension CameraFrameInfo: Decodable {
    private enum K: String, CodingKey { case available, ts, ageS, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        ts = try? c.decodeIfPresent(String.self, forKey: .ts)
        ageS = try? c.decodeIfPresent(Double.self, forKey: .ageS)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }
}

extension CameraDisplay: Decodable {
    private enum K: String, CodingKey { case cameraState, stamp, verdict }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        cameraState = (try? c.decode(CameraState.self, forKey: .cameraState)) ?? .offline
        stamp = try? c.decodeIfPresent(String.self, forKey: .stamp)
        verdict = (try? c.decodeIfPresent(CameraVerdict.self, forKey: .verdict)) ?? CameraVerdict()
    }
}

extension CameraVerdict: Decodable {
    private enum K: String, CodingKey { case label, value, tone }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "stillness"
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? "no reading"
        tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)) ?? .standby
    }
}

// MARK: - pi-hole

/// The Zero's DNS numbers, and the Zero itself.
///
/// Everything but `api_version` is nullable on the wire: FTL answers some of
/// these and the host answers the rest, and either half can be missing while
/// the other is fine.
struct PiholeData: Equatable {
    var apiVersion: Int
    var queriesToday: Int?
    var blockedToday: Int?
    var blockRatePct: Double?
    var domainsOnList: Int?
    var clientsActive: Int?
    var topBlocked: String?
    var hostUptimeS: Double?
    var hostProcs: Int?
    var hostCores: Int?
    var hostCpuPct: Double?
    /// FTL's own share, not the machine's. Unused by any panel; kept because
    /// the collector sends it and dropping a field is how a model starts lying.
    var ftlCpuPct: Double?
    var ftlMemPct: Double?

    init(apiVersion: Int = 6, queriesToday: Int? = nil, blockedToday: Int? = nil,
         blockRatePct: Double? = nil, domainsOnList: Int? = nil, clientsActive: Int? = nil,
         topBlocked: String? = nil, hostUptimeS: Double? = nil, hostProcs: Int? = nil,
         hostCores: Int? = nil, hostCpuPct: Double? = nil, ftlCpuPct: Double? = nil,
         ftlMemPct: Double? = nil) {
        self.apiVersion = apiVersion
        self.queriesToday = queriesToday
        self.blockedToday = blockedToday
        self.blockRatePct = blockRatePct
        self.domainsOnList = domainsOnList
        self.clientsActive = clientsActive
        self.topBlocked = topBlocked
        self.hostUptimeS = hostUptimeS
        self.hostProcs = hostProcs
        self.hostCores = hostCores
        self.hostCpuPct = hostCpuPct
        self.ftlCpuPct = ftlCpuPct
        self.ftlMemPct = ftlMemPct
    }
}

extension PiholeData: Decodable {
    private enum K: String, CodingKey {
        case apiVersion, queriesToday, blockedToday, blockRatePct, domainsOnList
        case clientsActive, topBlocked, hostUptimeS, hostProcs, hostCores
        case hostCpuPct, ftlCpuPct, ftlMemPct
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        apiVersion = (try? c.decodeIfPresent(Int.self, forKey: .apiVersion)) ?? 6
        queriesToday = try? c.decodeIfPresent(Int.self, forKey: .queriesToday)
        blockedToday = try? c.decodeIfPresent(Int.self, forKey: .blockedToday)
        blockRatePct = try? c.decodeIfPresent(Double.self, forKey: .blockRatePct)
        domainsOnList = try? c.decodeIfPresent(Int.self, forKey: .domainsOnList)
        clientsActive = try? c.decodeIfPresent(Int.self, forKey: .clientsActive)
        topBlocked = try? c.decodeIfPresent(String.self, forKey: .topBlocked)
        hostUptimeS = try? c.decodeIfPresent(Double.self, forKey: .hostUptimeS)
        hostProcs = try? c.decodeIfPresent(Int.self, forKey: .hostProcs)
        hostCores = try? c.decodeIfPresent(Int.self, forKey: .hostCores)
        hostCpuPct = try? c.decodeIfPresent(Double.self, forKey: .hostCpuPct)
        ftlCpuPct = try? c.decodeIfPresent(Double.self, forKey: .ftlCpuPct)
        ftlMemPct = try? c.decodeIfPresent(Double.self, forKey: .ftlMemPct)
    }
}

// MARK: - nodes

/// One machine on the tailnet, as the collector last found it.
///
/// `tone` and `label` are the collector's own verdict rather than something
/// derived here: the rule for what "Connected" means belongs to the process
/// that did the probing.
struct NodeRow: Equatable, Identifiable {
    var id: String
    var host: String
    var addr: String
    /// The board, in the words on its own box: "Pi 5 · NVMe", "Zero W · armv6l".
    var kind: String
    var role: String
    /// How it was reached. `self` means the collector is running on it, which
    /// is why the Pi 5 has no round trip to report.
    var probe: String
    var connected: Bool
    var rttMs: Double?
    var uptimeS: Double?
    var load1: Double?
    var tempC: Double?
    var link: Int
    var tone: Tone
    var label: String
    var downSince: String?
    var checkedAt: String?

    init(id: String, host: String = "", addr: String = "", kind: String = "",
         role: String = "", probe: String = "", connected: Bool = false,
         rttMs: Double? = nil, uptimeS: Double? = nil, load1: Double? = nil,
         tempC: Double? = nil, link: Int = 0, tone: Tone = .default,
         label: String = "", downSince: String? = nil, checkedAt: String? = nil) {
        self.id = id
        self.host = host
        self.addr = addr
        self.kind = kind
        self.role = role
        self.probe = probe
        self.connected = connected
        self.rttMs = rttMs
        self.uptimeS = uptimeS
        self.load1 = load1
        self.tempC = tempC
        self.link = link
        self.tone = tone
        self.label = label
        self.downSince = downSince
        self.checkedAt = checkedAt
    }
}

extension NodeRow: Decodable {
    private enum K: String, CodingKey {
        case id, host, addr, kind, role, probe, connected, rttMs, uptimeS
        case load1, tempC, link, tone, label, downSince, checkedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        addr = (try? c.decodeIfPresent(String.self, forKey: .addr)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
        probe = (try? c.decodeIfPresent(String.self, forKey: .probe)) ?? ""
        connected = (try? c.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        rttMs = try? c.decodeIfPresent(Double.self, forKey: .rttMs)
        uptimeS = try? c.decodeIfPresent(Double.self, forKey: .uptimeS)
        load1 = try? c.decodeIfPresent(Double.self, forKey: .load1)
        tempC = try? c.decodeIfPresent(Double.self, forKey: .tempC)
        link = (try? c.decodeIfPresent(Int.self, forKey: .link)) ?? 0
        tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)) ?? .default
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        downSince = try? c.decodeIfPresent(String.self, forKey: .downSince)
        checkedAt = try? c.decodeIfPresent(String.self, forKey: .checkedAt)
    }
}

struct NodesData: Equatable {
    var nodes: [NodeRow]
    var connected: Int
    var total: Int

    init(nodes: [NodeRow] = [], connected: Int = 0, total: Int = 0) {
        self.nodes = nodes
        self.connected = connected
        self.total = total
    }
}

extension NodesData: Decodable {
    private enum K: String, CodingKey { case nodes, connected, total }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        nodes = (try? c.decodeIfPresent([NodeRow].self, forKey: .nodes)) ?? []
        connected = (try? c.decodeIfPresent(Int.self, forKey: .connected)) ?? 0
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
    }
}

// MARK: - commits

struct CommitRow: Equatable, Identifiable {
    var id: String
    var sha: String
    var title: String
    var repo: String
    /// ISO, never a pre-rendered "4m". Rendered through `relTime` at draw time.
    var committedAt: String?
    var url: String?

    init(id: String, sha: String = "", title: String = "", repo: String = "",
         committedAt: String? = nil, url: String? = nil) {
        self.id = id
        self.sha = sha
        self.title = title
        self.repo = repo
        self.committedAt = committedAt
        self.url = url
    }
}

extension CommitRow: Decodable {
    private enum K: String, CodingKey { case id, sha, title, repo, committedAt, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        sha = (try? c.decodeIfPresent(String.self, forKey: .sha)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? ""
        committedAt = try? c.decodeIfPresent(String.self, forKey: .committedAt)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }
}

struct CommitsRateLimit: Equatable {
    var remaining: Int?
    var limit: Int?
    var resetsAt: String?

    init(remaining: Int? = nil, limit: Int? = nil, resetsAt: String? = nil) {
        self.remaining = remaining
        self.limit = limit
        self.resetsAt = resetsAt
    }
}

extension CommitsRateLimit: Decodable {
    private enum K: String, CodingKey { case remaining, limit, resetsAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        remaining = try? c.decodeIfPresent(Int.self, forKey: .remaining)
        limit = try? c.decodeIfPresent(Int.self, forKey: .limit)
        resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

struct CommitsData: Equatable {
    var commits: [CommitRow]
    var reposOk: Int
    var reposFailed: Int
    /// Repos with no git remote. GitHub structurally cannot see these, so the
    /// commit list is a floor and the panel says so underneath itself.
    var reposUntracked: [String]
    var rateLimit: CommitsRateLimit?

    /* Diagnostics the collector added with auto-discovery. All optional: an
       older collector does not send them and no panel may require them. */
    var reposSeen: Int?
    var reposPolled: Int?
    var reposEmpty: Int?
    var reposDeferred: Int?
    var discovered: Bool?
    var apiCalls: Int?

    init(commits: [CommitRow] = [], reposOk: Int = 0, reposFailed: Int = 0,
         reposUntracked: [String] = [], rateLimit: CommitsRateLimit? = nil,
         reposSeen: Int? = nil, reposPolled: Int? = nil, reposEmpty: Int? = nil,
         reposDeferred: Int? = nil, discovered: Bool? = nil, apiCalls: Int? = nil) {
        self.commits = commits
        self.reposOk = reposOk
        self.reposFailed = reposFailed
        self.reposUntracked = reposUntracked
        self.rateLimit = rateLimit
        self.reposSeen = reposSeen
        self.reposPolled = reposPolled
        self.reposEmpty = reposEmpty
        self.reposDeferred = reposDeferred
        self.discovered = discovered
        self.apiCalls = apiCalls
    }
}

extension CommitsData: Decodable {
    private enum K: String, CodingKey {
        case commits, reposOk, reposFailed, reposUntracked, rateLimit
        case reposSeen, reposPolled, reposEmpty, reposDeferred, discovered, apiCalls
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        commits = (try? c.decodeIfPresent([CommitRow].self, forKey: .commits)) ?? []
        reposOk = (try? c.decodeIfPresent(Int.self, forKey: .reposOk)) ?? 0
        reposFailed = (try? c.decodeIfPresent(Int.self, forKey: .reposFailed)) ?? 0
        reposUntracked = (try? c.decodeIfPresent([String].self, forKey: .reposUntracked)) ?? []
        rateLimit = try? c.decodeIfPresent(CommitsRateLimit.self, forKey: .rateLimit)
        reposSeen = try? c.decodeIfPresent(Int.self, forKey: .reposSeen)
        reposPolled = try? c.decodeIfPresent(Int.self, forKey: .reposPolled)
        reposEmpty = try? c.decodeIfPresent(Int.self, forKey: .reposEmpty)
        reposDeferred = try? c.decodeIfPresent(Int.self, forKey: .reposDeferred)
        discovered = try? c.decodeIfPresent(Bool.self, forKey: .discovered)
        apiCalls = try? c.decodeIfPresent(Int.self, forKey: .apiCalls)
    }
}

// MARK: - healthchecks

/// One line of the morning self-test. A check that can only say PASS is not
/// worth a row, so `detail` carries the reading it actually took.
struct HealthCheckRow: Equatable, Identifiable {
    var id: String
    var label: String
    var ok: Bool
    var detail: String

    init(id: String, label: String = "", ok: Bool = true, detail: String = "") {
        self.id = id
        self.label = label
        self.ok = ok
        self.detail = detail
    }
}

extension HealthCheckRow: Decodable {
    private enum K: String, CodingKey { case id, label, ok, detail }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
    }
}

struct HealthCheckDay: Equatable, Identifiable {
    /// Calendar day, YYYY-MM-DD. A date, not an age: nothing here is relative.
    var date: String
    var ranAt: String?
    var pass: Int
    var fail: Int
    var checks: [HealthCheckRow]

    var id: String { date }

    init(date: String, ranAt: String? = nil, pass: Int = 0, fail: Int = 0,
         checks: [HealthCheckRow] = []) {
        self.date = date
        self.ranAt = ranAt
        self.pass = pass
        self.fail = fail
        self.checks = checks
    }
}

extension HealthCheckDay: Decodable {
    private enum K: String, CodingKey { case date, ranAt, pass, fail, checks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        ranAt = try? c.decodeIfPresent(String.self, forKey: .ranAt)
        pass = (try? c.decodeIfPresent(Int.self, forKey: .pass)) ?? 0
        fail = (try? c.decodeIfPresent(Int.self, forKey: .fail)) ?? 0
        checks = (try? c.decodeIfPresent([HealthCheckRow].self, forKey: .checks)) ?? []
    }
}

struct HealthchecksData: Equatable {
    /// Newest first. `days[0]` is the most recent run that exists, which is not
    /// necessarily today's -- a run that never happened leaves yesterday at the
    /// head of the list. **A panel must not read `days[0]` as "today".**
    var days: [HealthCheckDay]

    init(days: [HealthCheckDay] = []) { self.days = days }
}

extension HealthchecksData: Decodable {
    private enum K: String, CodingKey { case days }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        days = (try? c.decodeIfPresent([HealthCheckDay].self, forKey: .days)) ?? []
    }
}

// MARK: - mail

struct MailCounts: Equatable {
    var inbox: Int
    var unread: Int
    /// Urgency 3 only. The one level that claims a day is the one worth a count.
    var urgent: Int
    /// In the inbox with no triage record yet. A number that never falls to
    /// zero means the triage worker is stuck.
    var triagePending: Int
    var outboxQueued: Int
}

extension MailCounts: Decodable {
    private enum K: String, CodingKey { case inbox, unread, urgent, triagePending, outboxQueued }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        inbox = (try? c.decodeIfPresent(Int.self, forKey: .inbox)) ?? 0
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        urgent = (try? c.decodeIfPresent(Int.self, forKey: .urgent)) ?? 0
        triagePending = (try? c.decodeIfPresent(Int.self, forKey: .triagePending)) ?? 0
        outboxQueued = (try? c.decodeIfPresent(Int.self, forKey: .outboxQueued)) ?? 0
    }
}

enum OutboxStatus: String, Decodable, Equatable { case queued, sent, error }

/// One message as the payload lists it: enough to draw a row and no more.
/// Bodies never travel in telemetry.
struct MailMessageSummary: Equatable, Identifiable {
    /// `sha256(Message-ID)[:16]`, hex. Identity and route at once.
    var key: String
    var from: String
    var subject: String
    /// ISO, never a pre-rendered age. Rendered through `relTime`.
    var date: String?
    var unread: Bool
    var flagged: Bool
    /// Null until triage has run. Null and 0 are different facts.
    var urgency: Int?
    var tags: [String]
    var summaryLine: String?
    var hasAi: Bool
    var hasDraft: Bool
    var attachmentsN: Int
    /// The newest send record for this message, or null when nothing has ever
    /// been sent.
    var outboxStatus: OutboxStatus?

    var id: String { key }
}

extension MailMessageSummary: Decodable {
    private enum K: String, CodingKey {
        case key, from, subject, date, unread, flagged, urgency, tags
        case summaryLine, hasAi, hasDraft, attachmentsN, outboxStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? "unknown"
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? false
        flagged = (try? c.decodeIfPresent(Bool.self, forKey: .flagged)) ?? false
        // decodeIfPresent is exactly right here and the reason the whole file
        // decodes by hand: a missing key and an explicit null are both "not
        // triaged", and neither may arrive as 0.
        urgency = try? c.decodeIfPresent(Int.self, forKey: .urgency)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        summaryLine = try? c.decodeIfPresent(String.self, forKey: .summaryLine)
        hasAi = (try? c.decodeIfPresent(Bool.self, forKey: .hasAi)) ?? false
        hasDraft = (try? c.decodeIfPresent(Bool.self, forKey: .hasDraft)) ?? false
        attachmentsN = (try? c.decodeIfPresent(Int.self, forKey: .attachmentsN)) ?? 0
        outboxStatus = try? c.decodeIfPresent(OutboxStatus.self, forKey: .outboxStatus)
    }
}

/// What the triage session made of one message. Every field is the machine's
/// opinion about somebody else's text.
struct MailAiArtifact: Equatable {
    var tags: [String]
    /// Null on a `failed` record: the worker gave up without a verdict, and a
    /// null here is what keeps that from ever reading as "urgency 0".
    var urgency: Int?
    var summary: [String]
    var model: String?
    var status: String
    var at: String?
}

extension MailAiArtifact: Decodable {
    private enum K: String, CodingKey { case tags, urgency, summary, model, status, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        urgency = try? c.decodeIfPresent(Int.self, forKey: .urgency)
        summary = (try? c.decodeIfPresent([String].self, forKey: .summary)) ?? []
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ok"
        at = try? c.decodeIfPresent(String.self, forKey: .at)
    }
}

/// A reply that has not been sent, from either writer.
struct MailDraft: Equatable {
    var status: String
    var text: String?
    var instructions: String?
    var model: String?
    var error: String?
    var at: String?
}

extension MailDraft: Decodable {
    private enum K: String, CodingKey { case status, text, instructions, model, error, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ready"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
    }
}

/// One send. Written `queued` by the collector and moved to a terminal state by
/// the actions worker. Never pruned: this is the audit trail, and a retry mints
/// a new record rather than overwriting this one.
struct MailOutboxEntry: Equatable, Identifiable {
    var id: String
    var key: String
    /// Computed server-side from the original's reply-to. Echoed, never sent.
    var to: String
    var subject: String
    var status: OutboxStatus
    var queuedAt: String?
    var sentAt: String?
    var smtpReply: String?
    var error: String?
}

extension MailOutboxEntry: Decodable {
    private enum K: String, CodingKey {
        case id, key, to, subject, status, queuedAt, sentAt, smtpReply, error
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        to = (try? c.decodeIfPresent(String.self, forKey: .to)) ?? ""
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        status = (try? c.decode(OutboxStatus.self, forKey: .status)) ?? .queued
        queuedAt = try? c.decodeIfPresent(String.self, forKey: .queuedAt)
        sentAt = try? c.decodeIfPresent(String.self, forKey: .sentAt)
        smtpReply = try? c.decodeIfPresent(String.self, forKey: .smtpReply)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct MailAttachment: Equatable, Identifiable {
    var n: Int
    var name: String
    var size: Int
    var ctype: String

    var id: Int { n }
}

extension MailAttachment: Decodable {
    private enum K: String, CodingKey { case n, name, size, ctype }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 0
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "attachment"
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
        ctype = (try? c.decodeIfPresent(String.self, forKey: .ctype)) ?? "application/octet-stream"
    }
}

/// One message, whole. Fetched by key from `/v1/mail/message/<key>`.
struct MailMessageFull: Equatable {
    var key: String
    var messageId: String?
    /// Routing hints, never identity.
    var uid: Int?
    var uidvalidity: Int?
    var fromName: String?
    var fromAddr: String?
    var to: String?
    var replyTo: String?
    var subject: String
    var date: String?
    var size: Int?
    var unread: Bool
    var flagged: Bool
    /// False once it has been archived. The message stays readable by key.
    var inInbox: Bool
    var references: [String]
    var attachments: [MailAttachment]
    /// Whether the poller kept the raw message at all, and whether the
    /// extracted text hit its 64 KB ceiling. Both are said out loud.
    var bodyCached: Bool
    var bodyTruncated: Bool
    /// The extracted plain text. Never markdown, never HTML.
    var body: String?
    var ai: MailAiArtifact?
    var draft: MailDraft?
    /// His own, which wins over the session's wherever both exist.
    var userDraft: MailDraft?
    /// Every send attempted for this message, oldest first.
    var outbox: [MailOutboxEntry]
}

extension MailMessageFull: Decodable {
    private enum K: String, CodingKey {
        case key, messageId, uid, uidvalidity, fromName, fromAddr, to, replyTo
        case subject, date, size, unread, flagged, inInbox, references, attachments
        case bodyCached, bodyTruncated, body, ai, draft, userDraft, outbox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        messageId = try? c.decodeIfPresent(String.self, forKey: .messageId)
        uid = try? c.decodeIfPresent(Int.self, forKey: .uid)
        uidvalidity = try? c.decodeIfPresent(Int.self, forKey: .uidvalidity)
        fromName = try? c.decodeIfPresent(String.self, forKey: .fromName)
        fromAddr = try? c.decodeIfPresent(String.self, forKey: .fromAddr)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        replyTo = try? c.decodeIfPresent(String.self, forKey: .replyTo)
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        size = try? c.decodeIfPresent(Int.self, forKey: .size)
        unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? false
        flagged = (try? c.decodeIfPresent(Bool.self, forKey: .flagged)) ?? false
        inInbox = (try? c.decodeIfPresent(Bool.self, forKey: .inInbox)) ?? true
        references = (try? c.decodeIfPresent([String].self, forKey: .references)) ?? []
        attachments = (try? c.decodeIfPresent([MailAttachment].self, forKey: .attachments)) ?? []
        bodyCached = (try? c.decodeIfPresent(Bool.self, forKey: .bodyCached)) ?? true
        bodyTruncated = (try? c.decodeIfPresent(Bool.self, forKey: .bodyTruncated)) ?? false
        // Left as decodeIfPresent on purpose: "" and nil are different answers.
        body = try? c.decodeIfPresent(String.self, forKey: .body)
        ai = try? c.decodeIfPresent(MailAiArtifact.self, forKey: .ai)
        draft = try? c.decodeIfPresent(MailDraft.self, forKey: .draft)
        userDraft = try? c.decodeIfPresent(MailDraft.self, forKey: .userDraft)
        outbox = (try? c.decodeIfPresent([MailOutboxEntry].self, forKey: .outbox)) ?? []
    }
}

struct MailData: Equatable {
    var counts: MailCounts
    /// When the poller last finished talking to Gmail. The source goes stale
    /// off this rather than off the collector's own fetch age.
    var lastPollAt: String?
    /// Newest first, capped by the collector.
    var messages: [MailMessageSummary]
}

extension MailData: Decodable {
    private enum K: String, CodingKey { case counts, lastPollAt, messages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        counts = (try? c.decodeIfPresent(MailCounts.self, forKey: .counts)) ?? MailCounts(inbox: 0, unread: 0, urgent: 0, triagePending: 0, outboxQueued: 0)
        lastPollAt = try? c.decodeIfPresent(String.self, forKey: .lastPollAt)
        messages = (try? c.decodeIfPresent([MailMessageSummary].self, forKey: .messages)) ?? []
    }
}

// MARK: - messages
//
// The iMessage channel, per MESSAGES-PROTOCOL.md §4, §6 and §7. The shape of
// this block is the mailbox's shape one level over: a `MessagesData` for the
// envelope, a per-chat row for the list, and a thread record fetched by key
// because bodies never travel in telemetry.
//
// **Every field is optional or defaulted.** A collector older than this build
// sends none of them and one newer may send more, and neither may cost the
// console the rest of the payload -- which is the rule the whole file is
// written by hand for.

/// What Charon Bridge last said about itself.
///
/// `fda` and `automation` are `Bool?` for the reason `urgency` is `Int?`: false
/// is "System Settings says no" and nil is "no heartbeat has ever said", and
/// Settings prints a different word for each.
struct MessagesBridge: Equatable {
    var seenAt: String?
    var fda: Bool?
    var automation: Bool?
    /// Version and state in the collector's own one string, e.g.
    /// `0.14.1 · verified`. Echoed, never parsed.
    var helper: String?
    var cursor: Int?
    var lastEventAt: String?
    /// Rows dropped because their chat is not on the allowlist. A counter, on
    /// purpose: the chats themselves are never named anywhere.
    var dropped: Int?
    var error: String?
}

extension MessagesBridge: Decodable {
    private enum K: String, CodingKey {
        case seenAt, fda, automation, helper, cursor, lastEventAt, dropped, error
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        seenAt = try? c.decodeIfPresent(String.self, forKey: .seenAt)
        fda = try? c.decodeIfPresent(Bool.self, forKey: .fda)
        automation = try? c.decodeIfPresent(Bool.self, forKey: .automation)
        helper = try? c.decodeIfPresent(String.self, forKey: .helper)
        cursor = try? c.decodeIfPresent(Int.self, forKey: .cursor)
        lastEventAt = try? c.decodeIfPresent(String.self, forKey: .lastEventAt)
        dropped = try? c.decodeIfPresent(Int.self, forKey: .dropped)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct MessagesCounts: Equatable {
    var chats: Int
    var unread: Int
    var needsYou: Int
    var queued: Int

    init(chats: Int = 0, unread: Int = 0, needsYou: Int = 0, queued: Int = 0) {
        self.chats = chats
        self.unread = unread
        self.needsYou = needsYou
        self.queued = queued
    }
}

extension MessagesCounts: Decodable {
    private enum K: String, CodingKey { case chats, unread, needsYou, queued }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        chats = (try? c.decodeIfPresent(Int.self, forKey: .chats)) ?? 0
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        needsYou = (try? c.decodeIfPresent(Int.self, forKey: .needsYou)) ?? 0
        queued = (try? c.decodeIfPresent(Int.self, forKey: .queued)) ?? 0
    }
}

/// What a chat may do, from `messages/config.json`. `auto` is stored and shown
/// and has no behaviour in v1 -- see MESSAGES-PROTOCOL.md §4.
enum MessagePolicy: String, Equatable, CaseIterable {
    case off, confirm, auto
}

extension MessagePolicy: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        // A policy this build has never heard of is `off`. An unknown word in
        // the send column may never fail open.
        self = MessagePolicy(rawValue: raw) ?? .off
    }
}

/// One conversation as the payload lists it, and as `/v1/messages/chats` lists
/// it with its config fields joined on. One type for both routes: the second is
/// the first plus `chat_identifier` and `participants`, and a chat spelled twice
/// is a chat that can disagree with itself.
struct MessageChatSummary: Equatable, Identifiable {
    /// `sha256(chat_guid)[:16]`, hex. Identity and route at once.
    var chatKey: String
    /// The Messages chat GUID. Config is keyed by it; routes never are.
    var chatGuid: String?
    var chatIdentifier: String?
    var name: String
    var isGroup: Bool
    var service: String
    var participants: [String]
    var policy: MessagePolicy
    /// Whether the Bridge is allowed to forward this chat at all.
    var read: Bool
    var lastAt: String?
    var lastPreview: String?
    var lastSender: String?
    /// How many inbound rows have not been seen in Charon. Charon's own count;
    /// the Messages app's read flags are ignored (§7).
    var unread: Int
    /// Null until triage has looked. Null and 0 are different facts.
    var urgencyMax: Int?
    var needsYou: Bool

    var id: String { chatKey }

    init(chatKey: String, chatGuid: String? = nil, chatIdentifier: String? = nil,
         name: String = "unknown", isGroup: Bool = false, service: String = "iMessage",
         participants: [String] = [], policy: MessagePolicy = .off, read: Bool = false,
         lastAt: String? = nil, lastPreview: String? = nil, lastSender: String? = nil,
         unread: Int = 0, urgencyMax: Int? = nil, needsYou: Bool = false) {
        self.chatKey = chatKey
        self.chatGuid = chatGuid
        self.chatIdentifier = chatIdentifier
        self.name = name
        self.isGroup = isGroup
        self.service = service
        self.participants = participants
        self.policy = policy
        self.read = read
        self.lastAt = lastAt
        self.lastPreview = lastPreview
        self.lastSender = lastSender
        self.unread = unread
        self.urgencyMax = urgencyMax
        self.needsYou = needsYou
    }

    /// What the thread head prints under the name: the handle the chat is
    /// reached at, or the group's size when there is no one handle.
    var handle: String {
        if let identifier = chatIdentifier, !identifier.isEmpty { return identifier }
        if isGroup { return "\(participants.count) people" }
        return participants.first ?? ""
    }
}

extension MessageChatSummary: Decodable {
    private enum K: String, CodingKey {
        case chatKey, chatGuid, chatIdentifier, name, isGroup, service, participants
        case policy, read, lastAt, lastPreview, lastSender, unread, urgencyMax, needsYou
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        chatKey = (try? c.decodeIfPresent(String.self, forKey: .chatKey)) ?? ""
        chatGuid = try? c.decodeIfPresent(String.self, forKey: .chatGuid)
        chatIdentifier = try? c.decodeIfPresent(String.self, forKey: .chatIdentifier)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "unknown"
        isGroup = (try? c.decodeIfPresent(Bool.self, forKey: .isGroup)) ?? false
        service = (try? c.decodeIfPresent(String.self, forKey: .service)) ?? "iMessage"
        participants = (try? c.decodeIfPresent([String].self, forKey: .participants)) ?? []
        policy = (try? c.decode(MessagePolicy.self, forKey: .policy)) ?? .off
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        lastAt = try? c.decodeIfPresent(String.self, forKey: .lastAt)
        lastPreview = try? c.decodeIfPresent(String.self, forKey: .lastPreview)
        lastSender = try? c.decodeIfPresent(String.self, forKey: .lastSender)
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        urgencyMax = try? c.decodeIfPresent(Int.self, forKey: .urgencyMax)
        needsYou = (try? c.decodeIfPresent(Bool.self, forKey: .needsYou)) ?? false
    }
}

/// One day of Charon, as the payload lists it. The document behind it is
/// fetched by date.
struct MessageSummaryRow: Equatable, Identifiable {
    var date: String
    var status: String
    var read: Bool
    var archived: Bool
    var needsYouN: Int
    var preview: String?
    var at: String?

    var id: String { date }

    init(date: String, status: String = "ok", read: Bool = false, archived: Bool = false,
         needsYouN: Int = 0, preview: String? = nil, at: String? = nil) {
        self.date = date
        self.status = status
        self.read = read
        self.archived = archived
        self.needsYouN = needsYouN
        self.preview = preview
        self.at = at
    }
}

extension MessageSummaryRow: Decodable {
    private enum K: String, CodingKey {
        case date, status, read, archived, needsYouN, preview, at
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ok"
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        needsYouN = (try? c.decodeIfPresent(Int.self, forKey: .needsYouN)) ?? 0
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
    }
}

struct MessagesData: Equatable {
    /// Nil when no heartbeat has ever arrived, which the panel says as `absent`
    /// rather than as a bridge that is off.
    var bridge: MessagesBridge?
    var counts: MessagesCounts
    /// Newest conversation first, capped by the collector.
    var chats: [MessageChatSummary]
    /// Newest day first.
    var summaries: [MessageSummaryRow]

    init(bridge: MessagesBridge? = nil, counts: MessagesCounts = MessagesCounts(),
         chats: [MessageChatSummary] = [], summaries: [MessageSummaryRow] = []) {
        self.bridge = bridge
        self.counts = counts
        self.chats = chats
        self.summaries = summaries
    }
}

extension MessagesData: Decodable {
    private enum K: String, CodingKey { case bridge, counts, chats, summaries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        bridge = try? c.decodeIfPresent(MessagesBridge.self, forKey: .bridge)
        counts = (try? c.decodeIfPresent(MessagesCounts.self, forKey: .counts))
            ?? MessagesCounts()
        chats = (try? c.decodeIfPresent([MessageChatSummary].self, forKey: .chats)) ?? []
        summaries = (try? c.decodeIfPresent([MessageSummaryRow].self, forKey: .summaries)) ?? []
    }
}

// ── the thread ──

struct MessageAttachment: Equatable, Identifiable {
    /// Its position in the row, 0-based. The whole of how three programs agree
    /// which file they mean: the Bridge uploads by it, the collector files by
    /// it, and this app asks for it back by it.
    var n: Int
    var filename: String
    var mimeType: String?
    var totalBytes: Int?
    /// The file is named in `chat.db` and is not on the Mac -- Messages ages
    /// the big ones out. Nothing will ever fetch it, and the tile says so.
    var missing: Bool
    /// Whether the Pi holds the bytes. The collector's own answer, and the one
    /// thing on this record that neither the phone nor the Bridge could know.
    var stored: Bool
    /// A sticker is a kind of image and is drawn as one.
    var isSticker: Bool

    var id: Int { n }

    init(n: Int, filename: String, mimeType: String? = nil, totalBytes: Int? = nil,
         missing: Bool = false, stored: Bool = false, isSticker: Bool = false) {
        self.n = n
        self.filename = filename
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.missing = missing
        self.stored = stored
        self.isSticker = isSticker
    }

    /// What kind of tile this is. Read off the mime type, with the filename as
    /// the fallback for a row whose type never made it out of the database.
    enum Kind { case image, video, file }

    var kind: Kind {
        let mime = (mimeType ?? "").lowercased()
        if isSticker || mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.isEmpty {
            let tail = (filename as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff"].contains(tail) {
                return .image
            }
            if ["mov", "mp4", "m4v", "3gp"].contains(tail) { return .video }
        }
        return .file
    }
}

extension MessageAttachment: Decodable {
    private enum K: String, CodingKey {
        case n, filename, mimeType, totalBytes, missing, stored, isSticker
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        // Zero rather than a crash. A collector older than the field sends no
        // `n`, and the thread fills it in from the position on its way past --
        // see `MessageRecord`, which is the only place that has the position.
        n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 0
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? "attachment"
        mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType)
        totalBytes = try? c.decodeIfPresent(Int.self, forKey: .totalBytes)
        missing = (try? c.decodeIfPresent(Bool.self, forKey: .missing)) ?? false
        stored = (try? c.decodeIfPresent(Bool.self, forKey: .stored)) ?? false
        isSticker = (try? c.decodeIfPresent(Bool.self, forKey: .isSticker)) ?? false
    }
}

/// What the triage session made of one inbound row. Outbound rows are stored
/// for context and never triaged (§7), so `ai` is nil on every one of them.
struct MessageAi: Equatable {
    var tags: [String]
    /// Null on a record the worker gave up on. Null and 0 are different facts.
    var urgency: Int?
    var needsYou: Bool
    var summary: String?
}

extension MessageAi: Decodable {
    private enum K: String, CodingKey { case tags, urgency, needsYou, summary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        urgency = try? c.decodeIfPresent(Int.self, forKey: .urgency)
        needsYou = (try? c.decodeIfPresent(Bool.self, forKey: .needsYou)) ?? false
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
    }
}

/// One message row, whole. The Event of §4 with the triage verdict joined on.
struct MessageRecord: Equatable, Identifiable {
    /// `sha256(guid)[:16]`, hex.
    var key: String
    var chatKey: String?
    var sender: String?
    var senderName: String?
    var isFromMe: Bool
    /// `""` is a row that carried only attachments; nil is a row whose text the
    /// store never had. The transcript says different things about the two.
    var text: String?
    var createdAt: String?
    var service: String?
    var attachments: [MessageAttachment]
    var ai: MessageAi?

    var id: String { key }

    init(key: String, chatKey: String? = nil, sender: String? = nil,
         senderName: String? = nil, isFromMe: Bool = false, text: String? = nil,
         createdAt: String? = nil, service: String? = nil,
         attachments: [MessageAttachment] = [], ai: MessageAi? = nil) {
        self.key = key
        self.chatKey = chatKey
        self.sender = sender
        self.senderName = senderName
        self.isFromMe = isFromMe
        self.text = text
        self.createdAt = createdAt
        self.service = service
        self.attachments = attachments
        self.ai = ai
    }
}

extension MessageRecord: Decodable {
    private enum K: String, CodingKey {
        case key, chatKey, sender, senderName, isFromMe, text, createdAt, service
        case attachments, ai
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        chatKey = try? c.decodeIfPresent(String.self, forKey: .chatKey)
        sender = try? c.decodeIfPresent(String.self, forKey: .sender)
        senderName = try? c.decodeIfPresent(String.self, forKey: .senderName)
        isFromMe = (try? c.decodeIfPresent(Bool.self, forKey: .isFromMe)) ?? false
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        service = try? c.decodeIfPresent(String.self, forKey: .service)
        // Numbered by where they are, whatever the document said. A collector
        // older than the field sends none, and one that sent a number
        // disagreeing with the position would point a tile at the wrong file:
        // the position is the identity on all three sides of this.
        attachments = ((try? c.decodeIfPresent([MessageAttachment].self,
                                               forKey: .attachments)) ?? [])
            .enumerated().map { at, item in
                var fixed = item
                fixed.n = at
                return fixed
            }
        ai = try? c.decodeIfPresent(MessageAi.self, forKey: .ai)
    }
}

/// A reply that has not been sent, from either writer. `MailDraft`'s twin and
/// deliberately not `MailDraft` itself: the two live on different routes and a
/// field one of them grows is not a field the other did.
struct MessageDraft: Equatable {
    var status: String
    var text: String?
    var instructions: String?
    var model: String?
    var error: String?
    var at: String?

    init(status: String = "ready", text: String? = nil, instructions: String? = nil,
         model: String? = nil, error: String? = nil, at: String? = nil) {
        self.status = status
        self.text = text
        self.instructions = instructions
        self.model = model
        self.error = error
        self.at = at
    }
}

extension MessageDraft: Decodable {
    private enum K: String, CodingKey { case status, text, instructions, model, error, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ready"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
    }
}

/// One send this box filed, as the thread route reports it back (§5).
///
/// Not a message and deliberately shaped like one only where it has to be: a
/// send is a *request* that leaves the Pi, gets performed on the Mac, and comes
/// back minutes later as an ordinary inbound row. `guid` is the row it became,
/// which is the one field that lets the app recognise its own optimistic bubble
/// when the real one lands: `sha256(guid)[:16]` is that message's key.
struct MessageOutboxItem: Equatable, Identifiable {
    /// The collector's own 16 hex outbox id.
    var id: String
    /// `queued` · `sent` · `failed`. An unknown word is none of the three and
    /// is drawn as nothing rather than guessed at.
    var status: String
    var body: String?
    var at: String?
    var sentAt: String?
    /// The Messages row GUID, once the Bridge has one.
    var guid: String?
    var messageId: String?
    var error: String?
    var disposition: String?

    init(id: String, status: String = "queued", body: String? = nil, at: String? = nil,
         sentAt: String? = nil, guid: String? = nil, messageId: String? = nil,
         error: String? = nil, disposition: String? = nil) {
        self.id = id
        self.status = status
        self.body = body
        self.at = at
        self.sentAt = sentAt
        self.guid = guid
        self.messageId = messageId
        self.error = error
        self.disposition = disposition
    }
}

extension MessageOutboxItem: Decodable {
    private enum K: String, CodingKey {
        case id, status, body, at, sentAt, guid, messageId, error, disposition
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "queued"
        body = try? c.decodeIfPresent(String.self, forKey: .body)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        sentAt = try? c.decodeIfPresent(String.self, forKey: .sentAt)
        guid = try? c.decodeIfPresent(String.self, forKey: .guid)
        messageId = try? c.decodeIfPresent(String.self, forKey: .messageId)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        disposition = try? c.decodeIfPresent(String.self, forKey: .disposition)
    }
}

/// One conversation, whole. Fetched from `/v1/messages/thread/<chat_key>`.
struct MessageThread: Equatable {
    var chat: MessageChatSummary?
    /// Oldest first, the way a transcript is read.
    var messages: [MessageRecord]
    var draft: MessageDraft?
    /// His own, which wins over the session's wherever both exist.
    var userDraft: MessageDraft?
    /// This chat's own sends from the last day, oldest first. Empty from a
    /// collector that predates the field, which is why it is a list with a
    /// default rather than an optional: nothing filed and nothing reported are
    /// the same picture on screen.
    var outbox: [MessageOutboxItem]
    /// The key of the newest row seen in Charon.
    var readTo: String?

    init(chat: MessageChatSummary? = nil, messages: [MessageRecord] = [],
         draft: MessageDraft? = nil, userDraft: MessageDraft? = nil,
         outbox: [MessageOutboxItem] = [], readTo: String? = nil) {
        self.chat = chat
        self.messages = messages
        self.draft = draft
        self.userDraft = userDraft
        self.outbox = outbox
        self.readTo = readTo
    }
}

extension MessageThread: Decodable {
    private enum K: String, CodingKey {
        case chat, messages, draft, userDraft, outbox, readTo
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        chat = try? c.decodeIfPresent(MessageChatSummary.self, forKey: .chat)
        messages = (try? c.decodeIfPresent([MessageRecord].self, forKey: .messages)) ?? []
        draft = try? c.decodeIfPresent(MessageDraft.self, forKey: .draft)
        userDraft = try? c.decodeIfPresent(MessageDraft.self, forKey: .userDraft)
        outbox = (try? c.decodeIfPresent([MessageOutboxItem].self, forKey: .outbox)) ?? []
        readTo = try? c.decodeIfPresent(String.self, forKey: .readTo)
    }
}

// ── the daily summary ──

/// One bullet in the summary document, and the chat it is about.
///
/// Decodes from a bare string as well as from an object, because a line that
/// names no chat has nothing to carry besides its own sentence and a collector
/// is allowed to say so by sending the sentence.
struct MessageSummaryLine: Equatable, Identifiable {
    var text: String
    /// Nil where the session named no one chat: `open` is drawn only where
    /// there is somewhere to go.
    var chatKey: String?

    var id: String { text }

    init(_ text: String, chatKey: String? = nil) {
        self.text = text
        self.chatKey = chatKey
    }
}

extension MessageSummaryLine: Decodable {
    private enum K: String, CodingKey { case text, chatKey }
    init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            text = bare
            chatKey = nil
            return
        }
        let c = try decoder.container(keyedBy: K.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        chatKey = try? c.decodeIfPresent(String.self, forKey: .chatKey)
    }
}

/// What a session on the Pi made of one day of chats. Not the user's words, and
/// the card says so on its own foot.
struct MessageSummaryDoc: Equatable {
    var date: String
    var status: String
    var needsYou: [MessageSummaryLine]
    var noticed: [MessageSummaryLine]
    var quiet: [MessageSummaryLine]
    /// A paragraph where the session wrote one instead of bullets. Drawn under
    /// the three sections, never in place of them.
    var prose: String?
    var model: String?
    var at: String?
    var read: Bool
    var archived: Bool

    init(date: String, status: String = "ok", needsYou: [MessageSummaryLine] = [],
         noticed: [MessageSummaryLine] = [], quiet: [MessageSummaryLine] = [],
         prose: String? = nil, model: String? = nil, at: String? = nil,
         read: Bool = false, archived: Bool = false) {
        self.date = date
        self.status = status
        self.needsYou = needsYou
        self.noticed = noticed
        self.quiet = quiet
        self.prose = prose
        self.model = model
        self.at = at
        self.read = read
        self.archived = archived
    }
}

extension MessageSummaryDoc: Decodable {
    private enum K: String, CodingKey {
        case date, status, needsYou, noticed, quiet, prose, model, at, read, archived
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ok"
        needsYou = (try? c.decodeIfPresent([MessageSummaryLine].self, forKey: .needsYou)) ?? []
        noticed = (try? c.decodeIfPresent([MessageSummaryLine].self, forKey: .noticed)) ?? []
        quiet = (try? c.decodeIfPresent([MessageSummaryLine].self, forKey: .quiet)) ?? []
        prose = try? c.decodeIfPresent(String.self, forKey: .prose)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
    }
}

// ── the allowlist ──

/// One chat's entry in `messages/config.json`, keyed there by `chat_guid`.
struct MessagesChatPolicy: Equatable {
    var read: Bool
    var send: MessagePolicy
    /// Carried so Settings can name a chat the payload no longer lists.
    var name: String?

    init(read: Bool, send: MessagePolicy, name: String? = nil) {
        self.read = read
        self.send = send
        self.name = name
    }
}

extension MessagesChatPolicy: Decodable {
    private enum K: String, CodingKey { case read, send, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        read = (try? c.decodeIfPresent(Bool.self, forKey: .read)) ?? false
        send = (try? c.decode(MessagePolicy.self, forKey: .send)) ?? .off
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// The whole allowlist. Written back whole: the collector owns one document and
/// a patch route would be a second way to say the same thing.
struct MessagesConfig: Equatable {
    var updatedAt: String?
    /// Keyed by `chat_guid`, exactly as the collector holds it.
    var chats: [String: MessagesChatPolicy]

    init(updatedAt: String? = nil, chats: [String: MessagesChatPolicy] = [:]) {
        self.updatedAt = updatedAt
        self.chats = chats
    }

    /// The body of a config PUT. Built here rather than at the call site so the
    /// one place that knows this document's shape is the type named after it.
    var json: [String: Any] {
        var out: [String: Any] = [:]
        for (guid, policy) in chats {
            var entry: [String: Any] = ["read": policy.read, "send": policy.send.rawValue]
            if let name = policy.name { entry["name"] = name }
            out[guid] = entry
        }
        return ["chats": out]
    }
}

extension MessagesConfig: Decodable {
    private enum K: String, CodingKey { case updatedAt, chats }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        chats = (try? c.decodeIfPresent([String: MessagesChatPolicy].self, forKey: .chats)) ?? [:]
    }
}

// MARK: - the decoder

enum MailJSON {
    /// One decoder for every route. snake_case is converted rather than spelled
    /// out per key, and every struct above still writes its own `init(from:)`
    /// so that a missing key is a default rather than a thrown document.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
