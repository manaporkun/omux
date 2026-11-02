# Building omux

```sh
./build.sh
open /Applications/omux.app
```

`build.sh` builds a release binary, assembles `build/omux.app`, and then **replaces `/Applications/omux.app`** so the Finder service and Dock entry stay registered. It signs with the first "Apple Development" certificate in your keychain, or ad hoc if there is none.

```sh
./build.sh --beta
```

builds and installs **omux Beta** next to the release app instead, with its own bundle id, preferences and workspace, so you can try a branch without touching your sessions. On its first launch it copies the release app's settings.

```sh
./build.sh --no-updates
```

installs a build that never checks for updates: Sparkle would otherwise replace a fork's build with the published release. Help › Check for Updates… is disabled in it.

Local builds (`./build.sh` and `scripts/preview-workspace.sh`) show their version, a build number and the commit at the bottom of the sidebar, e.g. `0.8.0 (14) · a920b2f`. The build number counts up on every local build, shared by the installed app and omux Dev and kept in `build/.build-number`; a `+` after the commit marks uncommitted changes.

```sh
./build.sh --dist
```

builds the release that goes on GitHub: signed with the Developer ID certificate and the hardened runtime, notarized, stapled, and packaged as `build/omux-<version>.dmg` and `.zip`. It also signs the zip for Sparkle and adds the version to `site/appcast.xml`, which goes live with the site. It needs the notarization credentials stored once with `xcrun notarytool store-credentials omux-notary`; `--no-notarize` only signs.

## Tests

```sh
swift test
```

The opt-in Codex integration checks are described in [codex.md](codex.md#checks). A GitHub Actions workflow builds and tests every pull request.
