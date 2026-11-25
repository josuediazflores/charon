from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import wave

import collector
import jarvis_brief_audio as audio


class PcmResponse(io.BytesIO):
    headers = {"Content-Type": "audio/pcm"}


class BriefAudioTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state = Path(tmp.name, "state")
        cfg = collector.load_config(str(Path(tmp.name, "unused-config")))
        cfg["chat"]["base_dir"] = tmp.name
        cfg["state_dir"] = str(self.state)
        self.store = collector.Collector(cfg)
        server = ThreadingHTTPServer(("127.0.0.1", 0), collector.make_handler(self.store, "test-token"))
        self.port = server.server_port
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.date = "2020-01-01"
        brief = collector.jarvis_runs.daily_brief(self.store.jarvis_dir(), lambda *_: False, self.date)
        self.text = brief["spoken"]
        self.body = {"transcript_sha256": hashlib.sha256(self.text.encode()).hexdigest()}

    def post(self, body, authenticated=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Authorization": "Bearer test-token"} if authenticated else {}
            conn.request("POST", "/v1/jarvis/brief/" + self.date + "/audio", json.dumps(body), headers)
            resp = conn.getresponse()
            return resp.status, resp.read()
        finally:
            conn.close()

    def test_authorization_stale_and_missing_config(self):
        with patch.dict(os.environ, {"ELEVENLABS_API_KEY": "", "ELEVENLABS_VOICE_ID": ""}), \
                patch.object(audio, "synthesize") as synthesize:
            self.assertEqual(self.post(self.body, authenticated=False)[0], 401)
            with patch("collector.admit", return_value=nullcontext(False)):
                self.assertEqual(self.post(self.body)[0], 409)
            self.assertEqual(self.post({"text": "untrusted script"})[0], 400)
            self.assertEqual(self.post({"transcript_sha256": "0"*64})[0], 409)
            self.assertEqual(self.post(self.body)[0], 503)
            with patch.dict(os.environ, {"ELEVENLABS_VOICE_ID": "voice"}):
                self.assertEqual(self.post(self.body)[0], 503)
            synthesize.assert_not_called()

    def test_wire_audio_and_durable_voice_specific_cache(self):
        seen = []
        pcm = bytes(256)
        def open_request(request, timeout):
            seen.append((request, timeout))
            return PcmResponse(pcm)
        with patch.dict(os.environ, {"ELEVENLABS_API_KEY": "test-key", "ELEVENLABS_VOICE_ID": "voice",
                                     "ELEVENLABS_TTS_MODEL": "eleven_flash_v2_5"}), \
                patch("urllib.request.build_opener") as factory:
            factory.return_value.open.side_effect = open_request
            with ThreadPoolExecutor(3) as pool:
                results = list(pool.map(lambda _: self.post(self.body), range(3)))
            self.assertEqual(len(seen), 1)
            req, _ = seen[0]
            self.assertEqual(req.full_url, "https://api.elevenlabs.io/v1/text-to-speech/voice?output_format=pcm_24000")
            self.assertEqual(req.get_header("Xi-api-key"), "test-key")
            self.assertEqual(json.loads(req.data), {"text": self.text, "model_id": "eleven_flash_v2_5"})
            self.assertEqual(results, [results[0]]*3)
            status, result = results[0]
            self.assertEqual(status, 200)
            with wave.open(io.BytesIO(result), "rb") as wav:
                self.assertEqual((wav.getframerate(), wav.getsampwidth(), wav.getnchannels()), (24000,2,1))
                self.assertEqual(wav.readframes(wav.getnframes()), pcm)
            # No upstream key is needed to replay the existing voice.
            with patch.dict(os.environ, {"ELEVENLABS_API_KEY": ""}):
                self.assertEqual(self.post(self.body), results[0])
            with patch.dict(os.environ, {"ELEVENLABS_VOICE_ID": "different"}):
                self.assertEqual(self.post(self.body)[0], 200)
            self.assertEqual(len(seen), 2)
            self.assertEqual(len(list(self.state.rglob("*.wav"))), 2)

    def test_failed_provider_response_is_not_cached_or_leaked(self):
        with patch.dict(os.environ, {"ELEVENLABS_API_KEY": "test-key", "ELEVENLABS_VOICE_ID": "voice"}), \
                patch("urllib.request.build_opener") as factory:
            factory.return_value.open.side_effect = urllib.error.HTTPError(
                "hidden", 401, "test-key-must-not-leak", {}, io.BytesIO(b"private details"))
            status, body = self.post(self.body)
            self.assertEqual(status, 502)
            self.assertNotIn(b"test-key", body)
            self.assertNotIn(b"private details", body)
            self.assertEqual(list(self.state.rglob("*.wav")), [])
            factory.return_value.open.side_effect = lambda *args, **kw: PcmResponse(b"")
            self.assertEqual(self.post(self.body)[0], 502)
            error_page = PcmResponse(b"{}")
            error_page.headers = {"Content-Type": "application/json"}
            factory.return_value.open.side_effect = lambda *args, **kw: error_page
            self.assertEqual(self.post(self.body)[0], 502)
