#!/usr/bin/env python3
"""The only file in Charon that can reach a model.

Deploys to /home/pi/charon-mail/bin/llm.py. Imported by mail-triage.py and
messages-triage.py and by nothing else (the offline test suite aside), which
is the point: `mail-actions.py`
imports maillib, so a model caller living in maillib would put one inside the
send path's import graph. The "no model in the send path" rule is structural
rather than promised, and this file is where the structure lives. See the
repository README.

Callers ask for a TIER, not a model. A tier is a property of the job -- cheap
and high volume, or good and user-facing -- and the provider table below turns
it into whatever the configured backend calls that. `run_session` returns the
model id it actually used, so the on-disk record says what really answered
instead of repeating a literal that can drift from the one that was called.

Three backends:

    claude-cli      the Claude Code CLI as a subprocess. The default, and what
                    the Pi runs today. Unchanged behaviour.
    anthropic-api   POST /v1/messages. No CLI, no agent loop, no filesystem.
    openai-compat   POST /v1/chat/completions, which is also what OpenRouter,
                    Ollama, LM Studio, vLLM, Groq and Together speak.

The HTTP backends are tool-less by construction: a process that only holds an
HTTPS socket cannot read a file however the session goes. claude-cli is INTENDED
to be tool-less -- mail-env/settings.json carries an empty allow list, and the
worker runs the session with mail-env/ as its working directory so that file is
picked up -- but that is a settings-loading convention rather than a guarantee
this repo can enforce, so verify the wiring on your install before relying on
it. The check is cheap: give the session a prompt that asks it to read a file
and confirm it cannot. If you want the strong version, run anthropic-api or
openai-compat, where there is nothing to verify.

Stdlib only, Python 3.11. This box gets no venv.

Config is read from the environment at CALL time, never at import time. The
worker calls maillib.load_env() inside main(), which is after this module is
imported, so a constant evaluated up here would read the environment as it was
before secrets/env landed in it.
"""

import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.request

TIER_CHEAP = "cheap"   # triage batches: high volume, low stakes
TIER_GOOD = "good"     # reply drafts: low volume, the operator's own voice
TIERS = (TIER_CHEAP, TIER_GOOD)

DEFAULT_PROVIDER = "claude-cli"

# `--model x --effort y`, the two flags the CLI takes. Effort has no analogue in
# the HTTP backends and is deliberately not mapped onto anyone else's reasoning
# parameter: the good tier is user-facing prose and is the one place a wrong
# guess is visible.
CLAUDE_CLI_TIERS = {
    TIER_CHEAP: ("sonnet", "medium"),
    TIER_GOOD: ("opus", "high"),
}

ANTHROPIC_TIERS = {
    TIER_CHEAP: "claude-sonnet-5",
    TIER_GOOD: "claude-opus-5",
}

# Generous, because the failure mode of a low cap is the quiet one. A truncated
# response loses the LAST fenced block in a batch, which does not error: the
# block simply fails to match, that message burns an attempt, and the run looks
# like a model that skipped one. A cap is not a cost, only a ceiling.
MAX_TOKENS = 8192

# 429 and 5xx are worth one more try. 4xx other than 429 is not: a bad request
# or a dead key is not going to be different in four seconds.
HTTP_RETRIES = 2
HTTP_BACKOFF_S = 4


class LLMError(Exception):
    """A reason a session did not produce text. Carries the string the caller
    writes to the record, already bounded by the caller."""


# -- config -------------------------------------------------------------------

def provider():
    """The configured backend. Absent means claude-cli, so an un-edited box
    keeps running exactly what it ran before this file existed."""
    return (os.environ.get("CHARON_LLM_PROVIDER") or DEFAULT_PROVIDER).strip()


def claude_binary():
    """Where the CLI is.

    Resolved rather than pinned. The old constant hardcoded the Pi's
    ~/.local/bin/claude, which is not where it lives on a Mac, so the injection
    test could only ever run on the machine where a bad port does damage.
    """
    explicit = os.environ.get("CHARON_CLAUDE_BIN")
    if explicit:
        return explicit
    found = shutil.which("claude")
    if found:
        return found
    return os.path.expanduser("~/.local/bin/claude")


def model_for(tier):
    """The model id this tier resolves to under the configured provider."""
    if tier not in TIERS:
        raise LLMError(f"unknown tier {tier!r}")
    name = provider()
    override = os.environ.get(
        "CHARON_MODEL_CHEAP" if tier == TIER_CHEAP else "CHARON_MODEL_GOOD")
    if name == "claude-cli":
        return override or CLAUDE_CLI_TIERS[tier][0]
    if name == "anthropic-api":
        return override or ANTHROPIC_TIERS[tier]
    if name == "openai-compat":
        if not override:
            raise LLMError(
                "openai-compat needs CHARON_MODEL_CHEAP and CHARON_MODEL_GOOD "
                "set in secrets/env; there is no sensible default model name "
                "for a backend that could be any of a dozen services")
        return override
    raise LLMError(f"unknown provider {name!r}")


def _require(var, why):
    got = os.environ.get(var)
    if not got:
        raise LLMError(f"{var} is not set: {why}")
    return got


# -- the seam -----------------------------------------------------------------

def run_session(prompt, tier, timeout_s, cwd=None):
    """One tool-less completion.

    Returns (text, None, model_id) or (None, why, None). The three-tuple is the
    whole contract: callers never learn which backend answered, only what it
    said and what to write in the record.

    `cwd` matters to claude-cli alone, where the working directory is what is
    meant to make the session load mail-env/settings.json and therefore what is
    meant to make it tool-less; verify that settings wiring on your install
    rather than taking it on trust. The HTTP backends ignore `cwd`, having no
    filesystem to point at.
    """
    name = provider()
    try:
        model = model_for(tier)
        if name == "claude-cli":
            text = _claude_cli(prompt, tier, model, timeout_s, cwd)
        elif name == "anthropic-api":
            text = _anthropic_api(prompt, model, timeout_s)
        elif name == "openai-compat":
            text = _openai_compat(prompt, model, timeout_s)
        else:
            raise LLMError(f"unknown provider {name!r}")
    except LLMError as exc:
        return None, str(exc), None

    if not text.strip():
        return None, "the session produced no output", None
    return text, None, model


# -- claude-cli ---------------------------------------------------------------

# The CLI's own words for a dead credential. Normalised to an `auth:` prefix so
# the console shows the same shape whatever the backend, and so nothing
# downstream has to learn a second provider's error vocabulary.
_AUTH_MARKERS = ("oauth", "authenticate", "authentication", "401",
                 "token expired", "login expired", "session expired")


def _claude_cli(prompt, tier, model, timeout_s, cwd):
    """The CLI as a subprocess, lifted from the old mail-triage.run_session.

    --max-turns 3 rather than 1: the session has no tools it is allowed to use,
    and a model that tries one anyway needs a turn to be told no and a turn to
    answer without it.
    """
    effort = CLAUDE_CLI_TIERS[tier][1]
    cmd = [
        claude_binary(), "-p",
        "--model", model,
        "--effort", effort,
        "--max-turns", "3",
        "--permission-mode", "dontAsk",
        "--output-format", "json",
    ]
    try:
        proc = subprocess.run(
            cmd, input=prompt, cwd=cwd, env=os.environ,
            capture_output=True, text=True, timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        raise LLMError(f"the session did not finish within {timeout_s}s")
    except OSError as exc:
        raise LLMError(f"cannot start the session: {exc}")

    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-300:]
        low = tail.lower()
        if any(marker in low for marker in _AUTH_MARKERS):
            raise LLMError("auth: the CLI could not authenticate; run "
                           "`claude setup-token` and update secrets/env")
        raise LLMError(f"session exited {proc.returncode}: {tail}" if tail
                       else f"session exited {proc.returncode}")

    try:
        doc = json.loads(proc.stdout)
    except ValueError:
        raise LLMError("the session returned output that is not JSON")
    if not isinstance(doc, dict):
        raise LLMError("the session returned output that is not a JSON object")

    result = doc.get("result")
    if not isinstance(result, str):
        result = ""
    if doc.get("is_error") or doc.get("subtype") not in (None, "success"):
        raise LLMError(result.strip()[:300] or "the session reported an error")
    return result


# -- shared HTTP --------------------------------------------------------------

def _post_json(url, headers, payload, timeout_s):
    """One JSON POST, with a retry on the failures worth retrying.

    The deadline is the caller's whole budget, not per attempt: a backend that
    is slow twice must not get twice the wall clock the worker allowed for the
    job, because that wall clock is what keeps a wedged session off the queue.
    """
    deadline = time.monotonic() + timeout_s
    body = json.dumps(payload).encode()
    last = "no attempt was made"

    for attempt in range(HTTP_RETRIES + 1):
        left = deadline - time.monotonic()
        if left <= 0:
            raise LLMError(f"the session did not finish within {timeout_s}s")
        req = urllib.request.Request(url, data=body, method="POST")
        for key, value in headers.items():
            req.add_header(key, value)
        try:
            with urllib.request.urlopen(req, timeout=left) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode()[:300]
            except Exception:  # noqa: BLE001
                pass
            if exc.code in (401, 403):
                raise LLMError(f"auth: the provider rejected the credential "
                               f"({exc.code}) {detail}".strip())
            if exc.code == 429 or exc.code >= 500:
                last = f"http {exc.code}: {detail}"
                if attempt < HTTP_RETRIES:
                    time.sleep(min(HTTP_BACKOFF_S * (attempt + 1),
                                   max(0, deadline - time.monotonic())))
                    continue
                raise LLMError(last)
            raise LLMError(f"http {exc.code}: {detail}")
        except urllib.error.URLError as exc:
            last = f"cannot reach the provider: {exc.reason}"
            if attempt < HTTP_RETRIES:
                time.sleep(min(HTTP_BACKOFF_S * (attempt + 1),
                               max(0, deadline - time.monotonic())))
                continue
            raise LLMError(last)
        except ValueError:
            raise LLMError("the provider returned output that is not JSON")
    raise LLMError(last)


# -- anthropic-api ------------------------------------------------------------

def _anthropic_api(prompt, model, timeout_s):
    """POST /v1/messages.

    The whole prompt goes in as one user turn. Charon has no system/user split
    to preserve: the worker already assembles the standing instruction and the
    fenced untrusted regions into a single document, which is exactly what the
    CLI was being handed on stdin.
    """
    key = _require("CHARON_LLM_API_KEY",
                   "anthropic-api needs a key in secrets/env")
    base = (os.environ.get("CHARON_LLM_BASE_URL")
            or "https://api.anthropic.com").rstrip("/")
    doc = _post_json(
        f"{base}/v1/messages",
        {"content-type": "application/json",
         "x-api-key": key,
         "anthropic-version": "2023-06-01"},
        {"model": model, "max_tokens": MAX_TOKENS,
         "messages": [{"role": "user", "content": prompt}]},
        timeout_s,
    )
    parts = doc.get("content")
    if not isinstance(parts, list):
        raise LLMError("the provider returned no content block")
    out = "".join(p.get("text", "") for p in parts
                  if isinstance(p, dict) and p.get("type") == "text")
    if doc.get("stop_reason") == "max_tokens":
        # Loud, because this is the quiet one. A truncated batch drops its last
        # block and reads downstream as a model that skipped a message.
        raise LLMError(f"the answer hit the {MAX_TOKENS} token ceiling and was "
                       "truncated; lower BATCH_MAX or raise MAX_TOKENS")
    return out


# -- openai-compat ------------------------------------------------------------

def _openai_compat(prompt, model, timeout_s):
    """POST /v1/chat/completions, the shape a dozen services agree on."""
    key = _require("CHARON_LLM_API_KEY",
                   "openai-compat needs a key in secrets/env (use any "
                   "non-empty placeholder for a local server that wants none)")
    base = _require("CHARON_LLM_BASE_URL",
                    "openai-compat needs the endpoint, e.g. "
                    "https://api.openai.com/v1 or http://localhost:11434/v1"
                    ).rstrip("/")
    doc = _post_json(
        f"{base}/chat/completions",
        {"content-type": "application/json",
         "authorization": f"Bearer {key}"},
        {"model": model, "max_tokens": MAX_TOKENS,
         "messages": [{"role": "user", "content": prompt}]},
        timeout_s,
    )
    choices = doc.get("choices")
    if not isinstance(choices, list) or not choices:
        err = doc.get("error")
        if isinstance(err, dict) and err.get("message"):
            raise LLMError(str(err["message"])[:300])
        raise LLMError("the provider returned no choices")
    first = choices[0]
    if isinstance(first, dict) and first.get("finish_reason") == "length":
        raise LLMError(f"the answer hit the {MAX_TOKENS} token ceiling and was "
                       "truncated; lower BATCH_MAX or raise MAX_TOKENS")
    message = (first or {}).get("message") or {}
    text = message.get("content")
    if not isinstance(text, str):
        raise LLMError("the provider returned no message content")
    return text
