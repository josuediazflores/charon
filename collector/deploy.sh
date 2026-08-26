#!/usr/bin/env bash
# Pull on the Pi and restart. Secrets and config.json are gitignored and never
# travel -- they are created once on the box by hand.
set -euo pipefail
HOST="${1:-pi@100.64.0.2}"
# Same override as mac/scripts/connect-live.sh, and the same default. Expanded
# here rather than on the Pi, so the remote shell is handed a literal.
COLLECTOR_DIR="${CHARON_COLLECTOR_DIR:-halftone-collector}"
ssh "$HOST" 'set -e
  cd ~/"'"$COLLECTOR_DIR"'"
  git pull --ff-only
  sudo systemctl restart halftone-collector
  sleep 4
  systemctl is-active halftone-collector

  # Health-check the address it actually binds, read from config.json. It is
  # not loopback -- hardcoding 127.0.0.1 here reported a false failure against
  # a perfectly healthy service.
  python3 - <<PY
import json, urllib.request, sys
cfg = json.load(open("config.json"))
url = "http://%s:%s/health" % (cfg.get("api_bind","127.0.0.1"), cfg.get("api_port",8788))
try:
    print(url, "->", urllib.request.urlopen(url, timeout=6).read().decode().strip())
except Exception as exc:
    print(url, "-> FAILED:", exc); sys.exit(1)
PY'
