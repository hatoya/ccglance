#!/usr/bin/env node
// ccglance uninstaller — removes only ccglance hooks from ~/.claude/settings.json
// (and from claude-desktop-switcher profiles / $CLAUDE_CONFIG_DIR, mirroring the
// installer) and deletes ~/.claude/ccglance/. Other hooks are left untouched.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const CCGLANCE_DIR = path.join(CLAUDE_DIR, "ccglance");
const CSW_PROFILES_DIR = path.join(os.homedir(), ".context-switcher-claude", "profiles");
const MARKER = "ccglance-hook.js";

function normalize(dir) {
  try {
    return fs.realpathSync(dir);
  } catch {
    return path.resolve(dir);
  }
}

// Same enumeration as install.js so every registered copy is removed.
function settingsPaths() {
  const paths = [];
  const seen = new Set();
  const add = (configDir) => {
    const key = normalize(configDir);
    if (seen.has(key)) return;
    seen.add(key);
    paths.push(path.join(configDir, "settings.json"));
  };

  add(CLAUDE_DIR);

  let entries = [];
  try {
    entries = fs.readdirSync(CSW_PROFILES_DIR, { withFileTypes: true });
  } catch {
    // Not a claude-desktop-switcher user
  }
  for (const entry of entries) {
    const cliData = path.join(CSW_PROFILES_DIR, entry.name, "cli-data");
    let stat;
    try {
      stat = fs.statSync(cliData);
    } catch {
      continue;
    }
    if (stat.isDirectory()) add(cliData);
  }

  const configDir = process.env.CLAUDE_CONFIG_DIR;
  if (typeof configDir === "string" && configDir.trim()) add(configDir);

  return paths;
}

function removeFrom(settingsPath) {
  if (!fs.existsSync(settingsPath)) return;
  let settings;
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (e) {
    console.error(`Could not parse ${settingsPath}: ${e.message}`);
    console.error("Skipping this file.");
    return;
  }
  if (!settings.hooks || typeof settings.hooks !== "object") return;
  let changed = false;
  for (const event of Object.keys(settings.hooks)) {
    if (!Array.isArray(settings.hooks[event])) continue;
    const before = settings.hooks[event].length;
    settings.hooks[event] = settings.hooks[event].filter(
      (g) =>
        !(
          g &&
          Array.isArray(g.hooks) &&
          g.hooks.some(
            (h) => typeof h.command === "string" && h.command.includes(MARKER)
          )
        )
    );
    if (settings.hooks[event].length !== before) changed = true;
    if (settings.hooks[event].length === 0) delete settings.hooks[event];
  }
  if (changed) {
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
    console.log(`ccglance hooks removed from ${settingsPath}`);
  }
}

function main() {
  for (const settingsPath of settingsPaths()) removeFrom(settingsPath);

  fs.rmSync(CCGLANCE_DIR, { recursive: true, force: true });
  console.log(`Removed ${CCGLANCE_DIR}`);
  console.log("You can now move ccglance.app to the Trash.");
}

main();
