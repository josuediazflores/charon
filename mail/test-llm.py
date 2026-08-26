#!/usr/bin/env python3
"""Offline tests for the provider seam. No model calls, no network, no cost.

Everything here is about the plumbing: does a tier resolve to the right model
under each provider, is the request shaped the way each API wants it, and does
every backend's failure land as the same normalised reason string. The one
thing these tests CANNOT tell you is whether a given model still honours the
fenced-output contract. That is what test-injection.py is for, and it is the
one that costs money.

    python3 test-llm.py
"""

import json
import os
import subprocess
import sys

import llm

ok = fail = 0


def check(passed, label, detail=""):
    global ok, fail
    if passed:
        ok += 1
        print(f"  ok    {label}")
    else:
        fail += 1
        print(f"  FAIL  {label}" + (f": {detail}" if detail else ""))


def env(**kw):
    """Replace exactly the CHARON_* vars, so a real secrets/env in the ambient
    environment cannot make a test pass that would fail on a clean box."""
    for key in [k for k in os.environ if k.startswith("CHARON_")]:
        del os.environ[key]
    os.environ.update({k: v for k, v in kw.items() if v is not None})


class Captured(Exception):
    """Carries the request a backend was about to make."""
    def __init__(self, args):
        self.args = args


print("1. tier resolution")
env()
check(llm.provider() == "claude-cli", "no config means claude-cli")
check(llm.model_for(llm.TIER_CHEAP) == "sonnet", "claude-cli cheap is sonnet")
check(llm.model_for(llm.TIER_GOOD) == "opus", "claude-cli good is opus")

env(CHARON_LLM_PROVIDER="anthropic-api")
check(llm.model_for(llm.TIER_CHEAP) == "claude-sonnet-5", "anthropic cheap tier")
check(llm.model_for(llm.TIER_GOOD) == "claude-opus-5", "anthropic good tier")

env(CHARON_LLM_PROVIDER="anthropic-api", CHARON_MODEL_GOOD="claude-opus-4-1")
check(llm.model_for(llm.TIER_GOOD) == "claude-opus-4-1", "an override wins")

env(CHARON_LLM_PROVIDER="openai-compat")
try:
    llm.model_for(llm.TIER_CHEAP)
    check(False, "openai-compat refuses to guess a model name")
except llm.LLMError as exc:
    check("CHARON_MODEL_CHEAP" in str(exc),
          "openai-compat refuses to guess a model name")

env(CHARON_LLM_PROVIDER="nonsense")
try:
    llm.model_for(llm.TIER_CHEAP)
    check(False, "an unknown provider is an error")
except llm.LLMError:
    check(True, "an unknown provider is an error")

env()
try:
    llm.model_for("enormous")
    check(False, "an unknown tier is an error")
except llm.LLMError:
    check(True, "an unknown tier is an error")

print("\n2. the CLI binary is resolved, not pinned")
env(CHARON_CLAUDE_BIN="/opt/somewhere/claude")
check(llm.claude_binary() == "/opt/somewhere/claude", "an explicit path wins")
env()
check(llm.claude_binary() != "" and os.path.basename(llm.claude_binary()) == "claude",
      "which() or the fallback, but always a claude", llm.claude_binary())

print("\n3. claude-cli builds the argv it always did")
env()
real_run = subprocess.run
try:
    subprocess.run = lambda *a, **k: (_ for _ in ()).throw(Captured((a, k)))
    try:
        llm.run_session("PROMPT", llm.TIER_CHEAP, 60, cwd="/tmp")
        check(False, "the cheap tier shells out")
    except Captured as cap:
        argv = cap.args[0][0]
        kw = cap.args[1]
        check("--model" in argv and argv[argv.index("--model") + 1] == "sonnet",
              "cheap tier passes --model sonnet")
        check("--effort" in argv and argv[argv.index("--effort") + 1] == "medium",
              "cheap tier passes --effort medium")
        check(argv[-2:] == ["--output-format", "json"], "asks for json output")
        check("--permission-mode" in argv
              and argv[argv.index("--permission-mode") + 1] == "dontAsk",
              "keeps dontAsk")
        check(kw.get("input") == "PROMPT", "the prompt goes in on stdin")
        check(kw.get("cwd") == "/tmp", "cwd is passed through for settings loading")
        check(kw.get("timeout") == 60, "the wall clock is passed through")
    try:
        llm.run_session("P", llm.TIER_GOOD, 60, cwd="/tmp")
    except Captured as cap:
        argv = cap.args[0][0]
        check(argv[argv.index("--model") + 1] == "opus", "good tier passes --model opus")
        check(argv[argv.index("--effort") + 1] == "high", "good tier passes --effort high")
finally:
    subprocess.run = real_run

print("\n4. claude-cli failures normalise")
env()
class P:
    def __init__(self, rc, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err

cases = [
    (P(1, err='"result":"Failed to authenticate: OAuth session expired"'),
     "auth:", "a dead OAuth session reads as auth"),
    (P(1, err="boom"), "session exited 1", "a plain non-zero exit says so"),
    (P(0, out="not json"), "not JSON", "unparseable stdout is caught"),
    (P(0, out=json.dumps({"is_error": True, "result": "nope"})),
     "nope", "is_error surfaces the message"),
    (P(0, out=json.dumps({"subtype": "success", "result": "  "})),
     "no output", "an empty answer is a failure"),
]
try:
    for proc, want, label in cases:
        subprocess.run = lambda *a, **k: proc
        text, why, model = llm.run_session("p", llm.TIER_CHEAP, 5, cwd="/tmp")
        check(text is None and why and want in why, label, f"got {why!r}")
        check(model is None, f"{label}: no model id on failure")
    subprocess.run = lambda *a, **k: P(0, out=json.dumps(
        {"subtype": "success", "result": "ANSWER"}))
    text, why, model = llm.run_session("p", llm.TIER_CHEAP, 5, cwd="/tmp")
    check(text == "ANSWER" and why is None, "a good answer comes back")
    check(model == "sonnet", "and reports the model that produced it", str(model))
finally:
    subprocess.run = real_run

print("\n5. anthropic-api request shape")
env(CHARON_LLM_PROVIDER="anthropic-api", CHARON_LLM_API_KEY="sk-test")
real_post = llm._post_json
try:
    llm._post_json = lambda *a: (_ for _ in ()).throw(Captured(a))
    try:
        llm.run_session("PROMPT", llm.TIER_GOOD, 90)
    except Captured as cap:
        url, headers, payload, timeout = cap.args
        check(url == "https://api.anthropic.com/v1/messages", "default endpoint", url)
        check(headers.get("x-api-key") == "sk-test", "key goes in x-api-key")
        check(headers.get("anthropic-version") == "2023-06-01", "version header set")
        check(payload["model"] == "claude-opus-5", "good tier model")
        check(payload["max_tokens"] == llm.MAX_TOKENS, "max_tokens set")
        check(payload["messages"] == [{"role": "user", "content": "PROMPT"}],
              "one user turn carrying the whole document")
        check(timeout == 90, "the caller's wall clock is the budget")

    llm._post_json = lambda *a: {"content": [{"type": "text", "text": "HI"}],
                                 "stop_reason": "end_turn"}
    text, why, model = llm.run_session("p", llm.TIER_CHEAP, 5)
    check(text == "HI" and why is None, "text is pulled out of the content blocks")
    check(model == "claude-sonnet-5", "reports the resolved model")

    llm._post_json = lambda *a: {"content": [{"type": "text", "text": "cut"}],
                                 "stop_reason": "max_tokens"}
    text, why, model = llm.run_session("p", llm.TIER_CHEAP, 5)
    check(text is None and "truncated" in (why or ""),
          "truncation is loud, not a short answer", str(why))
finally:
    llm._post_json = real_post

print("\n6. openai-compat request shape")
env(CHARON_LLM_PROVIDER="openai-compat", CHARON_LLM_API_KEY="sk-x",
    CHARON_LLM_BASE_URL="http://localhost:11434/v1",
    CHARON_MODEL_CHEAP="qwen2.5:7b", CHARON_MODEL_GOOD="qwen2.5:32b")
try:
    llm._post_json = lambda *a: (_ for _ in ()).throw(Captured(a))
    try:
        llm.run_session("PROMPT", llm.TIER_CHEAP, 30)
    except Captured as cap:
        url, headers, payload, _ = cap.args
        check(url == "http://localhost:11434/v1/chat/completions",
              "endpoint is base + /chat/completions", url)
        check(headers.get("authorization") == "Bearer sk-x", "bearer auth")
        check(payload["model"] == "qwen2.5:7b", "cheap tier model from env")

    llm._post_json = lambda *a: {"choices": [
        {"finish_reason": "stop", "message": {"content": "YO"}}]}
    text, why, model = llm.run_session("p", llm.TIER_GOOD, 5)
    check(text == "YO" and model == "qwen2.5:32b", "answer and model come back")

    llm._post_json = lambda *a: {"choices": [
        {"finish_reason": "length", "message": {"content": "cu"}}]}
    text, why, _ = llm.run_session("p", llm.TIER_CHEAP, 5)
    check(text is None and "truncated" in (why or ""), "length finish is loud")

    llm._post_json = lambda *a: {"error": {"message": "model not found"}}
    text, why, _ = llm.run_session("p", llm.TIER_CHEAP, 5)
    check(text is None and "model not found" in (why or ""),
          "a provider error message is surfaced", str(why))
finally:
    llm._post_json = real_post

print("\n7. missing config fails with a sentence, not a traceback")
env(CHARON_LLM_PROVIDER="openai-compat", CHARON_MODEL_CHEAP="m")
text, why, _ = llm.run_session("p", llm.TIER_CHEAP, 5)
check(text is None and "CHARON_LLM_API_KEY" in (why or ""),
      "a missing key names the variable", str(why))
env(CHARON_LLM_PROVIDER="openai-compat", CHARON_MODEL_CHEAP="m",
    CHARON_LLM_API_KEY="k")
text, why, _ = llm.run_session("p", llm.TIER_CHEAP, 5)
check(text is None and "CHARON_LLM_BASE_URL" in (why or ""),
      "a missing endpoint names the variable", str(why))

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
