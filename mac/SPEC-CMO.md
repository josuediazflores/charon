# SPEC-CMO — Phase B: CMO, Chat, Jarvis, Settings

Extends SPEC.md (mail) and SPEC-CONSOLE.md (shell + Overview + Hardware).
Phase B replaces the four placeholder tabs with the real thing. The web
console and its design system are the reference implementations; `file:line`
cites below point into them, and the behavior they name is restated here.
Neither is part of this repo.

## Build decisions (final)

1. **Dictation is deferred.** The web's [talk] mic is blocked in production
   anyway (plain-http tailnet → 'insecure'). Native port ships the talk row
   with the voice toggle but replaces the mic button with a dim
   "dictation not built yet" word. No mic entitlement this phase.
2. **Voice PLAYBACK ships.** Port useSpeaker to AVFoundation: one serialized
   queue/pump, one-ahead prefetch, generation counter for cancel, the
   two-miss dead-turn rule, canned shelf checked first. Drop unlock() (no
   autoplay policy natively). Canned assets: the 40 WAVs + manifest.json ship
   in `Resources/Canned` (voice am_michael).
   Sentence cursor ported exactly from voice/sentences.ts (prefix seams,
   never emit a character twice, finalize contradiction rule).
3. **Markdown**: port the hand-rolled parser subset exactly
   (views/markdown.tsx) — h1/head(2-3)/p/ul/hr/code/quote, fence suspension,
   `---` beats bullets, ordered-list & table lines stay literal one-line
   paragraphs, lazy continuation, space-joined paragraphs, md- slug ids with
   -2 collision suffix. ONE renderer parameterized for the two Drawn variants
   (plain vs draft-blocks-with-copy/dismiss).
4. **Clipboard**: NSPasteboard; the 'clipboard blocked' state and hidden
   textarea fallback do not exist natively — drop them, keep
   copy → copied (2s) on draft blocks.
5. **401**: on any GET, surface "unauthorized · check the token" as the
   feed-down note instead of a generic failure (native has no cookie mint;
   the sheet already exists). Mail write paths keep SPEC.md behavior.
6. **Pickers**: rebuild the Jarvis hand-built listbox (upward-opening,
   arrow/Home/End/Enter/Escape, • mark in reserved column) and use it in
   BOTH chat and jarvis (web chat's raw selects are the known-inconsistent
   leftover; Jarvis treatment is the keeper).
7. **Safety parity, no additions**: no confirmation dialogs exist in this
   slice and we add none. Keep: chat delete = [x] → [sure?] two-step with
   Escape disarm (the only irreversible act); every standing claim sentence
   verbatim (ask footer, draft-block sentence, chat foot, jarvis foot);
   dismissal is curation-not-deletion with one-click restore. Jobs file with
   one click by design; the footer sentence is the disclosure.
8. **Fold animation**: SwiftUI withAnimation 220ms, bypass under reduced
   motion; drop the imperative reflow machinery.
9. **System-mono exception**: chat/jarvis answer bodies render in the system
   monospaced font at 13/18 (deliberate readability break from the 7×16
   grid). Everything else stays Departure Mono 11/22.
10. **Demo fixtures** for cmo, chat, jarvis ported from
    src/data/fixture.ts (incl. DEMO_BRIEFING; ?demo=standby → briefing
    missing). Demo writes mutate the local store per SPEC.md precedent.
11. **Settings tab**: build the real four panels / nine rows (Wave 1 only);
    storage lives in the existing Settings.swift (charon-settings-v1
    equivalent). The three prose readouts verbatim in substance; the mail
    readout's five facts must never become switches. No Pi-tier rows.
12. **Seen marks**: cmo-watch-seen / cmo-docs-seen → UserDefaults dicts
    keyed name→timestamp; isNew = timestamp mismatch. Conversations get no
    seen dot (deliberate).
13. **Glyph audit**: every glyph introduced must be checked against
    Departure Mono's cmap. Verified present: ✦ ⌘ ◌ • ▲ ▼. Known absent
    (system fallback, inherited): ▸ ◎ ◉ ⏻ ▤ ✉.
14. **Polling cadences**: ask 10s while thinking; chat/jarvis 1s live / 5s
    idle, occlusion-gated with immediate fetch on return; an earlier jarvis
    day is NEVER polled; jobs fetched only when a job card is on screen;
    a running job does not raise the poll rate.

## Surfaces in this phase

CMO + Settings:
- Markdown engine + both renderer variants; briefing reader (states
  loading/missing/error incl. 401 wording, item→heading token matcher with
  score ≥ 2, LANE_WORDS fallback, drafts slice, breadcrumb + raw link, item
  walk, per-item verdict strip, DismissControl); CmoView with all six panels
  + AskWindow embed (18 rows) + selection/archive bottom bar; Archive,
  Briefings, File (watch/doc) pages; ASK.EXE window both modes (controlled
  28 rows on its own page, uncontrolled embed), AskField (cell-sized input,
  cursor only while empty, 2000 cap), thinking verbs (28-word list, 2.5s
  cycle, no back-to-back repeat), staleness line, thread doors; dismissals
  store (optimistic, rollback, FAILED label); seen marks; pipeline bar
  (30 cells, never round a non-empty bucket to 0); Sparkline (eighth-blocks,
  cap, nothing under 2 points, removed entirely when hideDelta); real
  Settings tab. Window/TitleBar chrome (_ □ ✕, disabled boxes drawn).
Chat + Jarvis:
- Chat: list route (cards with rails, two-step delete, n shortcut) +
  conversation route (Window HALFTONE.CHAT, transcript, composer keyed by
  thread id, sentBaseline race guard, optimistic model/effort, busyReason
  strings, stop only when stoppable, send = the view's single cyan spend).
- Jarvis: hero + Orb (cols 28, gold ink, exact palette/tilt/subsample/fps
  math, reduced-motion stop), DayStrip, transcript (say/job/notice/compaction
  merge sorted stably on `at`, unknown kind → nothing, job record beats
  turn copy, stopped draws nothing), ContextMeter (dash when null/stale,
  bands <50/50-75/>75, never "% remaining"), fold, composer + [run as job]
  (never 409s) + per-job stop + lane stop + [compact], presence derivation
  (exact priority order), voice playback per decision 2, talk row per
  decision 1.
- Both: scrollback pattern (own scrollTop, keyed repaint, real blank end
  row), 12-row minimum buffers, listbox pickers, day/thread routing with
  malformed → tab fallback semantics.

## Reference map (condensed scout findings)

### CMO tab (views/CmoView.tsx, 581 lines)
Envelope cmo; lanes = non-zero only; current briefing day from
heartbeat.briefing path else agent_date; offered = current + briefings
deduped; borrowed = agent_date != heartbeat.run_date; itemsDay = agent_date
?? run_date. PageHead subtitle: feedDown → "Collector unreachable. Showing
the last values received." / ok|no_new_items → "Run <run_date> · <n> new
items." / other → heartbeat.detail ?? "The last run did not finish." / no
data → "No run recorded yet."
Panels: Briefing (span 8, lanes line, DataTable Pri(StatusLamp 4-pri of 3;
dismissed → × + sr "dismissed")/Lane muted/Item primary-or-dim/Added right;
sort pri asc-first added desc-first, glyphs ▴▾; row → #cmo/<day>/<ordinal>
or selection toggle; empty dormant → "Not wired. Run the CMO job once to
produce a heartbeat." else "No items in the last run"; under-panel briefings
links ≤5 + "all ▸", "showing briefing from <date> · " when borrowed).
Run (span 4, Metric "new items" compact Demoted; DotLeaders last run/
duration/attempt/deduped today/ledger; Rule "items / day"; Sparkline counts,
cap, REMOVED when hideDelta). Pipeline (span 4, 30-cell bar; ramp new █
br-white / drafted ▓ white / contacted ▒ br-black / dead ░ black;
proportional scale only when total > 30, never round non-empty to 0; four
DotLeaders "<glyph> <key>"). Drafts (span 4, dense table Draft/With(target);
every row → #cmo/<day>/drafts; empty "No drafts queued"). Watchlist (span 4,
Company (NewDot when unseen; link only if dossier exists → mark seen +
#cmo/watch/<name>)/When). Documents (span 4, NewDot + #cmo/doc/<slug>,
Updated = updated.slice(0,10); empty "No documents on the Pi yet.").
Ask cell (span 8): AskWindow uncontrolled maxRows 18.
Bottom bar: idle "archive ▸" (disabled without itemsDay) + "view archive ▸";
selecting "done (n)"/"archiving…" + cancel + "· tap items and drafts to
select"; commit = parallel dismiss() calls.

### Briefing reader (CmoReaderView.tsx, 556)
GET /v1/cmo/briefing/<date>, Accept text/plain. States: loading
"reading briefings/<date>.md"; missing (404) panel "No briefing for <date>.
The CMO writes one file a day, and this day has none on disk."; error panel
footer pill fault "unreadable" + message (401 special wording); ok = doc.
Scoping: keyTokens (lowercase, strip non-letters, drop <3 chars + 60-word
stoplist), matchHeading score ≥ 2 ties-to-earlier, fallbacks exact heading →
LANE_WORDS {ads:[advertiser], demand:[act today, demand], market:
[competitor, market]} → whole doc; 'drafts' → first heading containing
"draft"; scoped route renders a SLICE (heading to next equal-or-shallower,
trailing hr trimmed); items used only when itemsDay === date. Breadcrumb
"◂ cmo / briefing <date>" (+ item N of M | drafts; out-of-range ordinal → no
meta) + dim raw link. Scroll to top on route change (+ re-jump after font
load — native: n/a). Draft blocks: pre + footer ghost button copy→copied(2s)
+ DismissControl terse when named (draftTitle strips "A. "/"B) " ordinals;
unnamed = un-dismissable) + "draft only · the cmo never sends". Code fences
AND blockquotes both become draft blocks here.

### Other CMO pages
Archive: "◂ cmo / archive"; two panels Dismissed items (Day 84px link
#cmo/<date> / Lane 63 / Item / restore 105) and Dismissed drafts (Day link
#cmo/<date>/drafts / Draft / restore); rows from dismissals store by kind;
closing note = nothing deleted. Briefings: one panel, newest first, meta
"<n> on disk", today suffixed " · today", footer "…the collector lists the
most recent 90." File view (watch|doc): dossier/doc text routes, four
states, no 401 branch, verb-free (no copy/dismiss), raw link.
Ask page: ".ask-page", "◂ cmo / ask / <id|new>", right "<n> thread(s) · <m>
thinking", AskWindow controlled 28 rows, thread mint navigates with
replace-semantics (not a back stop), close → #cmo.

### ASK.EXE (ui/AskWindow.tsx, 687)
Modes: uncontrolled (embed, 18 rows, maximize → ask page, close disabled) /
controlled (28 rows, route owns selection, maximize disabled, close → #cmo).
THINKING_POLL_MS 10s; EMBED_THREADS 5; QUESTION_MAX 2000. Buffer order:
empty line ("new thread · type below" / "no conversations yet · type
below"); optimistic "$ <q>" + "[✕ask] not filed — the collector did not
take it" on refusal; turns (q = "$ text"; a = markdown + meta "answered in
<dur> · read: <list|not stated> · HH:MM", error turn = pill fault ✕ask +
error + time); record states ("reading the thread" / "this thread is not on
the Pi." / [✕ask] msg); in-flight follow-up echo; ThinkingMeta (pill caution
~ask + cycling verb); staleness "stale · reflects <date>" yellow, hidden
while thinking (thread.updated vs heartbeat.started_at); real blank end row.
Own scrollTop = scrollHeight keyed on painted string. Fetch keyed
"<id>@<updated>/<status>#<tick>"; polling = active && !failed && (!id ||
thinking); activeThinking biased to over-report (sent-unanswered counts).
ask(): optimistic pending → POST → select(id). followUp(): per-thread
sending map → on success delete optimistic + tick bump (no splice). Submit
continues open thread when active && !thinking else new thread. Fixed footer
"answers may draft · the cmo never sends · sessions read memory, never
write it". Thread doors: DotLeader per other thread (label first_q|pending|
id, value "<n> turns"), ≤5 + "all <n> threads ▸" in embed, "new thread ▸"
both. AskField: $ sigil, input sized max(text,placeholder)+1 cells, Enter
submits, block cursor only while EMPTY, placeholder "follow up…"/"ask the
cmo", autofocus on page only.

### Chat (views/ChatView.tsx 1021, api/chat.ts)
LIVE 1s / IDLE 5s / 4000 cap / 12-row floor. inFlight = queued ||
status=='running'. statusOf: ~queued caution / ▸running caution / ✕failed
fault / idle. WriteResult ok|busy(409)|failed. List route: bar "CHAT <n>
session(s)|—|starting a session" + [+ new]; rule; note "an assistant running
on the pi · it reads this box and the web, and changes nothing";
SessionList (null → "reading the sessions" | "the collector is not
answering · sessions are on the pi, not here"; [] → "no sessions yet");
SessionCard: "$ <title|new session>" + status glyph+word + relTime; said
line priority live("waiting for the runner"/"answering"+cursor) → error
("the session failed") → preview → "nothing asked yet"|"no answer yet";
"<model> · <n> turn(s)"; left rail caution when live, fault on error.
DeleteRow [x]→[sure?] second click deletes; one armed at a time; Escape
disarms; 409 note "[✕del] <title> · a turn is in flight | · not deleted".
`n` = new (list route only, no modifiers, not in inputs). Conversation
route: "◂ chat / <title>" + stamp; Rule bright; Window HALFTONE.CHAT flush
close → #chat; Transcript (empty "nothing asked yet · this session reads
this pi and the web, and changes nothing"; UserTurn When-gutter(5 cells,
blank when no ts) + $ + pre-wrap; AssistantTurn ToolLines + system-mono pre
+ "<model> · <elapsed>s"; optimistic copy; Streaming pill + partial +
cursor; [✕turn] / [✕send]; blank end row); Composer keyed by thread id
(rows 2, Enter sends / Shift+Enter newline, "<len>/4000 · enter sends ·
shift+enter newline", model+effort pickers disabled while busy, [stop] only
when stoppable, send = single cyan spend); sentBaseline race guard;
busyReason "filing…" / "queued · the runner has not picked this up yet" /
"answering · [stop] to give up on it"; settle() busy → "<what> — a turn is
already in flight", failed → "<what> — the collector did not take it".
Foot "runs on the pi · reads the box and the web · writes nothing here --
jobs in the jarvis tab do the writing". archived exists in API/model but NO
UI — do not build one.

### Jarvis (views/JarvisView.tsx 1927, api/jarvis.ts)
Same cadences; TEXT_MAX 4000; FOLD_MS 220; TITLE_MAX 60; efforts
low/medium/high/xhigh/max. Two lanes: say can 409, job NEVER. Page: hero
(Orb cols 28 gold, activity from presence; JARVIS 22px; presence.word;
"<day> · today | ◂ back to today" + relTime); Rule bright; DayStrip (null →
"the days are on the pi · not read yet"; [] → "no earlier days"; chips
MM-DD, open day bracketed, ▸ caution in-flight, ✕ fault error, sr words);
note "one conversation a day · jobs run in their own lane and never block
it"; transcript panel with HAND-BUILT head (TRANSCRIPT, "· n turns" when
folded, one fold button ▲/▼ — deliberately not TitleBar); fold animates
height 220ms, body stays mounted; Composer today only, else "an earlier
day · reading only · today is where you can type"; talk row ([◌ talk]
replaced per decision 1; [◌ voice]/[• voice live]/[• voice whole];
"voice unavailable" dim); foot "runs on the pi · talk reads only · jobs may
write, and every write shows".
Transcript merge: turns + compactions stable-sorted on at. say/user =
right-aligned rounded card (surface-2, hover -3, 6px radius, 120ms — the
ONE rounded+transitioned element outside mail) max 62 cells; say/assistant
= ToolLines ("→ " dim) + system-mono 13/18 pre + "HH:MM · <model> ·
<elapsed>s"; job = JobCard (head job/title/<glyph word>/HH:MM/[stop] while
queued|running; body error(fault) → result pre → waiting sentence ("filed ·
its runner has not picked it up yet" / "running on the pi · the
conversation is not waiting for it") → stopped draws nothing; job record
beats turn copy; rail only on error); notice = ! + collector sentence +
[compact]|"· folded" + HH:MM, tone from band(pct) frozen at crossing;
unknown kind renders NOTHING; FoldLine "folded <n> turn(s) · everything
above is still here, the context is not". ContextMeter: null|stale → "
context — · folded, nothing measured since | · nothing measured yet";
else "[!!|!] context <pct>% [nearly full|filling]"; bands <50 quiet, 50-75
caution, >75 fault; never "% remaining". jobState: queued ~ caution /
running ▸ caution / done + nominal / error ✕ fault / stopped - quiet
(NOT a fault) / default · quiet. presence priority: listening 1.0 caution →
filing .6 → queued .9 → thinking .9 → speaking .45 default → unreachable 0
fault → working .3 (any job live) → failed .12 fault → idle .05.
Fetch: today vs typed day (404 → missing ≠ unreachable); day strip on route
change only; jobs only when a job card is visible; earlier day never
polled; running job does not raise rate.

### Voice (decision 2 details)
useSpeaker: single AudioContext-equivalent, ordered queue, prefetch one
ahead, canned shelf GET /canned/manifest.json {version, voice:"am_michael",
entries sentence→file} checked before synth; one miss one retry, lone
failure skips sentence, two in a row kills the turn, sets unavailable,
plays canned "The Mac's asleep, so it's text only for now."; cancel() =
generation bump + drop queue + abort fetches + stop source; called on
barge-in ([talk], send), toggle transitions, unmount. Public shape
{enqueue, cancel, warm, speaking, unavailable}. sentences.ts: prefix
cursor; strips "[output truncated]"/"[stopped]"; boundary = .!?… +
whitespace (through one closer of "')]) or blank line; terminator at
snapshot end is not a boundary; prefix seam resyncs emitting nothing;
rewritten spoken prefix swallows new text whole; finalize emits unspoken
remainder or nothing if final text contradicts stream; whole mode = never
feed cursor, finalize once. TTS: POST /v1/jarvis/tts {text} → WAV blob,
null on non-200; /tts/warm fire-and-forget on voice-on and send-while-on.

### Settings (SettingsView.tsx, 290)
Renders WITHOUT payload (above the guard). Four panels, nine rows:
Mail/"the mail program": collapse the rail while reading (toggle,
railCollapse); show the ai line under each row (rowNote); open the ai
summary with the message (summaryOpen); after archiving, go to (choice
next/inbox, afterArchive); how sending and archiving work (readout "fixed"
— five facts, never switches). Briefing/"the 6am cmo": the briefing runs on
(readout "opus · effort high" — 80 turns, 4500s wall, ≤2 attempts, edited
in the briefing runner's own config, deliberately not here). Console/"around every
tab": open the console on (choice, 7 tabs, landingTab); crt scanlines
(toggle, scanlines). This browser/"on this device": where these are saved
(readout — native wording: UserDefaults on this Mac, never reaches the Pi).
ToggleRow = DotLeader value ghost caps Button ON(bright)/OFF(dim),
aria-pressed. ChoiceRow = DotLeader value Select sm quiet caps. Rows WRAP,
never ellipsize. Native adds nothing from waves 2-5 (esp. NOT "run the 6am
briefing" — gates a recurring paid job, needs explicit user OK).

### Data shapes (model.ts — full field lists in scout; key ones)
CmoRunStatus running|ok|no_new_items|failed_timeout|auth_expired|
failed_no_briefing|failed_claude_error. CmoHeartbeat {source,
schema_version, status, detail?, run_date, started_at?, finished_at?
(null while running), duration_sec?, attempt?, new_items?, briefing?,
commit?, next_run?}. CmoItem {pri 1..3 (1 = act today), lane, title,
added?}. CmoPipeline {new,drafted,contacted,dead}. CmoDraft {title,target}.
CmoLane {lane,ready}. CmoWatch {name, event?, when?}. CmoMemory {seen,
leads, deduped_today, compacted?}. CmoAgentResult {new_items?, briefing?,
leads_updated?, summary?, items[], pipeline?, drafts[], memory?, lanes[],
watchlist[]}. CmoDay {date,count}. CmoDismissed {kind item|draft, title,
lane?, date, dismissed_at}. CmoDoc {slug, updated}. CmoAskThreadSummary
{id, first_q ≤80, turns, updated, status thinking|idle}. CmoAskTurn {role
q|a, text, at, reads?, duration_s?, error? (error+text not exclusive)}.
CmoAskThread {id, created, updated, session_id?, status, turns[]}.
CmoData {heartbeat, agent? (may be an EARLIER run), agent_date?,
items_daily[], briefings[] (≤90 newest first), dismissed[], dossiers?[],
docs?[], ask?[]}. ALL optional-tolerant.
ChatThreadSummary {id, title ('' when untouched), preview?, updated_at,
status idle|running|error, model sonnet|opus, turn_count, queued (NOT a
status), archived?}. ChatTurn {role, text, at, tools?, model?, elapsed_s?}.
ChatThread {id, title, created_at, updated_at, model, effort?, status,
error?, claude_session_id?, turns[], partial?, queued}.
JarvisSayTurn {kind say, role, text, at, tools?, model?, elapsed_s?}.
JarvisJobTurn {kind job, job_id, title, at (never moves), state (rewritten
in place)}. JarvisNoticeTurn {kind notice, notice context, text, at, pct
(frozen), action compact}. JarvisContext {tokens, window, pct, at, stale}
(lags one turn; a floor). JarvisCompaction {at, before_tokens, kept,
turns_folded}. JarvisDay {day, created_at, updated_at, model, effort?,
status (talk lane only), error?, claude_session_id? (cleared by
compaction), partial?, turns[], context?, compactions[], queued}.
JarvisDaySummary {day, updated_at, turn_count, job_count, status, queued,
model, context {tokens,pct}?, preview}. JarvisJob {id, title, text, state
queued|running|done|error|stopped, created_at, updated_at, result?,
error?, tools?, model?, elapsed_s?}.

### Routes (all same-origin, bearer)
CMO: POST /v1/cmo/dismiss {kind,title,lane,date} · /restore
{kind,title,date} (lane omitted) · /ask {question[,thread]} → {ok?,id?} ·
GET /ask/<id> → thread (404 null) · GET /briefing/<date> text/plain ·
GET /dossier/<slug>, /doc/<slug> text/plain.
Chat: GET /v1/chat → {threads?} · GET /v1/chat/<id> (404 null) · POST /new
{model} → {ok?,id?} · /<id>/send {text} · /model {model} · /effort
{effort} · /stop · /delete (can 409) · /archive {archived} (NO UI — skip).
Jarvis: GET /v1/jarvis/today · /days → {days?} · /day/<day> (404 null) ·
/jobs → {jobs?} (≤50) · POST /say {text} (409 busy) · /stop · /model ·
/effort · /compact (409 while in flight; nulls session id, sets
context.stale) · /job {text,title} (never 409) · /job/<id>/stop ·
/tts {text} → WAV · /tts/warm.
WriteResult mapping: 409 → busy, other non-OK/network → failed.

### DS additions this phase
Window/TitleBar (32px bar, hatched grip, three 14×14 boxes _ □ ✕, disabled
boxes drawn dim, hover inverts, close hovers fault; body 1px border no top,
7/14 padding or flush). Sparkline (eighth-block ▁▂▃▄▅▆▇█ per point, cap
brightens last, <2 points = nothing). Select (drawn shell + native control
hidden — replaced by listbox per decision 6). Orb (cols param, palette
" .:;',wiogOLXHWYV@", tilt 23.4°, 2×2 subsample, blank under 35% in disc,
rows = round(cols*7/11), fps = 8 + round(activity*4), step = 2π/(period*fps)
* (1 + activity*5), limb falloff v *= 0.35 + 0.65*z^0.45, deterministic
noise, reduced-motion stops, sr label beside).
