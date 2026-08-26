import Foundation

/* A complete payload, for demo mode -- ported from the web console's
 * `demoPayload` fixture.
 *
 * **Fixtured at the payload boundary rather than the component boundary.**
 * That is what keeps demo mode from duplicating the compositions: the views are
 * written once against `TelemetryPayload` and demo mode simply supplies a
 * different one. There is no parallel view tree and no branching inside panels.
 *
 * The three unhappy modes walk every branch of `health()` without unplugging
 * hardware -- which matters, because those are exactly the states you hope
 * never to see and therefore never get to review. Two of them are worth
 * spelling out:
 *
 *   `stale` puts the camera, the self-test and the mailbox in the SEMANTIC
 *   stale case -- a fresh four-second fetch carrying an upstream that admits it
 *   has nothing -- while the Pi-hole, the nodes and the commits go stale the
 *   transport way, with a six-hour-old copy. The two look identical in
 *   `status` and need completely different sentences, and this is the live
 *   situation whenever the camera is unplugged and the Pi is fine.
 *
 *   `standby` is not an error. Every source comes back `dormant` with the
 *   reason it was never wired, and nothing on screen may draw it red.
 *
 * The mailbox is the one source this file does not invent. `DemoStore` owns the
 * eight fixture messages and mutates them as the reader writes; this only puts
 * the right envelope around whatever it has.
 *
 * Demo fixtures. Every person, company, repository, address, and figure in this
 * file is fictional; any resemblance to real entities is coincidental.
 */

enum DemoMode: String, CaseIterable {
    /// The happy payload.
    case one = "1"
    case stale
    case failed
    case standby

    /// Read once at launch from `defaults write com.example.charon
    /// demoMode stale`. There is no UI for it in this phase: it exists so the
    /// four states can be looked at without unplugging a Raspberry Pi.
    static var preference: DemoMode {
        DemoMode(rawValue: UserDefaults.standard.string(forKey: "demoMode") ?? "") ?? .one
    }
}

enum DemoPayload {

    // MARK: - clocks

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func stamp(_ at: Date) -> String { iso.string(from: at) }

    /// YYYY-MM-DD in local time. Assembled from the parts rather than sliced off
    /// an ISO string, which is UTC and would name the wrong day every evening.
    private static func isoDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - envelopes

    private static func env<T>(_ data: T, _ status: SourceStatus, _ ageS: Double,
                               _ interval: Double, _ staleReason: String? = nil,
                               now: Date) -> SourceEnvelope<T> {
        SourceEnvelope(
            status: status,
            fetchedAt: stamp(now.addingTimeInterval(-ageS)),
            ageS: ageS,
            staleReason: staleReason,
            intervalS: interval,
            nextAttemptInS: Int(Swift.max(0, (interval - ageS).rounded())),
            consecutiveFailures: status == .error ? 4 : 0,
            error: status == .error
                ? SourceError(kind: "TimeoutError", message: "no response in 6s",
                              at: stamp(now.addingTimeInterval(-ageS)))
                : nil,
            data: data)
    }

    /// Never configured is not in trouble. The message is the one line the
    /// panel can honestly say about a source that has never run.
    private static func dormant<T>(_ message: String) -> SourceEnvelope<T> {
        SourceEnvelope(
            status: .dormant, fetchedAt: nil, ageS: nil, staleReason: nil,
            intervalS: 300, nextAttemptInS: nil, consecutiveFailures: 0,
            error: SourceError(kind: "not_configured", message: message, at: nil),
            data: nil)
    }

    // MARK: - the morning self-test
    //
    // The same six checks run every day, so the fixture states them once and
    // names only the day that came back different. Ten days of literal rows
    // would be sixty lines saying the same thing.

    private static let checks: [(id: String, label: String, detail: String)] = [
        ("throttled", "throttled", "get_throttled 0x0"),
        ("soc_temp", "soc temp", "37.5°C · limit 70°C"),
        ("root_disk", "root disk", "18% of 234G used"),
        ("state_dir", "state dir", "/var/lib/halftone writable"),
        ("memory", "memory", "2.4G of 7.8G used"),
        ("zero_dns", "pizero dns", "10.0.0.3:53 · 12ms"),
    ]

    private static func checkDay(_ daysBack: Int, failed: [String: String] = [:],
                                 now: Date) -> HealthCheckDay {
        let day = now.addingTimeInterval(-Double(daysBack) * 86_400)
        let at = Calendar.current.date(bySettingHour: 6, minute: 12, second: 0, of: day) ?? day
        let rows = checks.map { c in
            HealthCheckRow(id: c.id, label: c.label, ok: failed[c.id] == nil,
                           detail: failed[c.id] ?? c.detail)
        }
        return HealthCheckDay(
            date: isoDay(at), ranAt: stamp(at),
            pass: rows.filter(\.ok).count, fail: rows.filter { !$0.ok }.count,
            checks: rows)
    }

    /// Newest first. Three days back the Zero stopped answering DNS.
    private static func checkDays(now: Date) -> [HealthCheckDay] {
        (0..<10).map { i in
            checkDay(i, failed: i == 3 ? ["zero_dns": "10.0.0.3:53 no answer"] : [:], now: now)
        }
    }

    // MARK: - the sources

    private static func camera(now: Date) -> CameraData {
        CameraData(
            state: "asleep",
            since: stamp(now.addingTimeInterval(-2_520)),
            elapsedS: 2_520,
            lastSample: stamp(now.addingTimeInterval(-4)),
            lastScore: 0.0012,
            monitorStale: false,
            monitorStaleForS: 0,
            monitor: CameraMonitor(alive: true, reason: nil, pid: 7415, beatAgeS: 3,
                                   feedOk: true, feedDownForS: nil, uptimeS: 54_120),
            frame: CameraFrameInfo(available: true,
                                   ts: stamp(now.addingTimeInterval(-6)),
                                   ageS: 6, url: "/v1/camera/latest.jpg"),
            display: CameraDisplay(
                cameraState: .live,
                stamp: stamp(now.addingTimeInterval(-6)),
                verdict: CameraVerdict(label: "stillness", value: "still · 42m",
                                       tone: .nominal)))
    }

    private static let pihole = PiholeData(
        apiVersion: 6,
        queriesToday: 43_003, blockedToday: 13_315, blockRatePct: 31.0,
        domainsOnList: 213_723, clientsActive: 4,
        topBlocked: "beacons.pushmetrics.example.com",
        hostUptimeS: 65_019, hostProcs: 111, hostCores: 1,
        hostCpuPct: 4.7, ftlCpuPct: 2.0, ftlMemPct: 6.5)

    private static func nodes(now: Date) -> NodesData {
        func ago(_ s: Double) -> String { stamp(now.addingTimeInterval(-s)) }
        return NodesData(
            nodes: [
                NodeRow(id: "pi5", host: "raspberrypi", addr: "10.0.0.2",
                        kind: "Pi 5 · NVMe", role: "Camera · stillness detect",
                        probe: "self", connected: true, rttMs: nil, uptimeS: 63_399,
                        load1: 0.02, tempC: 37.5, link: 3, tone: .nominal,
                        label: "Connected", downSince: nil, checkedAt: ago(4)),
                NodeRow(id: "pizero", host: "pizero", addr: "10.0.0.3",
                        kind: "Zero W · armv6l", role: "Pi-hole DNS",
                        probe: "tcp:53", connected: true, rttMs: 12.3, uptimeS: 65_019,
                        load1: nil, tempC: nil, link: 3, tone: .nominal,
                        label: "Connected", downSince: nil, checkedAt: ago(4)),
                NodeRow(id: "tapo", host: "tapo-c100", addr: "10.0.0.4",
                        kind: "RTSP cam", role: "Camera feed source",
                        probe: "tcp:554", connected: false, rttMs: nil, uptimeS: nil,
                        load1: nil, tempC: nil, link: 0, tone: .fault,
                        label: "Offline", downSince: ago(9_400), checkedAt: ago(4)),
                NodeRow(id: "orin", host: "orin", addr: "100.64.0.4",
                        kind: "Orin Nano", role: "Jetson · vision node",
                        probe: "tcp:22", connected: false, rttMs: nil, uptimeS: nil,
                        load1: nil, tempC: nil, link: 0, tone: .fault,
                        label: "Offline", downSince: ago(1_123_200), checkedAt: ago(4)),
            ],
            connected: 2, total: 4)
    }

    private static func commits(now: Date) -> CommitsData {
        func ago(_ s: Double) -> String { stamp(now.addingTimeInterval(-s)) }
        return CommitsData(
            commits: [
                CommitRow(id: "e939747", sha: "e939747",
                          title: "Tokens: 1-bit tty design system",
                          repo: "tty-ds", committedAt: ago(240)),
                CommitRow(id: "2a1c8f0", sha: "2a1c8f0",
                          title: "Season standings: fix tiebreak on equal points",
                          repo: "scorekeeper", committedAt: ago(7_200)),
                CommitRow(id: "7d40b19", sha: "7d40b19",
                          title: "Drop divisions from the schema, seasons only",
                          repo: "scorekeeper", committedAt: ago(18_000)),
                CommitRow(id: "b8e2c31", sha: "b8e2c31",
                          title: "Sensor read via 0x21A0, scale by 128",
                          repo: "can-reader", committedAt: ago(86_400)),
                CommitRow(id: "15fa0d7", sha: "15fa0d7",
                          title: "Serial handshake retries on cold boot",
                          repo: "rover-fw", committedAt: ago(97_200)),
            ],
            reposOk: 4, reposFailed: 0,
            reposUntracked: ["can-reader", "fieldnotes", "pi-image"],
            rateLimit: CommitsRateLimit(remaining: 4_912, limit: 5_000,
                                        resetsAt: stamp(now.addingTimeInterval(1_800))))
    }

    // MARK: - the payload

    static func make(mode: DemoMode, mail: MailData?, messages: MessagesData? = nil,
                     now: Date = Date()) -> TelemetryPayload {
        let stale = mode == .stale
        let failed = mode == .failed
        let standby = mode == .standby

        let status: SourceStatus = failed ? .error : stale ? .stale : standby ? .dormant : .ok
        let age: Double = stale ? 21_600 : failed ? 900 : 4

        let days = checkDays(now: now)

        // ── camera ──
        // Stale the semantic way: a current fetch carrying an upstream that
        // admits it has nothing. `age_s` stays at 4 and the reason does the
        // talking, or the panel reads "stale 4s ago" over a two-hour outage.
        let cameraEnv: SourceEnvelope<CameraData> = standby
            ? dormant("MONITOR_API_TOKEN is unset; cannot reach the monitor")
            : env(camera(now: now), status, stale ? 4 : age, 10,
                  stale ? "camera feed down 2h 19m" : nil, now: now)

        let piholeEnv: SourceEnvelope<PiholeData> = standby
            ? dormant("PIHOLE_APP_PASSWORD is unset")
            : env(pihole, status, age, 30, now: now)

        let nodesEnv: SourceEnvelope<NodesData> = standby
            ? dormant("nodes.list is empty")
            : env(nodes(now: now), status, age, 15, now: now)

        let commitsEnv: SourceEnvelope<CommitsData> = standby
            ? dormant("GITHUB_TOKEN is unset")
            : env(commits(now: now), status, age, 300, now: now)

        // ── the self-test ──
        // Stale the semantic way too, and for the same reason: reading the
        // results file succeeds every time, and what it finds is a run that
        // never happened. Today's day is withheld, the newest on offer is
        // yesterday's, and the reason names that date.
        let healthEnv: SourceEnvelope<HealthchecksData> = standby
            ? dormant("healthchecks.enabled is false")
            : env(HealthchecksData(days: stale ? Array(days.dropFirst()) : days),
                  status, stale ? 4 : age, 300,
                  stale ? "no check run since \(days[1].date)" : nil, now: now)

        // ── the mailbox ──
        // The eight fixture messages are DemoStore's and are not touched here;
        // only the envelope around them changes, and in the stale case the last
        // poll moves back so the counts line has something old to say.
        let mailEnv: SourceEnvelope<MailData>?
        if standby {
            mailEnv = dormant("no mail state on disk; the poller has never run")
        } else if let mail {
            if stale {
                var idle = mail
                idle.lastPollAt = stamp(now.addingTimeInterval(-9_000))
                mailEnv = env(idle, status, 4, 60, "no imap poll in 2h 30m", now: now)
            } else if failed {
                mailEnv = env(mail, .error, 900, 60, now: now)
            } else {
                mailEnv = env(mail, status, age, 60, now: now)
            }
        } else {
            mailEnv = nil
        }

        // ── the iMessage bridge ──
        // The chats and the summaries are `DemoMessagesStore`'s and are not
        // touched here; only the envelope around them changes. `stale` is the
        // semantic case again and its reason is the one the collector writes
        // for a bridge that has stopped reporting (MESSAGES-PROTOCOL.md §6):
        // the store answered instantly, and what it holds is two hours old.
        let messagesEnv: SourceEnvelope<MessagesData>?
        if standby {
            messagesEnv = dormant("no messages store yet; the bridge has never reported")
        } else if let messages {
            if stale {
                messagesEnv = env(messages, status, 4, 20,
                                  "bridge not reporting for 2h 19m", now: now)
            } else if failed {
                messagesEnv = env(messages, .error, 900, 20, now: now)
            } else {
                messagesEnv = env(messages, status, age, 20, now: now)
            }
        } else {
            messagesEnv = nil
        }

        // ── the CMO ──
        // `degraded`, not `stale`: the heartbeat file was read perfectly and
        // what it says is that the run failed. The reason is the collector's
        // own short phrase, which becomes the pill; the full sentence is in the
        // heartbeat's `detail` and renders in the page head.
        //
        // The body differs with it. `stale` carries today's failed heartbeat
        // over YESTERDAY's agent result, which is the whole reason `agent_date`
        // exists -- it is what puts "showing briefing from <date>" on screen.
        let cmoEnv: SourceEnvelope<CmoData> = standby
            ? dormant("no heartbeat yet; the CMO job has never run")
            : stale
                ? env(DemoCmo.failedRun(now: now), .degraded, age, 60,
                      "claude auth expired", now: now)
                : failed
                    ? env(DemoCmo.ok(now: now), .error, 900, 60, now: now)
                    : env(DemoCmo.ok(now: now), status, age, 60, now: now)

        return TelemetryPayload(
            schema: 1,
            serverTime: stamp(now),
            collector: CollectorInfo(version: "halftone-collector/1",
                                     startedAt: stamp(now.addingTimeInterval(-17_489)),
                                     uptimeS: 17_489),
            health: HealthCounts(
                worst: status,
                ok: status == .ok ? 8 : 0,
                degraded: 0,
                stale: stale ? 8 : 0,
                dormant: standby ? 8 : 0,
                error: failed ? 8 : 0),
            camera: cameraEnv,
            pihole: piholeEnv,
            nodes: nodesEnv,
            commits: commitsEnv,
            healthchecks: healthEnv,
            cmo: cmoEnv,
            mail: mailEnv,
            messages: messagesEnv)
    }
}
