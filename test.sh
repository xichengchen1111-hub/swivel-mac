#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Swift Testing ships with Swift 6; XCTest is absent in some Command Line Tools installations.
# Explicitly load its bundled macro plugin to handle incremental Swift Build module emission.
SWIVEL_SWIFT_BIN="$(dirname "$(xcrun --find swift)")"
SWIVEL_TEST_PLUGIN="$SWIVEL_SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
SWIVEL_TEST_ARGS=(--disable-xctest)
if [[ -f "$SWIVEL_TEST_PLUGIN" ]]; then
    SWIVEL_TEST_ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$SWIVEL_TEST_PLUGIN")
fi
swift test "${SWIVEL_TEST_ARGS[@]}" "$@"
