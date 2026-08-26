# Charon macOS — build spec (v1)

Native macOS SwiftUI port of the Halftone console's MAIL tab. (An early rule kept
the name "Charon" out of the UI; it was later reversed, and the shipped app is
named Charon.) Goal of v1: the user can
open the app today and click through the whole mail experience on demo fixtures,
then point it at the Pi collector later with a URL + token.

## Non-negotiable context

The web console is the reference implementation: its mail list, reader, API
client, optimistic-pending rules, formatters and palette tokens are what this
port is a port *of*. Where this spec names a file below — `mailPending.ts`,
`fixture.ts`, `mail.css` — it means that module of the console, and the rule
stated here is the rule that matters. The console itself is not part of this
repo.

## Project setup

- Generate the Xcode project with **xcodegen**: `project.yml` is the source of
  truth, run `xcodegen generate`.
- Product name `Charon`, display name **"Charon"**, bundle id
  `com.example.charon`; the Xcode project and its app target are still called
  `HalftoneMail`, which is a name on disk and not one the user sees. macOS
  deployment target **15.0** (needs SwiftUI's `textRenderer(_:)`, which draws
  the box a chat tag stands in). Swift 5.10+ mode is fine; Swift 6 strict
  concurrency not required.
- App Sandbox ON with `com.apple.security.network.client` entitlement (outgoing
  HTTP to the tailnet; note the collector is plain http — set
  `NSAppTransportSecurity > NSAllowsLocalNetworking` and an ATS exception for
  arbitrary loads in Info.plist, since 100.x.x.x plain-http is the real target).
- Font: `DepartureMono-Regular.ttf` ships in `Resources/Fonts/` (with its OFL
  license text); Info.plist sets `ATSApplicationFontsPath = Fonts`. Family name
  is "Departure Mono". Fallback if registration fails at runtime: Menlo.

## Architecture

Three layers, strictly separated:

1. **Models** (`Models.swift`): Codable structs mirroring the collector JSON
   exactly (snake_case keys via CodingKeys or a decoder strategy).
   `MailData`, `MailCounts`, `MailMessageSummary` (12 keys), `MailMessageFull`,
   `MailAiArtifact`, `MailDraft`, `MailOutboxEntry`, `SourceEnvelope<MailData>`,
   plus the telemetry wrapper (only `sources.mail` needs decoding; ignore other
   sources with lenient decoding). CRITICAL: `urgency: Int?` where nil = not
   triaged and 0 = triaged-ignorable — never collapse them. `body: String?` where
   "" (poller kept no copy vs cached-empty) is distinct from nil.

2. **Data source** (`protocol MailStore`): async methods `telemetry()`,
   `message(key:)`, `markRead/markUnread/archive(key:)`, `requestDraft(key:instructions:)`,
   `saveDraft(key:body:)`, `send(key:body:) -> String?` (outbox id or nil on refusal).
   Two implementations:
   - **DemoStore**: port the fixture mailbox from `fixture.ts` (6-10 messages
     covering: unread, urgent(3), this-week(2), untriaged (urgency nil), tagged,
     with-AI-summary, with-AI-draft-ready, failed-triage, attachment-bearing,
     archived-not-in-inbox, outbox queued/sent/error). Demo writes mutate local
     state; `requestDraft` flips queued→ready after 6s; `send` returns a synthetic
     id and flips queued→sent after 4s. All timings match the web demo.
   - **LiveClient**: URLSession against `baseURL`; every request carries
     `Authorization: Bearer <token>`. GET `/v1/telemetry`, GET
     `/v1/mail/message/<key>` (validate key against `^[a-f0-9]{16}$` BEFORE
     requesting — the server returns SPA HTML 200 for malformed keys), POSTs per
     the reference client. `save-draft` posts `{key, body}` — the field is `body`.
     `send` posts `{key, body}` only (max 8000 chars, enforce client-side);
     recipient and subject are computed server-side, never transmitted. Parse
     `{ok, id}` from send; nil on any non-ok. Errors close connections
     server-side — treat connection reset as a refusal, not a network fault.

3. **App state** (`@Observable MailModel`):
   - `payload` (last telemetry), `selection: String?` (message key — the single
     source of truth, the moral equivalent of the `#mail/<key>` hash route),
     pending sets (`readHere`, `freshHere`, `goneHere`) with the exact
     reconciliation contract from `mailPending.ts`: a pending read clears only
     when the payload lists the key with `unread == false`; a pending unread
     clears on `unread == true`; a pending archive clears when the key is absent
     from the list; **a key absent from the list confirms nothing for read/unread**.
   - Telemetry poll: 10s interval, paused when the app is inactive/window
     occluded (scenePhase + `NSApplication.didResignActive`), immediate refetch
     on reactivation.
   - Reader working-poll: 10s re-fetch of the open message ONLY while
     `draftWorking || filing || (sentId != nil && record == nil) || record?.status == "queued"`.

## UI (SwiftUI)

**Window**: single window, min 720x480, default 1200x800, pure black background.
Title bar: transparent/unified, window title "Email".

**Split behavior**: measure the CONTENT width with GeometryReader. >= 1000pt:
list pane fixed 380pt + hairline divider + reader pane. < 1000pt: list OR reader
(selection non-nil shows reader with a back control). Not a media query on the
window — the container.

**List** (port MailView):
- App bar: mail glyph, "Email" 22px, counts text ("N messages" / "no poll
  recorded yet"), gear button (opens connection sheet).
- Health strip only when the envelope is stale/degraded/error/dormant.
- Counts line: "unread N · urgent N · to triage N · queued N · polled X ago",
  dimmed when stale.
- Rows: 3-line grid — (unread dot | avatar | sender · marks · urgency dot · relTime),
  (subject), (tag chips · outbox word · summary line or "not triaged yet").
  Marks: paperclip+count, star (flagged), pencil (has_draft), fault (outbox error).
  Urgency dots: 3=red "needs today", 2=amber "this week", 1=no color, nil=nothing.
  Hover reveals the archive key; archive failure flashes "not archived" 2s.
  Selected row: 2px cyan inset leading rail + raised background.
- Empty states: dormant ("Not wired…") vs empty inbox ("Nothing in the inbox.").
- Footer (both layouts): "triage and drafts are written by a session that cannot
  send · a reply leaves only when you click SEND".

**Reader** (port MailReaderView) — identity is the key: apply `.id(key)` so the
view fully remounts per message (a half-written reply must never leak into
another message's draft save).
- Doc states: loading / missing / error / ok — port the copy verbatim.
- Message card: subject 22px, avatar+identity row, from/to chips, date+size meta.
- Verdict row: urgency chip (reader wording: 3 "needs today", 2 "this week",
  1 "whenever", 0 "ignorable") + tag chips.
- Action bar: Reply (r), AI draft, Summary (toggle, disabled without ai),
  Archive, Unread, and the walk group (‹ N/M › with k/j).
- Summary panel: model line, bullets, "written by a session that read this
  message · not the sender's words" foot; failed-triage copy.
- Body: monospaced plain text, NEVER HTML rendering of any kind. body_cached
  false → "The poller kept no copy of this body…" copy; body_truncated →
  "body truncated at 64 KB · the whole message is on the Pi".
- Attachments: rows with clip icon, name, size. v1: tapping does a download via
  the live client (URLSession download + NSSavePanel) or no-op with a note in
  demo mode.
- Compose: to-chip (echo only), subject computed "Re: " once, TextEditor body,
  1.5s debounced autosave to save-draft, save-state line, AI-draft instruction
  field (Enter files it), draft status rows, draft-collision offer
  (Use the draft / Keep mine).

**CONFIRM SEND — port exactly, this is the safety-critical piece:**
1. Resting: SEND key disabled unless (reply address exists && text non-empty &&
   !filing), reason text beside it.
2. First click: `confirming = true`, NO request. A bordered strip appears:
   "This leaves the Pi and cannot be taken back." + `CONFIRM SEND <recipient>`
   (the app's ONLY filled-cyan control) + quiet Cancel.
3. Second click: confirm strip disappears immediately, then POST. nil → refused.
4. Send state is a WORD, never a color: QUEUEING → QUEUED / SENT HH:MM /
   SEND FAILED (+ reason line). Retry appears only on failure and jumps back to
   the confirm step with the text intact — it never re-posts an old record.
5. The send-state line renders inside the compose panel when open and in its
   place when closed — never hidden behind a click.

**Keyboard**: j/→ and k/← walk (list scope: open first/last; reader scope:
next/prev), r = reply, Esc = back to list (restore rail). All ignored while a
text field has focus. Use `.onKeyPress` / commands, not NSEvent monitors, where
possible.

## Visual dialect (from mail.css + tokens.css — port faithfully, no inventions)

- Departure Mono at exactly two sizes: 11 and 22. Weight 400 everywhere —
  hierarchy comes from ink level and letter-case, never bold.
- True black ground `#000`; surfaces `#0d0d0d` / `#1c1c1c` / `#2a2a2a`; ink ramp
  `#ffffff` → `#a8a8a8` → `#7d7d7d` → `#4a4a4a`; hairlines `#232323`/`#3a3a3a`.
- Fixed color meanings: green `#7ee07e` ok/unread; amber `#ffcc55` caution/urg-2;
  red `#ff5f4f` fault/urg-3; cyan `#5fdede` spent EXACTLY twice — the selected
  row's inset rail and the confirm-send fill. Nowhere else.
- Corner radii 6/10/12 only. Chips are capsules with uppercase micro-labels.
- Animate background/border/text color only, 120ms ease. Nothing else moves.
- Every state has a non-color channel: glyph, word, or shape. Accessibility
  labels on all icon-only controls.
- Icons: port the MailKit inline SVGs as `Path`-based SwiftUI shapes or SF
  Symbols equivalents at 16pt with 1.25 stroke — prefer hand-drawn Path ports
  for the distinctive ones (mail, archive, reply, sparkle, pencil, clip, star,
  fault, unread, send, chevrons), SF Symbols acceptable where visually identical.
- Avatars: 32pt (40pt reader) circles; hue = FNV-1a hash of the address clamped
  to 96–204°, saturation 16%, background L 23%, foreground L 76%, 2-char initials.

## Settings (v1 minimal)

Gear opens a sheet: mode picker (Demo / Live), base URL field (default
`http://100.64.0.2:8788` — an example tailnet address; set your own), token
field (stored in Keychain via Security
framework; never UserDefaults), Test button that hits `/v1/telemetry` and
reports ok/401/unreachable. Behavior toggles rowNote / summaryOpen /
afterArchive ship as constants matching web defaults (true / true / next); no UI
for them in v1.

## Invariants checklist (verify before finishing)

- [ ] No HTML rendering anywhere (no WKWebView, no AttributedString(html:)).
- [ ] Send POST carries only key+body; recipient never chosen client-side.
- [ ] Two-step confirm; server would send on first POST, so the gate is ours.
- [ ] Retry mints a new send, never re-posts an outbox id.
- [ ] urgency nil ≠ 0 in model AND rendering.
- [ ] save-draft JSON field is `body`.
- [ ] Key regex validated client-side before /v1/mail/message.
- [ ] Pending-state reconciliation matches mailPending.ts verbatim.
- [ ] Esc in a focused text field does nothing.
- [ ] Cyan appears exactly twice.

## Build

```
xcodegen generate
xcodebuild -project HalftoneMail.xcodeproj -scheme HalftoneMail \
  -configuration Debug -derivedDataPath DerivedData build
```

The product lands at `DerivedData/Build/Products/Debug/Charon.app`.
