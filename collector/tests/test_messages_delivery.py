"""Offline delivery failure and replay tests using the real file store."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tests.test_messages_routes import (C, CHAT_A, CHAT_A_GUID, CHAT_B,
                                       CHAT_B_GUID, build, event)

REQUEST = "01234567-89ab-4cde-8fab-0123456789ab"


class MessagesDelivery(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = scratch.name
        self.collector = build(self.tmp)
        self.store = Path(self.tmp, "messages")
        self.allow({guid: {"read": True, "send": "confirm"}
                    for guid in (CHAT_A_GUID, CHAT_B_GUID)})

    def allow(self, chats):
        self.assertTrue(self.collector.messages_config_put({"chats": chats})[0])

    def ingest(self, events, cursor, history=False):
        return self.collector.messages_ingest({
            "events": events, "cursor": cursor, "backfill": history})

    def fail_write(self, path):
        write = C.write_atomic

        def write_unless_failed(target, data):
            if Path(target) == path:
                return False
            return write(target, data)

        return patch.object(C, "write_atomic", side_effect=write_unless_failed)

    def test_live_stops_at_first_fault_and_recovers_whole_batch(self):
        rows = [event(f"live-{n}", CHAT_A_GUID, "test", n) for n in (10, 11, 12)]
        with self.fail_write(self.store / "bodies" / (rows[1]["key"] + ".txt")):
            reply, _, status = self.ingest(rows, 15)
        self.assertIsNone(reply)
        self.assertEqual(status, 503)
        self.assertEqual(self.collector.messages_state()["cursor"], 10)
        self.assertIsNone(self.collector.messages_record(rows[2]["key"]))
        reply = self.ingest(rows, 15)[0]
        self.assertEqual((reply["stored"], reply["duplicates"], reply["cursor_ack"]), (2, 1, 15))
        self.assertEqual(self.collector.messages_chat_summary_doc(CHAT_A)["unread"], 3)

    def test_history_fault_replays_page_without_touching_live_cursor(self):
        self.ingest([], 500)
        rows = [event(f"old-{n}", CHAT_A_GUID, "test", n) for n in (10, 11, 12)]
        with self.fail_write(self.store / "index" / (rows[1]["key"] + ".json")):
            reply, _, status = self.ingest(rows, 15, history=True)
        self.assertIsNone(reply)
        self.assertEqual(status, 503)
        self.assertEqual(self.collector.messages_state()["cursor"], 500)
        self.assertIsNone(self.collector.messages_record(rows[2]["key"]))
        reply = self.ingest(rows, 15, history=True)[0]
        self.assertEqual((reply["stored"], reply["duplicates"]), (2, 1))
        self.assertEqual(self.collector.messages_state()["cursor"], 500)
        self.ingest(rows, 15)
        self.assertEqual(list((self.store / C.MESSAGES_QUEUE_NAME).iterdir()), [])

    def test_crash_between_record_and_triage_spool_is_repairable(self):
        row = event("inbound", CHAT_A_GUID, "test", 1)
        spool = self.store / C.MESSAGES_QUEUE_NAME / ("triage-" + row["key"])
        with self.fail_write(spool):
            reply, _, status = self.ingest([row], 1)
        self.assertIsNone(reply)
        self.assertEqual(status, 503)
        self.assertEqual(self.collector.messages_state()["cursor"], 0)
        self.collector = build(self.tmp)
        self.assertEqual(self.ingest([row], 1)[0]["duplicates"], 1)
        self.assertEqual(spool.read_text(), row["key"])
        self.assertEqual(self.collector.messages_chat_summary_doc(CHAT_A)["unread"], 1)
        (self.store / "ai" / (row["key"] + ".json")).write_text(json.dumps({"status": "ok"}))
        spool.unlink()
        self.ingest([row], 1)
        self.assertFalse(spool.exists())

    def test_cursor_state_write_fault_has_no_success_receipt(self):
        with patch.object(self.collector, "messages_write_state", return_value=False):
            reply, _, status = self.ingest([], 22)
        self.assertIsNone(reply)
        self.assertEqual(status, 503)

    def test_revoked_and_unlisted_rows_are_permanent_skips(self):
        self.allow({CHAT_A_GUID: {"read": False, "send": "confirm"}})
        for history in (False, True):
            rows = [event(f"blocked-{history}-{i}", guid, "test", i)
                    for i, guid in enumerate((CHAT_A_GUID, CHAT_B_GUID), 1)]
            reply = self.ingest(rows, 2, history)[0]
            self.assertEqual((reply["stored"], reply.get("rejected")), (0, 2))
            for row in rows:
                self.assertIsNone(self.collector.messages_record(row["key"]))
                self.assertFalse((self.store / "bodies" / (row["key"] + ".txt")).exists())

    def attachment_record(self):
        row = event("attachment-row", CHAT_A_GUID, "test", 1)
        row["attachments"] = [{"n": 0, "filename": "test.txt", "mime_type": "text/plain",
                               "total_bytes": 3, "missing": False}]
        self.assertEqual(self.ingest([row], 1)[0]["stored"], 1)
        return row["key"]

    def test_revoked_chat_cannot_start_attachment_import(self):
        key = self.attachment_record()
        self.allow({})
        staged, _, status = self.collector.messages_attachment_staging(key, 0)
        self.assertIsNone(staged)
        self.assertEqual(status, 403)
        self.assertFalse((self.store / "attachments" / key).exists())

    def test_revocation_during_upload_discards_staged_bytes_and_preserves_existing(self):
        key = self.attachment_record()

        def stage(data):
            path, why, _ = self.collector.messages_attachment_staging(key, 0)
            self.assertIsNotNone(path, why)
            Path(path).write_bytes(data)
            return (key, 0, path, len(data), hashlib.sha256(data).hexdigest(),
                    "text/plain", "test.txt", None)

        first = stage(b"one")
        self.assertTrue(self.collector.messages_attachment_store(*first)[0])
        second = stage(b"two")
        self.allow({})
        reply, _, status = self.collector.messages_attachment_store(*second)
        self.assertIsNone(reply)
        self.assertEqual(status, 403)
        self.assertFalse(Path(second[2]).exists())
        held_path = self.collector.messages_attachment_open(key, 0)[0]
        self.assertEqual(Path(held_path).read_bytes(), b"one")

    def test_unreadable_existing_allowlist_is_a_retryable_fault(self):
        (self.store / "config.json").write_text("{")
        row = event("config-fault", CHAT_A_GUID, "test", 4)
        reply, _, status = self.ingest([row], 4)
        self.assertIsNone(reply)
        self.assertEqual(status, 503)
        self.assertIsNone(self.collector.messages_record(row["key"]))

    def test_read_disabled_and_unsupported_send_policy_cannot_queue(self):
        for policy in ({"read": False, "send": "confirm"}, {"read": True, "send": "auto"}):
            with self.subTest(policy=policy):
                self.allow({CHAT_A_GUID: policy})
                self.assertEqual(self.collector.messages_send(CHAT_A, "test")[2], 403)
                self.assertEqual(self.collector.messages_outbox_queued(), [])

    def test_same_submission_recovers_across_restart_and_terminal_report(self):
        mid = self.collector.messages_send(CHAT_A, "test", REQUEST)[0]
        self.assertIsNotNone(mid)
        self.collector = build(self.tmp)
        self.assertEqual(self.collector.messages_send(CHAT_A, "test", REQUEST)[0], mid)
        self.assertEqual(self.collector.messages_send(CHAT_A, "changed", REQUEST)[2], 409)
        self.assertEqual(self.collector.messages_send(CHAT_B, "test", REQUEST)[2], 409)
        self.assertEqual(len(self.collector.messages_outbox_queued()), 1)
        report = {"status": "failed", "error": "test", "disposition": "not_started", "retry_safe": True}
        self.assertTrue(self.collector.messages_outbox_report(mid, report)[0])
        self.assertEqual(self.collector.messages_send(CHAT_A, "test", REQUEST)[0], mid)
        self.assertFalse(self.collector.messages_outbox_queued())
        row = self.collector.messages_thread_outbox(CHAT_A)[0]
        self.assertEqual((row["request_id"], row["retry_safe"]), (REQUEST, True))

    def test_queue_marker_failure_and_resubmission_create_one_send(self):
        write = C.write_atomic

        def fail_marker(path, data):
            if Path(path).parent.name == C.MESSAGES_ACTIONS_NAME:
                return False
            return write(path, data)

        with patch.object(C, "write_atomic", side_effect=fail_marker):
            self.collector.messages_send(CHAT_A, "test", REQUEST)
        records = self.collector.messages_outbox_queued()
        self.assertEqual(len(records), 1)
        mid = records[0]["id"]
        self.assertEqual(self.collector.messages_send(CHAT_A, "test", REQUEST)[0], mid)
        self.assertEqual(len(self.collector.messages_outbox_queued()), 1)

    def test_terminal_report_replay_does_not_change_audit_or_record(self):
        for report in ({"status": "sent", "guid": "outgoing-guid", "message_id": "22"},
                       {"status": "failed", "error": "reason", "disposition": "unknown", "retry_safe": False}):
            mid = self.collector.messages_send(CHAT_A, "test")[0]
            self.assertTrue(self.collector.messages_outbox_report(mid, report)[0])
            path = self.store / "outbox" / (mid + ".json")
            before = path.read_bytes(), (self.store / "audit.log").read_bytes()
            self.assertTrue(self.collector.messages_outbox_report(mid, report)[0])
            conflicting = dict(report)
            if report["status"] == "sent":
                conflicting["message_id"] = "23"
            else:
                conflicting["retry_safe"] = True
            self.assertEqual(self.collector.messages_outbox_report(mid, conflicting)[2], 409)
            self.assertEqual(before, (path.read_bytes(), (self.store / "audit.log").read_bytes()))
