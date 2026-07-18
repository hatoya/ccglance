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
};

// Subagent-spawning tools ("Task" classically, "Agent" in newer builds)
const AGENT_TOOLS = new Set(["Task", "Agent"]);
const MAX_AGENTS = 10;

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
function desktopTitle(sessionId) {
  const root = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Claude",
    "claude-code-sessions"
  );
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
        if (typeof j.title === "string" && j.title.trim()) {
          const mtime = fs.statSync(p).mtimeMs;
          if (!best || mtime > best.mtime) best = { title: j.title.trim(), mtime };
        }
      }
    }
  }
  walk(root, 0);
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

// Running-subagent tracking: PreToolUse on an agent tool pushes an entry,
// PostToolUse removes the matching one. tool_use_id (present on both events in
// newer builds) is the correlation key, with tool_input.description as the
// fallback. Background agents (run_in_background) are not tracked: their tool
// call returns a task id immediately, so PostToolUse fires while the agent is
// still running and the row would be wrong either way.
function agentDescription(input) {
  const ti = input.tool_input || {};
  const d =
    typeof ti.description === "string"
      ? ti.description.replace(/[\x00-\x1f\x7f]+/g, " ").trim()
      : "";
  return d ? d.slice(0, 120) : null;
}

function isBackgroundAgent(input) {
  const ti = input.tool_input || {};
  return ti.run_in_background === true;
}

function pushAgent(base, input, now) {
  const ti = input.tool_input || {};
  const agents = Array.isArray(base.agents) ? base.agents : [];
  agents.push({
    id: typeof input.tool_use_id === "string" ? input.tool_use_id : null,
    description: agentDescription(input),
    type: typeof ti.subagent_type === "string" ? ti.subagent_type : null,
    startedAt: now,
  });
  base.agents = agents.slice(-MAX_AGENTS);
}

function removeAgent(base, input) {
  if (!Array.isArray(base.agents) || base.agents.length === 0) return;
  const id = typeof input.tool_use_id === "string" ? input.tool_use_id : null;
  let i = id ? base.agents.findIndex((a) => a && a.id === id) : -1;
  if (i < 0) {
    const desc = agentDescription(input);
    i = base.agents.findIndex((a) => a && a.description === desc);
  }
  if (i < 0) i = 0; // no match (e.g. truncated description) — drop the oldest
  base.agents.splice(i, 1);
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
function runGhPrView(cwd, candidates, done) {
  if (candidates.length === 0) return done(undefined);
  execFile(
    candidates[0],
    ["pr", "view", "--json", "number,state,isDraft,url"],
    { cwd, timeout: 15000 },
    (err, stdout, stderr) => {
      // Hooks may run with a limited PATH; try well-known install locations
      if (err && err.code === "ENOENT") return runGhPrView(cwd, candidates.slice(1), done);
      if (err) {
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
    turnStartedAt: null,
    createdAt: now,
    updatedAt: now,
  };
  // Only trust cwd when the event actually carries it — never fall back to
  // process.cwd(), which would overwrite the project name with a wrong dir.
  if (typeof input.cwd === "string" && input.cwd.length > 0) {
    base.cwd = input.cwd;
    base.project = projectFromCwd(input.cwd) || base.project;
  }
  if (title) base.title = title;
  // Captured once per session (unwritten fields persist across events), which
  // also backfills sessions that predate this hook version. SessionStart
  // re-captures so a resumed session doesn't keep a stale host from a state
  // file that survived a crash.
  if (!base.host || input.hook_event_name === "SessionStart") {
    base.host = captureHost();
  }
  base.updatedAt = now;

  switch (input.hook_event_name) {
    case "SessionStart":
      base.status = "idle";
      base.tool = null;
      base.turnStartedAt = null;
      base.agents = [];
      saveState(base);
      launchApp();
      spawnPrFetch(sessionId, base.cwd);
      break;

    case "UserPromptSubmit":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      base.turnStartedAt = now;
      base.agents = [];
      saveState(base);
      break;

    case "PreToolUse":
      // Tools that block on user input never trigger a Notification event
      // (AskUserQuestion shows its own picker; ExitPlanMode waits for plan
      // approval) — surface them as awaiting-input immediately.
      if (INPUT_TOOLS[input.tool_name]) {
        base.status = "permission";
        base.tool = null;
        base.message = INPUT_TOOLS[input.tool_name];
      } else {
        base.status = "tool";
        base.tool = TOOL_LABELS[input.tool_name] || "Using tool";
        base.message = null;
        if (AGENT_TOOLS.has(input.tool_name) && !isBackgroundAgent(input)) {
          pushAgent(base, input, now);
        }
      }
      if (base.turnStartedAt == null) base.turnStartedAt = now;
      saveState(base);
      break;

    case "PostToolUse":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      if (AGENT_TOOLS.has(input.tool_name) && !isBackgroundAgent(input)) {
        removeAgent(base, input);
      }
      saveState(base);
      if (isPrMutatingTool(input)) spawnPrFetch(sessionId, base.cwd);
      break;

    case "Notification": {
      // Fires for permission requests and idle "waiting for input" prompts
      const msg = String(input.message || "");
      base.status = "permission";
      base.message = /permission/i.test(msg)
        ? "Awaiting permission"
        : "Waiting for input";
      if (base.turnStartedAt == null) base.turnStartedAt = now;
      saveState(base);
      break;
    }

    case "Stop":
      base.status = "idle";
      base.tool = null;
      base.message = null;
      base.turnStartedAt = null;
      base.agents = [];
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
