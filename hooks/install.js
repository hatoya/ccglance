#!/usr/bin/env node
// ccglance installer — copies the hook script to ~/.claude/ccglance/hooks/ and
// merges ccglance hooks into ~/.claude/settings.json (backed up first).
// Existing hooks are preserved; running twice is a no-op.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS = path.join(CLAUDE_DIR, "settings.json");
const BACKUP = path.join(CLAUDE_DIR, "settings.json.bak-ccglance");
const HOOKS_DIR = path.join(CLAUDE_DIR, "ccglance", "hooks");
const HOOK_DEST = path.join(HOOKS_DIR, "ccglance-hook.js");
const HOOK_SRC = path.join(__dirname, "ccglance-hook.js");

const EVENTS = [
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "Notification",
  "Stop",
];

const MARKER = "ccglance-hook.js";
const COMMAND = `node "${HOOK_DEST}"`;

function main() {
  // 1. Copy hook script
  fs.mkdirSync(HOOKS_DIR, { recursive: true, mode: 0o700 });
  fs.copyFileSync(HOOK_SRC, HOOK_DEST);
  fs.mkdirSync(path.join(CLAUDE_DIR, "ccglance", "sessions"), { recursive: true, mode: 0o700 });

  // 2. Load settings
  let settings = {};
  if (fs.existsSync(SETTINGS)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    } catch (e) {
      console.error(`Could not parse ${SETTINGS}: ${e.message}`);
      console.error("Fix the file and re-run this installer.");
      process.exit(1);
    }
    // Backup before touching anything
    fs.copyFileSync(SETTINGS, BACKUP);
  }

  // 3. Merge hooks
  settings.hooks = settings.hooks || {};
  let changed = false;
  for (const event of EVENTS) {
    const groups = (settings.hooks[event] = settings.hooks[event] || []);
    const already = groups.some(
      (g) =>
        Array.isArray(g.hooks) &&
        g.hooks.some((h) => typeof h.command === "string" && h.command.includes(MARKER))
    );
    if (!already) {
      groups.push({ hooks: [{ type: "command", command: COMMAND }] });
      changed = true;
    }
  }

  // 4. Write back
  if (changed) {
    fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
    console.log(`ccglance hooks installed into ${SETTINGS}`);
    console.log(`(backup: ${BACKUP})`);
    console.log("Restart any running Claude Code session to pick them up.");
  } else {
    console.log("ccglance hooks already installed — nothing to do.");
  }
}

main();
