"""Click-to-play ElevenLabs narration for a saved daily brief on the collector."""
import fcntl
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import wave

from jarvis_runs import RunError


FORMAT = "pcm_24000"
MAX_AUDIO_BYTES = 24 * 1024 * 1024


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        # The API key belongs to the fixed ElevenLabs host.
        return None


def synthesize(text, voice, model, key):
    url = "https://api.elevenlabs.io/v1/text-to-speech/" + urllib.parse.quote(voice, safe="")
    req = urllib.request.Request(url + "?output_format=" + FORMAT,
                                 data=json.dumps({"text": text, "model_id": model}).encode(),
                                 headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(_NoRedirects()).open(req, timeout=45) as response:
            content_type = response.headers.get("Content-Type", "").split(";")[0].lower()
            if not (content_type.startswith("audio/") or content_type == "application/octet-stream"):
                raise RunError(502, "ElevenLabs returned an unexpected response format.")
            pcm = response.read(MAX_AUDIO_BYTES + 1)
    except urllib.error.HTTPError as exc:
        exc.close()
        raise RunError(502, f"ElevenLabs refused the speech request (HTTP {exc.code}).") from exc
    except (OSError, http.client.HTTPException) as exc:
        raise RunError(502, "Could not reach ElevenLabs to generate this recording.") from exc
    if not pcm or len(pcm) % 2 or len(pcm) > MAX_AUDIO_BYTES:
        raise RunError(502, "ElevenLabs returned incomplete or oversized audio.")
    out = io.BytesIO()
    with wave.open(out, "wb") as wav:
        wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
        wav.writeframes(pcm)
    return out.getvalue()


def recording(state_dir, transcript, expected_digest):
    if hashlib.sha256(transcript.encode()).hexdigest() != expected_digest:
        raise RunError(409, "This brief has changed. Refresh it before playing.")
    if not transcript.strip():
        raise RunError(404, "This brief has no narration.")
    if len(transcript) > 4000:
        raise RunError(422, "This transcript is too long for brief narration.")
    voice = os.environ.get("ELEVENLABS_VOICE_ID", "").strip()
    if not voice:
        raise RunError(503, "Set ELEVENLABS_VOICE_ID on the Pi to enable narration.")
    model = os.environ.get("ELEVENLABS_TTS_MODEL", "").strip() or "eleven_flash_v2_5"
    version = hashlib.sha256(json.dumps([voice, model, FORMAT, expected_digest]).encode()).hexdigest()
    directory = Path(state_dir) / "jarvis-brief-audio"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (version + ".wav")
    # Two Mac windows, or reconnects after a lost response, share one synthesis.
    with (directory / (version + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            return path.read_bytes()
        except FileNotFoundError:
            pass
        key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
        if not key:
            raise RunError(503, "Set ELEVENLABS_API_KEY on the Pi to enable narration.")
        audio = synthesize(transcript, voice, model, key)
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as tmp:
            name = tmp.name
            try:
                tmp.write(audio)
                tmp.flush()
                os.fsync(tmp.fileno())
                os.replace(name, path)
            finally:
                Path(name).unlink(missing_ok=True)
        return audio
