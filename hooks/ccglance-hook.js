#!/usr/bin/env node
// ccglance hook — receives Claude Code lifecycle events on stdin and writes
// per-session state to ~/.claude/ccglance/sessions/<session_id>.json
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile, spawn } = require("child_process");

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
};

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
  runGhPrView(cwd, GH_CANDIDATES, (pr) => {
    if (pr === undefined) return process.exit(0);
    // Merge only the pr field into the freshest state; the session may have
    // moved on (or ended) while gh was running.
    const state = loadState(sessionId);
    if (!state) return process.exit(0);
    if (pr) state.pr = pr;
    else delete state.pr;
    // Re-check right before writing: SessionEnd may have deleted the file
    // while gh was running, and this write must not resurrect the session
    if (!fs.existsSync(stateFile(sessionId))) return process.exit(0);
    // Leave updatedAt untouched so this write never extends the 12h pruning
    saveState(state);
    process.exit(0);
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
    updatedAt: now,
  };
  // Only trust cwd when the event actually carries it — never fall back to
  // process.cwd(), which would overwrite the project name with a wrong dir.
  if (typeof input.cwd === "string" && input.cwd.length > 0) {
    base.cwd = input.cwd;
    base.project = projectFromCwd(input.cwd) || base.project;
  }
  // Refresh the session title on turn boundaries (cheap enough; skipped on
  // every PreToolUse/PostToolUse to stay fast).
  const ev = input.hook_event_name;
  if (ev === "SessionStart" || ev === "UserPromptSubmit" || ev === "Stop" || ev === "Notification") {
    // Desktop store first (the title editable in Claude Desktop), then the
    // transcript (CLI / SDK renames), otherwise keep what we had.
    const t = desktopTitle(sessionId) || sessionTitle(input.transcript_path);
    if (t) base.title = t;
  }
  base.updatedAt = now;

  switch (input.hook_event_name) {
    case "SessionStart":
      base.status = "idle";
      base.tool = null;
      base.turnStartedAt = null;
      saveState(base);
      launchApp();
      spawnPrFetch(sessionId, base.cwd);
      break;

    case "UserPromptSubmit":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      base.turnStartedAt = now;
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
      }
      if (base.turnStartedAt == null) base.turnStartedAt = now;
      saveState(base);
      break;

    case "PostToolUse":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      saveState(base);
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
