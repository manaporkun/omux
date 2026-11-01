#!/usr/bin/env python3
"""Three real app launches with shell-only fixtures; no agents, accounts, or model calls."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix="omux-native-persistence-"))
data = root / "workspace"
data.mkdir()
app = root / "omux Persistence Checks.app"
bundle_id = "net.pf1.omux.checks." + uuid.uuid4().hex + ".workspace-preview"
tmux = shutil.which("tmux")
if not tmux:
    raise SystemExit("Install tmux before running the native persistence checks.")
namespace = "omux-" + hashlib.sha256(str(data.resolve()).encode()).hexdigest()[:16]
ids = [str(uuid.uuid4()).upper() for _ in range(3)]
group_id = str(uuid.uuid4()).upper()
fixture = {
    "groups": [{"id": group_id, "name": "Persistence checks", "directory": str(data),
                "provider": "shell", "command": "", "tabs": [
                    {"id": ident, "name": f"Test shell {index + 1}", "provider": "shell", "command": "",
                     "claudeSessionID": str(uuid.uuid4()).upper(), "autoName": False}
                    for index, ident in enumerate(ids)]}],
    "selectedTabID": ids[0],
    "canvas": {"projectID": group_id, "projects": [], "pinnedProjects": []},
}
(data / "workspace.json").write_text(json.dumps(fixture))
try:
    subprocess.run(["sh", "scripts/preview-workspace.sh", str(app)], cwd=repo, check=True)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=bundle_id, CFBundleName="omux Persistence Checks",
                CFBundleDisplayName="omux Persistence Checks")
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    for key, value in [("autoResume", "true"), ("persistentSessions", "true"),
                       ("welcomed", "true"), ("confirmQuit", "false")]:
        subprocess.run(["defaults", "write", bundle_id, key, "-bool", value], check=True)
    for phase in (1, 2, 3):
        subprocess.run(["open", "-n", "-W", "--env", "OMUX_WORKSPACE_DIRECTORY=" + str(data),
                        "--env", "OMUX_PERSISTENCE_SMOKE=" + str(phase), str(app)], check=True, timeout=40)
        result = json.loads((data / f"persistence-phase-{phase}.json").read_text())
        if not result["ok"]:
            raise RuntimeError(result.get("error", f"Phase {phase} failed"))
        print(f"PASS native application persistence phase {phase}", flush=True)
        time.sleep(1)
    for check in result["checks"]:
        print("  " + check)
    print("Verification artifacts: " + str(data))
finally:
    # Never kill a server. Only exact fixture IDs in this disposable workspace are eligible.
    rows = subprocess.run([tmux, "-L", namespace, "list-sessions", "-F",
                           "#{session_id}\t#{session_name}\t#{@omux-id}"], text=True, capture_output=True)
    for line in rows.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[2].upper() in ids and fields[1] == "omux-" + fields[2].lower():
            subprocess.run([tmux, "-L", namespace, "kill-session", "-t", fields[0]], capture_output=True)
    subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
