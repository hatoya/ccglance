# Session state file contract

`~/.claude/ccglance/sessions/<session_id>.json` is the interface between the
Claude Code hook (`hooks/ccglance-hook.js`, the writer) and every ccglance
panel (the macOS app in `Sources/`, the planned Windows app, the demo
driver in `docs/demo-sessions.js`). This document is the contract both sides
follow. When the hook and a panel disagree, the hook's `saveState()` is the
source of truth and this file must be updated.

## Compatibility rules

- Changes are additive: new fields may appear, existing fields keep their
  meaning. A missing field means an older writer, never an error.
- Readers must tolerate unknown keys.
- Any writer that patches an existing file (the macOS app does this for
  `title` and `prDismissed`) must round-trip unknown keys byte-for-byte in
  meaning: parse the raw JSON, change only its own fields, write it back.
  Re-encoding through a typed model that drops unknown fields is a bug.
- Fields marked *hook-private* below are never interpreted by a panel and
  must be preserved when patching.

## Locations

| What | macOS | Windows |
|---|---|---|
| Session files | `~/.claude/ccglance/sessions/` | `%USERPROFILE%\.claude\ccglance\sessions\` |
| Installed hook | `~/.claude/ccglance/hooks/ccglance-hook.js` | `%USERPROFILE%\.claude\ccglance\hooks\ccglance-hook.js` |
| App location hint (written by the Windows app, read by the hook) | not used | `%USERPROFILE%\.claude\ccglance\app-path.txt` |
| Claude Code settings the hook is registered in | `~/.claude/settings.json`, every `~/.context-switcher-claude/profiles/*/cli-data/settings.json` that exists, `$CLAUDE_CONFIG_DIR/settings.json` | same, with `%USERPROFILE%` |
| Claude Desktop session store (titles, PR dismissals) | `~/Library/Application Support/Claude/claude-code-sessions/` | `%APPDATA%\Claude\claude-code-sessions\` |

`~` is `$HOME` on macOS and `%USERPROFILE%` on Windows (node's
`os.homedir()`). Directories are created with mode `0o700` where the OS
honours it; on Windows the mode is ignored and the directory inherits the
user profile's ACL.

## File lifecycle

- The file name is the Claude Code `session_id`, accepted only when it matches
  `^[A-Za-z0-9_-]{1,128}$`. Anything else is ignored by the hook.
- Created on the first event for a session, rewritten in full on every event,
  deleted at `SessionEnd`. On Windows a handle held by another process can
  make that delete fail even after the hook's short retry; the 12-hour prune
  below then cleans up the ghost.
- The whole file is one minified JSON object on a single line.
- Panels delete a file whose `updatedAt` is older than 12 hours (a session
  that crashed without `SessionEnd`).
- Sibling files that are not `.json` (`<id>.json.lock`,
  `<id>.json.<pid>.tmp`, `<id>.json.lock.<pid>.stale`) are hook-private
  residue. Panels may delete them when older than 1 hour and must never parse
  them.
- A file that fails to parse is skipped for that poll, not deleted. The hook
  may be mid-write.

## Writers and concurrency

Three processes write the same file:

1. **The hook** (one process per Claude Code event) writes every field.
2. **The hook's `--fetch-pr` child** (detached, spawned by `SessionStart`,
   `Stop`, PR-mutating tool calls, and by the panel's periodic refresh) writes
   only `pr`. It deliberately leaves `updatedAt` alone so PR polling never
   extends the 12-hour prune window.
3. **The panel** patches `title` and `prDismissed` from the Claude Desktop
   store (raw JSON patch, unknown keys preserved).

Serialization: writers take `<file>.lock` (created with `O_EXCL`, content is
the writer's pid). A lock older than 5 s is considered stale and stolen; a
writer that cannot get the lock within 2 s proceeds unlocked rather than
stall Claude Code. Every write goes to `<file>.<pid>.tmp` and is renamed over
the target so readers never see a partial file.

**Windows readers must open session files with
`FileShare.ReadWrite | FileShare.Delete`.** Holding the file with the default
share mode blocks the hook's rename; the hook retries for about 100 ms and
then drops that write, so the panel would show stale state until the next
event. Antivirus and indexer handles cause the same transient failure, which
is why the retry exists.

## Fields

Timestamps are Unix seconds as JSON numbers (fractional). `null` means "known
to be empty"; an absent key means "never set by this writer version" or
"deliberately removed" as noted.

### Top level

| Field | Type | Set by | Notes |
|---|---|---|---|
| `sessionId` | string | hook, once | Equals the file name stem. Required. |
| `project` | string \| null | hook, any event carrying `cwd` | Base name of `cwd`, except inside `<project>/.claude/worktrees/<name>` where it is the base name of `<project>`. Panels group rows by this. |
| `cwd` | string \| null | hook, any event carrying `cwd` | Raw working directory from the event. Never falls back to the hook's own cwd. |
| `title` | string \| null | hook on `SessionStart` / `UserPromptSubmit` / `Stop` / `Notification`; panel from the Desktop store | Only overwritten when a title is found; never cleared by the hook. |
| `status` | `"idle"` \| `"thinking"` \| `"tool"` \| `"permission"` | hook | Required. See the transition table. |
| `tool` | string \| null | hook | Human label for the running tool: `Editing`, `Reading`, `Running command`, `Searching`, `Browsing`, `Running agent`, `Monitoring`, or `Using tool`. `null` outside `tool` status. |
| `message` | string \| null | hook | `Awaiting permission`, `Waiting for input`, `Waiting for answer`, `Awaiting plan approval`. Informational; panels currently do not render it. |
| `permissionMode` | string \| null | hook, when the event carries `permission_mode` (max 64 chars) | `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, or any future value. Forced to `null` after `ExitPlanMode` completes if still `plan`. |
| `planApprovedAt` | number \| null | hook | Set when `ExitPlanMode` completes (that event only fires on approval). Cleared only when `permissionMode` transitions into `plan`; survives `Stop` and `SessionStart`. |
| `turnStartedAt` | number \| null | hook | Start of the current turn. `null` while idle. |
| `waitStartedAt` | number \| null | hook | Start of the current prompt wait (permission or question). Panels show elapsed time from this when present, else from `turnStartedAt`. |
| `createdAt` | number | hook, once | Panels show `New session…` as the title for 30 s after this when `title` is empty. |
| `updatedAt` | number | hook (not the `--fetch-pr` child) | Bumped on every event. Required; drives the 12-hour prune. |
| `agents` | array | hook | Running subagents, newest last, at most 10. Key absent until the first agent. |
| `tasks` | array | hook | Running background commands and monitors, newest last, at most 10. Key absent until the first task. |
| `pr` | object | `--fetch-pr` child | Absent when `gh` definitively reports no PR; unchanged on transient failures. |
| `prDismissed` | string[] | panel | PR URLs dismissed in Claude Desktop, sorted, at most 32. A panel hides the PR indicator when `pr.url` is listed. |
| `host` | object | hook, on creation and every `SessionStart` | See below. |
| `env` | string | hook, alongside `host` | Name of an isolated environment (claude-desktop-switcher profile) derived from `CLAUDE_CONFIG_DIR`. Key deleted for the default environment. Recorded, not displayed. |
| `turnActive` | boolean | hook | *hook-private.* Distinguishes a steering message from a new turn. |
| `waitKey` | string \| null | hook | *hook-private.* The `message` the current wait was opened with. |
| `waitId` | string \| null | hook | *hook-private.* Correlation key of the pending prompt. |
| `pendingCalls` | object | hook | *hook-private.* Tool calls awaiting `PostToolUse`. Deleted at `SessionStart` and `Stop`. |

### `agents[]`

| Field | Type | Notes |
|---|---|---|
| `id` | string \| null | `tool_use_id` of the `Task` / `Agent` call. |
| `description` | string \| null | Trimmed to 120 characters. |
| `type` | string \| null | `subagent_type` (`Explore`, `general-purpose`, …). |
| `bg` | boolean | Background agents outlive the turn; only these survive `Stop`. |
| `startedAt` | number | |
| `agentId` | string | Only for background agents, added when the launch response reports it. Used to match `TaskStop`. |

Panel label: `description`, else `type`, else `agent`.

### `tasks[]`

| Field | Type | Notes |
|---|---|---|
| `id` | string \| null | `tool_use_id` of the `Bash` / `Monitor` call. |
| `taskId` | string \| null | Background shell id from the tool response. Rows without one are dropped at turn boundaries. |
| `description` | string \| null | Tool description, else the monitor condition, else the program name of the command with env-assignment prefixes stripped. The raw command is never stored: background commands are where inline secrets live and the panel ends up in screenshots. |
| `startedAt` | number | |
| `kind` | `"monitor"` | Monitor rows only. |
| `monitorId` | string | Monitor rows only. |
| `expiresAt` | number \| null | Monitor rows only. The hook drops the row once this passes. |

Panel label: `description`, else `monitor` for monitors, else `command`.

### `pr`

| Field | Type | Notes |
|---|---|---|
| `number` | integer | |
| `state` | `"OPEN"` \| `"MERGED"` \| `"CLOSED"` | |
| `isDraft` | boolean | |
| `mergeable` | `"MERGEABLE"` \| `"CONFLICTING"` \| `"UNKNOWN"` | Key omitted when `gh` is too old to report it; treat as unknown. |
| `url` | string | |
| `checkedAt` | number | |

The PR is whatever `gh pr view` resolves for the branch checked out in `cwd`.
No branch name is stored.

### `host`

Identity of the process tree that runs Claude Code, for the panel's
jump-to-window feature. All values are `null` when unknown.

| Field | Platform | Source |
|---|---|---|
| `bundleId` | macOS | `__CFBundleIdentifier` of the GUI ancestor (`com.apple.Terminal`, `com.googlecode.iterm2`, `com.anthropic.claudefordesktop`, …). |
| `termProgram` | both | `TERM_PROGRAM` (`Apple_Terminal`, `iTerm.app`, `vscode`, `tmux`, …). |
| `itermSessionId` | macOS | `ITERM_SESSION_ID`, format `w0t2p0:<UUID>`. |
| `tty` | macOS | `/dev/ttysNNN`, captured only for Terminal.app outside tmux. |
| `wtSessionId` | Windows | `WT_SESSION` (Windows Terminal). Key present only on Windows. |
| `wtProfileId` | Windows | `WT_PROFILE_ID`. Key present only on Windows. |
| `winSessionName` | Windows | `SESSIONNAME`. Key present only on Windows. |

The Windows keys are recorded for a future jump feature; no panel uses them
yet.

## Event to state transitions

| Event | `status` | Other fields |
|---|---|---|
| `SessionStart` | `idle` | `tool`, `turnStartedAt` cleared; `turnActive` false; wait cleared; `pendingCalls` deleted; `host`/`env` re-captured; agents and tasks kept unless `source` is `clear`. Launches the app and a `--fetch-pr`. |
| `UserPromptSubmit` | `thinking` | New turn: `turnStartedAt` set, `turnActive` true, `tool`/`message` cleared. A prompt while a turn is active is a steering message and keeps the turn. |
| `PreToolUse` | `tool` (or `permission` for `AskUserQuestion` / `ExitPlanMode`) | `tool` label set; `turnStartedAt` set if missing; agent/task rows pushed for `Task`/`Agent`/background `Bash`/`Monitor`. |
| `PermissionRequest` | `permission` | `message` = `Awaiting permission`; `waitStartedAt` set. |
| `Notification` | `permission` | `message` = `Awaiting permission` or `Waiting for input`; `waitStartedAt` set. |
| `PostToolUse` | `thinking` | `tool`/`message` cleared; wait ended; sync agent row removed; task id attached; `planApprovedAt` set for `ExitPlanMode`. PR-mutating tools trigger a `--fetch-pr`. |
| `Stop` | `idle` | `tool`, `message`, `turnStartedAt` cleared; `turnActive` false; wait cleared; `pendingCalls` deleted; only background rows kept. Triggers a `--fetch-pr`. |
| `SessionEnd` | — | File deleted. |
| anything else | unchanged | `updatedAt` refreshed if the file exists. |

## Rendering rules panels agree on

- Order: sessions whose `status` is not `idle` first, then by `project`
  (ordinal). Group by `project`, using an em dash for a missing project;
  groups sorted case-insensitively.
- Elapsed time: `thinking`/`tool` count from `turnStartedAt`; `permission`
  counts from `waitStartedAt`, falling back to `turnStartedAt`.
- Title: `title`, else `New session…` for 30 s after `createdAt`, else
  `Session ` + the first 8 characters of `sessionId`.
- Child rows: `agents` first, then `tasks`, in array order.
- PR indicator only on idle rows, hidden when `pr.url` is in `prDismissed`.
- A panel that wants a fresh PR status runs
  `node <hook> --fetch-pr <sessionId> <cwd>` itself rather than calling `gh`.

## Launching the app from the hook

`SessionStart` launches the panel so it appears without the user starting it.

- macOS: `open -g -a ccglance` (background launch by name).
- Windows: the hook resolves the executable in this order and spawns it
  detached and hidden: `CCGLANCE_EXE`, the path in
  `~/.claude/ccglance/app-path.txt`, `%LOCALAPPDATA%\Programs\ccglance\ccglance.exe`,
  `%USERPROFILE%\scoop\apps\ccglance\current\ccglance.exe`. The Windows app
  writes its own absolute path to `app-path.txt` (UTF-8, one line) at every
  start; a relative path or one not ending in `.exe` is ignored.

Requirements on the executable: it must be single-instance (a second launch
exits or hands over) and must show its window without activating it, because
the hook fires while the user is typing in Claude Code. It is launched
without `windowsHide`, so it may show its window normally; it must not rely
on the launcher's `STARTUPINFO` show state.

## Examples

A session in the middle of a tool call, with one background agent:

```json
{"sessionId":"3f1c9a0e-2b7d-4e5a-9c1f-0d8b7a6e5f4c","project":"ccglance","title":"Windows support","cwd":"/Users/me/ccglance","status":"tool","tool":"Running command","message":null,"permissionMode":"acceptEdits","planApprovedAt":1788000100.2,"turnStartedAt":1788000300.5,"waitStartedAt":null,"createdAt":1787999000.1,"updatedAt":1788000312.8,"host":{"bundleId":"com.apple.Terminal","termProgram":"Apple_Terminal","itermSessionId":null,"tty":"/dev/ttys004"},"turnActive":true,"waitKey":null,"waitId":null,"pendingCalls":{"Bash":["id:toolu_01ABC"]},"agents":[{"id":"toolu_01AGENT","description":"Map build, CI, docs, release","type":"Explore","bg":true,"startedAt":1788000305.0,"agentId":"a1877f1992f87bec6"}]}
```

An idle session on Windows with an open PR:

```json
{"sessionId":"9b2d4c6e-8f0a-4b1c-a3d5-e7f9a1b3c5d7","project":"demo","title":null,"cwd":"C:\\Users\\me\\demo","status":"idle","tool":null,"message":null,"permissionMode":"default","planApprovedAt":null,"turnStartedAt":null,"waitStartedAt":null,"createdAt":1788001000.0,"updatedAt":1788001900.4,"host":{"bundleId":null,"termProgram":null,"itermSessionId":null,"tty":null,"wtSessionId":"7c1e2f3a-4b5c-6d7e-8f90-a1b2c3d4e5f6","wtProfileId":"{61c54bbd-c2c6-5271-96e7-009a87ff44bf}","winSessionName":"Console"},"turnActive":false,"waitKey":null,"waitId":null,"pr":{"number":42,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","url":"https://github.com/me/demo/pull/42","checkedAt":1788001905.1}}
```
