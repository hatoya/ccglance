#!/usr/bin/env node
// ccglance installer — copies the hook script to ~/.claude/ccglance/hooks/ and
// merges ccglance hooks into ~/.claude/settings.json (backed up first).
// Also registers into claude-desktop-switcher profiles
// (~/.context-switcher-claude/profiles/*/cli-data/settings.json) and, when set,
// $CLAUDE_CONFIG_DIR/settings.json, so sessions from isolated environments
// still reach the shared ~/.claude/ccglance/sessions/ store.
// Existing hooks are preserved; running twice is a no-op.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const HOOKS_DIR = path.join(CLAUDE_DIR, "ccglance", "hooks");
const HOOK_DEST = path.join(HOOKS_DIR, "ccglance-hook.js");
const HOOK_SRC = path.join(__dirname, "ccglance-hook.js");
const CSW_PROFILES_DIR = path.join(os.homedir(), ".context-switcher-claude", "profiles");

const EVENTS = [
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "Notification",
  // The desktop app signals permission prompts only through this event
  "PermissionRequest",
  "Stop",
];

const MARKER = "ccglance-hook.js";
const COMMAND = `node "${HOOK_DEST}"`;

function normalize(dir) {
  try {
    return fs.realpathSync(dir);
  } catch {
    return path.resolve(dir);
  }
}

// Every Claude Code config dir whose settings.json should carry the hooks.
// `required` marks the default target, whose failure aborts the install.
function settingsTargets() {
  const targets = [];
  const seen = new Set();
  const add = (configDir, required) => {
    const key = normalize(configDir);
    if (seen.has(key)) return;
    seen.add(key);
    targets.push({ settingsPath: path.join(configDir, "settings.json"), required });
  };

  add(CLAUDE_DIR, true);

  let entries = [];
  try {
    entries = fs.readdirSync(CSW_PROFILES_DIR, { withFileTypes: true });
  } catch {
    // Not a claude-desktop-switcher user
  }
  // Only profiles whose cli-data dir already exists (CSW creates it with the
  // profile): pre-creating it here would leave debris in profiles CSW hasn't
  // initialized. statSync (not entry.isDirectory) so symlinked profiles work.
  for (const entry of entries) {
    const cliData = path.join(CSW_PROFILES_DIR, entry.name, "cli-data");
    let stat;
    try {
      stat = fs.statSync(cliData);
    } catch {
      continue;
    }
    if (stat.isDirectory()) add(cliData, false);
  }

  const configDir = process.env.CLAUDE_CONFIG_DIR;
  if (typeof configDir === "string" && configDir.trim()) add(configDir, false);

  return targets;
}

// Merge ccglance hooks into one settings.json. Returns "installed",
// "unchanged", or "skipped" (unparseable non-default target).
function installInto(target) {
  const { settingsPath, required } = target;
  const backupPath = path.join(path.dirname(settingsPath), "settings.json.bak-ccglance");

  let settings = {};
  const exists = fs.existsSync(settingsPath);
  if (exists) {
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    } catch (e) {
      console.error(`Could not parse ${settingsPath}: ${e.message}`);
      if (required) {
        console.error("Fix the file and re-run this installer.");
        process.exit(1);
      }
      console.error("Skipping this environment.");
      return "skipped";
    }
  }

  // Guarded merge: a settings file with valid JSON but the wrong shape
  // (e.g. "hooks": "wat") must not crash the whole install run — other
  // environments still deserve their hooks.
  let changed = false;
  try {
    settings.hooks = settings.hooks || {};
    for (const event of EVENTS) {
      const groups = (settings.hooks[event] = settings.hooks[event] || []);
      const already = groups.some(
        (g) =>
          g &&
          Array.isArray(g.hooks) &&
          g.hooks.some((h) => typeof h.command === "string" && h.command.includes(MARKER))
      );
      if (!already) {
        groups.push({ hooks: [{ type: "command", command: COMMAND }] });
        changed = true;
      }
    }
  } catch (e) {
    console.error(`Could not merge hooks into ${settingsPath}: ${e.message}`);
    if (required) {
      console.error("Fix the file and re-run this installer.");
      process.exit(1);
    }
    console.error("Skipping this environment.");
    return "skipped";
  }
  if (!changed) return "unchanged";

  // Backup before touching anything
  if (exists) fs.copyFileSync(settingsPath, backupPath);
  else fs.mkdirSync(path.dirname(settingsPath), { recursive: true, mode: 0o700 });
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log(`ccglance hooks installed into ${settingsPath}`);
  if (exists) console.log(`(backup: ${backupPath})`);
  return "installed";
}

function main() {
  // 1. Copy hook script
  fs.mkdirSync(HOOKS_DIR, { recursive: true, mode: 0o700 });
  fs.copyFileSync(HOOK_SRC, HOOK_DEST);
  fs.mkdirSync(path.join(CLAUDE_DIR, "ccglance", "sessions"), { recursive: true, mode: 0o700 });

  // 2. Merge hooks into every target
  let installed = 0;
  for (const target of settingsTargets()) {
    if (installInto(target) === "installed") installed++;
  }
  if (installed > 0) {
    console.log("Restart any running Claude Code session to pick them up.");
  } else {
    console.log("ccglance hooks already installed — nothing to do.");
  }
}

main();
