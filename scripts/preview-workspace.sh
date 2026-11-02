#!/bin/sh
# Build a separate development app without installing or replacing the release app.
set -eu
cd "$(dirname "$0")/.."
swift build
OMUX_BIN_DIR=$(swift build --show-bin-path)
OMUX_PREVIEW_APP="$PWD/build/omux Dev.app"
mkdir -p "$OMUX_PREVIEW_APP/Contents/MacOS" "$OMUX_PREVIEW_APP/Contents/Resources" "$OMUX_PREVIEW_APP/Contents/Frameworks"
# Replace the binaries rather than overwrite them: persistent sessions keep running
# omux-session-relay from this bundle, and rewriting a running binary in place kills it.
rm -f "$OMUX_PREVIEW_APP/Contents/MacOS/omux" "$OMUX_PREVIEW_APP/Contents/MacOS/omux-session-relay"
cp "$OMUX_BIN_DIR/omux" "$OMUX_PREVIEW_APP/Contents/MacOS/omux"
cp "$OMUX_BIN_DIR/omux-session-relay" "$OMUX_PREVIEW_APP/Contents/MacOS/omux-session-relay"
cp Resources/omux.icns "$OMUX_PREVIEW_APP/Contents/Resources/omux.icns"
ditto "$OMUX_BIN_DIR/Sparkle.framework" "$OMUX_PREVIEW_APP/Contents/Frameworks/Sparkle.framework"
for resource in "$OMUX_BIN_DIR"/*.bundle; do
    if [ -d "$resource" ]; then ditto "$resource" "$OMUX_PREVIEW_APP/Contents/Resources/$(basename "$resource")"; fi
done
OMUX_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then OMUX_COMMIT="$OMUX_COMMIT+"; fi
OMUX_BUILD=$(sh scripts/next-build-number.sh)
python3 - "$OMUX_PREVIEW_APP/Contents/Info.plist" "$OMUX_COMMIT" "$OMUX_BUILD" <<'PY'
import plistlib, sys
from pathlib import Path
info = plistlib.loads(Path('Info.plist').read_bytes())
name = Path(sys.argv[1]).parents[1].stem
# Preserve the existing persistent preview's preferences and session namespace.
identifier = 'net.pf1.omux.persistence.workspace-preview'
info.update(CFBundleIdentifier=identifier, CFBundleName=name,
            CFBundleDisplayName=name, OmuxCommit=sys.argv[2], OmuxBuild=sys.argv[3], SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
# This development preview doesn't register a second Finder service or folder association.
info.pop('NSServices', None)
info.pop('CFBundleDocumentTypes', None)
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign --force --deep --sign - "$OMUX_PREVIEW_APP"
printf '\nBuilt %s\nOpen it with: open "%s"\n' "$OMUX_PREVIEW_APP" "$OMUX_PREVIEW_APP"
