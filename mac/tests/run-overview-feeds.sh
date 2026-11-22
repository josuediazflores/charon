#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "${SWIFT_MODULECACHE_PATH:-$test_dir/modules}" \
    Sources/Console/OverviewFeedProvider.swift tests/TestOverviewFeeds.swift -o "$test_dir/tests"
"$test_dir/tests"
