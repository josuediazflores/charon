import Foundation

/* The mailbox's routes: one read that is too big for the payload, and five
 * writes -- ported from the web console's mail API client.
 *
 * **Every write here is a request, not the act.** The collector writes a file
 * and drops a spool entry; a worker on the Pi does the thing a moment later. So
 * four of these return a bare Bool meaning "filed", and the caller holds an
 * optimistic copy until a telemetry poll confirms it. `send` is the exception
 * and returns an id: the outbox record it names did not exist a moment ago and
 * the caller has no other way to learn what it is called.
 *
 * **The recipient is not in this file.** `send` posts a key and a body; the
 * collector computes who a reply goes to from the original's own reply-to.
 * Nothing typed in this app can redirect an outgoing email, which is the point
 * of leaving the address out of the request entirely.
 */

/* The collector's other three programs, on the same connection.
 *
 * A separate protocol from `MailStore` and refined by it, so one object answers
 * for the whole console: the shell holds exactly one store, and a tab that
 * needed its own would be a second address, a second token and a second poll
 * against the same Pi.
 *
 * **Every write is a request, not the act**, with the mailbox's own exception:
 * `cmoAsk`, `chatNew` and their kin return an id, because the record they name
 * did not exist a moment ago and the caller has no other way to learn what it
 * is called.
 *
 * The reads that fetch a document return `nil` for "the collector does not have
 * this" and throw for "the collector could not be asked". Those are different
 * facts and every one of the four reader states depends on telling them apart.
 */
@MainActor
protocol ConsoleStore: AnyObject {

    // ── the cmo ──
    func cmoDismiss(_ entry: Dismissal) async -> Bool
    func cmoRestore(_ entry: Dismissal) async -> Bool
    /// The thread id, or nil when nothing was filed. `thread` omitted starts a
    /// new conversation; passing one appends to it.
    func cmoAsk(question: String, thread: String?) async -> String?
    func cmoThread(id: String) async throws -> CmoAskThread?
    /// `text/plain` markdown. Nil on 404, which is most days.
    func cmoBriefing(date: String) async throws -> String?
    func cmoDossier(slug: String) async throws -> String?
    func cmoDoc(slug: String) async throws -> String?

    // ── chat ──
    /// Nil when the collector could not be reached at all -- which is a
    /// different picture from an empty list and must not draw as one.
    func chatList() async -> [ChatThreadSummary]?
    func chatThread(id: String) async throws -> ChatThread?
    func chatNew(model: ChatModelName) async -> String?
    func chatSend(id: String, text: String) async -> WriteResult
    func chatSetModel(id: String, model: ChatModelName) async -> WriteResult
    func chatSetEffort(id: String, effort: JarvisEffort) async -> WriteResult
    func chatStop(id: String) async -> WriteResult
    func chatDelete(id: String) async -> WriteResult
    /// Put a conversation away, or take it back out.
    ///
    /// Unlike `chatDelete` this is allowed while a turn is in flight, and that
    /// is the collector's decision rather than a gap in it: the flag lives
    /// beside the thread rather than in its file, so setting it touches nothing
    /// the runner is holding. `busy` never comes back from this route.
    func chatArchive(id: String, archived: Bool) async -> WriteResult

    // ── jarvis ──
    func jarvisToday() async throws -> JarvisDay?
    func jarvisDays() async -> [JarvisDaySummary]?
    func jarvisDay(_ day: String) async throws -> JarvisDay?
    func jarvisJobs() async -> [JarvisJob]?
    func overnightRuns(before cursor: String?) async throws -> OvernightRunPage
    func overnightRun(id: String) async throws -> OvernightRun?
    /// A local temporary download. Its caller moves or removes it after reading.
    func overnightFile(run: String, file: String) async throws -> URL?
    /// The talk lane, which can answer `busy`: one turn at a time.
    func jarvisSay(text: String) async -> WriteResult
    func jarvisStop() async -> WriteResult
    func jarvisSetModel(_ model: JarvisModelName) async -> WriteResult
    func jarvisSetEffort(_ effort: JarvisEffort) async -> WriteResult
    func jarvisCompact() async -> WriteResult
    /// The work lane, which never answers `busy`: jobs run beside the
    /// conversation under their own lock.
    func jarvisJob(text: String, title: String) async -> WriteResult
    func jarvisJobStop(id: String) async -> WriteResult
    /// A WAV, or nil when the far end would not synthesise one.
    func jarvisTts(text: String) async -> Data?
    func jarvisWarmTts()
}

/* The iMessage channel's routes, per MESSAGES-PROTOCOL.md §5.
 *
 * A protocol of its own and refined by `MailStore` for `ConsoleStore`'s reason:
 * the shell holds exactly one store, and a tab that needed its own would be a
 * second address, a second token and a second poll against the same Pi.
 *
 * **Every write here is a request, not the act**, with one exception and it is
 * the same exception the mailbox has: `send` returns an id, because the outbox
 * record it names did not exist a moment ago and the caller has no other way to
 * learn what it is called.
 *
 * **The recipient is not in this file either.** `send` posts a chat key and a
 * body; the collector resolves the chat guid and the Bridge performs it through
 * Messages.app from the user's own number. Nothing typed in this app can
 * redirect an outgoing text, which is the point of leaving the handle out of
 * the request entirely.
 */
@MainActor
protocol MessagesStore: AnyObject {
    /// One conversation, whole. Nil when the collector does not have this chat.
    func thread(chatKey: String, limit: Int, before: String?) async throws -> MessageThread?
    /// Move the per-chat mark. "Unread" in Charon means not yet seen in Charon
    /// -- the Messages app's own flags are never touched (§7).
    func markRead(chatKey: String) async -> Bool
    func requestDraft(chatKey: String, instructions: String?) async -> Bool
    func saveDraft(chatKey: String, body: String) async -> Bool
    /// A lost acknowledgement may still have queued the request.
    func send(_ request: MessageSendRequest) async -> MessageSubmission

    /// One day's document. Nil on 404, which is most dates.
    func summary(date: String) async throws -> MessageSummaryDoc?
    func summaryRead(date: String) async -> Bool
    func summaryArchive(date: String) async -> Bool

    /// The allowlist, whole. Nil when the collector does not have one yet.
    func config() async throws -> MessagesConfig?
    /// And back, whole: the collector owns one document and a patch route would
    /// be a second way to say the same thing.
    func setConfig(_ config: MessagesConfig) async -> Bool
    /// Every chat the Bridge has ever uploaded, allowlisted or not, so Settings
    /// can offer "allow a chat" without this app ever seeing `chat.db`. Nil for
    /// "could not be asked", which is not an empty directory.
    func chats() async -> [MessageChatSummary]?

    // ── the attachments ──
    //
    // Two calls and one asymmetry, and the asymmetry is the whole design. The
    // bytes live on the Pi; this app never touches `~/Library/Messages` and
    // has no way to, being sandboxed. So a photograph the Bridge has already
    // uploaded is a fetch, and one it has not is a request for the Mac next
    // door to go and get it -- which arrives seconds later, or does not.

    /// One attachment's bytes. Nil when the Pi does not hold them yet, which
    /// is a fact the tile draws rather than an error.
    func attachmentData(key: String, n: Int) async -> Data?
    /// Ask the Bridge to upload one. A request, not the act: it lands in a
    /// spool on the Pi and the Mac answers it on its next poll.
    func wantAttachment(key: String, n: Int) async -> Bool
}

@MainActor
protocol MailStore: ConsoleStore, MessagesStore {
    func telemetry() async throws -> TelemetryPayload
    /// Nil when the collector does not have this key.
    func message(key: String) async throws -> MailMessageFull?

    func markRead(key: String) async -> Bool
    func markUnread(key: String) async -> Bool
    func archive(key: String) async -> Bool
    func requestDraft(key: String, instructions: String?) async -> Bool
    func saveDraft(key: String, body: String) async -> Bool
    /// The outbox id, or nil when nothing was filed. Nil is a real answer and
    /// not merely an error: nothing was filed, nothing will be sent, and the
    /// reader says exactly that.
    func send(key: String, body: String) async -> String?

    /// Whether an attachment can actually be fetched. Demo mode says no and the
    /// reader prints a note instead of pretending.
    var canDownloadAttachments: Bool { get }
    func attachment(key: String, n: Int) async throws -> Data

    /// The bytes the last successful `telemetry()` decoded from, for the
    /// last-known-good cache. Nil where there are none to keep: a fixture is
    /// not a reading and must never be rehydrated as one.
    var lastRawTelemetry: Data? { get }
}

extension MailStore {
    /// A store that invents its payload has nothing to cache.
    var lastRawTelemetry: Data? { nil }
}

enum MailRoute {

    /// The collector returns the SPA's own HTML with a 200 for a key that is
    /// not sixteen hex characters, so a malformed key must never reach it: a
    /// JSON decode failure on a page of markup reads as a broken collector.
    static func isValidKey(_ key: String) -> Bool {
        guard key.count == 16 else { return false }
        return key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The ceiling the collector enforces, enforced here too so an over-long
    /// reply is refused before it is filed rather than after.
    static let maxSendBody = 8000
}

/// The messages routes' own guards, `MailRoute`'s twin one channel over.
/// Not to be confused with `MessagesRoute`, which is a place in the tab.
enum MessageRoute {

    /// Chat keys are the mailbox's own shape -- `sha256(...)[:16]` -- and the
    /// collector answers a path it does not recognise with the console's own
    /// HTML and a 200, so the same guard applies for the same reason.
    static func isValidKey(_ key: String) -> Bool { MailRoute.isValidKey(key) }

    /// `YYYY-MM-DD`, and nothing else, for the same reason: a summary route
    /// with a slug in it comes back as a page of markup with a success code on
    /// it, which reads as a broken collector rather than as a bad date.
    static func isValidDate(_ date: String) -> Bool {
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// The ceiling the collector enforces on a text (§8), enforced here too so
    /// an over-long reply is refused before it is filed rather than after. Half
    /// the mailbox's, because a text message is not an email.
    static let maxSendBody = 4000

    /// How many attachments one row may have (§8), checked before a position
    /// goes in a URL for the same reason a key is: the collector's route takes
    /// three digits, and a number outside it is a page of markup with a
    /// success code on it rather than a 404.
    static let maxAttachments = 20

    /// What the thread route asks for when nobody says otherwise.
    static let threadLimit = 50
}

enum MailError: LocalizedError {
    case badKey
    case http(Int)
    /// A 401 or 403 on a read.
    ///
    /// Singled out on the GETs and only there. A native app has no cookie to
    /// mint and no `/?k=<token>` to visit, so the honest sentence names the one
    /// thing that can be wrong and the one place it is set -- which is the
    /// gear, and the gear already exists. Writes are deliberately unchanged:
    /// they draw one refusal for every reason, 401 included.
    case unauthorized
    case notConfigured
    case demoOnly

    var errorDescription: String? {
        switch self {
        case .badKey: return "not a message key"
        case .http(let code): return "collector returned HTTP \(code)"
        case .unauthorized: return "unauthorized · check the token"
        case .notConfigured: return "no collector address set"
        case .demoOnly: return "demo mode"
        }
    }
}
