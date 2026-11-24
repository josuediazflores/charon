#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "${SWIFT_MODULECACHE_PATH:-$test_dir/modules}" \
    Sources/Models.swift Sources/CmoModels.swift Sources/Jarvis/OvernightRun.swift \
    tests/TestOvernightRuns.swift -o "$test_dir/tests"
"$test_dir/tests"
