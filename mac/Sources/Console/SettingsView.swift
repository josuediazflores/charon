import AppKit
import SwiftUI
import UniformTypeIdentifiers

/* The console's preferences, as a destination in the rail.
 *
 * A tty page, not a mail page: settings govern the whole console, so they are
 * drawn in its own face even when the thing being configured is one of the two
 * tabs that are not. The values live in `ConsoleSettings`, and this page is
 * only a place to read and flip them -- which is why the shell answers this tab
 * above the payload guard.
 *
 * **One panel here is not about this Mac, and it is the exception that proves
 * the rule.** The Messages allowlist lives on the Pi because the Bridge and the
 * collector both enforce it and a copy on one laptop would be a third opinion.
 * Its readouts come out of the telemetry envelope, so they say `unknown` rather
 * than lying when no payload has landed -- and every other row on this page is
 * still a preference that never leaves this machine.
 *
 * One panel per subject, and a subject is a program or the shell around them:
 * the mail app, the 6am briefing, the console itself, and the machine all four
 * are kept on. The next program's settings land as a sibling panel, not as
 * rework.
 *
 * **Not every row is a control.** Three of them are readouts, and one of those
 * three is a fence: how sending and archiving work is stated here precisely
 * because Settings is the first place somebody goes to look for the switch that
 * turns the send confirm off. A page that stayed silent about it would read as
 * a page that has not got round to it yet, rather than as the answer.
 *
 * **No `tone` on any Panel here.** A coloured frame in this console means this
 * block is the thing in trouble, and a preferences page is never in trouble.
 */

struct SettingsView: View {

    /// The console's one store and its one payload. Read for the Messages
    /// panel and for nothing else on this page.
    var model: MailModel

    private let settings = ConsoleSettings.shared

    // ── the messages allowlist, which lives on the Pi ──
    /// What the collector last said the allowlist is. Nil until the first read
    /// lands, which the panel draws as a waiting line rather than as an empty
    /// allowlist -- those are different facts and only one of them is alarming.
    @State private var config: MessagesConfig?
    /// Every chat the Bridge has uploaded, for the "allow a chat" list.
    @State private var known: [MessageChatSummary] = []
    /// Whether the add row is open.
    @State private var adding = false
    @State private var allowlistRefresh = 0
    /// Why the last edit did not land, if it did not.
    @State private var allowFault: String?

    /// Why the last pick did not land, if it did not. Held rather than
    /// swallowed: a copy that failed silently would leave the masthead drawing
    /// the globe with no word anywhere about why, and this row's note is the
    /// only place on the page that could say.
    @State private var pickFault: String?

    /// Where a message goes once it is filed.
    private let afterArchive = ["the next message", "the inbox"]

    /// The transparency slider works in what its label says. The wash is
    /// stored as its own opacity, because that is what the layer takes;
    /// transparency is one minus it, and the conversion lives here rather than
    /// in the control so the number on the page and the number in the
    /// preference are the same number read two ways.
    private var transparency: Double { 1 - settings.groundOpacity }

    /// Half the ground is as much of the desktop as this console will show:
    /// every figure on every page is ink on that wash.
    private var transparencyRange: ClosedRange<Double> {
        0...(1 - ConsoleSettings.groundRange.lowerBound)
    }

    /// The picture's strength, straight off the preference: unlike the wash
    /// this one is not read two ways, so the track is the range itself.
    private var backdropRange: ClosedRange<Double> { ConsoleSettings.backdropRange }

    /// The art's width, as the slider's own units. Cells are whole numbers and
    /// a track is not, so the conversion lives here -- the same place the wash
    /// converts -- and the readout beside the track is the preference itself
    /// rather than a rounding of a rounding.
    private var colRange: ClosedRange<Double> {
        let cells = ConsoleSettings.mastheadColRange
        return Double(cells.lowerBound)...Double(cells.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HT.row) {
            PageHead(title: "Settings", subtitle: "how this console behaves")
            KeyButton("Connection") { model.showingConnection = true }

            // **A measure, because every row here is a dot leader.** A leader
            // is a line the eye follows from a label to its control, and on a
            // 1600pt window these ran the whole pane -- a hundred and eighty
            // dots between "crt scanlines" and the `[ ON ]` that answers it,
            // which is a longer trip than the label is worth and further than
            // anybody can hold a row. 124 cells is the width the notes under
            // the rows already wrap at comfortably, so the panels stop where
            // the prose does.
            //
            // Leading, and not the centred column the chat list uses: the page
            // head above is set flush left and a centred body under a flush-left
            // title is two pages.
            VStack(alignment: .leading, spacing: HT.row) {
                HTGrid {
                    Cell(span: 12) { features }
                    if settings.isEnabled(.mail) {
                        Cell(span: 12) { mail }
                    }
                    if settings.isEnabled(.messages) {
                        Cell(span: 12) { messages }
                    }
                    if settings.isEnabled(.cmo) {
                        Cell(span: 12) { briefing }
                    }
                    Cell(span: 12) { console }
                    Cell(span: 12) { machine }
                }
            }
            .frame(maxWidth: HT.cw * 124, alignment: .leading)
        }
    }

    private var features: some View {
        Panel(title: "Features") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ConsoleFeature.allCases, id: \.self) { feature in
                    if model.connection.mode == .live {
                        let client = model.store as? LiveClient
                        FeatureRoutineSetting(feature: feature, client: client,
                                              access: model.payload?.featureAccess?[feature.rawValue]) { enabled in
                            if let client, model.store === client, model.connection.mode == .live {
                                model.confirmFeature(enabled, for: feature)
                            }
                        }
                        .id(ObjectIdentifier(model.store))
                    } else {
                        ToggleRow(label: ConsoleNav.label(feature.rawValue),
                                  on: settings.isEnabled(feature)) {
                            settings.setEnabled(!settings.isEnabled(feature), for: feature)
                        }
                    }
                }
                SettingsNote(model.connection.mode == .live
                    ? "Off pauses this feature on the connected Pi and hides its tab. On resumes its previously active jobs. Saved work stays available for resume."
                    : "Choose which features appear in Demo on this Mac.")
            }
        }
    }

    // MARK: - the mail program

    private var mail: some View {
        Panel(title: "Mail", meta: AnyView(meta("the mail program"))) {
            VStack(alignment: .leading, spacing: 0) {
                ToggleRow(label: "collapse the rail while reading",
                          on: settings.railCollapse) {
                    settings.railCollapse.toggle()
                }
                SettingsNote("The HALFTONE rail steps aside when a message opens, and comes "
                             + "back when it closes. Off, the rail stays put everywhere.")

                ToggleRow(label: "show the ai line under each row", on: settings.rowNote) {
                    settings.rowNote.toggle()
                }
                SettingsNote("Line three of a row: the tags, whether a reply is queued or "
                             + "sent, and the machine's one-line reading of the message. Off "
                             + "is a tighter inbox of sender, subject and time. It is also "
                             + "where a message says it has not been triaged yet, so off "
                             + "hides the only per-row sign that triage is behind. The "
                             + "count above the list still says how many are waiting. A send "
                             + "that failed is not on that line at all: it is a mark on line "
                             + "one, because nothing above the list counts one.")

                ToggleRow(label: "open the ai summary with the message",
                          on: settings.summaryOpen) {
                    settings.summaryOpen.toggle()
                }
                SettingsNote("Off, the sender's own words are the first thing on the page and "
                             + "the reading of them waits to be asked for. The SUMMARY key "
                             + "still opens it wherever there is a reading. On a message "
                             + "triage has not reached there is none, and the key is off with "
                             + "it. Closing one has never carried to the next.")

                ChoiceRow(label: "after archiving, go to",
                          value: settings.afterArchive == .inbox ? "the inbox" : "the next message",
                          options: afterArchive) { picked in
                    // The answer is rebuilt from the two words rather than cast
                    // out of the control: a listbox can only hand back one of
                    // its own options, but a cast would keep being true after
                    // somebody adds a third and forgets this line.
                    settings.afterArchive = picked == "the inbox" ? .inbox : .next
                }
                SettingsNote("The next message is a walk through the morning: file it, read "
                             + "the one behind it, and stop when the inbox does. The inbox is "
                             + "one message at a time. Either way the last message in the list "
                             + "ends on the inbox, because there is nothing behind it.")

                // **None of these five may ever become a switch.** They are what
                // makes it safe to point a model at a mailbox at all, and every
                // one of them is somebody's reasonable-sounding request: skip
                // the confirm, let it open a thread, retry the send that failed.
                // They are written down here rather than nowhere because this is
                // the page that gets searched for the way to turn the confirm
                // off, and the answer is that there is not one.
                DotLeader(label: "how sending and archiving work", value: "fixed",
                          labelInk: HT.inkBright)
                SettingsNote("Sending is your click and nothing else: no model is anywhere "
                             + "in the send path. The recipient is recomputed on the Pi from "
                             + "the message being replied to, and is never sent from this "
                             + "Mac. Replies only: nothing here can open a thread with "
                             + "somebody. Nothing retries a send that failed; it is reported "
                             + "and left where you can see it. Archiving is IMAP \\Deleted "
                             + "plus an expunge, which is Gmail's archive only while that "
                             + "account's auto-expunge is on, and nothing on this Mac can "
                             + "check which mode it is in.")
            }
        }
    }

    // MARK: - the imessage bridge

    /// One row of the allowlist, as the table lists it.
    ///
    /// Keyed by the chat guid, which is what `messages/config.json` is keyed
    /// by. The 16-hex chat key is a route and never an identity here.
    private struct AllowRow: Identifiable {
        var guid: String
        var name: String
        var read: Bool
        var send: MessagePolicy
        var id: String { guid }
    }

    /// The allowlist, readable chats first and then alphabetically.
    ///
    /// A dictionary has no order, so the table has to choose one, and this is
    /// the one worth having: the chats that actually leave this Mac are the
    /// ones somebody came to this page to check.
    private var allowRows: [AllowRow] {
        guard let config else { return [] }
        return config.chats
            .map { AllowRow(guid: $0.key, name: $0.value.name ?? $0.key,
                            read: $0.value.read, send: $0.value.send) }
            .sorted { a, b in
                if a.read != b.read { return a.read }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// The chats the Bridge knows about that are not on the list yet.
    private var candidates: [MessageChatSummary] {
        known.filter { chat in
            guard let guid = chat.chatGuid else { return false }
            return config?.chats[guid] == nil
        }
    }

    private var bridge: MessagesBridge? { model.messagesData?.bridge }

    private var messages: some View {
        Panel(title: "Messages", meta: AnyView(meta("the imessage bridge"))) {
            VStack(alignment: .leading, spacing: 0) {
                // Six readouts, and every one of them is the heartbeat's own
                // word rather than this app's opinion of it. A field no
                // heartbeat has ever carried says `unknown` in dim ink, which
                // is a different fact from `no`.
                DotLeader(label: "bridge", value: reporting ? "live" : "absent",
                          tone: reporting ? .nominal : .caution,
                          labelInk: HT.inkBright)
                DotLeader(label: "helper", value: bridge?.helper ?? "unknown",
                          dim: bridge?.helper == nil, labelInk: HT.inkBright)
                DotLeader(label: "full disk access", value: granted(bridge?.fda),
                          tone: tone(bridge?.fda), dim: bridge?.fda == nil,
                          labelInk: HT.inkBright)
                DotLeader(label: "automation → messages", value: granted(bridge?.automation),
                          tone: tone(bridge?.automation), dim: bridge?.automation == nil,
                          labelInk: HT.inkBright)
                DotLeader(label: "last event",
                          value: bridge?.lastEventAt.map { Fmt.relTime($0) + " ago" }
                              ?? "unknown",
                          dim: bridge?.lastEventAt == nil, labelInk: HT.inkBright)
                DotLeader(label: "cursor",
                          value: bridge?.cursor.map { "rowid \(Fmt.num($0))" } ?? "unknown",
                          dim: bridge?.cursor == nil, labelInk: HT.inkBright)
                SettingsNote("Runs on this Mac as a login item. Only allowlisted chats "
                             + "leave the Mac; they go to the Pi over Tailscale like mail "
                             + "does.")

                allowlist

                ActionRow(label: "allow a chat", title: adding ? "cancel" : "add") {
                    adding.toggle()
                    if adding { allowlistRefresh += 1 }
                }
                if adding {
                    ChoiceRow(label: "chat",
                              value: candidates.isEmpty ? "nothing to add" : "choose",
                              options: candidates.map(candidateLabel)) { picked in
                        allow(picked)
                    }
                }
                SettingsNote("confirm: charon drafts, you click SEND. auto: charon may "
                             + "send on its own in that chat. Everything sends from your "
                             + "number, as you.")

                if let allowFault {
                    SettingsNote(allowFault)
                }

                ActionRow(label: "open Charon Bridge", title: "open",
                          disabled: bridgeApp == nil, act: openBridge)
                ActionRow(label: "reveal bridge in Finder", title: "reveal",
                          disabled: bridgeApp == nil, act: revealBridge)
            }
        }
        .task(id: allowlistRefresh) { await loadAllowlist() }
    }

    /// A heartbeat inside the collector's own window. `absent` rather than
    /// `off`: a Mac that is asleep has not failed, it has stopped talking.
    private var reporting: Bool {
        bridge?.seenAt != nil && model.messagesEnv?.status != .dormant
    }

    private func granted(_ flag: Bool?) -> String {
        guard let flag else { return "unknown" }
        return flag ? "granted" : "not granted"
    }

    private func tone(_ flag: Bool?) -> Tone {
        guard let flag else { return .default }
        return flag ? .nominal : .caution
    }

    /// Name and identifier, which is the pair that tells two chats with the
    /// same contact name apart.
    private func candidateLabel(_ chat: MessageChatSummary) -> String {
        let handle = chat.handle
        return handle.isEmpty ? chat.name : "\(chat.name) · \(handle)"
    }

    @ViewBuilder
    private var allowlist: some View {
        if config == nil {
            SettingsNote("reading the allowlist from the collector…")
        } else {
            DataTable(
                columns: [
                    DataColumn(key: "chat", header: "chat", flexible: true,
                               cell: { row in DataColumn<AllowRow>.primary(row.name) }),
                    DataColumn(key: "read", header: "read", width: HT.cw * 12,
                               cell: { row in
                        AnyView(HTButton(title: row.read ? "on" : "off", variant: .ghost,
                                         size: .sm, caps: true) {
                            set(row.guid) { $0.read.toggle() }
                        })
                    }),
                    DataColumn(key: "send", header: "send", width: HT.cw * 18,
                               cell: { row in
                        AnyView(HStack(spacing: HT.cw) {
                            Listbox(label: "send policy for \(row.name)",
                                    value: row.send.rawValue,
                                    options: MessagePolicy.allCases.map(\.rawValue),
                                    quiet: true, caps: true, opensUp: false) { picked in
                                guard let next = MessagePolicy(rawValue: picked) else { return }
                                set(row.guid) { $0.send = next }
                            }
                            // Stored and shown, and it does nothing yet: v1
                            // gives behaviour to off and confirm only.
                            if row.send == .auto {
                                Text("(v2)").font(HT.body).foregroundStyle(HT.inkDim)
                            }
                        })
                    }),
                ],
                rows: allowRows,
                empty: "No chat is allowlisted. Nothing leaves this Mac.",
                dense: true)
            .padding(.top, HT.s2)
            .padding(.bottom, HT.s3)
        }
    }

    // MARK: - allowlist acts
    //
    // Optimistic, and the whole document goes back every time: the collector
    // owns one config file, and a patch route would be a second way to say the
    // same thing. A refusal restores what the Pi still believes.

    private func loadAllowlist() async {
        guard settings.isEnabled(.messages), !Task.isCancelled else { return }
        do {
            let latest = try await model.store.config()
            guard settings.isEnabled(.messages), !Task.isCancelled else { return }
            config = latest ?? MessagesConfig()
            allowFault = nil
        } catch {
            guard settings.isEnabled(.messages), !Task.isCancelled else { return }
            allowFault = "the allowlist could not be read: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let chats = await model.store.chats()
        guard settings.isEnabled(.messages), !Task.isCancelled else { return }
        known = chats ?? []
    }

    private func set(_ guid: String, _ edit: (inout MessagesChatPolicy) -> Void) {
        guard var next = config, var entry = next.chats[guid] else { return }
        let before = next
        edit(&entry)
        next.chats[guid] = entry
        config = next
        push(next, rollback: before)
    }

    private func allow(_ label: String) {
        guard let chat = candidates.first(where: { candidateLabel($0) == label }),
              let guid = chat.chatGuid, var next = config else { return }
        let before = next
        // Readable and confirm-to-send, which is the only pair worth defaulting
        // to: a chat allowed for reading with sending off cannot be replied to
        // from here at all, and `auto` has no behaviour to default into.
        next.chats[guid] = MessagesChatPolicy(read: true, send: .confirm, name: chat.name)
        config = next
        adding = false
        push(next, rollback: before)
    }

    private func push(_ next: MessagesConfig, rollback: MessagesConfig) {
        Task {
            if await model.store.setConfig(next) {
                allowFault = nil
            } else {
                config = rollback
                allowFault = "not saved · the collector did not take it."
            }
        }
    }

    // MARK: - the helper app
    //
    // Two doors and no third: this app never reads `chat.db`, never spawns the
    // helper and never checks a permission. It can point at the Bridge, and the
    // Bridge reports for itself.

    private static let bridgeBundleId = "com.example.charon.bridge"

    private var bridgeApp: URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SettingsView.bridgeBundleId)
    }

    private func openBridge() {
        guard let bridgeApp else { return }
        NSWorkspace.shared.openApplication(at: bridgeApp,
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    private func revealBridge() {
        guard let bridgeApp else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bridgeApp])
    }

    // MARK: - the 6am cmo

    private var briefing: some View {
        Panel(title: "Briefing", meta: AnyView(meta("the 6am cmo"))) {
            VStack(alignment: .leading, spacing: 0) {
                DotLeader(label: "the briefing runs on", value: "opus · effort high",
                          labelInk: HT.inkBright)
                SettingsNote("Eighty turns, inside a 4500 second wall, and at most two "
                             + "attempts: one retry five minutes later, then it gives up "
                             + "until tomorrow. Those are edited in run-cmo.sh on the Pi and "
                             + "deliberately not here: the turn budget only means anything "
                             + "next to the wall clock beside it, and a console that could "
                             + "raise one without the other would be a run that dies at the "
                             + "timeout every morning with a briefing half written.")
            }
        }
    }

    // MARK: - the shell

    private var console: some View {
        Panel(title: "Console", meta: AnyView(meta("around every tab"))) {
            VStack(alignment: .leading, spacing: 0) {
                ChoiceRow(label: "open the console on",
                          value: ConsoleNav.label(settings.landing),
                          options: settings.availableTabs.map(\.label)) { picked in
                    if let item = settings.availableTabs.first(where: { $0.label == picked }) {
                        settings.landingTab = item.id
                    }
                }
                SettingsNote("Only a cold start. Whichever tab you were on stays where it is "
                             + "for as long as the window is open, and a landing tab this "
                             + "console does not have opens Overview, which is what keeps a "
                             + "preference written by an older build from quietly becoming "
                             + "home.")

                ToggleRow(label: "crt scanlines", on: settings.scanlines) {
                    settings.scanlines.toggle()
                }
                SettingsNote("Atmosphere, over the whole shell. It is paid for in legibility "
                             + "on exactly the dense figures this console exists to print, so "
                             + "it is off out of the box.")

                // Behind the window, and directly above the slider that says
                // how much of behind is read: the two rows are one sentence,
                // and the slider's own note finishes it by naming whichever of
                // the two things is actually back there. The same track and the
                // same step as that one, because they are the same kind of
                // question asked about two layers.
                SliderRow(label: "backdrop",
                          value: settings.backdrop,
                          range: backdropRange,
                          step: 0.05,
                          grain: 0.01,
                          readout: "\(Int((settings.backdrop * 100).rounded()))%") { shown in
                    settings.backdrop = shown
                }
                SettingsNote("A picture behind the window, standing where the desktop "
                             + "stands. It is printed faintly on purpose: the desktop back "
                             + "there arrives blurred and this does not, so at full strength "
                             + "its edges cut straight under the type. Zero is no picture.")

                SliderRow(label: "window transparency",
                          value: transparency,
                          range: transparencyRange,
                          // Five points of the number beside it per press, and
                          // one point per click: the arrows are for choosing,
                          // the track is for landing.
                          step: 0.05,
                          grain: 0.01,
                          readout: "\(Int((transparency * 100).rounded()))%") { shown in
                    settings.groundOpacity = 1 - shown
                }
                SettingsNote(settings.backdrop > 0
                             ? "how much of the picture and the desktop shows through"
                             : "how much of the desktop shows through the window")

                // Directly under the wash, because they are the same surface
                // read two ways: this one is what colour it is, the one above is
                // how much of it there is. Rebuilt from the name rather than
                // cast, like the archive row -- and nil-checked, so a name this
                // build has no family for does nothing instead of silently
                // choosing the first one.
                ChoiceRow(label: "ground",
                          value: settings.ground.label,
                          options: GroundFamily.labels) { picked in
                    if let family = GroundFamily.named(picked) {
                        settings.groundFamily = family.rawValue
                    }
                }
                SettingsNote("the color under everything · ink and accents stay put")

                // The masthead's slot, and then its width, in that order: what
                // is in it decides whether the size row means anything, and the
                // picture row only exists for one of the five answers.
                ChoiceRow(label: "masthead art",
                          value: settings.masthead.label,
                          options: MastheadArt.labels) { picked in
                    if let art = MastheadArt.named(picked) {
                        settings.mastheadArt = art.rawValue
                    }
                }
                SettingsNote("What stands beside the identity block at the top of Overview. "
                             + "The globe and the orb turn, and both stop dead under Reduce "
                             + "Motion; the sphere is a still dither plate; image is one of "
                             + "your own, drawn plain. None leaves the identity block standing "
                             + "on its own, which is what the masthead already does on a "
                             + "window under 720, whichever art is chosen.")

                SliderRow(label: "art size",
                          value: Double(settings.mastheadCols),
                          range: colRange,
                          // Two cells a press and two cells a click. One would
                          // be a control with twenty-nine stops on a
                          // twenty-cell track, which is a track that cannot
                          // land on half of its own values.
                          step: 2,
                          grain: 2,
                          readout: "\(settings.mastheadCols) cols") { shown in
                    settings.mastheadCols = Int(shown.rounded())
                }
                SettingsNote("columns of the ascii art · sets image width on the same scale")

                if settings.masthead == .image {
                    ActionRow(label: "choose image", title: "pick", act: pick)
                    SettingsNote(pictureNote)
                }
            }
        }
    }

    /// What the picture row has to say for itself: the fault if the last pick
    /// failed, the filename if there is one, and otherwise the fact that the
    /// globe is standing in.
    private var pictureNote: String {
        if let pickFault { return pickFault }
        guard let name = settings.mastheadImageFile, !name.isEmpty else {
            return "Nothing picked yet, so the globe is standing in. Whatever you choose is "
                + "copied into this app's own storage, which is why moving or deleting the "
                + "original afterwards changes nothing up there."
        }
        if MastheadImage.stamp(name).isEmpty {
            return "\(name): not there any more, so the globe is standing in until you pick "
                + "another."
        }
        return "\(name): the copy in this app's own storage, not the file you picked."
    }

    /// The one entitled act in this feature, and it is the user performing it:
    /// an open panel is a file chosen by hand, which is what
    /// `files.user-selected` means. Nothing else in this app reads a path.
    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "A picture for the Overview masthead."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            settings.mastheadImageFile = try MastheadImage.adopt(source)
            pickFault = nil
        } catch {
            pickFault = "That file could not be copied in: \(error.localizedDescription)."
        }
    }

    // MARK: - this Mac

    private var machine: some View {
        Panel(title: "This Mac", meta: AnyView(meta("on this device"))) {
            VStack(alignment: .leading, spacing: 0) {
                DotLeader(label: "where these are saved", value: "this mac",
                          labelInk: HT.inkBright)
                SettingsNote("Appearance and Demo preferences are saved on this Mac. Live feature switches are saved on the connected Pi and apply to every connected Mac. The collector token is stored in Keychain.")
            }
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text).font(HT.body).foregroundStyle(HT.inkDim).lineLimit(1)
    }
}

// MARK: - the rows

/* A setting, as one line: what it is called, then the word it is set to.
   The word is the whole control and both channels at once -- ON is bright, OFF
   is dim, and either reads correctly printed in one bit.

   Rows WRAP rather than ellipsize: a setting whose name is cut in half is a
   setting nobody can decide about, and the note under it is already a paragraph
   -- one more wrapped line costs nothing this page has.
*/
private struct ToggleRow: View {
    var label: String
    var on: Bool
    var flip: () -> Void

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Text(label.lowercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .fixedSize(horizontal: false, vertical: true)

            GlyphRun(glyph: ".", color: HT.inkFaint)

            HTButton(title: on ? "on" : "off", variant: .ghost, size: .sm, caps: true,
                     action: flip)
        }
        .frame(minHeight: HT.row)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(on ? "on" : "off"))
    }
}

/// A setting with more than two answers, on the same line and in the same
/// place: the value slot of a leader, where every other reading on this page
/// already is. Quiet, because the panel is the frame and a second bordered box
/// inside it draws the control twice; caps, because it stands where ON and OFF
/// stand and a lowercase answer beside them would read as prose.
private struct ChoiceRow: View {
    var label: String
    var value: String
    var options: [String]
    var pick: (String) -> Void

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Text(label.lowercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .fixedSize(horizontal: false, vertical: true)

            GlyphRun(glyph: ".", color: HT.inkFaint)

            // Downward, unlike the composers': this button is near the top of a
            // long page, and a list opening up from here would be the one
            // clipped by the console's own scrollport.
            Listbox(label: label, value: value, options: options,
                    quiet: true, caps: true, opensUp: false, onPick: pick)
        }
        .frame(minHeight: HT.row)
    }
}

/// A setting whose answer is somewhere else: the value slot holds the way to go
/// and get it rather than the thing itself.
///
/// The same ghost button `ToggleRow` puts ON and OFF in, for the same reason --
/// the row is already inside a panel, and a bordered control in the value slot
/// would draw the frame twice. What was picked is reported by the note under
/// the row, because a filename is longer than a value slot and wraps like prose.
private struct ActionRow: View {
    var label: String
    var title: String
    /// Dim and inert. One caller: the two doors to a helper app that is not
    /// installed on this Mac, which is a fact worth drawing rather than hiding.
    var disabled: Bool = false
    var act: () -> Void

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Text(label.lowercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .fixedSize(horizontal: false, vertical: true)

            GlyphRun(glyph: ".", color: HT.inkFaint)

            HTButton(title: title, variant: .ghost, size: .sm, caps: true,
                     disabled: disabled, action: act)
        }
        .frame(minHeight: HT.row)
    }
}

/// A setting with a range rather than an answer. The track stands exactly
/// where ON and OFF stand, and the reading after it is the number the label
/// promises -- so the row is still a leader with a value on the end of it.
///
/// No accessibility element around the row: the slider is its own, with the
/// adjustable action on it, and a wrapper here would bury the one thing on the
/// row that can be operated without the pointer.
private struct SliderRow: View {
    var label: String
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var grain: Double
    var readout: String
    var set: (Double) -> Void

    var body: some View {
        RunRow(spacing: HT.cw, runIndex: 1, runMin: HT.cw2, leadFraction: 0.6) {
            Text(label.lowercased())
                .font(HT.body)
                .foregroundStyle(HT.inkBright)
                .fixedSize(horizontal: false, vertical: true)

            GlyphRun(glyph: ".", color: HT.inkFaint)

            SegSlider(label: label, value: value, range: range,
                      step: step, grain: grain, readout: readout, onChange: set)
        }
        .frame(minHeight: HT.row)
    }
}

/// The sentence under a row -- and on a readout row, the row. Named rather than
/// repeated a dozen times: a dozen copies of one treatment is how one of them
/// ends up not dim.
private struct SettingsNote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // Ink + measure (user's pick from the design review, 2026-08-20): the
        // note is indented one label-step and capped at 68 cells, so the prose
        // reads as an aside under a bright label instead of a wall the width
        // of the window. The cap is characters, not a fraction: readability is
        // about line length, and 68 cells is 68 cells at every window size.
        Text(text)
            .font(HT.body)
            .foregroundStyle(HT.inkDim)
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: HT.cw * 68, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, HT.cw2)
            .padding(.top, HT.s1)
            .padding(.bottom, HT.cw3)
    }
}

private struct FeatureRoutineSetting: View {
    let feature: ConsoleFeature
    private var label: String { ConsoleNav.label(feature.rawValue) }
    let client: LiveClient?
    let access: Bool?
    let confirmed: (Bool) -> Void
    @State private var status: FeatureRoutineStatus?
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HT.s1) {
            if busy {
                DotLeader(label: label, value: "Checking Pi…")
            } else if let enabled = status?.enabled {
                ToggleRow(label: label, on: enabled) { Task { await update(!enabled) } }
            } else if status?.finishingWork == true {
                DotLeader(label: label, value: "Finishing active work")
                KeyButton("Check again") { Task { await update(nil) } }
                KeyButton("Resume") { Task { await update(true) } }
            } else if status?.waitingForBridge == true {
                DotLeader(label: label, value: "Waiting for Bridge")
                SettingsNote("Each registered Mac must connect and confirm its Messages work has stopped.")
                KeyButton("Check again") { Task { await update(nil) } }
                KeyButton("Resume Messages") { Task { await update(true) } }
            } else if let retry = status?.retryEnabled {
                DotLeader(label: label, value: "Change incomplete")
                KeyButton(retry ? "Retry resume" : "Retry pause") { Task { await update(retry) } }
            } else {
                DotLeader(label: label, value: "Unconfirmed")
                KeyButton("Check Pi status") { Task { await update(nil) } }
            }
            if let issue { SettingsNote(issue) }
        }
        .task { await update(nil) }
        .onChange(of: access) { _, value in
            if let value, status?.enabled != value {
                Task { await update(nil) }
            }
        }
    }

    @MainActor
    private func update(_ enabled: Bool?) async {
        guard !busy else { return }
        guard let client else { issue = "Connect to the collector to manage this feature."; return }
        busy = true
        defer { busy = false }
        do {
            let result = try await client.featureRoutines(feature, enabled: enabled)
            try Task.checkCancellation()
            status = result
            issue = nil
            if let enabled = result.enabled { confirmed(enabled) }
            else if result.retryEnabled == false { confirmed(false) }
        } catch {
            status = nil
            issue = error.localizedDescription
        }
    }
}
