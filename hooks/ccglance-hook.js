#!/usr/bin/env node
// ccglance hook — receives Claude Code lifecycle events on stdin and writes
// per-session state to ~/.claude/ccglance/sessions/<session_id>.json
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

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
  const tmp = `${file}.tmp`;
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

// Running-subagent tracking: PreToolUse on an agent tool pushes an entry,
// PostToolUse removes the matching one. tool_input.description is present on
// both events, so it doubles as the correlation key.
function agentDescription(input) {
  const ti = input.tool_input || {};
  const d =
    typeof ti.description === "string"
      ? ti.description.replace(/[\x00-\x1f\x7f]+/g, " ").trim()
      : "";
  return d ? d.slice(0, 120) : null;
}

function pushAgent(base, input, now) {
  const ti = input.tool_input || {};
  const agents = Array.isArray(base.agents) ? base.agents : [];
  agents.push({
    description: agentDescription(input),
    type: typeof ti.subagent_type === "string" ? ti.subagent_type : null,
    startedAt: now,
  });
  base.agents = agents.slice(-MAX_AGENTS);
}

function removeAgent(base, input) {
  if (!Array.isArray(base.agents) || base.agents.length === 0) return;
  const desc = agentDescription(input);
  let i = base.agents.findIndex((a) => a && a.description === desc);
  if (i < 0) i = 0; // no match (e.g. truncated description) — drop the oldest
  base.agents.splice(i, 1);
}

function launchApp() {
  // Best effort: bring ccglance up when a session starts (ignore failures)
  execFile("open", ["-g", "-a", "ccglance"], () => {});
}

async function main() {
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
      base.agents = [];
      saveState(base);
      launchApp();
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
        if (AGENT_TOOLS.has(input.tool_name)) pushAgent(base, input, now);
      }
      if (base.turnStartedAt == null) base.turnStartedAt = now;
      saveState(base);
      break;

    case "PostToolUse":
      base.status = "thinking";
      base.tool = null;
      base.message = null;
      if (AGENT_TOOLS.has(input.tool_name)) removeAgent(base, input);
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
      base.agents = [];
      saveState(base);
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
