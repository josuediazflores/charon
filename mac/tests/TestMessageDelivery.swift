import Foundation

@main
struct TestMessageDelivery {
    static func main() async throws {
        func require(_ ok: Bool, _ reason: String) {
            if !ok { print("FAIL: \(reason)"); exit(1) }
        }
        let key = "abcd0123456789ef"
        let id = "0123456789abcdef"
        let intent = MessageSendRequest(chatKey: key, body: "fixture")
        let decoder = MailJSON.decoder
        func row(_ fields: String) throws -> MessageOutboxItem {
            try decoder.decode(MessageOutboxItem.self, from: Data(("{\"id\":\""+id+"\""+fields+"}").utf8))
        }
        let incomplete = try row("")
        require(incomplete.deliveryStage == .unknown, "missing status stays unknown")
        require(try row(#","status":"failed""#).deliveryStage == .unknown, "legacy failure cannot offer retry")
        require(try row(#","status":"failed","disposition":"may_have_completed","retry_safe":true"#).deliveryStage == .unknown, "uncertain delivery cannot offer retry")
        require(try row(#","status":"failed","disposition":"not_started","retry_safe":false"#).deliveryStage != .retryable, "explicit refusal of retry")
        let failed = try row(#","status":"failed","body":"fixture","disposition":"not_started","retry_safe":true"#)
        require(failed.deliveryStage == .retryable, "proven failure can be retried")

        let oldAck = Data(#"{"ok":true,"id":"0123456789abcdef"}"#.utf8)
        require(intent.response(status: 200, data: oldAck) == .accepted(id), "old-server acknowledgement")
        require(intent.response(status: 200, data: Data("{}".utf8)) == .unknown, "incomplete success is uncertain")
        require(intent.response(status: 504, data: Data()) == .unknown, "gateway timeout is uncertain")
        require(intent.response(status: 403, data: Data()) == .refused, "server refusal before queue")
        require(intent.payload["request_id"] == intent.requestID.uuidString.lowercased(), "wire id is stable")
        var submissions = 0
        let timedOut = await intent.submit { payload in
            submissions += 1
            require(payload == intent.payload, "transport receives the intent id")
            throw URLError(.timedOut)
        }
        require(timedOut == .unknown && submissions == 1, "timeout must not replay the POST")
        let wrongAck = Data(#"{"ok":true,"id":"0123456789abcdef","request_id":"unrelated"}"#.utf8)
        require(intent.response(status: 200, data: wrongAck) == .unknown, "mismatched receipt")

        var ledger = MessageDeliveryLedger()
        require(ledger.hold(intent), "new local send is held")
        require(!ledger.hold(intent), "one timer per intent")
        require(ledger.rows(for: "different").isEmpty, "pending text stays in its chat")
        ledger.reconcile(chatKey: "different", outbox: [], outboundKeys: [])
        require(ledger.rows(for: key)[0].stage == .holding, "navigating to another thread preserves the undo window")
        require(ledger.begin(intent), "file an authorized send once")
        require(!ledger.begin(intent), "cannot file again")
        ledger.complete(intent, with: .unknown)
        require(ledger.rows(for: key).first?.stage == .unknown, "lost ack cannot be retried")
        var receipt = try row(",\"status\":\"queued\",\"request_id\":\"\(intent.id)\",\"body\":\"fixture\"")
        require(receipt.requestID == intent.requestID, "thread wire id decodes")
        ledger.reconcile(chatKey: key, outbox: [receipt], outboundKeys: [])
        require(ledger.rows(for: key).count == 1 && ledger.rows(for: key)[0].stage == .queued, "lost ack reconciles by intent")
        ledger.complete(intent, with: .unknown)
        require(ledger.rows(for: key)[0].stage == .queued, "late timeout cannot undo receipt")
        receipt.status = "sent"
        receipt.guid = "fixture-guid"
        ledger.reconcile(chatKey: key, outbox: [receipt], outboundKeys: [])
        require(ledger.rows(for: key)[0].stage == .sent, "only a sent receipt shows sent")
        ledger.reconcile(chatKey: key, outbox: [receipt], outboundKeys: [MsgKey.of("fixture-guid")])
        require(ledger.rows(for: key).isEmpty, "matching outbound event replaces receipt")

        var legacy = MessageDeliveryLedger()
        let oldRequest = MessageSendRequest(chatKey: key, body: "legacy")
        require(legacy.hold(oldRequest) && legacy.begin(oldRequest), "legacy send submitted")
        let oldReceipt = MessageOutboxItem(id: id, status: "sent", body: oldRequest.body)
        legacy.reconcile(chatKey: key, outbox: [oldReceipt], outboundKeys: [])
        legacy.complete(oldRequest, with: .accepted(id))
        require(legacy.rows(for: key).count == 1 && legacy.rows(for: key)[0].stage == .sent,
                "late legacy acknowledgement joins the already-visible server row")

        var ambiguous = MessageDeliveryLedger()
        let failedUnknown = try row(#","status":"failed","body":"legacy","disposition":"may_have_completed""#)
        ambiguous.reconcile(chatKey: key, outbox: [failedUnknown], outboundKeys: [])
        ambiguous.reconcile(chatKey: key, outbox: [MessageOutboxItem(id: id, status: "queued", body: "legacy")], outboundKeys: [])
        require(ambiguous.rows(for: key).first?.stage == .unknown, "stale queued snapshot cannot downgrade an uncertain terminal outcome")
        require(ambiguous.rows(for: key).first?.retryRequest == nil, "reopening unknown legacy receipt cannot create a retry")
        ambiguous.reconcile(chatKey: key, outbox: [], outboundKeys: [], now: Date().addingTimeInterval(86_401))
        require(ambiguous.rows(for: key).isEmpty, "expired outbox rows do not accumulate")

        var reopened = MessageDeliveryLedger()
        reopened.reconcile(chatKey: key, outbox: [failed], outboundKeys: [])
        let historical = reopened.rows(for: key)[0]
        guard let retry = historical.retryRequest else { print("FAIL: missing safe retry"); exit(1) }
        require(reopened.hold(retry) && reopened.begin(retry), "explicit retry is a new send")
        require(reopened.rows(for: key).first?.retryRequest == nil, "original row cannot submit another retry")
        var second = MessageDeliveryLedger()
        second.reconcile(chatKey: key, outbox: [failed], outboundKeys: [])
        require(second.rows(for: key)[0].retryRequest?.requestID == retry.requestID, "retry of a receipt is idempotent across reopens")
        let cancelled = MessageSendRequest(chatKey: key, body: "undo")
        require(second.hold(cancelled), "can hold second text")
        require(second.undo(cancelled.id) && !second.begin(cancelled), "undo prevents submission")
        print("PASS: delivery states, receipts, idempotent submission and manual retry")
    }
}
