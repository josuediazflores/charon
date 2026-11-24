import Foundation

/* The collector, over the tailnet.
 *
 * Every request carries `Authorization: Bearer <token>`. The web client does
 * not, because the Vite proxy attaches the token in dev and the collector
 * serves the app from its own origin with a session cookie in prod; a native
 * app has neither, so the header is the whole of the credential.
 */

enum ProbeResult {
    case ok
    case unauthorized
    case unreachable(String)
}

@MainActor
final class LiveClient: MailStore {

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    /// The last telemetry document that decoded, verbatim. Held for the
    /// cross-launch cache; overwritten only by a fetch that got all the way
    /// through, so a half-read or malformed answer never replaces a good one.
    private(set) var lastRawTelemetry: Data?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        // The collector is polled every ten seconds and every answer is meant
        // to be the current one; a cached telemetry document is a lie with a
        // timestamp on it.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - plumbing

    private func request(_ path: String, method: String = "GET",
                         accept: String = "application/json",
                         query: [URLQueryItem] = [],
                         json: [String: Any]? = nil) -> URLRequest {
        // `appendingPathComponent` percent-escapes a `?`, so a route with a
        // query cannot be spelled as one string: the path is appended and the
        // query is set on the components, which is the only way the collector
        // ever sees a `?` rather than a `%3F`.
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty,
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// A read, checked. Throws `.unauthorized` on 401 and 403 so every reader
    /// in the console says the one useful thing about a token instead of
    /// quoting a status code -- build decision 5.
    private func check(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw MailError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw MailError.unauthorized }
        return http.statusCode
    }

    /// A write. Returns whether the collector took it.
    ///
    /// **A dropped connection is a refusal, not a fault.** The collector closes
    /// the socket on a request it will not honour, so `networkConnectionLost`
    /// arrives here for exactly the same reason a 400 would: nothing was filed.
    /// Both answers are false, and the caller draws one refusal either way --
    /// including 401, which is deliberately not singled out.
    private func post(_ path: String, _ body: [String: Any]? = nil) async -> Bool {
        do {
            let (_, response) = try await session.data(for: request(path, method: "POST", json: body))
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// A write with three answers rather than two.
    ///
    /// 409 is a real state on the conversation routes and not a fault: a turn
    /// is already in flight, which the view already knows how to draw. Every
    /// other refusal is one FAILED, 401 included -- the read paths are where
    /// the token gets named.
    private func write(_ path: String, _ body: [String: Any]? = nil) async -> WriteResult {
        do {
            let (_, response) = try await session.data(for: request(path, method: "POST", json: body))
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 409 { return .busy }
            return (200..<300).contains(http.statusCode) ? .ok : .failed
        } catch {
            return .failed
        }
    }

    /// A POST that mints something. The id, or nil when nothing was filed --
    /// `ok: false` with an id is still a refusal.
    private func mint(_ path: String, _ body: [String: Any]) async -> String? {
        do {
            let (data, response) = try await session.data(
                for: request(path, method: "POST", json: body))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let ok = doc["ok"] as? Bool, ok == false { return nil }
            return doc["id"] as? String
        } catch {
            return nil
        }
    }

    /// One JSON document by route. Nil on 404, which is the collector saying it
    /// does not have this rather than that it could not be asked.
    private func fetch<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                     as type: T.Type) async throws -> T? {
        let (data, response) = try await session.data(for: request(path, query: query))
        let code = try check(response)
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw MailError.http(code) }
        return try MailJSON.decoder.decode(T.self, from: data)
    }

    /// A list route that answers nil for "could not be asked".
    ///
    /// Nil rather than `[]` for the distinction the whole console is built on:
    /// an empty list is a box with nothing in it, an unreachable collector is a
    /// box we know nothing about, and drawing the second as the first says "no
    /// conversations yet" over a Pi that is simply off.
    private func list<T: Decodable>(_ path: String, key: String, as type: T.Type) async -> [T]? {
        do {
            let (data, response) = try await session.data(for: request(path))
            guard (200..<300).contains(try check(response)) else { return nil }
            guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // `?? []` like every list in this app: a collector older than this
            // build sends no such key, and an empty tab beats a crash.
            guard let rows = doc[key] else { return [] }
            let blob = try JSONSerialization.data(withJSONObject: rows)
            return try MailJSON.decoder.decode([T].self, from: blob)
        } catch {
            return nil
        }
    }

    /// One markdown document. Nil on 404: most dates have no briefing, and that
    /// is not a degradation.
    private func text(_ path: String) async throws -> String? {
        let (data, response) = try await session.data(
            for: request(path, accept: "text/plain"))
        let code = try check(response)
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw MailError.http(code) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - reads

    func telemetry() async throws -> TelemetryPayload {
        let (data, response) = try await session.data(for: request("v1/telemetry"))
        let code = try check(response)
        guard (200..<300).contains(code) else { throw MailError.http(code) }
        let payload = try MailJSON.decoder.decode(TelemetryPayload.self, from: data)
        lastRawTelemetry = data
        return payload
    }

    /// One message, whole. Nil when the collector does not have it.
    ///
    /// **The key is validated before the request, not after the answer.** The
    /// collector serves the console's own SPA with a 200 for any path it does
    /// not recognise, so a malformed key comes back as a page of HTML with a
    /// success code on it -- which would surface as "the collector is broken"
    /// rather than as "that is not a message key".
    func message(key: String) async throws -> MailMessageFull? {
        guard MailRoute.isValidKey(key) else { throw MailError.badKey }
        return try await fetch("v1/mail/message/\(key)", as: MailMessageFull.self)
    }

    // MARK: - writes

    func markRead(key: String) async -> Bool {
        guard MailRoute.isValidKey(key) else { return false }
        return await post("v1/mail/read", ["key": key])
    }

    func markUnread(key: String) async -> Bool {
        guard MailRoute.isValidKey(key) else { return false }
        return await post("v1/mail/unread", ["key": key])
    }

    func archive(key: String) async -> Bool {
        guard MailRoute.isValidKey(key) else { return false }
        return await post("v1/mail/archive", ["key": key])
    }

    func requestDraft(key: String, instructions: String?) async -> Bool {
        guard MailRoute.isValidKey(key) else { return false }
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return await post("v1/mail/draft",
                          trimmed.isEmpty ? ["key": key] : ["key": key, "instructions": trimmed])
    }

    /// `body`, not `text`: the collector validates save-draft and send with one
    /// parser, and the field is named for the send it might become.
    func saveDraft(key: String, body: String) async -> Bool {
        guard MailRoute.isValidKey(key) else { return false }
        return await post("v1/mail/save-draft", ["key": key, "body": body])
    }

    /// Send the reply. Returns the outbox id, or nil if nothing was filed.
    ///
    /// **The one outward action in this system.** A human click reaches this
    /// function, the collector writes an outbox record, and a worker with no
    /// model in it opens the socket. The id is what the reader polls on, so nil
    /// is a real answer and not merely an error.
    ///
    /// The request carries a key and a body and nothing else. The recipient and
    /// the subject are computed server-side from the original's own headers --
    /// nothing typed in this app can redirect an outgoing email, which is the
    /// point of leaving the address out of the request entirely.
    func send(key: String, body: String) async -> String? {
        guard MailRoute.isValidKey(key) else { return nil }
        guard body.count <= MailRoute.maxSendBody else { return nil }

        do {
            let (data, response) = try await session.data(
                for: request("v1/mail/send", method: "POST", json: ["key": key, "body": body]))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // `ok` false with an id is still a refusal: the record the caller
            // would poll on is not one the collector has agreed to send.
            if let ok = doc["ok"] as? Bool, ok == false { return nil }
            return doc["id"] as? String
        } catch {
            return nil
        }
    }

    // MARK: - messages
    //
    // MESSAGES-PROTOCOL.md §5, App → collector. Same five helpers as the
    // mailbox, same guard before every URL is built: the collector answers a
    // path it does not recognise with the console's own HTML and a 200, so a
    // malformed key or date would come back as a page of markup with a success
    // code on it -- which surfaces as "the collector is broken" rather than as
    // "that is not a chat".

    func thread(chatKey: String, limit: Int, before: String?) async throws -> MessageThread? {
        guard MessageRoute.isValidKey(chatKey) else { throw MailError.badKey }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        // Only when it is a key. A cursor that is not one is a request the
        // collector would answer with the whole thread, silently.
        if let before, MessageRoute.isValidKey(before) {
            query.append(URLQueryItem(name: "before", value: before))
        }
        return try await fetch("v1/messages/thread/\(chatKey)", query: query,
                               as: MessageThread.self)
    }

    func markRead(chatKey: String) async -> Bool {
        guard MessageRoute.isValidKey(chatKey) else { return false }
        return await post("v1/messages/read", ["chat_key": chatKey])
    }

    func requestDraft(chatKey: String, instructions: String?) async -> Bool {
        guard MessageRoute.isValidKey(chatKey) else { return false }
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return await post("v1/messages/draft",
                          trimmed.isEmpty
                            ? ["chat_key": chatKey]
                            : ["chat_key": chatKey, "instructions": trimmed])
    }

    func saveDraft(chatKey: String, body: String) async -> Bool {
        guard MessageRoute.isValidKey(chatKey) else { return false }
        return await post("v1/messages/save-draft", ["chat_key": chatKey, "body": body])
    }

    func send(_ intent: MessageSendRequest) async -> MessageSubmission {
        guard MessageRoute.isValidKey(intent.chatKey), !intent.body.isEmpty,
              intent.body.count <= MessageRoute.maxSendBody else { return .refused }
        return await intent.submit { body in
            try await self.session.data(for: self.request("v1/messages/send", method: "POST", json: body))
        }
    }

    func summary(date: String) async throws -> MessageSummaryDoc? {
        guard MessageRoute.isValidDate(date) else { throw MailError.badKey }
        return try await fetch("v1/messages/summary/\(date)", as: MessageSummaryDoc.self)
    }

    func summaryRead(date: String) async -> Bool {
        guard MessageRoute.isValidDate(date) else { return false }
        return await post("v1/messages/summary/read", ["date": date])
    }

    func summaryArchive(date: String) async -> Bool {
        guard MessageRoute.isValidDate(date) else { return false }
        return await post("v1/messages/summary/archive", ["date": date])
    }

    func config() async throws -> MessagesConfig? {
        try await fetch("v1/messages/config", as: MessagesConfig.self)
    }

    func setConfig(_ config: MessagesConfig) async -> Bool {
        await post("v1/messages/config", config.json)
    }

    func chats() async -> [MessageChatSummary]? {
        await list("v1/messages/chats", key: "chats", as: MessageChatSummary.self)
    }

    /// One attachment out of the messages store. §5, App → collector.
    ///
    /// Nil covers both "not stored yet" and "could not be asked", and they are
    /// deliberately one answer here: the tile's next move is the same either
    /// way, which is to offer `fetch` and let the want route say what it
    /// thinks. Everywhere else in this app that distinction matters; on this
    /// one route it would be a second spinner for a state nobody can act on.
    func attachmentData(key: String, n: Int) async -> Data? {
        guard MessageRoute.isValidKey(key), n >= 0, n < MessageRoute.maxAttachments
        else { return nil }
        do {
            let (data, response) = try await session.data(
                for: request("v1/messages/attachment/\(key)/\(n)", accept: "*/*"))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func wantAttachment(key: String, n: Int) async -> Bool {
        guard MessageRoute.isValidKey(key), n >= 0, n < MessageRoute.maxAttachments
        else { return false }
        return await post("v1/messages/attachment/\(key)/\(n)/want")
    }

    // MARK: - attachments

    var canDownloadAttachments: Bool { true }

    func attachment(key: String, n: Int) async throws -> Data {
        guard MailRoute.isValidKey(key) else { throw MailError.badKey }
        let (data, response) = try await session.data(for: request("v1/mail/attachment/\(key)/\(n)"))
        let code = try check(response)
        guard (200..<300).contains(code) else { throw MailError.http(code) }
        return data
    }

    // MARK: - the cmo
    //
    // Neither curation call returns the new list: the caller holds an
    // optimistic copy and a later telemetry poll confirms it, so a response
    // body here would be a second source of truth for a state that already has
    // one.

    /// An empty request checks the Pi without changing its schedule.
    func featureRoutines(_ feature: ConsoleFeature, enabled: Bool? = nil) async throws -> FeatureRoutineStatus {
        let body: [String: Any] = enabled.map { ["enabled": $0] } ?? [:]
        let (data, response) = try await session.data(for: request("v1/\(feature.rawValue)/routines", method: "POST", json: body))
        let code = try check(response)
        guard code == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw NSError(domain: "FeatureRoutines", code: code, userInfo: [NSLocalizedDescriptionKey:
                code == 404 ? "Update the collector to manage feature jobs." : (message ?? "Collector returned HTTP \(code).")])
        }
        let status = try JSONDecoder().decode(FeatureRoutineStatus.self, from: data)
        guard (status.enabled != nil) != (status.retryEnabled != nil) else { throw URLError(.cannotParseResponse) }
        return status
    }

    func cmoDismiss(_ entry: Dismissal) async -> Bool {
        await post("v1/cmo/dismiss", [
            "kind": entry.kind.rawValue,
            "title": entry.title,
            // Explicitly null rather than absent: the collector stores the
            // lane it is given, and a draft has none.
            "lane": entry.lane.map { $0 as Any } ?? NSNull(),
            "date": entry.date,
        ])
    }

    func cmoRestore(_ entry: Dismissal) async -> Bool {
        // The lane is not sent: identity is kind + title + date, and a field
        // the collector ignores is one more thing that can look like it
        // matters.
        await post("v1/cmo/restore", [
            "kind": entry.kind.rawValue, "title": entry.title, "date": entry.date,
        ])
    }

    func cmoAsk(question: String, thread: String?) async -> String? {
        var body: [String: Any] = ["question": question]
        if let thread { body["thread"] = thread }
        return await mint("v1/cmo/ask", body)
    }

    func cmoThread(id: String) async throws -> CmoAskThread? {
        try await fetch("v1/cmo/ask/\(id)", as: CmoAskThread.self)
    }

    func cmoBriefing(date: String) async throws -> String? {
        try await text("v1/cmo/briefing/\(date)")
    }

    func cmoDossier(slug: String) async throws -> String? {
        try await text("v1/cmo/dossier/\(slug)")
    }

    func cmoDoc(slug: String) async throws -> String? {
        try await text("v1/cmo/doc/\(slug)")
    }

    // MARK: - chat

    func chatList() async -> [ChatThreadSummary]? {
        await list("v1/chat", key: "threads", as: ChatThreadSummary.self)
    }

    func chatThread(id: String) async throws -> ChatThread? {
        try await fetch("v1/chat/\(id)", as: ChatThread.self)
    }

    func chatNew(model: ChatModelName) async -> String? {
        await mint("v1/chat/new", ["model": model.rawValue])
    }

    func chatSend(id: String, text: String) async -> WriteResult {
        await write("v1/chat/\(id)/send", ["text": text])
    }

    func chatSetModel(id: String, model: ChatModelName) async -> WriteResult {
        await write("v1/chat/\(id)/model", ["model": model.rawValue])
    }

    func chatSetEffort(id: String, effort: JarvisEffort) async -> WriteResult {
        await write("v1/chat/\(id)/effort", ["effort": effort.rawValue])
    }

    func chatStop(id: String) async -> WriteResult {
        await write("v1/chat/\(id)/stop")
    }

    /// The one write here that is the act rather than a request for it, which
    /// is also why it is the one that can come back busy: a thread with a turn
    /// in flight has a subprocess holding it.
    func chatDelete(id: String) async -> WriteResult {
        await write("v1/chat/\(id)/delete")
    }

    /// And the one write that is allowed mid-turn, for the opposite reason: the
    /// flag is stored outside the thread file, so no subprocess owns it.
    func chatArchive(id: String, archived: Bool) async -> WriteResult {
        await write("v1/chat/\(id)/archive", ["archived": archived])
    }

    // MARK: - jarvis

    func jarvisToday() async throws -> JarvisDay? {
        try await fetch("v1/jarvis/today", as: JarvisDay.self)
    }

    func jarvisDays() async -> [JarvisDaySummary]? {
        await list("v1/jarvis/days", key: "days", as: JarvisDaySummary.self)
    }

    func jarvisDay(_ day: String) async throws -> JarvisDay? {
        try await fetch("v1/jarvis/day/\(day)", as: JarvisDay.self)
    }

    func overnightRuns(before cursor: String?) async throws -> OvernightRunPage {
        let query = cursor.map { [URLQueryItem(name: "before", value: $0)] } ?? []
        let (data, response) = try await session.data(for: request("v1/jarvis/runs", query: query))
        let code = try check(response)
        // Older collectors send the web dashboard for unknown paths, sometimes with HTTP 200.
        if cursor == nil && (code == 404 || (code == 200 && response.mimeType == "text/html")) {
            struct Jobs: Decodable { let jobs: [JarvisJob] }
            guard let list = try await fetch("v1/jarvis/jobs", as: Jobs.self) else { throw MailError.http(404) }
            return OvernightRunPage(runs: list.jobs.map(OvernightRun.legacy), nextCursor: nil, legacy: true)
        }
        guard code == 200 else { throw MailError.http(code) }
        return try MailJSON.decoder.decode(OvernightRunPage.self, from: data)
    }

    func overnightRun(id: String) async throws -> OvernightRun? {
        guard OvernightRun.validID(id) else { throw MailError.badKey }
        return try await fetch("v1/jarvis/runs/\(id)", as: OvernightRun.self)
    }

    func overnightFile(run: String, file: String) async throws -> URL? {
        guard OvernightRun.validID(run), OvernightRun.validID(file) else { throw MailError.badKey }
        let path = "v1/jarvis/runs/\(run)/files/\(file)"
        let (url, response) = try await session.download(for: request(path, accept: "application/octet-stream"))
        do {
            let code = try check(response)
            if code == 404 {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            guard code == 200 else { throw MailError.http(code) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func jarvisJobs() async -> [JarvisJob]? {
        await list("v1/jarvis/jobs", key: "jobs", as: JarvisJob.self)
    }

    func jarvisSay(text: String) async -> WriteResult {
        await write("v1/jarvis/say", ["text": text])
    }

    func jarvisStop() async -> WriteResult {
        await write("v1/jarvis/stop")
    }

    func jarvisSetModel(_ model: JarvisModelName) async -> WriteResult {
        await write("v1/jarvis/model", ["model": model.rawValue])
    }

    func jarvisSetEffort(_ effort: JarvisEffort) async -> WriteResult {
        await write("v1/jarvis/effort", ["effort": effort.rawValue])
    }

    func jarvisCompact() async -> WriteResult {
        await write("v1/jarvis/compact")
    }

    /// The work lane. Never 409s: jobs run beside the conversation under their
    /// own lock, which is the whole reason the second lane exists.
    func jarvisJob(text: String, title: String) async -> WriteResult {
        await write("v1/jarvis/job", ["text": text, "title": title])
    }

    func jarvisJobStop(id: String) async -> WriteResult {
        await write("v1/jarvis/job/\(id)/stop")
    }

    func jarvisTts(text: String) async -> Data? {
        do {
            let (data, response) = try await session.data(
                for: request("v1/jarvis/tts", method: "POST",
                             accept: "audio/wav", json: ["text": text]))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Fire and forget. Nothing reads the answer and nothing should wait on it.
    func jarvisWarmTts() {
        Task { _ = await post("v1/jarvis/tts/warm") }
    }

    // MARK: - the settings sheet's probe

    func probe() async -> ProbeResult {
        do {
            let (_, response) = try await session.data(for: request("v1/telemetry"))
            guard let http = response as? HTTPURLResponse else { return .unreachable("no response") }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            if (200..<300).contains(http.statusCode) { return .ok }
            return .unreachable("HTTP \(http.statusCode)")
        } catch {
            return .unreachable((error as NSError).localizedDescription)
        }
    }
}
