import SwiftUI

/* ── Overview ──────────────────────────────────────────────────────────
   The landing page. Ported from the web console's overview view.

   **Composition only.** Not one line here decides what stale looks like:
   every panel fed by the collector goes through `SourcePanel`, which reads
   `health()` and hands the body back a `Health` to demote values with. A view
   that set a panel's tone itself would be the first crack in that rule.

   It reads four sources -- camera, pi-hole, nodes, commits -- plus the
   collector's own uptime and its tally of every source. It deliberately does
   not read the mailbox, the CMO or the self-test: those have tabs, and a
   landing page that summarised all seven would be a worse version of each.
*/

struct ConsoleView: View {
    var profileKey: String
    var isDemo: Bool
    @State private var history = OverviewMetricHistory()
    var payload: TelemetryPayload?
    var connectionError: String?
    var feedDown: Bool
    /// The clock every relative time on this page is measured from. Moved by
    /// the poll, never read from `Date()` inside a row.
    var now: Date
    /// The collector, for the camera still. The frame's own URL is a path on
    /// that host and its route wants the bearer.
    var base: URL?
    var bearer: String?

    /// Read, never written. The identity slot's art and its width are
    /// preferences, and reading them here -- inside this body -- is the whole
    /// of the live binding: the settings object is observed, so picking a
    /// different art in Settings re-runs this and hands the masthead a
    /// different element in the same pass. No `.id`, no relaunch.
    private let settings = ConsoleSettings.shared

    private var cam: CameraData? { payload?.camera?.data }
    private var ph: PiholeData? { payload?.pihole?.data }
    private var nd: NodesData? { payload?.nodes?.data }
    private var cm: CommitsData? { payload?.commits?.data }

    /// Every node the collector could not reach. The subtitle names them, the
    /// nodes panel counts them, and neither invents the rule for what
    /// "connected" means -- the collector already decided that.
    private var faults: [NodeRow] { (nd?.nodes ?? []).filter { !$0.connected } }

    var body: some View {
        OverviewDashboard(profileKey: profileKey, isDemo: isDemo) { entry, isEditing, updateManualValue in
            if let widget = entry.widget {
                if payload == nil && [.pihole, .nodes, .stillness, .commits, .camera, .blocking].contains(widget) {
                    Panel(title: widget.title) {
                        Text(connectionError == nil ? "Waiting for telemetry." : "Collector unavailable.")
                            .font(HT.body)
                            .foregroundStyle(HT.inkDim)
                    }
                } else {
                    widgetBody(widget, config: entry.configuration, isEditing: isEditing,
                               updateManualValue: updateManualValue)
                }
            }
        }
        .onChange(of: payload, initial: true) { _, latest in history.observe(latest, feedDown: feedDown) }
        .onChange(of: feedDown) { _, down in history.observe(payload, feedDown: down) }
    }

    @ViewBuilder
    private func widgetBody(_ widget: OverviewWidget, config: OverviewWidgetConfig, isEditing: Bool,
                            updateManualValue: @escaping (Double) -> Void) -> some View {
        switch widget {
        case .weather, .quakes:
            OverviewFeedWidget(kind: widget, config: config, isDemo: isDemo, allowNetwork: !isEditing)
        case .metric:
            OverviewTelemetryMetric(config: config, payload: payload, feedDown: feedDown, history: history)
        case .progress:
            OverviewProgressWidget(config: config, payload: payload, feedDown: feedDown,
                                   isEditing: isEditing, updateManualValue: updateManualValue)
        case .custom:
            if let spec = config.custom {
                CustomWidgetView(spec: spec, isEditing: isEditing, isDemo: isDemo)
            }
        case .identity: identity
        case .date: PageHead(title: Fmt.longDate(now), subtitle: subtitle, titleSize: 18)
        case .pihole: piholeCell
        case .nodes: nodesCell
        case .stillness: stillnessCell
        case .commits: commitsCell
        case .camera: cameraCell
        case .blocking: blockingCell
        case .artwork: plateCell
        case .status:
            MastheadStrip(legend: feedDown ? "Offline" : "Live", signal: !feedDown)
        }
    }

    private var identity: some View {
        Masthead(user: "operator", host: "halftone",
                 rows: mastheadRows,
                 art: settings.masthead.view(cols: settings.mastheadCols,
                                             imageFile: settings.mastheadImageFile))
    }

    // MARK: - the identity block

    private var mastheadRows: [MastheadRow] {
        guard payload != nil else {
            if connectionError == nil { return [MastheadRow("collector", "connecting")] }
            return [MastheadRow("collector", "offline", tone: .caution)]
        }
        return [
            MastheadRow("collector", "up \(Fmt.dur(payload?.collector?.uptimeS))"),
            MastheadRow("nodes",
                        nd.map { "\($0.connected) of \($0.total) connected" } ?? "—",
                        tone: (nd?.connected ?? 0) < (nd?.total ?? 0) ? .caution : .nominal),
            MastheadRow("blocked",
                        ph.map { "\(Fmt.num($0.blockedToday)) today" } ?? "—",
                        tone: .nominal),
            MastheadRow("stillness",
                        cam?.display.verdict.value ?? "—",
                        tone: cam?.display.verdict.tone ?? .standby),
            MastheadRow("sources", sourceWords, tone: sourceTone),
        ]
    }

    /// Every non-zero bucket, in the order the collector counts them.
    ///
    /// Non-zero rather than a fixed three, because the counts otherwise stop
    /// adding up to the number of sources: with a stale camera this line read
    /// "2 ok · 1 not wired" over four sources, and the one in trouble was the
    /// one it left out.
    private var sourceWords: String {
        let h = payload?.health
        let buckets: [(Int, String)] = [
            (h?.ok ?? 0, "ok"),
            (h?.degraded ?? 0, "degraded"),
            (h?.stale ?? 0, "stale"),
            (h?.error ?? 0, "failed"),
            (h?.dormant ?? 0, "not wired"),
        ]
        let words = buckets.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return words.isEmpty ? "no sources" : words.joined(separator: " · ")
    }

    private var sourceTone: Tone {
        let h = payload?.health
        if (h?.error ?? 0) > 0 { return .fault }
        if (h?.stale ?? 0) > 0 || (h?.degraded ?? 0) > 0 { return .caution }
        return .default
    }

    private var subtitle: String {
        if payload == nil { return connectionError ?? "Waiting for the first reading." }
        if feedDown { return "Collector unreachable. Showing the last values received." }
        guard !faults.isEmpty else { return "All sources reporting." }
        let plural = faults.count > 1 ? "s" : ""
        return "\(faults.count) node\(plural) not answering: "
            + faults.map(\.host).joined(separator: ", ") + "."
    }

    // MARK: - ads blocked

    private var piholeCell: some View {
        SourcePanel(env: payload?.pihole, feedDown: feedDown,
                    title: "Pi-hole", meta: "pi-zero-w") { h in
            VStack(alignment: .leading, spacing: 0) {
                Metric(
                    label: "ads blocked today",
                    value: Fmt.num(ph?.blockedToday),
                    // Not a Delta. The block rate is a ratio, not a change,
                    // and a Delta renders an arrow and the word "up" -- so
                    // feeding it 31.0% would claim blocking had risen by a
                    // third when it simply was a third. Nothing upstream
                    // reports a prior period, so there is no honest delta
                    // to draw here.
                    footer: AnyView(
                        Text("\(Fmt.pct(ph?.blockRatePct)) of \(Fmt.num(ph?.queriesToday)) queries")
                            .htDemoted(h.dim)),
                    dim: h.dim)

                SegBar(value: ph?.blockRatePct ?? 0,
                       tone: h.dim ? .standby : .nominal,
                       label: "rate", block: true)
                    .padding(.top, HT.row)
            }
        }
    }

    // MARK: - nodes

    private var nodesCell: some View {
        SourcePanel(env: payload?.nodes, feedDown: feedDown, title: "Nodes") { h in
            VStack(alignment: .leading, spacing: 0) {
                Metric(
                    label: "nodes connected",
                    value: nd.map { "\($0.connected)" } ?? "—",
                    unit: nd.map { "of \($0.total)" },
                    footer: AnyView(
                        Text(faults.isEmpty
                             ? "all answering"
                             : "\(faults.map(\.host).joined(separator: ", ")) offline")
                            .foregroundStyle(HT.inkDim)),
                    tone: (nd?.connected ?? 0) < (nd?.total ?? 0) ? .caution : .default,
                    dim: h.dim)

                // A meter per machine the collector is itself running on:
                // those are the only ones that can report a load average,
                // because the others are reached over a socket.
                VStack(alignment: .leading, spacing: HT.s1) {
                    ForEach((nd?.nodes ?? []).filter { $0.probe == "self" }) { n in
                        SegBar(value: Swift.min(100, (n.load1 ?? 0) * 100),
                               tone: h.dim ? .standby : .nominal,
                               label: "cpu",
                               readout: n.load1.map { String(format: "%.2f", $0) } ?? "—",
                               block: true)
                    }
                }
                .padding(.top, HT.row)
            }
        }
    }

    // MARK: - stillness

    /// The one panel on this page whose body ignores its own health.
    ///
    /// Deliberate, and ported as-is: the verdict is a word the collector wrote,
    /// so it is either the current word or it is not there at all. There is no
    /// stale reading of "still · 42m" to demote -- and the panel's frame, lamp
    /// and footer still report the staleness, because `SourcePanel` draws those
    /// whatever the body does.
    private var stillnessCell: some View {
        SourcePanel(env: payload?.camera, feedDown: feedDown,
                    title: "Stillness", meta: "raspberrypi") { _ in
            VStack(alignment: .leading, spacing: 0) {
                Metric(
                    label: cam?.display.verdict.label ?? "stillness",
                    value: cam?.display.verdict.value ?? "no reading",
                    footer: AnyView(
                        Text("last sample \(Fmt.relTime(cam?.lastSample, now: now))")
                            .foregroundStyle(HT.inkDim)),
                    tone: cam?.display.verdict.tone ?? .standby,
                    size: .compact)

                VStack(alignment: .leading, spacing: 0) {
                    DotLeader(label: "monitor",
                              value: (cam?.monitor.alive ?? false) ? "running" : "not running",
                              tone: (cam?.monitor.alive ?? false) ? .nominal : .fault)
                    DotLeader(label: "camera feed",
                              value: (cam?.monitor.feedOk ?? false)
                                  ? "up"
                                  : "down \(Fmt.dur(cam?.monitor.feedDownForS))",
                              tone: (cam?.monitor.feedOk ?? false) ? .nominal : .fault)
                }
                .padding(.top, HT.row)
            }
        }
    }

    // MARK: - recent commits

    private var commitsCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourcePanel(env: payload?.commits, feedDown: feedDown,
                        title: "Recent commits", icon: "⌗",
                        meta: cm.map { "last \($0.commits.count)" },
                        flush: true) { _ in
                DataTable(columns: commitColumns,
                          rows: cm?.commits ?? [],
                          empty: payload?.commits?.status == .dormant
                              ? "Not wired. Add a fine-grained GitHub token to the collector."
                              : "No commits")
            }

            // Under the panel rather than in it: this is a caveat about the
            // table above, not a row of it.
            if let cm, !cm.reposUntracked.isEmpty {
                Text("\(cm.reposUntracked.count) repo\(cm.reposUntracked.count > 1 ? "s" : "") "
                     + "not on GitHub (\(cm.reposUntracked.joined(separator: ", "))), "
                     + "not counted above.")
                    .font(HT.body)
                    .foregroundStyle(HT.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, HT.row)
            }
        }
    }

    private var commitColumns: [DataColumn<CommitRow>] {
        [
            DataColumn(key: "sha", header: "Sha", width: 72,
                       cell: { DataColumn<CommitRow>.muted($0.sha) }),
            // The sentence, so this is the column that absorbs the slack.
            DataColumn(key: "title", header: "Subject", flexible: true,
                       cell: { DataColumn<CommitRow>.primary($0.title) }),
            DataColumn(key: "repo", header: "Repo",
                       cell: { DataColumn<CommitRow>.muted($0.repo) }),
            DataColumn(key: "when", header: "When", align: .trailing,
                       cell: { c in
                           DataColumn<CommitRow>.plain(Fmt.relTime(c.committedAt, now: now))
                       }),
        ]
    }

    // MARK: - the dog camera

    private var cameraCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourcePanel(env: payload?.camera, feedDown: feedDown,
                        title: "Dog camera", glyph: .overview, ticks: true) { _ in
                CameraFrame(label: "Dog cam",
                            src: frameURL,
                            bearer: bearer,
                            state: cam?.display.cameraState ?? .offline,
                            stamp: Fmt.clock(cam?.display.stamp),
                            verdict: verdict,
                            refreshSeconds: 10,
                            aspect: 16.0 / 10.0)
            }

            Text("Stillness, not sleep. A motionless awake dog reads as still, "
                 + "and an empty pen can read as still.")
                .font(HT.body)
                .foregroundStyle(HT.inkDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, HT.row)
        }
    }

    /// Whether there is a feed at all is decided by the JSON, never by whether
    /// an image happened to load: a frame that fails after this falls to NO
    /// SIGNAL on its own and the next poll gets to prove itself.
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

    // MARK: - blocking

    private var blockingCell: some View {
        SourcePanel(env: payload?.pihole, feedDown: feedDown,
                    title: "Blocking", icon: "⊘", ticks: true) { h in
            VStack(alignment: .leading, spacing: 0) {
                DotLeader(label: "queries today", value: Fmt.num(ph?.queriesToday))
                DotLeader(label: "blocked today", value: Fmt.num(ph?.blockedToday),
                          tone: h.dim ? .standby : .nominal)
                DotLeader(label: "block rate", value: Fmt.pct(ph?.blockRatePct))
                DotLeader(label: "domains on list", value: Fmt.num(ph?.domainsOnList))
                DotLeader(label: "clients", value: Fmt.num(ph?.clientsActive))
                Rule(variant: .dotted)
                DotLeader(label: "top blocked", value: ph?.topBlocked ?? "—")
            }
        }
    }

    // MARK: - the plate

    /// The one block on this page that is only texture. It has no reading in
    /// it, which is exactly what lets it carry the two numbers as a caption
    /// instead of as a panel.
    private var plateCell: some View {
        DitherPlate(pattern: .sphere, scale: 3, aspect: 16.0 / 7.0,
                    caption: plateCaption)
    }

    private var plateCaption: String {
        guard let ph, let nd else { return "Waiting for the collector." }
        return "\(Fmt.num(ph.blockedToday)) ads blocked.\n"
            + "\(nd.connected) of \(nd.total) nodes up."
    }
}
