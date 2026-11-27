import SwiftUI

/* ── Hardware ──────────────────────────────────────────────────────────
   Every machine, and the morning self-test. Ported from the web console's
   hardware view.

   **Two panels here are wired to an envelope their body does not come from,
   and that is deliberate.** The Pi 5 panel is framed by the *nodes* source
   because that is what says whether the board is answering at all, while its
   lower half reads the camera monitor running on it; the Zero panel is framed
   by *pi-hole* for the same reason in reverse -- the DNS service is the thing
   that goes wrong, and the node row only supplies the one status line. Both
   mismatches are ported exactly. A panel framed by the source that fails is
   worth more than a panel framed by the source it happens to read.

   No Masthead: the system already named itself on Overview, and it is one per
   view.
*/

struct HardwareView: View {
    var payload: TelemetryPayload
    var feedDown: Bool
    var now: Date
    var base: URL?
    var bearer: String?

    private var nd: NodesData? { payload.nodes?.data }
    private var ph: PiholeData? { payload.pihole?.data }
    private var cam: CameraData? { payload.camera?.data }
    /// Optional on purpose: a payload from a collector older than this panel
    /// has no such key at all, and an absent envelope is the unknown treatment
    /// rather than a crash.
    private var hc: HealthchecksData? { payload.healthchecks?.data }

    private var nodes: [NodeRow] { nd?.nodes ?? [] }
    private var days: [HealthCheckDay] { hc?.days ?? [] }
    private var pi5: NodeRow? { nodes.first { $0.id == "pi5" } }
    private var zero: NodeRow? { nodes.first { $0.id == "pizero" } }
    private var down: [NodeRow] { nodes.filter { !$0.connected } }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            PageHead(title: "Hardware", subtitle: subtitle)

            HTGrid {
                nodesCell
                pi5Cell
                zeroCell
                cameraCell
                checksCell
                Cell(span: 12) {
                    MastheadStrip(
                        legend: nd.map { "\($0.connected) of \($0.total) connected" }
                            ?? "no reading",
                        signal: !feedDown && nd != nil && nd?.connected == nd?.total)
                }
            }
        }
    }

    private var subtitle: String {
        if feedDown { return "Collector unreachable. These are the last known states." }
        if down.isEmpty { return "\(nodes.count) nodes tracked. All answering." }
        return "\(nodes.count) nodes tracked. \(down.count) not answering."
    }

    // MARK: - every machine

    private var nodesCell: some View {
        Cell(span: 12) {
            SourcePanel(env: payload.nodes, feedDown: feedDown,
                        title: "Nodes", glyph: .hardware, ticks: true, flush: true) { _ in
                ViewThatFits(in: .horizontal) {
                    DataTable(columns: nodeColumns, rows: nodes, empty: "No nodes configured")
                        .frame(minWidth: 750)
                    VStack(alignment: .leading, spacing: 0) {
                        if nodes.isEmpty { Text("No nodes configured").foregroundStyle(HT.inkMid) }
                        ForEach(nodes) { node in
                            DisclosureGroup {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                                    ForEach(nodeColumns.filter { $0.key != "host" && $0.key != "state" }, id: \.key) { col in
                                        GridRow { Text(col.header).foregroundStyle(HT.inkMid); col.cell(node) }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            } label: {
                                HStack {
                                    Text(node.host).font(.body.weight(.medium))
                                    Spacer()
                                    Text(node.label.capitalized).foregroundStyle(node.tone.ink ?? HT.inkMid)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
    }

    private var nodeColumns: [DataColumn<NodeRow>] {
        [
            DataColumn(key: "host", header: "Host",
                       cell: { DataColumn<NodeRow>.primary($0.host) }),
            DataColumn(key: "kind", header: "Board",
                       cell: { DataColumn<NodeRow>.muted($0.kind) }),
            // The sentence, so this is the column that absorbs the slack.
            DataColumn(key: "role", header: "Role", flexible: true,
                       cell: { DataColumn<NodeRow>.plain($0.role) }),
            // Gated on `connected`: an uptime from a machine that is not
            // answering is the uptime it had when it stopped, and printing it
            // straight reads as a machine that is up.
            DataColumn(key: "uptime", header: "Uptime", align: .trailing,
                       cell: { n in
                           n.connected && n.uptimeS != nil
                               ? DataColumn<NodeRow>.plain(Fmt.dur(n.uptimeS))
                               : DataColumn<NodeRow>.muted("—")
                       }),
            DataColumn(key: "temp", header: "Temp", align: .trailing,
                       cell: { n in
                           n.connected && n.tempC != nil
                               ? DataColumn<NodeRow>.plain(Fmt.temp(n.tempC))
                               : DataColumn<NodeRow>.muted("—")
                       }),
            // NOT gated on `connected`, and that is the point: a round trip is
            // a fact about the probe that just ran, so a machine that answered
            // ping and nothing else still has one worth reading.
            DataColumn(key: "rtt", header: "RTT", align: .trailing,
                       cell: { n in
                           n.rttMs != nil
                               ? DataColumn<NodeRow>.plain("\(Fmt.raw(n.rttMs))ms")
                               : DataColumn<NodeRow>.muted("—")
                       }),
            DataColumn(key: "link", header: "Link",
                       cell: { n in
                           AnyView(StatusLamp(level: n.link, of: 3,
                                              tone: n.connected ? .nominal : .fault))
                       }),
            // The collector's own verdict, word and colour. The rule for what
            // "Connected" means belongs to the process that did the probing.
            DataColumn(key: "state", header: "Status",
                       cell: { n in AnyView(StatusPill(text: n.label, tone: n.tone)) }),
        ]
    }

    // MARK: - the Pi 5

    private var pi5Cell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: payload.nodes, feedDown: feedDown,
                        title: "raspberrypi", ticks: true) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    DotLeader(label: "status",
                              value: (pi5?.connected ?? false) ? "connected" : "offline",
                              tone: (pi5?.connected ?? false) ? .nominal : .fault)
                    DotLeader(label: "uptime", value: Fmt.dur(pi5?.uptimeS))
                    DotLeader(label: "load avg",
                              value: pi5?.load1.map { String(format: "%.2f", $0) } ?? "—")
                    // A board with no temperature to report reads nominal, not
                    // caution: the missing reading is not a hot one. Ported as
                    // written -- `(temp ?? 0) >= 70`.
                    DotLeader(label: "soc temp", value: Fmt.temp(pi5?.tempC),
                              tone: (pi5?.tempC ?? 0) >= 70 ? .caution : .nominal)

                    Rule(label: "dog monitor")

                    DotLeader(label: "watch",
                              value: (cam?.monitor.alive ?? false)
                                  ? "up \(Fmt.dur(cam?.monitor.uptimeS))"
                                  : "not running",
                              tone: (cam?.monitor.alive ?? false) ? .nominal : .fault)
                    DotLeader(label: "feed",
                              value: (cam?.monitor.feedOk ?? false)
                                  ? "up"
                                  : "down \(Fmt.dur(cam?.monitor.feedDownForS))",
                              tone: (cam?.monitor.feedOk ?? false) ? .nominal : .fault)
                    DotLeader(label: "frame",
                              value: (cam?.frame.available ?? false)
                                  ? "\(Fmt.relTime(cam?.frame.ts, now: now)) old"
                                  : "none",
                              tone: (cam?.frame.available ?? false) ? .nominal : .standby)
                }
            }
        }
    }

    // MARK: - the Zero

    private var zeroCell: some View {
        Cell(span: 4, spanMd: 6) {
            SourcePanel(env: payload.pihole, feedDown: feedDown,
                        title: "pizero", ticks: true) { h in
                VStack(alignment: .leading, spacing: 0) {
                    DotLeader(label: "status",
                              value: (zero?.connected ?? false) ? "connected" : "offline",
                              tone: (zero?.connected ?? false) ? .nominal : .fault)
                    DotLeader(label: "uptime", value: Fmt.dur(ph?.hostUptimeS))
                    // A raw count, ungrouped: one core does not want a comma
                    // and this number never reaches four figures.
                    DotLeader(label: "cores", value: ph?.hostCores.map(String.init) ?? "—")
                    DotLeader(label: "processes", value: Fmt.num(ph?.hostProcs))

                    Rule(label: "pi-hole")

                    DotLeader(label: "blocked today", value: Fmt.num(ph?.blockedToday),
                              tone: h.dim ? .standby : .nominal)
                    DotLeader(label: "queries today", value: Fmt.num(ph?.queriesToday))

                    // The trailing space in each label is load-bearing: it pads
                    // "cpu" and "ftl" to the same cell count so the two runs
                    // start on the same column.
                    VStack(alignment: .leading, spacing: HT.s1) {
                        SegBar(value: ph?.hostCpuPct ?? 0,
                               tone: h.dim ? .standby : .nominal,
                               label: "cpu ", readout: Fmt.pct(ph?.hostCpuPct, 0), block: true)
                        SegBar(value: ph?.ftlMemPct ?? 0,
                               tone: h.dim ? .standby : .nominal,
                               label: "ftl ", readout: Fmt.pct(ph?.ftlMemPct, 0), block: true)
                    }
                    .padding(.top, HT.row)
                }
            }
        }
    }

    // MARK: - the camera

    private var cameraCell: some View {
        Cell(span: 4, spanMd: 12) {
            SourcePanel(env: payload.camera, feedDown: feedDown,
                        title: "Dog camera", glyph: .overview, ticks: true) { _ in
                // No aspect here, unlike Overview: this panel is a third of the
                // grid rather than half, so the frame takes the design system's
                // own 4:3 and the still is not letterboxed to fit a column.
                CameraFrame(label: "Dog cam · Pi 5",
                            src: frameURL,
                            bearer: bearer,
                            state: cam?.display.cameraState ?? .offline,
                            stamp: Fmt.clock(cam?.display.stamp),
                            verdict: verdict,
                            refreshSeconds: 10)
            }
        }
    }

    private var frameURL: URL? {
        guard let cam, cam.frame.available, let path = cam.frame.url, let base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    private var verdict: CameraVerdictSpec? {
        cam.map {
            CameraVerdictSpec(label: $0.display.verdict.label,
                              value: $0.display.verdict.value,
                              tone: $0.display.verdict.tone)
        }
    }

    // MARK: - the morning self-test

    private var checksCell: some View {
        Cell(span: 12) {
            SourcePanel(env: payload.healthchecks, feedDown: feedDown,
                        title: "Daily checks", ticks: true) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    // The newest run that exists, which is not necessarily
                    // today's: a run that never happened leaves yesterday at
                    // the head of the list, and the envelope's stale reason is
                    // what says so.
                    LogStream(entries: HardwareView.checkLines(days.first))

                    if days.count > 1 {
                        Rule(label: "history")
                        // Ten rows of the cell grid, so the cap lands on a line
                        // boundary rather than halfway through one.
                        LogStream(entries: HardwareView.historyLines(Array(days.dropFirst())),
                                  maxHeight: 160)
                    }
                }
            }
        }
    }

    /* Row mapping only. Whether the panel is stale is SourcePanel's business.

       **The capitals here come back lowercase**, and that is the reference's
       netted-out behaviour rather than an accident: the stylesheet lowercases
       every LogStream line, the view builds them in caps, and porting only
       half of that round trip would change what the panel says. */

    /// The most recent run, itemised one check to a line.
    static func checkLines(_ day: HealthCheckDay?) -> [LogEntry] {
        (day?.checks ?? []).map { c in
            LogEntry(id: c.id,
                     text: c.detail.isEmpty
                         ? c.label.uppercased()
                         : "\(c.label.uppercased()) · \(c.detail)",
                     state: c.ok ? "PASS" : "FAIL",
                     tone: c.ok ? .nominal : .fault)
        }
    }

    /// Every earlier run, one day to a line, newest first. A passing day is
    /// worth a count and nothing else; a failing one is worth the names.
    static func historyLines(_ days: [HealthCheckDay]) -> [LogEntry] {
        days.map { d in
            LogEntry(id: d.date,
                     time: d.date,
                     text: d.fail > 0
                         ? d.checks.filter { !$0.ok }.map { $0.label.uppercased() }
                             .joined(separator: ", ")
                         : "ALL CHECKS PASSED",
                     state: d.fail > 0 ? "FAIL" : "\(d.pass)/\(d.pass + d.fail) PASS",
                     tone: d.fail > 0 ? .fault : .nominal)
        }
    }
}
