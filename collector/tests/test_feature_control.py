import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import feature_control as fc


class FeaturePauseTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.enterContext(patch.object(fc, "STATE", self.root))
        self.enterContext(patch.object(fc, "CONFIG_DIR", self.root))

    def register(self, feature, **config):
        manifest = self.root / (feature + "-units.json")
        manifest.write_text(json.dumps(dict(pairs=[], **config)))
        return fc.FeatureControl(feature)

    def test_all_features_drain_and_isolate(self):
        for feature in fc.FEATURES:
            control = self.register(feature)
            with fc.admit(feature) as admitted:
                self.assertTrue(admitted)
                self.assertIsNone(control.apply(False)["enabled"])
                with fc.admit(feature) as another:
                    self.assertFalse(another)
                with fc.admit("nodes") as independent:
                    self.assertTrue(independent)
            self.assertFalse(fc.FeatureControl(feature).apply()["enabled"])
            self.assertTrue(control.apply(True)["enabled"])

    def test_pause_waits_for_each_bridge_and_current_generation(self):
        control = self.register("messages", bridges=["first", "second"])
        self.assertTrue(control.apply(False)["waitingForBridge"])
        first = control.bridge_state("first")["generation"]
        control.bridge_state("first", first)
        control.bridge_state("other", first)
        self.assertTrue(control.apply()["waitingForBridge"])
        self.assertTrue(control.apply(True)["enabled"])
        self.assertTrue(control.bridge_state("second")["enabled"])
        control.apply(False)
        generation = control.bridge_state("second", first)["generation"]
        self.assertNotEqual(first, generation)
        control.bridge_state("first", generation)
        self.assertTrue(control.apply()["waitingForBridge"])
        control.bridge_state("second", generation)
        self.assertFalse(control.apply()["enabled"])

    def test_standalone_restores_only_previously_active(self):
        control = self.register("mail", services=["ingest.service", "idle.service"])
        active = {"ingest.service"}
        def run(verb, *args):
            if verb == "show":
                if args[1] == "DropInPaths":
                    return f"/etc/systemd/system/{args[-1]}.d/{fc.guard_name('mail')}"
                return "active" if args[-1] in active else "inactive"
            if verb == "start":
                active.update(args)
            if verb == "stop":
                active.difference_update(args)
        control.run = run
        control.apply(False)
        self.assertEqual(active, set())
        control.apply(True)
        self.assertEqual(active, {"ingest.service"})

    def test_access_is_per_registered_feature(self):
        self.assertEqual(fc.feature_access(), {})
        self.register("chat").apply(False)
        self.register("mail")
        self.assertEqual(fc.feature_access(), {"chat": False, "mail": True})

    def test_unregistered_bridge_cannot_restart(self):
        control = self.register("messages", bridges=["known"])
        with self.assertRaises(RuntimeError):
            control.bridge_state("unregistered")
        self.assertTrue(control.bridge_state("KNOWN.local")["enabled"])

    def test_http_routes_and_existing_delivery_receipts(self):
        import http.client
        from http.server import ThreadingHTTPServer
        import threading
        import collector

        class Store:
            cfg = {}
            def messages_outbox_report(self, mid, report):
                return True, None, 200

        token = "feature-test-token"
        server = ThreadingHTTPServer(("127.0.0.1", 0), collector.make_handler(Store(), token))
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        def call(path, body=None, auth=None, method="POST"):
            conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            try:
                conn.request(method, path, json.dumps(body) if body is not None else None,
                             {"Authorization": "Bearer " + token} if auth is None else auth)
                response = conn.getresponse()
                return response.status, json.loads(response.read())
            finally:
                conn.close()
        for feature in fc.FEATURES:
            self.register(feature)
            path = f"/v1/{feature}/routines"
            self.assertEqual(call(path, {}, auth={})[0], 401)
            self.assertEqual(call(path, {"enabled": False}, auth={"Cookie": f"{collector.COOKIE}={token}"})[0], 401)
            self.assertEqual(call(path, {"enabled": 0})[0], 400)
            self.assertEqual(call(path, {"enabled": False}), (200, {"enabled": False}))
            for method in ["GET", "POST", "PUT"]:
                self.assertEqual(call(f"/v1/{feature}/test", method=method)[0], 409)
        self.assertEqual(call("/v1/sources/messages", method="GET")[0], 409)
        path = "/v1/messages/bridge-control"
        self.assertEqual(call(path, {"host": "test"}, auth={})[0], 401)
        self.assertFalse(call(path, {"host": "test"})[1]["enabled"])
        self.assertEqual(call("/v1/messages/outbox/0123456789abcdef", {"protocol": collector.MESSAGES_PROTOCOL, "status": "sent"})[0], 200)

    def test_mail_does_not_interrupt_a_delivery_receipt(self):
        active = {"outbox.path", "outbox.service"}
        self.register("mail")
        def run(verb, *args):
            if verb == "show":
                unit = args[-1]
                if args[1] == "DropInPaths":
                    return f"/etc/systemd/system/{unit}.d/{fc.guard_name('mail')}"
                return "active" if unit in active else "inactive"
            if verb == "stop":
                active.difference_update(args)
            if verb == "start":
                active.update(args)
        ctl = fc.FeatureControl("mail", run=run)
        ctl.manifest.write_text('[["outbox.path","outbox.service"]]')
        self.assertTrue(ctl.apply(False)["finishingWork"])
        self.assertEqual(active, {"outbox.service"})
        active.remove("outbox.service")
        self.assertFalse(ctl.apply()["enabled"])
        self.assertTrue(ctl.apply(True)["enabled"])
        self.assertEqual(active, {"outbox.path"})
