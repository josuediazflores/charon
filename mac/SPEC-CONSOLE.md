# SPEC-CONSOLE — Phase A: shell + Overview + Hardware

Extends SPEC.md (the mail app, already built). Goal: the app becomes the whole
Halftone console. This phase: app shell (sidebar nav, topbar, connecting state),
the Overview tab, the Hardware tab, and demo fixtures for every source. The mail
feature already in Sources/ becomes tab 4 and MUST keep working unchanged.

Source of truth for every claim below: a read-only scout of the web console and
its design system, which are the reference implementations. Neither is part of
this repo; the behavior they define is restated here.

## Build decisions (made, do not relitigate)

1. **App identity**: display name becomes "Halftone". Product/bundle id stay
   `HalftoneMail` / `com.example.charon` — the Keychain service string and the
   `defaults` domain are both derived from the bundle id, so changing it after
   a token is stored orphans that token. Window title = current tab label.
2. **Nav icons**: keep the web's glyphs (◉ ⏻ ▤ ✉ ❯ ✦ ⌘). Four are absent from
   Departure Mono and will fall back to a system face — the web has the same
   documented bug (App.tsx:44-48). Parity over purity; note it in a comment.
3. **ht-dim contrast bug**: inherit as-is. Faithful port, no local fixes.
4. **CommandField**: port as the same inert affordance (focus on ⌘K, no search).
5. **Dither sphere**: reimplement paintField + Atkinson in CoreGraphics,
   rendered once per size change into an image (no animation). Decorative.
6. **Globe**: port the ASCII globe (27 cols → 17 rows, density ramp
   `" .:;',wiogOLXHWYV@"`, orthographic, 23.4° tilt, 8 fps Timer, 60s/rev).
   Freeze when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
7. **DS narrow-width fixes**: port the POST-diff behaviour (dots collapse
   before values truncate; Panel title ellipsizes before meta; ≤720 hides
   Masthead art including the Globe; grid collapses to one column).
8. **Zero animation** is a design rule: no implicit SwiftUI animations
   anywhere in the new code. Only motion: cursor blink (1060ms square wave)
   and the Globe's 8 fps step.
9. **Persistence**: last-known-good telemetry payload cached (UserDefaults,
   key `hc-telemetry-v1` equivalent) and rehydrated on cold start with
   `hydrated: true` → renders as feedDown until the first live payload.
10. **Polling**: keep the existing 10s telemetry poll; gate on window
    occlusion/app-active (NSApplication.didBecomeActiveNotification,
    NSWindow.didChangeOcclusionStateNotification), immediate fetch on return.
11. **Swift models**: every source envelope OPTIONAL in TelemetryPayload
    (healthchecks is typed required in TS but read optionally — older
    collectors lack it; a strict Decodable would crash).
12. **Relative times** recompute on every poll tick, never baked.
    Locales pinned: num = en_US, longDate = en_GB ("Thursday, 13 August").

## Phase A work order

Stage 1 (kit): Swift models for camera/pihole/nodes/commits/healthchecks +
full TelemetryPayload; health() mapping (extend existing Health.swift to the
full table below); DS component kit in SwiftUI: Panel (notch + ticks + tones),
DotLeader, Metric, StatusLamp, StatusPill, SegBar, Rule, DataTable (pinned
header), LogStream, Masthead + MastheadStrip, CameraFrame, Dither, Globe,
Prompt (+ blinking cursor), CommandField, Button/IconButton, Sidebar/RailStub,
TopBar, PageHead, Grid/Cell (12-col, spanMd ≤1100, one column ≤720 measured on
the CONTENT box, not the window). Demo payload covering every source in modes
1/stale/failed/standby (port from the console's `fixture.ts` demoPayload).

Stage 2 (views): restructure the app root into the shell (sidebar with 7 tabs,
topbar, connecting state, scanlines overlay hook, sidebar footer sources/last
sync panel); build ConsoleView (Overview) and HardwareView exactly per the
reference map; mount the existing mail feature as tab 4 (rail collapse +
pin behaviour when a mail message is open); CMO/Chat/Jarvis/Settings tabs get
placeholder panels ("not built yet" in the house style) pending Phase B.
Rebuild, verify launch + window, keep all SPEC.md mail invariants green.

## Reference map (scout findings, file:line cited)

File:line citations are pointers into the web console and its design system —
the module named is where the behavior came from.

### 1. App shell (App.tsx, 551 lines)

NAV (App.tsx:38-52), order literal: overview ◉ Overview · hardware ⏻ Hardware ·
cmo ▤ CMO · mail ✉ Mail · chat ❯ Chat · jarvis ✦ Jarvis · settings ⌘ Settings.
Font bug documented at App.tsx:44-48 (see decision 2).

Hash routing (routeFromHash, App.tsx:134-256): no router lib. Bare hash →
landing tab from settings, validated against NAV, fallback overview
(:159-163). Present-but-unrecognised hash → Overview, NOT landing (:137-158).
Sub-routes: #cmo/archive|briefings; #cmo/ask[/id|/new] id /^[a-z0-9-]{1,64}$/;
#cmo/watch|doc/<slug>; #chat/<id>|new; #jarvis/<YYYY-MM-DD> real-calendar
validated; #mail/settings → settings redirect; #mail/<key> /^[a-f0-9]{16}$/;
#cmo/<day>[/<n>|/drafts]. Malformed sub-segment → the tab, never empty reader.
Native mapping: sidebar selection + per-tab reader state; preserve the
"unrecognised → Overview, bare → landing tab" split.

Rail: Sidebar name "Halftone" mark ◧, one section, 7 items (:411-445). Footer
Panel dense with two DotLeaders: `sources` = "<ok>/<total|—>" from
payload.health; `last sync` = dur(now−fetchedAt) or —, tone caution when
feedDown (:422-431, :341-346). Collapse is COMPOSITION (:374-378): collapsed →
swap rail for RailStub. Conditions (:399-409): inTheWay = railCollapse &&
tab==mail && mailKey!=nil; here = "tab/mailKey"; collapsed = inTheWay &&
pinned != here. pinned is a PLACE STRING (auto-expires on route change), not a
bool. RailStub (:321-334, app.css:377-423): 28px wide button, full height,
border-right line, cap ◧ 48px tall bottom-ruled signal-colored, cue ">"
16px below in signal; hover surface-3/ink-bright. When inTheWay, sidebar
brandAside gets an IconButton "<" size sm "Hide the rail" → pinned=nil.

TopBar (:447-464): CommandField placeholder "Search nodes, commits" (inert,
⌘K focuses); actions: DEMO chip (br-yellow) when demo; IconButton ⟳ bordered =
refresh; StatusLamp level feedDown?0:3 of 3, tone fault/nominal, label
offline/live. No page footer — views end with MastheadStrip; sidebar footer is
the only persistent one.

Scanlines: settings.scanlines → overlay class on shell root
(base.css:153-164): repeating gradient 180deg rgba(255,255,255,0.026) 0-1px,
transparent 1-3px, z-50, non-interactive. Default off.

Render guards (:487-537): settings tab renders BEFORE the payload guard (so a
dead Pi can't trap you); !payload → Panel "Connecting" with Prompt
`you@halftone:~$ halftone telemetry --follow` + blinking cursor + dim line
(error ?? "waiting for the first payload from the collector"); else tab switch,
default Overview.

Telemetry plumbing: POLL_MS 10s; AbortController per tick; on failure KEEP the
last payload, set reachable=false + error; visibility-gated (decision 10);
cache key hc-telemetry-v1 {at, payload}; feedDown = !reachable || hydrated.
Preferences: charon-settings-v1 (already ported): railCollapse true,
landingTab 'overview', rowNote true, summaryOpen true, afterArchive 'next',
scanlines false.

Global keys: only ⌘K (CommandField focus). Theme: single dark, no toggle.

### 2. Overview (ConsoleView.tsx, 318 lines)

Reads camera/pihole/nodes/commits (+ collector, health). NOT cmo, mail,
healthchecks. faults = nodes where !connected.

Masthead: user "you" host "halftone", art Globe cols 27, swatches (two rows
of 8, 14×8px, c0-c7 / c8-c15). Rows (key / 40-dot run / value, keys space-
padded to longest): collector = "up <dur(uptime_s)>"; nodes = "<connected> of
<total> connected"|— tone caution if short else nominal; blocked =
"<num(blocked_today)> today"|— nominal; stillness = camera
display.verdict.value|— tone verdict.tone|standby; sources = non-zero health
buckets joined " · " in order ok/degraded/stale/failed/not wired, "no sources"
if all zero, tone fault if error>0 else caution if stale||degraded (:29-76;
non-zero rule is a bugfix :55-58).

PageHead: title longDate() en-GB "Thursday, 13 August"; subtitle feedDown →
"Collector unreachable. Showing the last values received." / faults →
"<n> node(s) not answering: <hosts>." / else "All sources reporting."

Grid (12-col, gap 16; spanMd ≤1100; one column ≤720):
- P1 Pi-hole (span 4/md 6, SourcePanel s.pihole, meta "pi-zero-w", render(h)):
  Metric "ads blocked today" num(blocked_today) Demoted by h.dim; footer
  "<pct(block_rate_pct)> of <num(queries_today)> queries" dim-gated; stack-row
  SegBar label "rate" value block_rate_pct block, tone standby-when-dim.
  Deliberately NOT a Delta (:93-97).
- P2 Nodes (span 4/md 6, s.nodes): Metric "nodes connected" value
  connected|— unit "of <total>", tone caution if short; footer always ht-dim
  "<hosts> offline"|"all answering"; stack-col of SegBar per node with
  probe=='self': label "cpu", value min(100, load1*100), readout
  load1.toFixed(2)|—, block.
- P3 Stillness (span 4/md 12, s.camera, meta "raspberrypi", render IGNORES h):
  Metric compact label display.verdict.label|'stillness' value verdict.value|
  'no reading' tone verdict.tone|standby; footer dim "last sample
  <relTime(last_sample)>"; DotLeaders: monitor → running/not running
  nominal/fault; camera feed → up / "down <dur(feed_down_for_s)>" nominal/fault.
- P4 Recent commits (span 7/md 12, s.commits, icon ⌗, meta "last <n>", flush):
  DataTable columns Sha(72px muted)/Subject(primary)/Repo(muted)/When(right,
  relTime). Empty: dormant → "Not wired. Add a fine-grained GitHub token to
  the collector." else "No commits". Below panel if repos_untracked: dim line
  "<n> repo(s) not on GitHub (<list>) — not counted above."
- P5 Dog camera (span 5/md 12, s.camera, icon ◉, ticks): CameraFrame label
  "Dog cam", src = frame.available ? url+"?rev="+ts : nil (gate on JSON feed,
  never on img load), state display.camera_state|offline, raw,
  refreshSeconds 10, aspect 16/10, stamp clock(display.stamp), verdict.
  Below: dim line "Stillness, not sleep. A motionless awake dog reads as
  still, and an empty pen can read as still."
- P6 Blocking (span 5/md 12, s.pihole, icon ⊘, ticks): DotLeaders queries
  today num / blocked today num tone standby-if-dim-else-nominal / block rate
  pct / domains on list num / clients num / Rule dotted / top blocked
  top_blocked|—.
- P7 Dither plate (span 7/md 12, bare Dither sphere scale 3 aspect 16/7):
  caption two lines pre-line "<num(blocked)> ads blocked.\n<connected> of
  <total> nodes up." else "Waiting for the collector."
- Strip (span 12): MastheadStrip legend Offline/Live, signal = !feedDown.

### 3. Hardware (HardwareView.tsx, 264 lines)

Locals: nd, ph, cam, hc = s.healthchecks?.data ?? nil (OPTIONAL on purpose);
pi5 = node id 'pi5'; zero = node id 'pizero'. checkLines(day):
{text: detail? "<LABEL> · <detail>" : LABEL, state PASS/FAIL, tone
nominal/fault}. historyLines(days[1:]): {time date, text failing labels
joined|"ALL CHECKS PASSED", state "FAIL"|"<pass>/<pass+fail> PASS"}.
NOTE LogStream CSS lowercases text — JS uppercase nets out lowercase on screen.

PageHead "Hardware"; subtitle feedDown → "Collector unreachable. These are the
last known states." else "<n> nodes tracked. <m> not answering."|"All
answering."  No Masthead.

- P1 Nodes (span 12, s.nodes, icon ⏻, ticks, flush): DataTable Host(primary)/
  Board(muted kind)/Role/Uptime(right, dur if connected&&uptime else muted —)/
  Temp(right, temp() same gate)/RTT(right "<n>ms", NOT gated on connected)/
  Link(StatusLamp level n.link of 3 tone nominal/fault)/Status(StatusPill
  n.tone n.label — collector-resolved). Empty "No nodes configured".
- P2 raspberrypi (span 4/md 6, ENVELOPE s.nodes but body mixes pi5+camera,
  ticks, render ignores h): status connected/offline nominal/fault; uptime
  dur; load avg load1.toFixed(2)|—; soc temp temp(temp_c) tone caution when
  (temp_c ?? 0) >= 70 (missing temp reads nominal — preserve); Rule "dog
  monitor"; watch = alive ? "up <dur(uptime_s)>" : "not running"; feed = up /
  "down <dur>"; frame = available ? "<relTime(ts)> old" : "none" nominal/standby.
- P3 pizero (span 4/md 6, ENVELOPE s.pihole, status line from nodes row,
  ticks, render(h)): status zero.connected; uptime dur(host_uptime_s); cores
  raw number; processes num(host_procs); Rule "pi-hole"; blocked today num
  dim-gated; queries today num; SegBars "cpu " host_cpu_pct readout pct(,0) and
  "ftl " ftl_mem_pct (trailing spaces align the runs), block.
- P4 Dog camera (span 4/md 12, s.camera, ticks): CameraFrame "Dog cam · Pi 5",
  same as Overview but NO aspect prop → DS default 4/3.
- P5 Daily checks (span 12, s.healthchecks ?? nil, ticks): LogStream
  checkLines(days[0]) (newest run, may not be today); if >1 day: Rule
  "history" + LogStream historyLines(days[1:]) maxHeight 160 (ten 16px rows).
- Strip: legend "<connected> of <total> connected"|"no reading", signal =
  !feedDown && all connected.

### 4. Data shapes (model.ts) — Swift Decodable, ALL envelopes optional

SourceEnvelope<T>: status ok|stale|degraded|dormant|error; fetched_at ISO?;
age_s Int?; stale_reason String?; interval_s Double; next_attempt_in_s Int?;
consecutive_failures Int; error {kind, message, at?}?; data T?.
Tone: default|nominal|caution|fault|standby|signal.

CameraData: state; since?; elapsed_s?; last_sample?; last_score Double?;
monitor_stale Bool; monitor_stale_for_s?; monitor {alive Bool, reason?, pid?,
beat_age_s?, feed_ok Bool?, feed_down_for_s?, uptime_s?}; frame {available
Bool, ts?, age_s?, url?}; display {camera_state live|stale|offline, stamp?,
verdict {label, value, tone}}. frame.url is a collector path — attach bearer.

PiholeData: api_version Int + nullable: queries_today, blocked_today,
block_rate_pct, domains_on_list, clients_active, top_blocked String?,
host_uptime_s, host_procs, host_cores, host_cpu_pct, ftl_cpu_pct (unused),
ftl_mem_pct.

NodeRow: id, host, addr, kind, role, probe String; connected Bool; rtt_ms?,
uptime_s?, load1 Double?, temp_c Double?; link Int 0-3; tone Tone; label
String; down_since?; checked_at. NodesData {nodes[], connected, total}.

CommitRow {id, sha, title, repo, committed_at?, url?}. CommitsData {commits[],
repos_ok, repos_failed, repos_untracked [String], rate_limit?, + optional
diagnostics}. Only commits[] and repos_untracked rendered.

HealthCheckRow {id, label, ok Bool, detail}. HealthCheckDay {date, ran_at,
pass, fail, checks[]}. HealthchecksData {days[]} newest first.

TelemetryPayload: schema Int; server_time; collector {version, started_at,
uptime_s}; health {worst, ok, degraded, stale, dormant, error}; sources
{camera, pihole, nodes, commits, healthchecks, cmo, mail} — all
SourceEnvelope, all OPTIONAL in Swift.

health(env, feedDown) table (health.ts:72-167):
- feedDown||nil env → tone nil, lamp 0/3 standby, pill nil, note "console
  offline · showing last known values", dim T, hideDelta T
- live → tone nil (NO frame on healthy), lamp 3/3 nominal, pill nil, note nil,
  dim F, hideDelta F
- stale → caution, lamp 1/3 caution, pill stale_reason|"stale <ageWords>",
  note per branch, dim T
- failed → fault, lamp 0/3 fault, pill "failed", note error.message|
  "source unreachable", dim T
- standby → tone nil, lamp 0/3 standby, pill "not wired" standby, dim T
ageWords: nil → "age unknown"; <60 "Ns ago"; <3600 "Nm"; <86400 "Nh"; else "Nd".
SourcePanel: meta always ends in the StatusLamp; footer = pill+note when
either; Demoted(dim) wraps values.

### 5. DS anatomy (tokens + components)

Tokens: cell 7×16px; type 11/22/33/44 only, all weight 400, radius 0,
duration 0. ANSI: c0 #1c1c1c c1 #cc4436 c2 #56a34b c3 #c9a227 c4 #3f7fc4
c5 #9a5fc4 c6 #35a3a3 c7 #a8a8a8 c8 #4a4a4a c9 #ff5f4f c10 #7ee07e c11 #ffcc55
c12 #6fb0ff c13 #c79fef c14 #5fdede c15 #fff. Ground: void #000, surface-2
#0d0d0d, -3 #1c1c1c, -4 #2a2a2a. Ink: #a8a8a8 / bright #fff / mid #7d7d7d /
dim #4a4a4a / faint #303030. Lines: faint #232323, line #3a3a3a, bright
#5c5c5c. Semantic: nominal c10, caution c11, fault c9, standby c8, signal c14,
signal-dim #1f5f5f, prompt c10. Focus = inverse video (bg c12, fg void) —
suppress macOS focus rings. tabular-nums everywhere.

Shell: sidebar 200px, border-right; brand row 48px bottom-ruled (mark ◧
signal, name uppercase bright); body scrolls independently; foot top-ruled
7/14 padding. Topbar 48px bottom-ruled, padding 0 21. Console = THE one
scroll container, padding 16/21 (≤720: 16/14), column gap 16.

PageHead: h1 22px uppercase bright; sub 11px dim. Grid: 12 minmax(0,1fr),
gap 16.

Panel: variants tty (1px line) / double (3px double bright) / bare. Titled
framed panels get 8px top margin; head is an overlay at top −8px, left/right
7px, 16px tall; title/icon/meta carry void background + 4px side padding so
the border breaks around them. Title 11 uppercase bright, shrinks+ellipsizes
first. Meta auto-left-margin dim. Body padding 14 (dense 7, flush 0). Foot
top-ruled 4/14 dim. Tone recolors frame + title. ticks = four DRAWN 7×7
corner strokes at −1px insets in line-bright; with ticks the frame drops to
line-faint unless toned.

DotLeader: label (max 60%, lowercase, mid, ellipsis) / dot run (flex 1 1 0,
clipped, faint) / value (shrinkable, ellipsis, bright; tone recolors value
only). Dots are characters. Native: fill width with '.' repeated to fit
(GeometryReader or layout), never a background pattern.

Metric: label lowercase mid; value 33px/48 bright tabular (+unit 11 dim
inline); foot 11 dim wrap. compact 22, hero 44. Tone recolors value.

StatusLamp: pips ▲/△ (dot ●/○, square ■/□), lit bright / unlit faint, tone
recolors lit; label uppercase dim, 7px gap.

StatusPill: [<glyph><LABEL>] — glyph per tone: default · nominal + caution !
fault ✕ standby - signal ›; brackets faint; uppercase; tone recolors pill.

SegBar: 10 glyph cells █ lit / ░ unlit (shade ▓, bar |/., equals =/-),
lit = round(clamp(value/max)*10); label uppercase mid; letter-spacing 0
mandatory; readout right tabular default "<round(ratio*100)>%"; block →
full-width row. role=meter semantics for a11y.

Rule: labelled = glyph×2 + lowercase mid text + clipped glyph run (─ ═ ┄ ·);
plain = clipped run; checker = 8px-tall checkerboard band; line color --ht-line.

DataTable: header row pinned (sticky) with void bg + bottom rule, uppercase
dim 4/7 padding; body rows 16px tall, no rules, nowrap, 0/7 padding;
.primary bright, .muted dim; empty state centered dim 32px padding.

LogStream: rows time (faint) / text (lowercase mid, max 62%, ellipsis) /
dot run / state (right, min 56px, uppercase bright, tone recolors state
only); maxHeight → its own scroll; hover surface-2.

Masthead: row gap 28, padding 14; art (Globe) hidden ≤720; id column
max-width 52ch: who = user(signal)@(dim)host(nominal); underline ─ ×
max(len,24) faint; rows key(signal, space-padded to longest)/40-dot run/value
(bright, tone recolors); swatches 2×8 of 14×8px ANSI cells.
MastheadStrip: checker band / LEGEND (uppercase, tracked 1px, bright;
signal → cyan legend + signal-dim checkers) / checker band.

CameraFrame: head label uppercase mid + right StatusLamp+word (live 3
nominal / stale 1 caution / offline 0 fault); view 1px border, img
aspect-filled; no-signal overlay: centered "No signal" fault text in fault
border on void; foot stamp dim (--:--:--) + right "next in Ns" / "every Ns
when wired" / "frame failed to load" faint; verdict line label lowercase mid,
value uppercase tone-colored. Refresh: Timer per refreshSeconds, 1s countdown;
use .reloadIgnoringLocalCacheData instead of the ?t= URL trick; attach bearer.

Dither: 1-bit Atkinson at scale 3; generated sphere field seed 7; caption
bottom-left void-backed bright pre-line. Static render per size (decision 5).

Globe: see decision 6; one flat ink color; pre-style line-height 1.

Prompt: user(nominal)@(dim)host(signal):(dim)path(c4)$(dim) command(bright) +
7×13px cursor block in prompt-green blinking 1060ms steps (off under reduced
motion).

CommandField: 32px tall, max-width 380, 1px line border (signal on focus),
"$" sigil prompt-green→signal on focus, placeholder faint, ⌘K Kbd cap
(surface-3 bg, min 14×16). Inert.

Button: 32px, [label] brackets faint via decoration, variants primary
(signal bg/void), secondary (bright + line border), ghost, quiet (underline
hover, no brackets), danger; sm 16px. IconButton 32×32 (sm 16×16), hover
inverts to ink-mid bg/void glyph, bordered adds line border, on = signal.

### 6. Hazards checklist (resolutions)

Glyph runs (dots/rules/underlines): compute character count from available
width / 7px advance; recompute on resize. Panel notch: ZStack overlay on the
border with void-filled labels; keep the 8px reserve. Ticks drawn with Path.
DataTable pinned header: LazyVStack + pinnedViews or manual; tables here are
non-interactive. Sticky/notch z-order: render notch above body. CameraFrame:
AsyncImage is insufficient (bearer + no-cache) — URLSession fetch into Image.
Occlusion-gated polling per decision 10. healthchecks optional per decision
11. feedIsStale() exists but is UNUSED — do not port. Formatters: num en_US,
pct, dur (42d 11h / 15h 02m / 7m / 30s), relTime, clock HH:MM:SS, temp,
longDate en-GB — extend the existing Format.swift, keep mail's exact behavior.
The pizero/raspberrypi envelope-vs-body mismatches are BY DESIGN — port
exactly. Demo modes 1/stale/failed/standby must exercise every health branch.

