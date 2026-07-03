#!/usr/bin/env node
// ccglance uninstaller — removes only ccglance hooks from ~/.claude/settings.json
// and deletes ~/.claude/ccglance/. Other hooks are left untouched.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS = path.join(CLAUDE_DIR, "settings.json");
const CCGLANCE_DIR = path.join(CLAUDE_DIR, "ccglance");
const MARKER = "ccglance-hook.js";

function main() {
  if (fs.existsSync(SETTINGS)) {
    let settings;
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    } catch (e) {
      console.error(`Could not parse ${SETTINGS}: ${e.message}`);
      process.exit(1);
    }
    if (settings.hooks) {
      let changed = false;
      for (const event of Object.keys(settings.hooks)) {
        const before = settings.hooks[event].length;
        settings.hooks[event] = settings.hooks[event].filter(
          (g) =>
            !(
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
        fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
        console.log("ccglance hooks removed from settings.json");
      } else {
        console.log("No ccglance hooks found in settings.json");
      }
    }
  }

  fs.rmSync(CCGLANCE_DIR, { recursive: true, force: true });
  console.log(`Removed ${CCGLANCE_DIR}`);
  console.log("You can now move ccglance.app to the Trash.");
}

main();
