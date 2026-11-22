#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "${SWIFT_MODULECACHE_PATH:-$test_dir/modules}" \
    Sources/Console/CustomWidgetData.swift Sources/Console/OverviewLayout.swift tests/TestOverviewLayout.swift -o "$test_dir/tests"
mkdir -p "$test_dir/Library/Preferences"
CFFIXED_USER_HOME="$test_dir" "$test_dir/tests"
