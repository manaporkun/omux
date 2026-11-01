# Native workspace

The workspace replaces the session list with a project sidebar and a grid of live SwiftTerm terminals.
Select a project to see its windows. Click terminal output or the expand button to focus a session;
All Windows (Esc) returns to the grid. The Session menu also supports previous/next session and
⌘1–⌘9. ⌘P searches projects; ⌥⌘N opens the next session needing attention across projects.

- Projects keep a stable alphabetical order, with pinned projects first. Their context menu includes
  pinning, editing, and opening a session. Status never reorders a project.
- Needs You includes blocked and errored sessions from every project, including sessions on the shelf.
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
An optional first script argument chooses a different output `.app` path.

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

## Current boundaries

This change builds the first native UI milestone. The terminal/provider lifecycle is still omux's existing
one: quitting closes the process trees and saved provider conversations can be resumed later. It does
**not** yet implement the design's persistent tmux host, restoration of scrollback after reboot, the
"while you were away" summary, or an inter-agent messaging service. Terminal input goes directly to the
provider, so there is no app-owned unsent draft to persist. These features must be implemented and
verified separately; the UI does not claim that running processes survive quitting or rebooting.
