import CryptoKit
import Foundation

enum MessageDeliveryStage {
    case holding, filing, queued, sent, unknown, retryable, refused, retried

    var label: String {
        switch self {
        case .holding: return "sending"
        case .filing: return "submitting"
        case .queued: return "queued"
        case .sent: return "sent"
        case .unknown: return "delivery unknown · check Messages"
        case .retryable, .refused: return "not sent"
        case .retried: return "retry requested"
        }
    }
}

extension MessageOutboxItem {
    var deliveryStage: MessageDeliveryStage {
        switch status {
        case "queued": return .queued
        case "sent": return .sent
        case "failed" where disposition == "not_started" && retrySafe == true: return .retryable
        default: return .unknown
        }
    }
}

enum MessageSubmission: Equatable {
    case accepted(String), refused, unknown
}

struct MessageSendRequest {
    let chatKey: String
    let body: String
    var requestID = UUID()
    var retryOf: String?
    var id: String { requestID.uuidString.lowercased() }

    var payload: [String: String] {
        ["chat_key": chatKey, "body": body, "request_id": id]
    }

    @MainActor
    func submit(_ send: ([String: String]) async throws -> (Data, URLResponse)) async -> MessageSubmission {
        do {
            let (data, reply) = try await send(payload)
            return response(status: (reply as? HTTPURLResponse)?.statusCode, data: data)
        } catch {
            return .unknown
        }
    }

    func response(status: Int?, data: Data) -> MessageSubmission {
        switch status {
        case 400, 401, 403, 404, 413, 422: return .refused
        default: break
        }
        guard let status, (200..<300).contains(status),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["ok"] as? Bool == true,
              let outboxID = doc["id"] as? String, outboxID.count == 16,
              outboxID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return .unknown }
        if let echoed = doc["request_id"], echoed as? String != id { return .unknown }
        return .accepted(outboxID)
    }
}

struct MessageDeliveryRow: Identifiable, Equatable {
    var id: String
    let chatKey: String
    let text: String
    var stage: MessageDeliveryStage
    var outboxID: String?
    var receivedStatus = false
    var firstSeen = Date()

    var retryRequest: MessageSendRequest? {
        guard stage == .retryable, let outboxID, !text.isEmpty else { return nil }
        return MessageSendRequest(chatKey: chatKey, body: text,
                                  requestID: Self.retryID(chatKey: chatKey, outboxID: outboxID),
                                  retryOf: outboxID)
    }

    // Reopening the same failed row on another Mac must yield the same retry intent.
    static func retryID(chatKey: String, outboxID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("charon/messages/retry/\(chatKey)/\(outboxID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80  // UUIDv8, application-defined hash.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

struct MessageDeliveryLedger {
    private var entries: [MessageDeliveryRow] = []
    private var retried: [String: Date] = [:]
    private var matchedEvents: [String: Date] = [:]

    func rows(for chatKey: String) -> [MessageDeliveryRow] {
        entries.filter { $0.chatKey == chatKey }.map { row in
            guard row.stage == .retryable, let id = row.outboxID, retried[id] != nil else { return row }
            var result = row
            result.stage = .retried
            return result
        }
    }

    mutating func hold(_ request: MessageSendRequest) -> Bool {
        guard !entries.contains(where: { $0.id == request.id }) else { return false }
        if let parent = request.retryOf, retried[parent] != nil { return false }
        entries.append(MessageDeliveryRow(id: request.id, chatKey: request.chatKey,
                                          text: request.body, stage: .holding))
        return true
    }

    mutating func undo(_ id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.stage == .holding }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func begin(_ request: MessageSendRequest) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == request.id && $0.stage == .holding }) else { return false }
        entries[i].stage = .filing
        if let parent = request.retryOf { retried[parent] = Date() }
        return true
    }

    mutating func complete(_ request: MessageSendRequest, with result: MessageSubmission) {
        guard let i = entries.firstIndex(where: { $0.id == request.id && $0.stage == .filing }) else { return }
        switch result {
        case .accepted(let id):
            let alreadyVisible = entries.contains {
                $0.chatKey == request.chatKey && $0.outboxID == id && $0.id != request.id
            }
            if matchedEvents[id] != nil || alreadyVisible {
                // A legacy thread has no request ID and can return the receipt before the POST answers.
                entries.remove(at: i)
                return
            }
            entries[i].outboxID = id
            entries[i].stage = .queued
        case .refused: entries[i].stage = .refused
        case .unknown: entries[i].stage = .unknown
        }
    }

    mutating func reconcile(chatKey: String, outbox: [MessageOutboxItem], outboundKeys: Set<String>,
                            now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-86_400)
        entries.removeAll { $0.firstSeen < cutoff && $0.stage != .holding && $0.stage != .filing }
        retried = retried.filter { $0.value >= cutoff }
        matchedEvents = matchedEvents.filter { $0.value >= cutoff }
        let requests = Set(outbox.compactMap(\.requestID))
        for receipt in outbox where !receipt.id.isEmpty {
            if receipt.deliveryStage == .retryable,
               requests.contains(MessageDeliveryRow.retryID(chatKey: chatKey, outboxID: receipt.id)) {
                retried[receipt.id] = now
            }
            if matchedEvents[receipt.id] != nil { continue }
            let id = receipt.requestID?.uuidString.lowercased() ?? receipt.id
            let i = entries.firstIndex { $0.chatKey == chatKey && ($0.id == id || $0.outboxID == receipt.id) }
            if receipt.deliveryStage == .sent, let guid = receipt.guid,
               outboundKeys.contains(MsgKey.of(guid)) {
                matchedEvents[receipt.id] = now
                if let i { entries.remove(at: i) }
                continue
            }
            if let i {
                // The same snapshot may arrive after a newer terminal receipt.
                if receipt.deliveryStage == .queued, entries[i].receivedStatus, entries[i].stage != .queued { continue }
                entries[i].stage = receipt.deliveryStage
                entries[i].outboxID = receipt.id
                entries[i].receivedStatus = true
            } else if let body = receipt.body {
                entries.append(MessageDeliveryRow(id: id, chatKey: chatKey, text: body,
                                                  stage: receipt.deliveryStage, outboxID: receipt.id,
                                                  receivedStatus: true, firstSeen: now))
            }
        }
    }
}

enum MsgKey {
    static func of(_ guid: String) -> String {
        SHA256.hash(data: Data(guid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
