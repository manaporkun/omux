#!/bin/sh
# Standalone checks for Command Line Tools installations without XCTest.
set -eu
cd "$(dirname "$0")/.."
swift build
OMUX_CHECK_BIN=$(swift build --show-bin-path)
OMUX_CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omux-persistence-verification.XXXXXX")
trap 'rm -rf "$OMUX_CHECK_DIR"' EXIT HUP INT TERM
"$OMUX_CHECK_BIN/omux-session-relay" --self-test
swiftc Sources/omux/PersistentSessionHost.swift scripts/verify-session-host.swift -o "$OMUX_CHECK_DIR/host-checks"
"$OMUX_CHECK_DIR/host-checks" "$OMUX_CHECK_BIN/omux-session-relay"
if [ "${OMUX_CODEX_INTEGRATION:-0}" = 1 ]; then
    swiftc Sources/omux/PersistentSessionHost.swift Sources/omux/CodexConnection.swift scripts/verify-codex-persistence.swift -o "$OMUX_CHECK_DIR/codex-checks"
    "$OMUX_CHECK_DIR/codex-checks"
fi
