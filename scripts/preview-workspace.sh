#!/bin/sh
# Build a separate development app without installing or replacing the release app.
set -eu
cd "$(dirname "$0")/.."
swift build
OMUX_BIN_DIR=$(swift build --show-bin-path)
OMUX_PREVIEW_APP="${1:-$PWD/build/omux Workspace.app}"
mkdir -p "$OMUX_PREVIEW_APP/Contents/MacOS" "$OMUX_PREVIEW_APP/Contents/Resources" "$OMUX_PREVIEW_APP/Contents/Frameworks"
cp "$OMUX_BIN_DIR/omux" "$OMUX_PREVIEW_APP/Contents/MacOS/omux"
cp "$OMUX_BIN_DIR/omux-session-relay" "$OMUX_PREVIEW_APP/Contents/MacOS/omux-session-relay"
cp Resources/omux.icns "$OMUX_PREVIEW_APP/Contents/Resources/omux.icns"
ditto "$OMUX_BIN_DIR/Sparkle.framework" "$OMUX_PREVIEW_APP/Contents/Frameworks/Sparkle.framework"
for resource in "$OMUX_BIN_DIR"/*.bundle; do
    if [ -d "$resource" ]; then ditto "$resource" "$OMUX_PREVIEW_APP/Contents/Resources/$(basename "$resource")"; fi
done
python3 - "$OMUX_PREVIEW_APP/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
info = plistlib.loads(Path('Info.plist').read_bytes())
name = Path(sys.argv[1]).parents[1].stem
identifier = 'net.pf1.omux.persistence.workspace-preview' if 'Persistent Workspace' in name else 'net.pf1.omux.workspace-preview'
info.update(CFBundleIdentifier=identifier, CFBundleName=name,
            CFBundleDisplayName=name, SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
# This development preview doesn't register a second Finder service or folder association.
info.pop('NSServices', None)
info.pop('CFBundleDocumentTypes', None)
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign --force --deep --sign - "$OMUX_PREVIEW_APP"
printf '\nBuilt %s\nOpen it with: open "%s"\n' "$OMUX_PREVIEW_APP" "$OMUX_PREVIEW_APP"
