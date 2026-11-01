# Native workspace

The workspace replaces the session list with a project sidebar and a grid of live SwiftTerm terminals.
Select a project to see its windows. Click terminal output or the expand button to focus a session;
All Windows (Esc) returns to the grid. The Session menu also supports previous/next session and
⌘1–⌘9. ⌘P searches projects; ⌥⌘N opens the next session needing attention across projects.

- Projects keep a stable alphabetical order, with pinned projects first. Their context menu includes
  pinning, editing, and opening a session. Status never reorders a project.
- Needs You includes blocked, errored, and interrupted sessions from every project, including sessions on the shelf.
- S/M/L controls the minimum terminal window size per project. The layout chooses readable landscape
  windows; crowded projects scroll instead of becoming tiny thumbnails.
- Drag a window's header onto another window to swap their slots. No process is restarted.
- Minimize moves a session to the shelf. Restore brings back the same terminal and process.
- The filter chips narrow the grid. The shelf remains available regardless of the active filter.
- Workspace JSON preserves the active project, maximized session, size, pinned projects, shelf, and
  window order. Older omux workspace files still load with default canvas settings.
- The sidebar reports the actual number of live local sessions; it does not estimate agent memory use.

## Development preview

```sh
sh scripts/preview-workspace.sh
open "build/omux Workspace.app"
```

This builds a separate application with bundle ID `net.pf1.omux.workspace-preview`. Its default workspace
is `~/Library/Application Support/omux-workspace-preview`, its preferences are separate, and its automatic
updater is disabled. Nothing is installed into `/Applications` and the release app is not replaced.
An optional first script argument chooses a different output `.app` path. A bundle named
`omux Persistent Workspace Preview.app` uses its own `net.pf1.omux.persistence.workspace-preview`
identity and `omux-persistent-workspace-preview` state folder, so it can coexist with the earlier UI preview.

For a disposable workspace, pass `--env OMUX_WORKSPACE_DIRECTORY=/absolute/path` to `open -n`.
Debug builds support opt-in native checks with `--env OMUX_WORKSPACE_SMOKE=1`. Use only a disposable
workspace containing at least three shell sessions and enable Auto-resume in the preview preferences.
The checks exercise real terminal/process identity through maximize, grid, shelf, restore, slot swaps,
and persistence, and write `checks.json` and app-view snapshots into the disposable workspace.
They refuse fixtures containing Claude, Codex, or custom-command providers.

The macOS 27 Command Line Tools SDK also exports a `State` macro without its compiler plugin.
`ViewState` explicitly aliases the existing SwiftUI State property wrapper to keep this app buildable
with Command Line Tools. It adds no new runtime or dependency.

## Verification

```sh
swift build
swift test
```

`WorkspaceLayoutTests` covers legacy data, conversation identity, saved layout, stale references,
landscape sizing, crowded/narrow windows, and attention/filter semantics. Running XCTest requires an
Xcode installation with XCTest; Command Line Tools alone may build the app but lack the test framework.

## Persistent sessions

Install tmux (`brew install tmux` on macOS). “Keep sessions running when omux closes” is enabled by
default and applies to new sessions. Without tmux or the bundled relay, new sessions use the existing
direct process mode with a notice explaining that quitting will stop them. A previously managed
session fails visibly if its host is unavailable; it is never silently duplicated as a new agent.

Each workspace has its own hashed tmux namespace and a separate config. User tmux configuration and
sessions are not modified. Sessions are matched by exact names, then addressed by stable tmux session
IDs and verified ownership tags. The application never issues `kill-server`.

- **Quit:** persistent shell, Claude Code, and Codex processes keep running. Codex's authenticated
  app-server also runs independently of the UI. Non-persistent sessions still stop.
- **Reopen:** attach to the existing terminal, restore up to 5,000 lines from tmux history, and reconnect
  to the same Codex server and exact saved conversation. No second startup command or model turn is
  submitted. Existing managed sessions reconnect even with Auto-resume switched off.
- **Close / Kill / Restart:** operate on that session only. Restart replaces its processes and resumes
  its saved provider conversation; it does not stop any other session or server.
- **Missing process / reboot:** show Interrupted and wait for Resume. Plain commands and agent work
  are not automatically replayed after their process disappears.

The small `omux-session-relay` executable keeps only bounded OSC 7501 program-status records in the
workspace's private session folders. It does not log terminal output or keystrokes. Directory watchers
update the UI on status changes; a single batched tmux snapshot monitors process health. Capability
queries are handled only while a live UI is attached and are not replayed after reopening.

Codex bearer tokens are stored in private session folders with owner-only files. Only their hashes
appear in server arguments. The TUI reads its token from the private file, and the server receives its
environment over stdin rather than through command arguments or generated shell scripts.

## Persistence verification without XCTest

```sh
sh scripts/verify-persistence.sh
OMUX_CODEX_INTEGRATION=1 sh scripts/verify-persistence.sh
python3 scripts/verify-native-persistence.py
```

The first checks the relay and real tmux reattachment, workspace isolation, targeted close, interrupted
process handling, and server environment transport. The opt-in Codex checks start real app-servers
with a disposable CODEX_HOME and an unreachable model endpoint: no account credentials are supplied and no
model turn is sent. They verify retained PID, endpoint, token and conversation identity, and that closing
one server does not affect another.

The native script creates its own temporary application identity, preferences and shell-only workspace,
then launches and quits the app three times. It verifies work continuing while the app is closed,
restored program status, unchanged shell PID, no repeated startup, and explicit resume for a lost
process. Reports are kept in the printed temporary workspace. Cleanup is restricted to fixture sessions;
the installed release app and user tmux sessions are not touched.

## Current boundaries

A Mac reboot still stops every process; only saved agent conversations and UI state can be resumed.
Disk snapshots of terminal scrollback after a reboot, a “while you were away” summary, and inter-agent
messaging are not implemented yet. The app does not own the provider's input draft: text typed into a
live persistent terminal remains with that process, but drafts cannot be guaranteed after a reboot.
