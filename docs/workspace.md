# Native workspace

The workspace replaces the session list with a project sidebar and a grid of live SwiftTerm terminals.
Select a project to see its windows. Click terminal output to type directly in the grid; the card-name
button provides the same focus action for keyboard and accessibility users. Maximize is a separate
card button; Restore Grid returns without losing terminal focus or placement. ⇧⌘M toggles those layout
actions for the active terminal. Escape is passed to terminal applications, never used for layout.
The Session menu also supports previous/next session and ⌘1–⌘9. ⌘P searches project names;
the sidebar's **Jump to session…** (⌘K) searches sessions across projects by name, live terminal title,
effective directory, and worktree branch. Search terms can match different fields. ↑/↓ selects a
result and Return opens that result, revealing it from the shelf or another project and restoring
terminal keyboard focus after the finder closes. Escape cancels. The finder shows at most 15 results
with the total and a refinement cue; an attention-only scope is available for inbox navigation.
⌥⌘N reveals and focuses the next session needing attention across projects.

- Projects keep a stable alphabetical order, with pinned projects first. Their context menu includes
  pinning, editing, and opening a session. Status never reorders a project.
  Projects with more than eight sessions use a bounded textual total/running/attention summary instead
  of status dots, leaving the name on its own line. Smaller selected projects retain labeled dots.
- Needs you includes unread activity, blocked, errored, and interrupted sessions across projects,
  including the shelf. Its total is followed by at most four preview entries and a clickable
  **View all N** action opening the existing attention-scoped finder. Entries explain Approval,
  Question, Authentication, Error, Interrupted, or unread activity where known. Viewing an unresolved
  blocked/error/interrupted session does not remove it from the inbox.
  The preview stays bounded during bursts so project navigation remains reachable.
- Grid cards include one compact context row: worktree branch plus repository location, or the
  effective directory. Hover/accessibility details expose full paths, including the live directory
  when it differs from the checkout. The existing folder-path preference controls location display;
  relevant PR and subagent controls remain available. Branch, PR, and transcript actions target their
  own card without maximizing it; detailed review and transcripts stay in existing surfaces.
- S/M/L controls the minimum terminal window size per project. The layout chooses readable landscape
  windows; crowded projects scroll instead of becoming tiny thumbnails.
- Drag a window's header onto another window to swap their slots. The header grip shows an open-hand
  cursor and explains the gesture; a highlighted target shows “Release to swap slots.” Terminal text
  selection remains separate. No process is restarted and the active terminal stays the keyboard target.
  In filtered grids, only the two chosen slots swap in the full project order; hidden and shelved
  sessions keep their slots. Restore shelf sessions before dragging them. Order survives project
  switching and relaunch.
- Minimize moves a session to the shelf. Restore brings back the same terminal and process.
- Filter counts include matching sessions in the grid and on the shelf. The grid reports both numbers;
  the shelf shows its total and highlights matching chips without hiding unrelated sessions.
  **Restore matching** restores only matching shelf sessions and preserves the filter. Individual shelf
  chips remain available to restore any session and show All. Interrupted sessions belong to Needs you,
  not Idle; ended sessions still match Idle.
- Workspace JSON preserves the active project, maximized session, size, pinned projects, shelf, and
  window order. Older omux workspace files still load with default canvas settings.
- The sidebar reports the actual number of live local sessions; it does not estimate agent memory use.
- The accent keyboard-target indicator identifies the visible terminal used by session commands;
  orange unread and blocked/error/interrupted status remain independent. Retained selection alone
  is not a command target. Hidden or minimized targets disable session commands; Reveal in the
  Session menu explicitly restores and focuses the retained session.
- Selecting a project does not acknowledge unread activity. Acknowledgment and notification
  suppression require engagement with the relevant terminal in the active key window. Reading a
  terminal never resolves its underlying blocked, error, or interrupted state.

## Interrupt, approval inspection, and recovery

**Interrupt** stops current work without deliberately exiting the agent. Shell/Claude terminals
receive one Ctrl-C, never an automatic second exit sequence; the foreground program decides how
to handle it. Codex uses `turn/interrupt` and waits for completion events. Connecting, idle, or
disconnected Codex states explain why turn interruption is unavailable instead of killing a session.
**End Session** terminates its process tree but keeps the card. **Restart Session** explicitly replaces
its processes. Neither is a synonym for Interrupt.

The approval info control opens full, selectable available details without answering. Claude/generic
OSC summaries explicitly disclose missing command, actor, or scope information and offer **Review in
terminal**. Codex shows separate command/reason, request type, available permission context, and
root/subagent identity only when established by its owned conversation maps. Allow/Deny remain
bound to the exact displayed request and send only supported `accept`/`decline` decisions, never
broader session/policy alternatives. File-content or command omissions require terminal review.

| Action | Meaning |
|---|---|
| **Reconnect terminal** | Reattach a verified surviving hosted process without replaying a command or starting another agent. |
| **Reopen conversation** | Open saved conversation history explicitly. It does not restore the old process or automatically continue unfinished work. Claude files are checked; Codex validates its recorded conversation when reopening and fails visibly if unavailable. |
| **Run command again…** | Review the exact command and execution directory before replay. Nonstandard provider invocations also require review because they may contain work. Cancel leaves the process unchanged; changed/stale reviews are rejected. |
| **Start Claude Code / Start Codex** | Explicitly start a new agent when no saved conversation has been verified. A missing previously known Claude conversation is reported before a replacement can be requested. |
| **Open shell** | Open or focus a shell without replaying agent work or a configured command. |

Restarting a custom command also requires its command/directory review and explains that it ends
the current processes. Running/approval-waiting programs and unverified hosts are not silently
replaced through recovery. The launch summary links saved sessions whose running process was
missing or unverified; it does not infer that they were mid-task. Opening a review link only reveals
the session. Dismissing the summary does not resolve blocked/error/interrupted state.


## Development preview

```sh
sh scripts/preview-workspace.sh
open "build/omux Dev.app"
```

This always updates `build/omux Dev.app`, the single development application. Its stable bundle ID
`net.pf1.omux.persistence.workspace-preview` and existing `~/Library/Application Support/omux-persistent-workspace-preview`
folder preserve preferences and persistent sessions from the earlier persistent previews. Its automatic
updater is disabled. Nothing is installed into `/Applications` and the release app is not replaced.
Quit omux Dev before rebuilding it.

For a disposable workspace, pass `--env OMUX_WORKSPACE_DIRECTORY=/absolute/path` to `open -n`.
Debug builds support opt-in native checks with `--env OMUX_WORKSPACE_SMOKE=1`. Use only a disposable
workspace containing at least three shell sessions. The checks exercise real first-click focus,
keyboard input, Escape delivery, hidden-target command safety, unread/blocked attention, terminal/process
identity through maximize, grid, shelf, restore, filtered slot swaps, persistence, a real shelf restore
click, finder Down/Return activation, keyboard-focus handoff, and attention-only activation.
Include a second project to exercise switching away and back after reordering; give the third shell
an explicit distinct directory to exercise typed directory search. More than 15 total sessions exposes
the finder cap/refinement cue. Checks write `checks.json` and app-view snapshots into the disposable
workspace and refuse agent/custom-command fixtures.

With six or more sessions, the native checks emit real shell status records to exercise a bounded
attention burst and the View all action. A nonempty second shell project exercises shelved
cross-project overflow activation. A real worktree session exercises its compact branch action,
S/M/L context, and the folder-path preference. Session Details checks render actual hosting,
preference-change stability, mixed direct/managed quit counts, and a real shell exit; mixed-mode
checks run only when tmux and the relay are available. Relay/host and three-launch persistence
regressions remain covered by the verification commands below.


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

Right-click a card or shelf chip and choose **Session Details…** to inspect its actual hosting mode.
“Keeps running after quit” requires a verified running hosted process; “Stops when omux quits”
describes a direct process. Details retain the direct-mode reason from launch, so changing Settings
cannot relabel an existing process. Missing tmux or a missing/non-executable relay is explained with
Settings and Persistence Help routes. Unstarted, ended, interrupted, failed, and unverifiable sessions
are distinguished instead of being promised persistence. A disconnected terminal can still have a
verified running hosted process. Quit-survival does not imply survival through reboot, logout,
shutdown, or a stopped host; saved conversations are separate.


Each workspace has its own hashed tmux namespace and a separate config. User tmux configuration and
sessions are not modified. Sessions are matched by exact names, then addressed by stable tmux session
IDs and verified ownership tags. The application never issues `kill-server`.
If an exact session is missing, operations fail closed instead of matching a similarly named session.
Retained dead panes are still recognized by their exact name and ownership tag, even when tmux no
longer reports a PID; explicit recovery/Restart can replace them without touching other sessions.

- **Quit:** persistent shell, Claude Code, and Codex processes keep running. Codex's authenticated
  app-server also runs independently of the UI. Non-persistent sessions still stop.
- **Reopen:** attach to the existing terminal, restore up to 5,000 lines from tmux history, and reconnect
  to the same Codex server and exact saved conversation. No second startup command or model turn is
  submitted. Reattachment is automatic and does not require a startup preference.
- **Close / End / Restart:** operate on that session only. Restart replaces its processes and reopens
  its saved provider conversation when available; custom invocations require review. It does not stop
  another session or server.
- **Missing process / reboot:** show Interrupted for a lost recorded process and provide explicit
  recovery actions. Plain commands and agent work are never automatically replayed.
- **New terminals and projects:** open usable shells, even when the project has Claude configured.
  Showing a card, opening a folder, or restoring the workspace never starts a new agent process.
  Recovery, reviewed command replay, Restart, provider-specific creation, worktree creation, and opening
  a recent conversation are explicit launch actions. The former Auto-resume preference is removed;
  saved values are ignored.

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

The first checks the relay and real tmux reattachment, workspace isolation, targeted close, real killed
pane recovery, same-tag prefix-decoy isolation, foreign ownership protection, and server environment
transport. The opt-in Codex checks start real app-servers
with a disposable CODEX_HOME and an unreachable model endpoint: no account credentials are supplied and no
model turn is sent. They verify retained PID, endpoint, token and conversation identity, and that closing
one server does not affect another.

The native script creates its own temporary application identity, preferences and shell-only workspace,
then launches and quits the app three times. It verifies work continuing while the app is closed,
restored program status, unchanged shell PID, no repeated startup, explicit Start after a real shell
death, and explicit resume for a missing process. Reports are kept in the printed temporary workspace.
Cleanup is restricted to fixture sessions;
the installed release app and user tmux sessions are not touched.

For explicit-launch regression checks, a debug build also accepts
`OMUX_EXPLICIT_LAUNCH_SMOKE=1` with `OMUX_WORKSPACE_DIRECTORY` pointing to a disposable workspace.
Its selected project must use provider `claude` and the exact harmless command
`printf 'started\n' >> '<workspace>/explicit-starts.txt'`; tabs must inherit that command and provider.
Enable persistent sessions and launch with `-autoResume YES` to exercise the ignored legacy preference.
The checks use marker commands rather than real agents, cover existing/new project opening,
missing-process recovery and required command review, and write `explicit-launch-smoke.json` before quitting.

`OMUX_LIFECYCLE_SMOKE=1` plus a disposable `OMUX_WORKSPACE_DIRECTORY` runs focused native checks.
Use at least three empty-command shell/Claude-configured sessions, never real agents or custom
startup commands. The checks use a real Python SIGINT probe, verify exactly one interrupt and shell
usability, inspect a long OSC approval without sending decision bytes, exercise launch-summary links,
and test command-review Cancel, confirmation, and stale-review rejection. Results and view snapshots
are written beside `lifecycle-checks.json`. The provider protocol smoke
`node scripts/codex-protocol-smoke.mjs` uses an isolated real Codex server/TUI and a local test endpoint;
it does not call OpenAI or use account credentials.


## Current boundaries

A Mac reboot still stops every process; only saved agent conversations and UI state can be resumed.
Disk snapshots of terminal scrollback after a reboot, a “while you were away” summary, and inter-agent
messaging are not implemented yet. The app does not own the provider's input draft: text typed into a
live persistent terminal remains with that process, but drafts cannot be guaranteed after a reboot.
