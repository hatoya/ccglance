# ccglance

[![Latest release](https://img.shields.io/github/v/release/hatoya/ccglance)](https://github.com/hatoya/ccglance/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/hatoya/ccglance/total)](https://github.com/hatoya/ccglance/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B%20(arm64)-black?logo=apple)
![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11%20(x64)-0078D4)
[![Release build](https://github.com/hatoya/ccglance/actions/workflows/release.yml/badge.svg)](https://github.com/hatoya/ccglance/actions/workflows/release.yml)

A macOS and Windows app that shows Claude Code activity in an **always-on-top floating panel** instead of the menu bar. Park it in a corner of a secondary display and see at a glance which sessions are working, awaiting permission (yellow pulse), or finished.

It uses the same hooks mechanism as [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar), but shows multiple sessions at once.

<img src="docs/demo.gif" alt="ccglance demo" width="523" />

First install is one command with Homebrew, or download the zip, unzip, drag the app into Applications, and launch it once. See [Install](#install) for details (Windows: [Install on Windows](#install-on-windows)).

## Install

**Homebrew** (Apple Silicon):

```bash
brew install --cask hatoya/tap/ccglance
```

**Manual download:**

1. [Download the latest `ccglance.zip`](https://github.com/hatoya/ccglance/releases/latest/download/ccglance.zip) and unzip it.
2. Drag **ccglance.app** into Applications.

Either way, launch the app once — on first launch it wires up the Claude Code hooks automatically (appends to `~/.claude/settings.json`; existing hooks are left untouched, and a backup is saved as `settings.json.bak-ccglance`). Then start a new Claude Code session — the panel appears and tracks it.

Isolated environments created with [claude-desktop-switcher](https://matsumotory.github.io/claude-desktop-switcher/) are picked up too: the installer also registers the hooks into each profile's `cli-data/settings.json`, so their sessions show up in the panel like any other. Environments created while the app is running are wired up within a minute (their very first session may not appear; the next one will).

> **If Claude Code is already open, restart it (or start a new session) once.** Hooks are loaded when a session starts.

> Releases are Developer ID signed and notarized, so Gatekeeper runs them without any extra approval steps.

Requires an Apple Silicon Mac running macOS 12+, [Claude Code](https://claude.com/claude-code) (CLI or Desktop app), and Node.js (for the hooks script). Intel Macs are not supported by the prebuilt releases (build from source instead).

If the automatic hook setup doesn't work, run it manually:

```bash
node "/Applications/ccglance.app/Contents/Resources/install.js"
```

For a custom isolated environment (any tool that sets `CLAUDE_CONFIG_DIR`), run the same command from a shell where that variable is set — the hooks get registered into that environment's `settings.json` as well.

### Build from source

```bash
git clone https://github.com/hatoya/ccglance
cd ccglance
./build.sh
cp -R build/ccglance.app /Applications/
open /Applications/ccglance.app
```

Requires the Xcode Command Line Tools (`xcode-select --install`).

## Install on Windows

1. [Download the latest `ccglance_windows.zip`](https://github.com/hatoya/ccglance/releases/latest/download/ccglance_windows.zip) and extract it somewhere you can write to, for example `%LOCALAPPDATA%\Programs\ccglance` (the in-app updater replaces the files in place, so not `Program Files`).
2. Run `ccglance.exe`. The release is not code-signed, so SmartScreen asks once: **More info → Run anyway**.

On first launch it wires up the Claude Code hooks exactly like the macOS app (appends to `%USERPROFILE%\.claude\settings.json`, backup saved as `settings.json.bak-ccglance`) and records its own location so later sessions can launch it. Then start a new Claude Code session.

Requires Windows 10 1809+ or Windows 11 (x64), [Claude Code](https://claude.com/claude-code), and Node.js on `PATH` (for the hooks script; nvm-windows, scoop and Volta installs are found too). The translucent panel needs Windows 11 22H2 or later; earlier versions get a solid dark panel with the same layout. The [gh CLI](https://cli.github.com) is optional and enables the PR status icons.

If the automatic hook setup doesn't work, run it manually from the folder you extracted to:

```powershell
node ".\hooks\install.js"
```

Not yet on Windows: the hover button that jumps to the session's terminal window, and pinning the panel to every virtual desktop (it shows on the desktop it was launched on). `winget` and Scoop packages are planned.

### Build from source on Windows

```powershell
git clone https://github.com/hatoya/ccglance
cd ccglance
powershell -ExecutionPolicy Bypass -File windows\build.ps1 -Run
```

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download) and Node.js. The script publishes a single-file `build\windows\ccglance\ccglance.exe` and packs `build\ccglance_windows.zip` with its `.sha256`. On a Mac, `dotnet build windows/ccglance.csproj -c Release` compiles the project (no run) for a quick check.

## Window behavior

- Always on top (even above full-screen apps)
- Visible on all Spaces / all monitors — leave it parked on a secondary display
- Drag to move it anywhere; the position is remembered
- Translucent HUD design that never steals focus (clicking it won't take focus away from the app you're working in)
- No Dock icon (Windows: no taskbar button and hidden from Alt-Tab)
- Right-click menu: quit / clear finished sessions / reinstall hooks / check for updates

## How it works

Claude Code lifecycle hooks (SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / PermissionRequest / Stop / SessionEnd) write per-session state to `~/.claude/ccglance/sessions/<session_id>.json`. The app polls this directory every 0.5 seconds and renders the result.

- State files are deleted when a session ends
- Files not updated for 12 hours (crashed sessions) are cleaned up automatically
- The app is launched automatically on `SessionStart` (`open -g -a ccglance` on macOS; on Windows the hook starts the exe recorded in `~/.claude/ccglance/app-path.txt`)
- The file format both apps read is documented in [docs/session-schema.md](docs/session-schema.md)

### PR status on idle sessions

When a session goes idle, its row icon shows the pull-request state of the session's branch — open (green), draft (gray), merged (purple), or closed (red) — with a `PR #n` tooltip. An open PR that GitHub reports as conflicting turns orange instead, so PRs that need a manual merge stand out. The hook fetches this via the [gh CLI](https://cli.github.com) (`gh pr view`) in a detached child process on `Stop`/`SessionStart` and right after PR-mutating tool calls (`gh pr create/merge/…`, the GitHub MCP equivalents), so nothing blocks Claude Code and the app itself never touches the network. If `gh` isn't installed or the branch has no PR, the plain idle dot is shown instead. While a session stays idle the app keeps the state fresh on its own — every 15 seconds for the first 30 minutes after the last hook event, then every 60 seconds — so merges or closes done on GitHub show up without touching the panel; **Refresh session names** in the right-click menu forces an immediate re-fetch. Dismissing a PR chip in Claude Desktop (its `×` button) hides the icon here too — the app reads the dismissal straight from the Desktop session store it already watches for session names, so the row falls back to the plain idle dot within a couple of seconds, and stays that way until the session opens another PR.

### Supported surfaces

| Surface | Supported |
| --- | --- |
| Claude Code CLI | ✅ |
| Claude Code Desktop (Code tab) | ✅ |
| Claude Desktop (Chat) / Cowork | ❌ (no hooks support) |

Permission detection relies on the CLI's permission notification. In the Desktop app, in-app prompts don't fire the hook, so the row keeps showing the tool name instead.

## Updates

The app checks GitHub Releases for the latest version 5 seconds after launch and every 24 hours (the launch check is skipped if the last check was less than 24 hours ago). When a newer version is found:

- An orange "⬆ Update to vX.Y.Z" banner appears at the bottom of the panel
- An "Update to ccglance vX.Y.Z…" item is added to the right-click menu

Clicking either one **updates in place**: it downloads the release zip → unpacks it → replaces the running `.app` → relaunches automatically. If the download or replacement fails, it rolls back and opens the release page in your browser (same for releases without a zip asset).

On Windows the same flow downloads `ccglance_windows.zip`, verifies its SHA-256, renames the running `ccglance.exe` aside, copies the new files in and relaunches. There is no code signature to check, so keep the app in a folder you can write to.

To check manually, use "Check for updates…" in the right-click menu.

Homebrew installs update the same way — the cask is marked `auto_updates`, so plain `brew upgrade` leaves the self-updating app alone (`brew upgrade --greedy` reinstalls it from the tap if you prefer managing updates through Homebrew).

### Updating manually

If you prefer not to use the in-app updater (or it can't run, e.g. the release has no zip asset):

1. [Download the latest `ccglance.zip`](https://github.com/hatoya/ccglance/releases/latest/download/ccglance.zip) and unzip it.
2. Drag **ccglance.app** into Applications — when Finder says an item with that name already exists, choose **Replace**. No need to uninstall first.
3. Launch it once. Hooks are refreshed automatically on every launch, so there is no manual migration step.

Release procedure (for maintainers):

1. Bump `VERSION` in `build.sh` and add the version's entry to `CHANGELOG.md` — list only what changed since the previous release
2. Push a `v<VERSION>` tag (`git tag v<VERSION> && git push origin v<VERSION>`). The [release workflow](.github/workflows/release.yml) builds the app on a macOS runner and the Windows client on a Windows runner, creates a draft release with auto-generated notes (categorized by PR label via [`.github/release.yml`](.github/release.yml)), attaches `ccglance.zip`, `ccglance.zip.sha256`, `ccglance_windows.zip` and `ccglance_windows.zip.sha256`, and publishes it (each platform's pair is required by its in-app updater; if either build fails nothing is published; the workflow syncs the build version to the tag, so a missed bump still produces a correct zip)
3. Releases are immutable: assets cannot be added after publishing and a published tag can never be reused, so never publish a release by hand before the assets are attached — a broken release must be re-cut under a new version
4. The workflow then updates the [Homebrew tap](https://github.com/hatoya/homebrew-tap) cask to the new version (requires the `TAP_GITHUB_TOKEN` secret — see [docs/HOMEBREW.md](docs/HOMEBREW.md); skipped when unset)

`./build.sh` still works locally for development, and re-running the workflow via `workflow_dispatch` with the tag is the fallback if a tag push didn't produce a release. The zip name is unversioned so the `releases/latest/download/ccglance.zip` link always works. The repository to check can be changed via `UpdateChecker.repo` in `Sources/UpdateChecker.swift`.

## Uninstall

```bash
node "/Applications/ccglance.app/Contents/Resources/uninstall.js"
```

Then move the app to the Trash (or, for Homebrew installs, run `brew uninstall --cask ccglance` instead). Only ccglance's hooks are removed — from `~/.claude/settings.json` and from any claude-desktop-switcher profiles; any other hooks are left intact. If you registered the hooks into a custom `CLAUDE_CONFIG_DIR` environment, run the uninstaller from a shell where that variable is set so they get removed there too.

On Windows, quit the app from its right-click menu, run the same script from the folder you extracted to, then delete that folder and `%APPDATA%\ccglance`:

```powershell
node ".\hooks\uninstall.js"
```

## Built with Claude / not affiliated

ccglance is an unofficial, open-source side project inspired by [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar). It was built almost entirely with [Claude](https://claude.com) — from the Swift app and the hook scripts to this README and the demo GIF. It is not affiliated with, endorsed by, or sponsored by Anthropic. "Claude" is a trademark of Anthropic.

## License

MIT
