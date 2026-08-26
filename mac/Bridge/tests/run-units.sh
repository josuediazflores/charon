#!/bin/bash
# The pure half of the Bridge, compiled on its own and run: framing, records,
# keys, the name chain, a history's page arithmetic, the allowlist decision. No
# Xcode target, no test runner -- these four files have no dependencies beyond
# Foundation and CryptoKit, and keeping the check that cheap is the reason they
# were separated out.
#
#   Bridge/tests/run-units.sh

set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out=$(mktemp -d /tmp/charon-bridge-units.XXXXXX)

xcrun swiftc -swift-version 5 -warnings-as-errors -o "$out/units" \
  "$root/JSONValue.swift" "$root/Frame.swift" "$root/Records.swift" \
  "$here/Assertions.swift" || { echo "FAIL: the units would not compile"; exit 1; }

"$out/units"
result=$?
rm -rf "$out"
exit $result
