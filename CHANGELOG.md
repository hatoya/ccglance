# Changelog

Release notes list only what changed since the previous release.

## v1.18.0

- Permission-waiting rows now count the wait itself instead of the whole turn — the row shows how long the prompt has been open, and the work that follows an answered prompt starts again from zero. The wait is tracked explicitly with a `waitStartedAt` timestamp rather than derived from the status, because a subagent's tool events arrive under the parent's `session_id` and would otherwise rewind the timer the user is watching. Only the approved tool's own `PostToolUse` (matched on the real `tool_use_id`), a prompt that answers the wait, or the end of the turn closes it. State files written by an older hook have no `waitStartedAt`, and those rows fall back to the turn clock as before
- Re-recorded the README demo GIF with the new wait clock — the demo's permission cycle now restarts the timer at both edges of the prompt
- Removed the download-button image from the README; first install now points at either the Homebrew one-liner or the plain zip download

## v1.17.1

- Rows now switch to the waiting look while a command's permission prompt is open in the Claude Desktop app. The wait was only picked up from the `Notification` event, which the desktop app does not fire for permission prompts (CLI only), so the row stayed on the orange "Running command" spark. The hook now handles the `PermissionRequest` event as well, and `install.js` registers it — the installer runs on every app launch, so existing users get the registration from the app update alone (a Claude Code session restart is needed for `settings.json` to take effect). The hook writes nothing to stdout, so the prompt itself is untouched

## v1.17.0

- Open PRs that GitHub reports as `CONFLICTING` now show an orange forked-branch icon (a branch that never rejoined) instead of the green open — or gray draft — PR icon, with a `PR #n · conflict` tooltip. Merged, closed, and undetermined states keep their previous look, and the hook falls back to the old field set when an older `gh` rejects the new `mergeable` field
- Permission-waiting rows now show the elapsed time in white instead of the word `Waiting`; the yellow hand icon and pulsing highlight still signal the wait, and the icon gained a `Waiting for permission` tooltip. The right label stays empty when the "hide time" display option is on
- Background task rows no longer disappear when a session is resumed or compacted — `SessionStart` used to clear all agent/task rows unconditionally, so long-running background work stayed invisible for the rest of the session. Rows are now reaped from the transcript instead, and only `/clear` wipes them outright

## v1.16.1

- Background task rows (background Bash commands, `Monitor` watches, background agents) now survive turn boundaries — the work outlives the turn that launched it, but the panel used to clear every row at Stop and at the next prompt, so still-running tasks vanished. Rows that can still be reaped from the transcript are kept and only untrustworthy strays are swept; turn boundaries also scan a wider 4MB transcript window as a last chance to catch a completion notification
- Recovered rows for background Bash commands whose `PreToolUse` record was lost, dropped rows for background requests that finished synchronously, and removed rows on `TaskStop`/`KillShell` (an explicit stop produces no completion notification, so monitors and background agents now record their task/agent id for kill matching)

## v1.16.0

- New "Display" submenu in the right-click menu lets you toggle four row elements individually (all shown by default, persisted across restarts): the permission-mode text, the plan-approved check, the elapsed time (rows fall back to the status word like "Thinking…" or the tool name when hidden), and background-task child rows (subagent and background-command rows; the panel height shrinks accordingly)
- Agents resumed in the background via `SendMessage` (e.g. asking a finished review agent to re-review) now appear as running agent rows under their session — previously this path bypassed the existing detection and the resumed agent never showed on the panel
- Re-recorded the README demo GIF with the latest UI, now including the permission-mode badges (PLAN / ACCEPT / AUTO)

## v1.15.0

- The permission-mode badge is now rendered as plain colored text instead of a pill with a tinted background, removing the custom padded-label class for a lighter look that matches the rest of the row

## v1.14.0

- The permission-mode badge moved from the left of the session title into the row's right-side cluster (between the plan-approved check and the elapsed time). Session titles now start at the same left edge on every row regardless of badge width; the badge hides while hovering a row so it never overlaps the jump button

## v1.13.0

- The permission-mode badge now sits to the left of the session title ([icon][mode badge][title]) instead of next to the elapsed time on the right, so the mode is visible at a glance next to the session name. The badge also stays visible while hovering a row (the hover jump button now only replaces the time/status and plan badge)

## v1.12.0

- The plan-approved check icon now stays on the session row after the turn ends — previously it disappeared as soon as the turn finished, so a quick approval was easy to miss. The badge is cleared only when a new plan cycle starts (the session's permission mode transitions back to `plan`), surviving turn ends and session restarts

## v1.11.1

- Session renames made in claude-desktop-switcher (CSW) environments now update on the panel in real time: the app resolves each CSW profile's Desktop session store (via `profile.toml`'s `desktop_user_data_dir`, falling back to the sibling `desktop-data` directory) in addition to the default store, watches all of them with FSEvents, and re-checks the store set every minute to pick up profiles added after launch — previously renames in isolated environments only appeared at the next hook turn boundary

## v1.11.0

- Plan approval is now visible on the panel: when the user approves a plan in plan mode (`ExitPlanMode` succeeds), a green check icon appears next to the mode badge until the turn ends (tooltip "Plan approved"). Approval-pending display is unchanged (PLAN badge + yellow Waiting), and old hooks / old app versions interoperate cleanly with the new field
- Fixed the mode badge text sitting flush with the badge top: the label now draws vertically centered, so the padding above and below the text is even

## v1.10.0

- Sessions running in claude-desktop-switcher (CSW) environments isolated via `CLAUDE_CONFIG_DIR` now show up on the panel: install.js/uninstall.js register hooks into each CSW profile's `cli-data/settings.json` and `$CLAUDE_CONFIG_DIR/settings.json` as well (idempotent, existing hooks preserved with backups created on change, broken environments skipped with a warning), and the app re-runs the installer when a new profile appears (one stat on `profiles/` every 60 seconds)
- Session rows now show a small permission-mode badge next to the elapsed time: PLAN (blue) / ACCEPT (green) / AUTO (yellow) / NO ASK (orange) / BYPASS (red). The `default` mode and state files from older hooks show no badge, so only deviating modes stand out
- Session renames made in a CSW environment's Claude Desktop are now picked up: the hook resolves the environment's own Desktop store from `profile.toml`'s `desktop_user_data_dir` (falling back to the sibling `desktop-data` directory) and scans it alongside the default store
- Removed the `$ ` prefix from background shell command rows and re-recorded the README demo GIF

## v1.9.1

- Background tasks started by the `Monitor` tool (CI watches, agent-completion waits) now show up as child rows under their session — previously these were the "sometimes a background task is missing" cases. Monitor rows show a label only (description, watch condition, or program name) with no `$` prefix, and raw commands stay out of the session JSON as before
- A foreground Bash command promoted to the background mid-run (e.g. via Ctrl-B) now gets its background row too
- Monitor rows are matched by `tool_use_id`, so intermediate task notifications no longer clear them early — they disappear on the completion notification

## v1.9.0

- Bash commands run with `run_in_background: true` now get their own indented row under the session, next to the subagent rows — marked with a `$` prefix and ticking their own elapsed time (previously a background dev server or long test run was invisible). Rows without a tool description show only the program name so raw commands (where inline secrets live) never land in the session JSON or on the always-on-top panel
- Background work completion is now detected by scanning the transcript tail for the harness's `<task-notification>` blocks; as a side effect, background agent rows disappear as soon as the agent finishes instead of lingering until the end of the turn
- Re-recorded the README demo GIF to include the background command row
- Fixed the pr-screenshots upload steps in the docs so adding a new screenshot preserves the existing ones

## v1.8.1

- Fixed the panel sitting behind other windows: the window level is now assigned after `isFloatingPanel` (which was silently resetting it to `.floating`), and the front order is re-asserted on space changes so entering another app's full-screen space no longer drops the panel behind it
- A panel position saved on a disconnected external display is now clamped back into the visible area, both at launch and whenever the screen layout changes
- Running subagent rows no longer disappear: a `PostToolUse` that matches no tracked entry leaves the list untouched instead of dropping the oldest one (previously it dropped the oldest running agent, and an entry with no description could be matched by any unrelated event), background agents (the default) are no longer removed the moment their tool call returns, and a steering message sent mid-turn keeps the running rows and elapsed time
- Agents started with `run_in_background: true` now get a row as well — they were skipped entirely before. Since hooks receive no completion signal for them, those rows stay until the turn ends
- Title write-back now merges into the raw session JSON instead of re-encoding it, so fields the app does not model are preserved

## v1.8.0

- Hovering a session row now shows a jump button that focuses the session's host app (Claude Desktop via `claude://resume` without a reload, Terminal.app/iTerm2 via AppleScript down to the exact tab, VS Code-family and other GUI hosts via window activation)
- Sessions waiting for input now show a hand icon instead of the yellow dot (falls back to the dot if the bundled Font Awesome font is unavailable)
- PR status now reflects within seconds after `gh pr` / GitHub MCP operations via an immediate post-tool fetch, and idle rows with an open PR refresh every 15 seconds (backing off to 60 seconds after 30 minutes of inactivity)

## v1.7.0

- Session renames made in Claude Desktop are now detected via an FSEvents watch on the Desktop store, so the panel picks up new titles without waiting for the next hook event
- Equalized horizontal padding in the social preview image
- Added a release skill codifying the end-to-end release flow

## v1.6.0

- Panel now draws a hairline border and a reliable drop shadow
- Edge resize cursors now show up over the panel borders, and the actual resize zones match the cursor zones
- Fixed the stale Release build badge in the README
- Re-recorded the README demo GIF (smaller file) and added a record-demo-gif skill to regenerate it

## v1.5.4

- Replace release-drafter with GitHub's auto-generated release notes (categorized by PR label via `.github/release.yml`), removing the standing notes draft that could be hand-published into a broken immutable release

## v1.5.3

- Regenerate the social preview image with the new Retina demo frame and the icon wordmark as its title
- Proper release of the accidentally hand-published v1.5.3 notes draft, which went out asset-less on the drafter's placeholder tag (now deleted); publishing releases must always go through a `v*` tag push

## v1.5.2

- Re-release of v1.5.1: pushing the tag auto-published release-drafter's draft (which named the same tag) before the workflow could attach assets, leaving an immutable asset-less release
- The drafter's placeholder tag name no longer matches real release tags, so tag pushes can't publish the notes draft

## v1.5.1

Published without release assets — superseded by v1.5.2.

- Re-release of v1.5.0, which was published without its zip/sha256 assets (GitHub immutable releases reject asset uploads after publishing, which broke the publish-triggered release workflow)
- Release workflow now runs on tag push and publishes via draft → attach assets → publish, compatible with immutable releases

## v1.5.0

Published without release assets — superseded by v1.5.1.

- Auto-updater now pins the update's code signature to the Developer ID Team ID, and a SECURITY.md was added
- CHANGELOG catch-up, README badges, and a social preview image

## v1.4.0

- Homebrew support: `brew install --cask hatoya/tap/ccglance` — the tap cask is updated automatically on every release
- New sessions show a placeholder label until their title resolves, instead of a temporary random name
- Removed non-functional keyboard shortcut hints from the right-click menu
- Documentation updated for Developer ID signed and notarized releases

## v1.3.0

- Releases are now Developer ID signed and notarized, so Gatekeeper opens them without warnings
- Updates install automatically when a newer release is found
- PR status is polled every 60 seconds while sessions are idle
- Fixed subagent status not being reflected in the panel
- Refreshed README demo GIF with subagent rows and the PR badge
- Fixed a release workflow condition that prevented signing secrets from being detected

## v1.2.0

- Show awaiting-input status while Claude is waiting on a question or plan approval
- Show running subagent status in the panel
- Show PR status on the idle row icon
- The yellow attention dot is no longer shown while a session is awaiting confirmation
- Fixed the polling interval documented in the README to match the implementation (0.5s)
- Added release-drafter for automated draft release notes

## v1.1.1

- Release assets (`ccglance.zip` + `.sha256`) are now built and attached automatically by GitHub Actions when a release is published
- Higher-quality demo GIF and a larger download button in the README
- Added "Built with Claude / not affiliated" section to the README

## v1.1.0

- Release zip is now unversioned (`ccglance.zip`), so the stable link `releases/latest/download/ccglance.zip` always points to the latest version
- Right-click menu: version / update block moved to the top
- README rewritten in English, with a demo GIF, a one-click download button, and manual-update instructions
- Added CHANGELOG

## v1.0.0

Initial release.
