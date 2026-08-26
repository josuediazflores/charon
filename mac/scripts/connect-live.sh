#!/bin/bash
# Wires the Halftone app to the live collector. Run it yourself: it moves the
# API token from the Pi into the login Keychain, and the token is never
# printed. Safe to re-run.
#
# Override any of the three for your own install:
#   CHARON_PI=pi@100.64.0.2  CHARON_BASE=http://100.64.0.2:8788  ./connect-live.sh

set -u
PI="${CHARON_PI:-pi@100.64.0.2}"                     # your Pi over Tailscale
BASE="${CHARON_BASE:-http://100.64.0.2:8788}"
COLLECTOR_DIR="${CHARON_COLLECTOR_DIR:-halftone-collector}"  # under the Pi user's home
SERVICE=com.example.charon.collector

TOKEN=$(ssh -o ConnectTimeout=8 "$PI" \
  "grep '^COLLECTOR_API_TOKEN' \"\$HOME/$COLLECTOR_DIR/.env\" | cut -d= -f2-" \
  | tr -d '"' | tr -d '[:space:]')
if [ ${#TOKEN} -lt 24 ]; then
  echo "FAIL: token fetch (got ${#TOKEN} chars): ssh or grep problem"; exit 1
fi
echo "ok: token fetched (${#TOKEN} chars)"

if ! security add-generic-password -U -A -s "$SERVICE" -a bearer -w "$TOKEN"; then
  echo "FAIL: keychain write"; exit 1
fi
security find-generic-password -s "$SERVICE" -a bearer >/dev/null 2>&1 \
  && echo "ok: keychain entry present" \
  || { echo "FAIL: keychain read-back"; exit 1; }

code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "$BASE/v1/telemetry")
[ "$code" = "200" ] && echo "ok: collector accepts the token (HTTP 200)" \
  || { echo "FAIL: collector said HTTP $code"; exit 1; }

defaults write com.example.charon mode live
defaults write com.example.charon baseURL "$BASE"
echo "ok: app set to live mode"

# The repo's own DerivedData, which is what xcodebuild here produces. The
# Xcode-default path under ~/Library holds whatever Xcode last built, which
# goes stale the moment builds happen on the command line.
APP="$(cd "$(dirname "$0")/.." && pwd)/DerivedData/Build/Products/Debug/Charon.app"
if [ ! -d "$APP" ]; then
  echo "FAIL: no build at $APP. Build it first (xcodebuild -project HalftoneMail.xcodeproj -scheme HalftoneMail -configuration Debug -derivedDataPath DerivedData build)"
  exit 1
fi

pkill -x Charon 2>/dev/null; sleep 1
open "$APP"
echo "ok: app relaunched, it should be live"
