#!/usr/bin/env node
// ccglance hook — receives Claude Code lifecycle events on stdin and writes
// per-session state to ~/.claude/ccglance/sessions/<session_id>.json
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile, execSync, spawn } = require("child_process");

const SESSIONS_DIR = path.join(os.homedir(), ".claude", "ccglance", "sessions");

const TOOL_LABELS = {
  Edit: "Editing",
  Write: "Editing",
  MultiEdit: "Editing",
  NotebookEdit: "Editing",
  Read: "Reading",
  Bash: "Running command",
  Grep: "Searching",
  Glob: "Searching",
  WebFetch: "Browsing",
  WebSearch: "Browsing",
  Task: "Running agent",
  Agent: "Running agent",
  Monitor: "Monitoring",
};

// Subagent-spawning tools ("Task" classically, "Agent" in newer builds)
const AGENT_TOOLS = new Set(["Task", "Agent"]);
// Tools that stop a background command ("KillShell" classically, "TaskStop"
// in newer builds)
const KILL_TOOLS = new Set(["TaskStop", "KillShell", "KillTask"]);
const MAX_AGENTS = 10;
const MAX_TASKS = 10;

// Tools that pause and wait for the user to respond
const INPUT_TOOLS = {
  AskUserQuestion: "Waiting for answer",
  ExitPlanMode: "Awaiting plan approval",
};

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (data += c));
    process.stdin.on("end", () => resolve(data));
    // Safety: don't hang Claude Code if stdin never closes
    setTimeout(() => resolve(data), 3000);
  });
}

function stateFile(sessionId) {
  return path.join(SESSIONS_DIR, `${sessionId}.json`);
}

function loadState(sessionId) {
  try {
    return JSON.parse(fs.readFileSync(stateFile(sessionId), "utf8"));
  } catch {
    return null;
  }
}

function saveState(state) {
  fs.mkdirSync(SESSIONS_DIR, { recursive: true, mode: 0o700 });
  const file = stateFile(state.sessionId);
  // pid in the tmp name: a detached --fetch-pr child and a hook event can
  // write the same session concurrently; a shared tmp path would corrupt it
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state));
  fs.renameSync(tmp, file);
}

// Each hook event runs as a separate process, and tool events from a running
// subagent share the parent's session_id — so concurrent load-modify-save on
// the same session file loses updates (e.g. three agents launched in parallel
// recording only one). A per-session lock file serializes writers. A crashed
// holder's lock goes stale and is stolen; if the lock can't be acquired within
// LOCK_WAIT_MS we proceed unlocked rather than stall Claude Code.
const LOCK_STALE_MS = 5000;
const LOCK_WAIT_MS = 2000;

let heldLock = null;
process.on("exit", () => {
  if (!heldLock) return;
  // Only unlink a lock that is still ours — after LOCK_STALE_MS it may have
  // been stolen and re-created by another hook process
  try {
    if (fs.readFileSync(heldLock, "utf8") === String(process.pid)) {
      fs.unlinkSync(heldLock);
    }
  } catch {}
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function acquireLock(sessionId) {
  try {
    fs.mkdirSync(SESSIONS_DIR, { recursive: true, mode: 0o700 });
  } catch {
    return;
  }
  const lock = `${stateFile(sessionId)}.lock`;
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    try {
      const fd = fs.openSync(lock, "wx");
      fs.writeSync(fd, String(process.pid));
      fs.closeSync(fd);
      heldLock = lock;
      return;
    } catch (e) {
      // Anything but "already locked" (EACCES, ENOSPC, …) won't heal by
      // retrying — proceed unlocked instead of busy-looping
      if (e.code !== "EEXIST") return;
      try {
        if (Date.now() - fs.statSync(lock).mtimeMs > LOCK_STALE_MS) {
          // Steal via rename: two thieves both unlinking could remove the
          // fresh lock the faster one just re-created
          const grave = `${lock}.${process.pid}.stale`;
          fs.renameSync(lock, grave);
          fs.unlinkSync(grave);
          continue;
        }
      } catch {
        continue; // lock vanished (or lost the steal race) — retry immediately
      }
      await sleep(15 + Math.floor(Math.random() * 30));
    }
  }
  // Deadline passed — proceed unlocked rather than stall Claude Code
}

// Desktop session title: the name shown/edited in the Claude Desktop app is NOT
// written to the transcript. It lives in the Desktop app's own store:
//   ~/Library/Application Support/Claude/claude-code-sessions/<ws>/<x>/local_<id>.json
// with fields { title, cliSessionId } — cliSessionId matches the hook's
// session_id. (See anthropics/claude-code#64304 for the on-disk analysis.)
// Isolated environments (claude-desktop-switcher) give the Desktop app its own
// user-data dir, so titles edited there never land in the default store. The
// hook runs inside the environment, so CLAUDE_CONFIG_DIR (the profile's
// cli-data dir) locates the sibling profile.toml, whose desktop_user_data_dir
// records where that store lives.
function desktopStoreRoots() {
  const roots = [
    path.join(os.homedir(), "Library", "Application Support", "Claude", "claude-code-sessions"),
  ];
  const dir = process.env.CLAUDE_CONFIG_DIR;
  if (typeof dir === "string" && dir.trim()) {
    const resolved = path.resolve(dir.trim());
    if (resolved === path.join(os.homedir(), ".claude")) return roots;
    const profileDir = path.dirname(resolved);
    let dataDir = null;
    try {
      const toml = fs.readFileSync(path.join(profileDir, "profile.toml"), "utf8");
      const m = toml.match(/^\s*desktop_user_data_dir\s*=\s*"([^"]+)"/m);
      if (m) {
        let v = m[1];
        if (v.startsWith("~/")) v = path.join(os.homedir(), v.slice(2));
        if (!path.isAbsolute(v)) v = path.join(profileDir, v);
        // A stale/bad value must fall through to the sibling guess below
        if (fs.existsSync(v)) dataDir = v;
      }
    } catch {}
    if (!dataDir) {
      const fallback = path.join(profileDir, "desktop-data");
      if (fs.existsSync(fallback)) dataDir = fallback;
    }
    if (dataDir) {
      const root = path.join(dataDir, "claude-code-sessions");
      if (!roots.includes(root)) roots.push(root);
    }
  }
  return roots;
}

function desktopTitle(sessionId) {
  let best = null; // { title, mtime }
  function walk(dir, depth) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (depth < 4) walk(p, depth + 1);
      } else if (e.isFile() && e.name.endsWith(".json")) {
        let j;
        try {
          j = JSON.parse(fs.readFileSync(p, "utf8"));
        } catch {
          continue;
        }
        const ids = [j.cliSessionId, j.sessionId, j.id].filter(Boolean);
        const bridged = Array.isArray(j.bridgeSessionIds) ? j.bridgeSessionIds : [];
        if (!ids.includes(sessionId) && !bridged.includes(sessionId)) continue;
        const t = cleanLabel(j.title);
        if (t) {
          const mtime = fs.statSync(p).mtimeMs;
          if (!best || mtime > best.mtime) best = { title: t, mtime };
        }
      }
    }
  }
  for (const root of desktopStoreRoots()) walk(root, 0);
  return best ? best.title : null;
}

// Transcript fallback (CLI sessions / SDK renames): custom title entries and
// {"type":"summary","summary":"..."} lines appended to the session jsonl.
function sessionTitle(transcriptPath) {
  if (!transcriptPath) return null;
  try {
    const st = fs.statSync(transcriptPath);
    const CHUNK = 256 * 1024;
    let data;
    if (st.size <= 2 * CHUNK) {
      data = fs.readFileSync(transcriptPath, "utf8");
    } else {
      const fd = fs.openSync(transcriptPath, "r");
      const head = Buffer.alloc(CHUNK);
      const tail = Buffer.alloc(CHUNK);
      fs.readSync(fd, head, 0, CHUNK, 0);
      fs.readSync(fd, tail, 0, CHUNK, st.size - CHUNK);
      fs.closeSync(fd);
      data = head.toString("utf8") + "\n" + tail.toString("utf8");
    }
    let custom = null;
    let summary = null;
    for (const line of data.split("\n")) {
      if (!line.includes('"summary"') && !/title/i.test(line)) continue;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue; // truncated line at a chunk boundary
      }
      const t =
        obj.customTitle ||
        obj.custom_title ||
        (typeof obj.type === "string" && /title/i.test(obj.type)
          ? obj.title || obj.name
          : null);
      if (typeof t === "string" && t.trim()) custom = t.trim();
      if (obj.type === "summary" && typeof obj.summary === "string" && obj.summary.trim()) {
        summary = obj.summary.trim(); // last one wins
      }
    }
    return custom || summary || null;
  } catch {
    return null;
  }
}

// Project name from cwd. Claude Code Desktop runs sessions inside worktrees
// (<project>/.claude/worktrees/<worktree-name>), so basename(cwd) would give
// the worktree name (e.g. "intelligent-babbage") instead of the project
// ("momiji"). Strip the worktree suffix and use the real project directory.
function projectFromCwd(cwd) {
  const m = cwd.match(/^(.*?)[\/\\]\.claude[\/\\]worktrees(?:[\/\\]|$)/);
  if (m && m[1]) return path.basename(m[1]);
  return path.basename(cwd);
}

// Host identity for the panel's jump-to-session button. Env vars are free;
// the ps call is only needed for Terminal.app tab matching (its AppleScript
// identifies tabs by tty), so it runs only in that case — and never under
// tmux, where the claude process's tty is the tmux pane pty, useless for
// matching a Terminal tab. process.ppid is the claude process holding the tty.
function captureHost() {
  const env = process.env;
  const host = {
    bundleId: env.__CFBundleIdentifier || null,
    termProgram: env.TERM_PROGRAM || null,
    itermSessionId: env.ITERM_SESSION_ID || null,
    tty: null,
  };
  if (host.bundleId === "com.apple.Terminal" && host.termProgram !== "tmux") {
    try {
      const t = execSync(`ps -o tty= -p ${process.ppid}`, { timeout: 1000 })
        .toString()
        .trim();
      if (t && t !== "??") host.tty = "/dev/" + t;
    } catch {}
  }
  return host;
}

// Isolated-environment name for the panel's group header. claude-desktop-switcher
// (and similar tools) point Claude Code at a separate config dir via
// CLAUDE_CONFIG_DIR; the default environment carries no name at all.
function envName() {
  const dir = process.env.CLAUDE_CONFIG_DIR;
  if (typeof dir !== "string" || !dir.trim()) return null;
  const resolved = path.resolve(dir.trim());
  if (resolved === path.join(os.homedir(), ".claude")) return null;
  const m = resolved.match(/[\/\\]\.context-switcher-claude[\/\\]profiles[\/\\]([^\/\\]+)[\/\\]cli-data[\/\\]?$/);
  if (m) return cleanLabel(m[1]);
  const base = path.basename(resolved);
  return cleanLabel(base === "cli-data" ? path.basename(path.dirname(resolved)) : base);
}

// Running-subagent tracking: PreToolUse on an agent tool pushes an entry.
// PostToolUse removes the matching one — but only for synchronous agents.
// tool_use_id (present on both events in newer builds) is the correlation key,
// with tool_input.description as the fallback.
//
// A background agent's tool call returns a task id immediately, so its
// PostToolUse fires while the agent is still running: honoring it would erase
// the row seconds after it appeared. Those entries are dropped by reapFinished
// once the transcript reports them done — background work routinely outlives
// the turn that launched it, so turn boundaries keep those rows (see
// keepBackgroundRows) and only sweep entries the reap could never match.
function cleanLabel(s) {
  if (typeof s !== "string") return null;
  const d = s.replace(/[\x00-\x1f\x7f]+/g, " ").trim();
  return d ? d.slice(0, 120) : null;
}

function agentDescription(input) {
  return cleanLabel((input.tool_input || {}).description);
}

function isSyncAgent(input) {
  const ti = input.tool_input || {};
  if (typeof ti.run_in_background === "boolean") return !ti.run_in_background;
  // Absent: the classic Task tool has no such parameter and always blocks,
  // while Agent runs in the background unless asked not to.
  return input.tool_name === "Task";
}

// A wait gets its own clock, so a waiting row reads as how long the prompt has
// been sitting there rather than how long the turn has been going. It is
// tracked explicitly rather than derived from status changes: tool events from
// a running subagent carry the parent's session_id (see the lock note above)
// and rewrite status mid-wait, which would restart the clock every time one
// landed.
// Which tool call a wait belongs to. The id is what a later event can be
// matched against; the name only tells prompts apart, because several calls of
// one tool share it. The tag records which of the two this is. Length-capped
// like every other value that lands in the state file; it is compared, never
// displayed.
function toolCallId(id) {
  return typeof id === "string" && id ? `id:${id.slice(0, 120)}` : null;
}

function correlationId(input) {
  const id = toolCallId(input.tool_use_id);
  if (id) return id;
  const name = input.tool_name;
  return typeof name === "string" && name ? `name:${name.slice(0, 120)}` : null;
}

// PermissionRequest carries no tool_use_id — Claude Code hands it to the hook
// runner but leaves it out of the payload — so the id has to come from the
// PreToolUse that ran moments earlier, as part of the same permission decision.
// Calls still in flight are tracked per tool name; these caps bound what an
// unmatched call can add to the state file.
const MAX_PENDING_TOOLS = 8;
const MAX_PENDING_PER_TOOL = 8;

function pendingKey(input) {
  const name = input.tool_name;
  return typeof name === "string" && name ? name.slice(0, 120) : null;
}

// The state file is only ever written here, but it is read back from disk and
// a truncated write must not throw on the next event.
function pendingMap(base) {
  const pending = base.pendingCalls;
  if (pending == null || typeof pending !== "object" || Array.isArray(pending)) return null;
  return pending;
}

function pendingIds(base, key) {
  const pending = pendingMap(base);
  if (key == null || pending == null) return null;
  const ids = pending[key];
  if (!Array.isArray(ids)) return null;
  return ids.filter((x) => typeof x === "string" && x.startsWith("id:"));
}

function trackCall(base, input) {
  const key = pendingKey(input);
  const id = toolCallId(input.tool_use_id);
  if (key == null || id == null) return;
  if (pendingMap(base) == null) base.pendingCalls = {};
  const pending = base.pendingCalls;
  const ids = pendingIds(base, key) || [];
  if (!ids.includes(id)) ids.push(id);
  if (ids.length > MAX_PENDING_PER_TOOL) ids.splice(0, ids.length - MAX_PENDING_PER_TOOL);
  pending[key] = ids;
  const keys = Object.keys(pending);
  if (keys.length > MAX_PENDING_TOOLS) {
    for (const stale of keys.slice(0, keys.length - MAX_PENDING_TOOLS)) delete pending[stale];
  }
}

function dropId(base, key, id) {
  const ids = pendingIds(base, key);
  if (ids == null) return;
  const rest = ids.filter((x) => x !== id);
  if (rest.length === ids.length) return;
  if (rest.length) base.pendingCalls[key] = rest;
  else delete base.pendingCalls[key];
}

function untrackCall(base, input) {
  const id = toolCallId(input.tool_use_id);
  if (id != null) dropId(base, pendingKey(input), id);
}

// A wait still bound to a call id when the next prompt arrives almost always
// means that call was answered without ever reaching PostToolUse — it was
// denied, or interrupted. Its entry is dead: left in, it makes every later
// prompt for the same tool look ambiguous, and the whole turn falls back to
// the tool name, which nothing closes. Denial followed by a corrected retry is
// the common path, so this matters. The exception — a second prompt opening
// over a live one — is the case permissionWaitId documents as accepted.
function dropDeadCall(base) {
  const dead = base.waitId;
  const pending = pendingMap(base);
  if (base.waitStartedAt == null || pending == null) return;
  if (typeof dead !== "string" || !dead.startsWith("id:")) return;
  for (const key of Object.keys(pending)) dropId(base, key, dead);
}

// Only an unambiguous match is used. Several calls of one tool in flight at
// once (a subagent running Bash while the user is asked about another Bash)
// give no way to tell which one the prompt belongs to, and guessing would let
// the wrong call's PostToolUse close the wait and rewind the clock under the
// user — so that case falls back to the tool name, which nothing can match.
//
// Two ways through remain, both needing a same-tool call in flight from a
// subagent: this call's PreToolUse write can be lost to the unlocked fallback,
// leaving the subagent's id as the only candidate; or the subagent's own
// prompt can arrive while this one is open, and dropDeadCall reads this
// still-live call as dead. Either way the subagent's PostToolUse ends the wait
// early. Two prompts at once already break the row — one wait slot cannot hold
// both, and any PostToolUse flips the status to thinking — so the cost is a
// wait re-measured from zero, which is not worth a second correlation key on
// every call.
function permissionWaitId(base, input) {
  dropDeadCall(base);
  const ids = pendingIds(base, pendingKey(input));
  if (ids && ids.length === 1) return ids[0];
  return correlationId(input);
}

function beginWait(base, now, id) {
  // A prompt of a different kind, or of the same kind for a different tool
  // call, is a new wait — a denial followed by a fresh permission request is
  // the common case. The Notification that follows a PermissionRequest for the
  // same prompt carries no id, so it never looks like a new one.
  const other = id != null && base.waitId != null && id !== base.waitId;
  if (base.waitStartedAt == null || base.waitKey !== base.message || other) {
    base.waitStartedAt = now;
    base.waitKey = base.message;
    base.waitId = null;
  }
  // Whichever of the two events carries a correlation key wins — the CLI
  // raises both, and only one of them names the tool being approved.
  if (id) base.waitId = id;
}

// Only the awaited call ends the wait. A background subagent reporting into
// this session hits PostToolUse constantly while the prompt is still up, and
// ending the wait there would restart the clock under the user — so a wait
// known by tool name alone is left for the prompt or the turn end to close,
// rather than closed by whichever call of that tool happens to finish first.
function endsWait(base, input) {
  if (base.waitStartedAt == null || base.waitId == null) return false;
  const id = toolCallId(input.tool_use_id);
  return id != null && base.waitId === id;
}

// The work that resumes after a wait starts from zero.
function endWait(base, now) {
  if (base.waitStartedAt == null) return;
  clearWait(base);
  base.turnStartedAt = now;
}

// Drops the wait without touching the turn clock — for the events that null it
// out themselves (a turn ending, a session starting).
function clearWait(base) {
  base.waitStartedAt = null;
  base.waitKey = null;
  base.waitId = null;
}

function pushAgent(base, input, now, description, extra) {
  const ti = input.tool_input || {};
  const agents = Array.isArray(base.agents) ? base.agents : [];
  agents.push(
    Object.assign(
      {
        id: typeof input.tool_use_id === "string" ? input.tool_use_id : null,
        description: description !== undefined ? description : agentDescription(input),
        type: typeof ti.subagent_type === "string" ? ti.subagent_type : null,
        // Background agents outlive the turn that launched them; only these
        // survive the turn-boundary sweep (keepBackgroundRows)
        bg: !isSyncAgent(input),
        startedAt: now,
      },
      extra
    )
  );
  base.agents = agents.slice(-MAX_AGENTS);
}

function removeAgent(base, input) {
  if (!Array.isArray(base.agents) || base.agents.length === 0) return;
  const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
  let i = id ? base.agents.findIndex((a) => a && a.id === id) : -1;
  if (i < 0) {
    // Only match on a real description — a null one would match every
    // description-less entry and remove an arbitrary running agent
    const desc = agentDescription(input);
    if (desc) i = base.agents.findIndex((a) => a && a.description === desc);
  }
  // No match: the PreToolUse was never recorded (lost to the unlocked
  // fallback, or reset by a turn boundary). Removing an arbitrary entry would
  // hide a different agent that is still running — leave the list alone and
  // let the turn-boundary sweep clear any sync-agent leftovers.
  if (i < 0) return;
  base.agents.splice(i, 1);
}

// Background shell commands (Bash with run_in_background). Like a background
// agent, the tool call returns as soon as the command is detached, so its
// PostToolUse says nothing about the command still running — the entry is only
// dropped when the transcript reports it finished (see reapFinished), or when
// the PostToolUse response carries no task id (the command ran to completion
// synchronously — no notification will ever come for it).
function isBackgroundBash(input) {
  return input.tool_name === "Bash" && (input.tool_input || {}).run_in_background === true;
}

// Monitor watches (CI runs, agent completion, file conditions) are background
// tasks too: the tool call returns "Monitor started" immediately and the watch
// keeps running. The reap matches the entry by tool_use_id alone — its task id
// (response taskId, stored as monitorId for kill matching) must stay out of
// the taskId field, because per-event notifications name the task id while
// the watch is still running and would reap a live row.
function isMonitor(input) {
  return input.tool_name === "Monitor";
}

// Without a description, label the row with the program name only. The raw
// command would land both in the session file and on an always-on-top panel
// that ends up in screenshots and screen shares, and background commands are
// exactly where inline secrets live (TOKEN=… cmd, curl -H "Authorization: …").
function commandLabel(cmd) {
  if (typeof cmd !== "string") return null;
  const words = cmd.trim().split(/\s+/);
  let i = 0;
  while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) i++; // env assignments
  return cleanLabel(words[i]);
}

function pushTask(base, input, now, extra) {
  const ti = input.tool_input || {};
  const tasks = Array.isArray(base.tasks) ? base.tasks : [];
  tasks.push(
    Object.assign(
      {
        id: typeof input.tool_use_id === "string" ? input.tool_use_id : null,
        taskId: null, // shell id, filled in from the PostToolUse response
        // "until" is Monitor's condition ("agent completes") — as safe to show
        // as a description, unlike the raw command
        description:
          cleanLabel(ti.description) || cleanLabel(ti.until) || commandLabel(ti.command),
        startedAt: now,
      },
      extra
    )
  );
  base.tasks = tasks.slice(-MAX_TASKS);
}

// The completion notification names the command by its shell id, which only the
// tool response carries — record it so both ids can be matched later. When no
// entry matches (the PreToolUse was lost to the unlocked fallback, or the
// harness backgrounded a foreground command mid-run), the response is the only
// evidence the command exists — add the row here instead of losing it.
function attachTaskId(base, input, now, taskId) {
  const tasks = Array.isArray(base.tasks) ? base.tasks : [];
  const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
  let entry = id ? tasks.find((t) => t && t.id === id) : null;
  if (!entry && !id) {
    // No correlation key: the newest entry still missing a taskId is the one
    // that just started (entries are pushed in call order). Monitor rows
    // never carry a taskId — they must not soak up a bash command's id.
    for (let i = tasks.length - 1; i >= 0; i--) {
      if (tasks[i] && !tasks[i].taskId && tasks[i].kind !== "monitor") {
        entry = tasks[i];
        break;
      }
    }
  }
  if (entry) entry.taskId = taskId;
  else pushTask(base, input, now, { taskId });
}

// A bg-requested command whose response carries no task id never detached —
// it finished (or failed) synchronously, so no completion notification will
// ever reap its row.
function removeTask(base, input) {
  if (!Array.isArray(base.tasks) || base.tasks.length === 0) return;
  const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
  let i = id ? base.tasks.findIndex((t) => t && t.id === id) : -1;
  if (i < 0 && !id) {
    // Same fallback as attachTaskId — and the same monitor guard: removing
    // the newest taskId-less row must never take out a live watch
    for (let j = base.tasks.length - 1; j >= 0; j--) {
      if (base.tasks[j] && !base.tasks[j].taskId && base.tasks[j].kind !== "monitor") {
        i = j;
        break;
      }
    }
  }
  if (i >= 0) base.tasks.splice(i, 1);
}

// Background work reports completion only in the transcript: the harness
// appends a <task-notification> block naming the finished command or agent by
// <task-id> (shell id) and <tool-use-id> (the call that started it). No hook
// event fires for it, so any hook running while something is tracked scans the
// transcript tail and drops what has finished. The window has to be generous —
// single transcript lines routinely run past 100KB (tool results, agent
// transcripts), so a small tail would push notifications out of view within a
// few tool calls. Turn boundaries scan a much larger window: they run once per
// turn, and are the last chance to catch a notification that scrolled past the
// per-event tail before a kept row goes stale.
const TAIL_BYTES = 512 * 1024;
const TAIL_BYTES_TURN = 4 * 1024 * 1024;
// The ids sit at the top of the block; its <result> can run for pages
const BLOCK_HEAD = 600;

function finishedIds(transcriptPath, tailBytes) {
  const ids = new Set();
  if (typeof transcriptPath !== "string" || !transcriptPath) return ids;
  try {
    const st = fs.statSync(transcriptPath);
    let data;
    if (st.size <= tailBytes) {
      data = fs.readFileSync(transcriptPath, "utf8");
    } else {
      const fd = fs.openSync(transcriptPath, "r");
      const buf = Buffer.alloc(tailBytes);
      fs.readSync(fd, buf, 0, tailBytes, st.size - tailBytes);
      fs.closeSync(fd);
      data = buf.toString("utf8");
    }
    // A real notification is the whole value of a JSON string field, so its
    // opening tag always follows the field's quote — anchoring on that quote
    // skips prose that merely quotes the format mid-sentence (this feature's
    // own development sessions do), which would otherwise hand back ids for
    // tasks that are still running. Only a bounded head of each block is
    // scanned: the ids sit at the top, while the closing tag may be pages away
    // or past the window entirely.
    const OPEN = '"<task-notification>';
    let start = data.indexOf(OPEN);
    while (start !== -1) {
      const head = data.slice(start, start + BLOCK_HEAD);
      const re = /<(task-id|tool-use-id)>([^<>\\"]{1,128})<\/\1>/g;
      let m;
      while ((m = re.exec(head)) !== null) ids.add(m[2]);
      start = data.indexOf(OPEN, start + 1);
    }
  } catch {}
  return ids;
}

function reapFinished(base, transcriptPath, tailBytes) {
  const agents = Array.isArray(base.agents) ? base.agents : [];
  const tasks = Array.isArray(base.tasks) ? base.tasks : [];
  if (agents.length === 0 && tasks.length === 0) return;
  const done = finishedIds(transcriptPath, tailBytes);
  if (done.size === 0) return;
  if (agents.length > 0) {
    base.agents = agents.filter((a) => !(a && a.id && done.has(a.id)));
  }
  if (tasks.length > 0) {
    base.tasks = tasks.filter(
      (t) => !(t && ((t.id && done.has(t.id)) || (t.taskId && done.has(t.taskId))))
    );
  }
}

// Turn-boundary sweep. Background work keeps running after its turn ends (a
// dev server launched with run_in_background, a Monitor watch, a background
// agent), so clearing the lists here would blank the panel while the work is
// still live — that was exactly the "background task not shown" bug. Instead
// keep every row the notification reap can still match, and drop only the
// ones it can't: sync-agent strays (their PostToolUse removal was lost) and
// entries with no usable id, which would otherwise be stuck until SessionEnd.
// Bash rows must have a confirmed taskId — a bg request that never detached
// gets no notification, so an id-only row could be such a stray.
function keepBackgroundRows(base) {
  if (Array.isArray(base.agents)) {
    base.agents = base.agents.filter((a) => a && a.bg === true && a.id);
  }
  if (Array.isArray(base.tasks)) {
    base.tasks = base.tasks.filter((t) => t && (t.taskId || (t.kind === "monitor" && t.id)));
  }
}

function launchApp() {
  // Best effort: bring ccglance up when a session starts (ignore failures)
  execFile("open", ["-g", "-a", "ccglance"], () => {});
}

// PR status for the session's branch, fetched via the gh CLI. Runs in a
// detached child (--fetch-pr mode) so the hook itself never blocks Claude
// Code waiting on the network.
const GH_CANDIDATES = ["gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"];

// done(pr): pr object → set it, null → clear the field (definitively no PR),
// undefined → keep the last known state (transient failure: network, timeout)
const GH_FIELDS = "number,state,isDraft,url,mergeable";
const GH_FIELDS_LEGACY = "number,state,isDraft,url"; // gh older than the mergeable field

function runGhPrView(cwd, candidates, done, fields = GH_FIELDS) {
  if (candidates.length === 0) return done(undefined);
  execFile(
    candidates[0],
    ["pr", "view", "--json", fields],
    { cwd, timeout: 15000 },
    (err, stdout, stderr) => {
      // Hooks may run with a limited PATH; try well-known install locations
      if (err && err.code === "ENOENT") return runGhPrView(cwd, candidates.slice(1), done, fields);
      if (err) {
        // A gh too old for one of the fields rejects the whole call; retry
        // without the newest one rather than losing PR status entirely
        if (fields !== GH_FIELDS_LEGACY && /unknown json field/i.test(String(stderr))) {
          return runGhPrView(cwd, candidates, done, GH_FIELDS_LEGACY);
        }
        const definitive = /no pull requests found|not a git repository|no git remotes/i.test(
          String(stderr)
        );
        return done(definitive ? null : undefined);
      }
      try {
        const j = JSON.parse(stdout);
        if (typeof j.state !== "string") return done(undefined);
        done({
          number: j.number,
          state: j.state, // "OPEN" | "MERGED" | "CLOSED"
          isDraft: !!j.isDraft,
          // "MERGEABLE" | "CONFLICTING" | "UNKNOWN"; dropped from the JSON when
          // absent, which the app reads as unknown
          mergeable: typeof j.mergeable === "string" ? j.mergeable : undefined,
          url: j.url,
          checkedAt: Date.now() / 1000,
        });
      } catch {
        done(undefined);
      }
    }
  );
}

function fetchPr(sessionId, cwd) {
  runGhPrView(cwd, GH_CANDIDATES, async (pr) => {
    try {
      if (pr !== undefined) {
        await acquireLock(sessionId);
        // Merge only the pr field into the freshest state; the session may have
        // moved on while gh was running, and if SessionEnd deleted the file this
        // write must not resurrect it (loadState returns null once it's gone).
        const state = loadState(sessionId);
        if (state) {
          if (pr) state.pr = pr;
          else delete state.pr;
          // Leave updatedAt untouched so this write never extends the 12h pruning
          saveState(state);
        }
      }
    } catch {}
    process.exit(0); // the exit handler releases the lock
  });
}

function spawnPrFetch(sessionId, cwd) {
  if (typeof cwd !== "string" || cwd.length === 0) return;
  try {
    spawn(process.execPath, [__filename, "--fetch-pr", sessionId, cwd], {
      detached: true,
      stdio: "ignore",
    }).unref();
  } catch {}
}

// PostToolUse: tools that can change the branch's PR state warrant an
// immediate re-fetch instead of waiting for the Stop-time one.
const PR_MUTATING_MCP = new Set([
  "mcp__github__create_pull_request",
  "mcp__github__merge_pull_request",
]);

function isPrMutatingTool(input) {
  if (PR_MUTATING_MCP.has(input.tool_name)) return true;
  if (input.tool_name !== "Bash") return false;
  const cmd = (input.tool_input || {}).command;
  return typeof cmd === "string" && /\bgh\s+pr\s+(create|merge|close|reopen|ready)\b/.test(cmd);
}

async function main() {
  if (process.argv[2] === "--fetch-pr") {
    const sessionId = process.argv[3];
    const cwd = process.argv[4];
    if (
      typeof sessionId !== "string" ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(sessionId) ||
      typeof cwd !== "string" ||
      !fs.existsSync(cwd)
    ) {
      process.exit(0);
    }
    fetchPr(sessionId, cwd);
    return;
  }

  const raw = await readStdin();
  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    process.exit(0);
  }

  const sessionId = input.session_id;
  // The id becomes a filename — accept only safe charsets (UUID-like), so a
  // malformed/hostile id can never traverse out of SESSIONS_DIR.
  if (typeof sessionId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(sessionId)) {
    process.exit(0);
  }

  // Refresh the session title on turn boundaries (skipped on every
  // PreToolUse/PostToolUse to stay fast). Resolved before taking the lock:
  // desktopTitle walks a directory tree and sessionTitle reads up to 512KB,
  // and neither needs the state file — holding the lock across them would
  // push concurrent hooks past LOCK_WAIT_MS into the unlocked fallback.
  const ev = input.hook_event_name;
  let title = null;
  if (ev === "SessionStart" || ev === "UserPromptSubmit" || ev === "Stop" || ev === "Notification") {
    // Desktop store first (the title editable in Claude Desktop), then the
    // transcript (CLI / SDK renames), otherwise keep what we had.
    title = desktopTitle(sessionId) || sessionTitle(input.transcript_path);
  }

  await acquireLock(sessionId);

  const now = Date.now() / 1000;
  const prev = loadState(sessionId);
  const base = prev || {
    sessionId,
    project: null,
    title: null,
    cwd: null,
    status: "idle",
    tool: null,
    message: null,
    permissionMode: null,
    planApprovedAt: null,
    turnStartedAt: null,
    waitStartedAt: null,
    createdAt: now,
    updatedAt: now,
  };
  // Only trust cwd when the event actually carries it — never fall back to
  // process.cwd(), which would overwrite the project name with a wrong dir.
  if (typeof input.cwd === "string" && input.cwd.length > 0) {
    base.cwd = input.cwd;
    base.project = projectFromCwd(input.cwd) || base.project;
  }
  // Trust the mode only when the event carries it — older Claude Code
  // versions omit permission_mode, and unwritten fields persist. The length
  // cap keeps a malformed value from bloating the state file (and the
  // tooltip it ends up in).
  if (
    typeof input.permission_mode === "string" &&
    input.permission_mode.length > 0 &&
    input.permission_mode.length <= 64
  ) {
    // Entering plan mode starts a new plan cycle — the approval badge from
    // the previous plan no longer applies. This is the only place the badge
    // is cleared: it survives turn ends and session restarts.
    if (input.permission_mode === "plan" && base.permissionMode !== "plan") {
      base.planApprovedAt = null;
    }
    base.permissionMode = input.permission_mode;
  }
  if (title) base.title = title;
  // Captured once per session (unwritten fields persist across events), which
  // also backfills sessions that predate this hook version. SessionStart
  // re-captures so a resumed session doesn't keep a stale host from a state
  // file that survived a crash.
  if (!base.host || input.hook_event_name === "SessionStart") {
    base.host = captureHost();
    const env = envName();
    if (env) base.env = env;
    else delete base.env;
  }
  base.updatedAt = now;

  // Drop rows for background work that has finished since the last event.
  // Turn boundaries get the wide scan: rows survive them now (see
  // keepBackgroundRows), so this is the last cheap moment to catch a
  // notification that already scrolled past the per-event tail.
  // PermissionRequest is deliberately absent: it blocks the prompt from
  // appearing, and the PreToolUse moments earlier already ran this same scan.
  if (ev === "PreToolUse" || ev === "PostToolUse" || ev === "Notification") {
    reapFinished(base, input.transcript_path, TAIL_BYTES);
  } else if (ev === "Stop" || ev === "UserPromptSubmit") {
    reapFinished(base, input.transcript_path, TAIL_BYTES_TURN);
  }

  switch (input.hook_event_name) {
    case "SessionStart":
      base.status = "idle";
      base.tool = null;
      base.turnStartedAt = null;
      base.turnActive = false;
      clearWait(base);
      delete base.pendingCalls;
      // SessionStart is not only a fresh start: source is one of startup /
      // resume / clear / compact, and resume and compact fire while background
      // work launched earlier is still running and still reporting into the
      // same transcript. Wiping the lists here dropped those rows for good — no
      // later event re-adds them, and the reap can only remove — so a command
      // running for hours stayed invisible for the rest of the session. Keep
      // what the reap can still match instead; a genuinely new session has no
      // prior state to keep, so startup is unaffected either way.
      // /clear is the exception: it drops the transcript the reap reads, so a
      // surviving row could never be cleared.
      //
      // A resume that follows a hard crash (no SessionEnd, so the state file
      // outlived the process that owned the work) can keep a row whose command
      // died with that process. That is accepted: the alternative — expiring
      // rows by age — hides exactly the long-running work this fixes, and a
      // clean exit deletes the whole file at SessionEnd.
      if (input.source === "clear") {
        base.agents = [];
        base.tasks = [];
      } else {
        reapFinished(base, input.transcript_path, TAIL_BYTES_TURN);
        keepBackgroundRows(base);
      }
      saveState(base);
      launchApp();
      spawnPrFetch(sessionId, base.cwd);
      break;

    case "UserPromptSubmit": {
      // A steering message sent while the turn is still running must not be
      // mistaken for a new turn: clearing agents there erases rows for agents
      // that are still working, and restarting the clock hides how long the
      // turn has really been going. turnActive tracks the boundary explicitly —
      // turnStartedAt can't, because PreToolUse and Notification also set it
      // (an idle "waiting for input" notification fires between turns).
      const newTurn = base.turnActive !== true;
      const answersWait = base.status === "permission";
      base.turnActive = true;
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      if (newTurn) {
        base.turnStartedAt = now;
        keepBackgroundRows(base);
      }
      // The prompt is the answer an idle wait was waiting for. A wait left
      // open by a denial (no PostToolUse ever comes) must not make a steering
      // message look like one, or it would restart the turn clock.
      if (answersWait) endWait(base, now);
      saveState(base);
      break;
    }

    case "PreToolUse":
      // Recorded before the branch: the PermissionRequest that may follow this
      // call needs the id, and it names only the tool.
      trackCall(base, input);
      // Tools that block on user input never trigger a Notification event
      // (AskUserQuestion shows its own picker; ExitPlanMode waits for plan
      // approval) — surface them as awaiting-input immediately.
      if (INPUT_TOOLS[input.tool_name]) {
        base.status = "permission";
        base.tool = null;
        base.message = INPUT_TOOLS[input.tool_name];
        beginWait(base, now, correlationId(input));
      } else {
        base.status = "tool";
        base.tool = TOOL_LABELS[input.tool_name] || "Using tool";
        base.message = null;
        if (AGENT_TOOLS.has(input.tool_name)) {
          pushAgent(base, input, now);
        } else if (isBackgroundBash(input)) {
          pushTask(base, input, now);
        } else if (isMonitor(input)) {
          pushTask(base, input, now, { kind: "monitor" });
        }
      }
      if (base.turnStartedAt == null) base.turnStartedAt = now;
      saveState(base);
      break;

    case "PostToolUse":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      // ExitPlanMode's PostToolUse fires only when the user approved the plan
      // (a rejection never reaches PostToolUse) — record the approval. The
      // approval also ends the plan cycle: drop a stale "plan" mode (events
      // may still carry the pre-approval mode) so the next plan entry is
      // seen as a fresh transition and clears the badge.
      if (input.tool_name === "ExitPlanMode") {
        base.planApprovedAt = now;
        if (base.permissionMode === "plan") base.permissionMode = null;
      }
      if (AGENT_TOOLS.has(input.tool_name)) {
        if (isSyncAgent(input)) {
          removeAgent(base, input);
        } else if (Array.isArray(base.agents)) {
          // A background agent's PostToolUse fires at spawn; its structured
          // agentId is the name a TaskStop uses — record it for kill matching
          const res = input.tool_response;
          const aid = res && typeof res === "object" ? res.agentId : null;
          const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
          if (typeof aid === "string" && aid && id) {
            const entry = base.agents.find((a) => a && a.id === id);
            if (entry) entry.agentId = aid;
          }
        }
      } else if (isMonitor(input)) {
        // Same for a watch: the response's structured taskId is what a
        // TaskStop names. Kept out of the taskId field — per-event
        // notifications name it while the watch is still running, and the
        // reap would take the row for finished (see isMonitor).
        const res = input.tool_response;
        const mid = res && typeof res === "object" ? res.taskId : null;
        const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
        if (typeof mid === "string" && mid && id && Array.isArray(base.tasks)) {
          const entry = base.tasks.find((t) => t && t.id === id);
          if (entry) entry.monitorId = mid;
        }
      } else if (input.tool_name === "Bash") {
        // Any Bash response carrying a backgroundTaskId is a live background
        // command: attach the id to its PreToolUse row, or add the row when
        // none was recorded (PreToolUse lost to the unlocked fallback, or a
        // foreground command moved to the background mid-run — Ctrl-B, or the
        // harness promoting a long runner). A bg request without the id never
        // detached (finished or failed synchronously) — drop its row.
        const res = input.tool_response;
        const taskId = res && typeof res === "object" ? res.backgroundTaskId : null;
        if (typeof taskId === "string" && taskId) {
          attachTaskId(base, input, now, taskId);
        } else if (isBackgroundBash(input)) {
          removeTask(base, input);
        }
      } else if (KILL_TOOLS.has(input.tool_name)) {
        // An explicit stop leaves no completion notification in the
        // transcript (verified against real sessions), so the reap would
        // never drop these rows — remove them by the stopped id here.
        const ti = input.tool_input || {};
        const killed = [ti.task_id, ti.taskId, ti.shell_id, ti.shellId].find(
          (v) => typeof v === "string" && v
        );
        if (killed) {
          if (Array.isArray(base.tasks)) {
            base.tasks = base.tasks.filter(
              (t) => !(t && (t.taskId === killed || t.monitorId === killed))
            );
          }
          if (Array.isArray(base.agents)) {
            base.agents = base.agents.filter((a) => !(a && a.agentId === killed));
          }
        }
      } else if (input.tool_name === "SendMessage") {
        // A message to an agent with no active task resumes it from its
        // transcript in the background — no Agent tool call records it, so
        // the response's resumedAgentId is the only signal (a send to a
        // still-running agent is merely delivered and carries no such field).
        // The completion notification names this call's tool_use_id, so the
        // normal reap path clears the row.
        const res = input.tool_response;
        const resumed = res && typeof res === "object" ? res.resumedAgentId : null;
        if (typeof resumed === "string" && resumed) {
          pushAgent(base, input, now, cleanLabel((input.tool_input || {}).summary), {
            agentId: resumed,
          });
        }
      }
      // The approved tool ran: an ExitPlanMode/AskUserQuestion answer or a
      // permission prompt the user let through. Background tools reporting
      // into this session while the prompt is still up do not match.
      if (endsWait(base, input)) endWait(base, now);
      untrackCall(base, input);
      saveState(base);
      if (isPrMutatingTool(input)) spawnPrFetch(sessionId, base.cwd);
      break;

    // Fires when Claude Code is about to ask for permission. The Claude Desktop
    // app raises no Notification for that (only the CLI does), so without this
    // the panel stayed on "Running command" for the whole time a command's
    // approval prompt was waiting. Writing nothing to stdout leaves the prompt
    // untouched — a decision would auto-answer it.
    case "PermissionRequest":
      base.status = "permission";
      base.message = "Awaiting permission";
      beginWait(base, now, permissionWaitId(base, input));
      saveState(base);
      break;

    case "Notification": {
      // Fires for permission requests and idle "waiting for input" prompts
      const msg = String(input.message || "");
      base.status = "permission";
      base.message = /permission/i.test(msg)
        ? "Awaiting permission"
        : "Waiting for input";
      // No tool_use_id here, and none on the PermissionRequest that precedes
      // this on the CLI either — that one is correlated through the pending
      // call it shares a tool name with, which this event cannot do because an
      // idle "waiting for input" wait has no tool at all (a prompt or the turn
      // ending is what closes it). Passing null leaves an id already bound by
      // the PermissionRequest in place.
      beginWait(base, now, null);
      saveState(base);
      break;
    }

    case "Stop":
      base.status = "idle";
      base.tool = null;
      base.message = null;
      // planApprovedAt is not cleared here — the badge stays until a new
      // plan cycle begins (permission mode transitions back to "plan").
      base.turnStartedAt = null;
      base.turnActive = false;
      clearWait(base);
      // A denied call never reaches PostToolUse, so its entry can only be
      // dropped here; nothing outlives the turn that asked for it.
      delete base.pendingCalls;
      keepBackgroundRows(base);
      saveState(base);
      spawnPrFetch(sessionId, base.cwd);
      break;

    case "SessionEnd":
      try {
        fs.unlinkSync(stateFile(sessionId));
      } catch {}
      break;

    default:
      // Unknown event: just refresh updatedAt so the session isn't pruned
      if (prev) saveState(base);
  }

  process.exit(0);
}

main();
