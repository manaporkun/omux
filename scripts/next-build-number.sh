#!/bin/sh
# Prints the next local build number, shared by ./build.sh and scripts/preview-workspace.sh so the
# installed app and omux Dev count up together. Kept in the ignored build/ folder.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
COUNTER=build/.build-number
NEXT=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$NEXT" > "$COUNTER"
echo "$NEXT"
