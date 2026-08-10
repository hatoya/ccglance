#!/usr/bin/env node
// Injects fake session data into ~/.claude/ccglance/sessions so the panel
// can be recorded for the README demo GIF. Run `node docs/demo-sessions.js`,
// record the panel, then press Ctrl+C — the demo files are cleaned up.

const fs = require("fs");
const os = require("os");
const path = require("path");

const DIR = path.join(os.homedir(), ".claude", "ccglance", "sessions");
fs.mkdirSync(DIR, { recursive: true });

const IDS = ["demo-readme-1", "demo-readme-2", "demo-readme-3"];
const file = (id) => path.join(DIR, id + ".json");

function write(id, state) {
  const now = Date.now() / 1000;
  fs.writeFileSync(
    file(id),
    JSON.stringify({
      sessionId: id,
      project: state.project,
      title: state.title,
      cwd: null,
      status: state.status,
      tool: state.tool || null,
      message: state.message || null,
      turnStartedAt: state.turnStartedAt ?? null,
      agents: state.agents || null,
      tasks: state.tasks || null,
      pr: state.pr || null,
      permissionMode: state.permissionMode || null,
      planApprovedAt: state.planApprovedAt ?? null,
      updatedAt: now,
    })
  );
}

const start = Date.now() / 1000;

function tick() {
  const now = Date.now() / 1000;
  const t = (now - start) % 24; // 24s loop

  // Session 1: steadily working with two subagents and a background command,
  // timer already past 1 minute
  write(IDS[0], {
    project: "ccglance",
    title: "Translate README to English",
    status: "thinking",
    permissionMode: "plan",
    turnStartedAt: start - 74,
    agents: [
      { description: "Survey docs structure", type: "Explore", startedAt: start - 41 },
      { description: "Draft translation", type: "general-purpose", startedAt: start - 23 },
    ],
    tasks: [
      { id: "demo-bash-1", taskId: "b1", description: "npm run dev", startedAt: start - 62 },
    ],
  });

  // Session 2: editing -> awaiting permission -> thinking, on a loop. The clock
  // restarts on both edges of the wait (see restartClock in the hook), so the
  // timer resets when the prompt appears and again when the work resumes.
  const loop = now - t;
  let s2;
  if (t < 8) {
    // Still the work that resumed at t=16 of the previous cycle
    s2 = { status: "tool", tool: "Editing", turnStartedAt: loop - 8 };
  } else if (t < 16) {
    s2 = { status: "permission", message: "Awaiting permission", turnStartedAt: loop + 8 };
  } else {
    s2 = { status: "thinking", turnStartedAt: loop + 16 };
  }
  write(IDS[1], { project: "my-webapp", title: "Fix login redirect", permissionMode: "acceptEdits", ...s2 });

  // Session 3: finished, PR open
  write(IDS[2], {
    project: "my-webapp",
    title: "Add unit tests",
    status: "idle",
    permissionMode: "auto",
    pr: { number: 42, state: "OPEN", isDraft: false, url: null },
  });
}

function cleanup() {
  for (const id of IDS) {
    try { fs.unlinkSync(file(id)); } catch {}
  }
  console.log("\nDemo sessions removed.");
  process.exit(0);
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

tick();
setInterval(tick, 500);
console.log("Demo sessions running — the ccglance panel should now show 3 sessions.");
console.log("Record the panel (cmd+shift+5), then press Ctrl+C here to clean up.");
