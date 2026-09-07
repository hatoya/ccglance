#!/usr/bin/env node
// Fixture smoke test for the hooks: replays hooks/test/events/*.json into
// ccglance-hook.js under a throwaway home directory and checks the resulting
// session file, then exercises install.js / uninstall.js against the same
// home. Runs once natively and once with the platform faked to win32.
//
//   node hooks/test/run.js
"use strict";

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const HOOKS_DIR = path.join(__dirname, "..");
const HOOK = path.join(HOOKS_DIR, "ccglance-hook.js");
const INSTALL = path.join(HOOKS_DIR, "install.js");
const UNINSTALL = path.join(HOOKS_DIR, "uninstall.js");
const PRELOAD = path.join(__dirname, "preload.js");
const EVENTS_DIR = path.join(__dirname, "events");
const SESSION_ID = "ccglance-test-0001";
const EVENT_NAMES = [
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "Notification",
  "PermissionRequest",
  "Stop",
];

function run(script, { home, input, extraEnv }) {
  const env = { ...process.env, HOME: home, USERPROFILE: home, WT_SESSION: "test-wt", ...extraEnv };
  // Whatever launched this test run must not leak into the captured host, and
  // on a real Windows box the hook must not walk the real Desktop store or
  // resolve real installs
  for (const k of [
    "CLAUDE_CONFIG_DIR",
    "__CFBundleIdentifier",
    "TERM_PROGRAM",
    "ITERM_SESSION_ID",
    "CCGLANCE_EXE",
    "APPDATA",
    "LOCALAPPDATA",
    "ProgramFiles",
  ]) {
    delete env[k];
  }
  const r = spawnSync(process.execPath, ["-r", PRELOAD, script], {
    input,
    env,
    encoding: "utf8",
    timeout: 10000,
  });
  assert.strictEqual(
    r.status,
    0,
    `${path.basename(script)} exited ${r.status}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`
  );
  return r;
}

function readState(home) {
  const file = path.join(home, ".claude", "ccglance", "sessions", `${SESSION_ID}.json`);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

// What the state must look like after each fixture (checked in file order)
const EXPECT = {
  "01-session-start.json": (s) => {
    assert.strictEqual(s.status, "idle");
    assert.strictEqual(s.project, "demo-project");
    assert.strictEqual(s.turnActive, false);
    assert.ok(typeof s.createdAt === "number" && typeof s.updatedAt === "number");
    assert.deepStrictEqual(Object.keys(s.host).slice(0, 4), [
      "bundleId",
      "termProgram",
      "itermSessionId",
      "tty",
    ]);
  },
  "02-user-prompt-submit.json": (s) => {
    assert.strictEqual(s.status, "thinking");
    assert.strictEqual(s.turnActive, true);
    assert.ok(typeof s.turnStartedAt === "number");
  },
  "03-pre-tool-use.json": (s) => {
    assert.strictEqual(s.status, "tool");
    assert.strictEqual(s.tool, "Running command");
  },
  "04-permission-request.json": (s) => {
    assert.strictEqual(s.status, "permission");
    assert.strictEqual(s.message, "Awaiting permission");
    assert.ok(typeof s.waitStartedAt === "number");
  },
  "05-post-tool-use.json": (s) => {
    assert.strictEqual(s.status, "thinking");
    assert.strictEqual(s.tool, null);
    assert.strictEqual(s.waitStartedAt, null);
  },
  "06-stop.json": (s) => {
    assert.strictEqual(s.status, "idle");
    assert.strictEqual(s.turnStartedAt, null);
    assert.strictEqual(s.turnActive, false);
    assert.ok(!("pendingCalls" in s));
  },
  "07-session-end.json": (s) => {
    assert.strictEqual(s, null, "SessionEnd must delete the state file");
  },
};

function testHook(home, platform, extraEnv) {
  const files = fs.readdirSync(EVENTS_DIR).filter((f) => f.endsWith(".json")).sort();
  assert.deepStrictEqual(Object.keys(EXPECT).sort(), files, "every fixture needs an expectation");
  for (const f of files) {
    run(HOOK, { home, input: fs.readFileSync(path.join(EVENTS_DIR, f), "utf8"), extraEnv });
    const state = readState(home);
    EXPECT[f](state);
    if (state && platform === "win32") {
      assert.strictEqual(state.host.wtSessionId, "test-wt");
      assert.ok("wtProfileId" in state.host && "winSessionName" in state.host);
      assert.strictEqual(state.host.bundleId, null);
    } else if (state) {
      assert.ok(!("wtSessionId" in state.host), "macOS output must not grow Windows keys");
    }
  }
  // Nothing but the state file may be left behind (no tmp/lock residue)
  const sessionsDir = path.join(home, ".claude", "ccglance", "sessions");
  assert.deepStrictEqual(fs.readdirSync(sessionsDir), []);
}

function testInstaller(home, platform, extraEnv) {
  const settingsPath = path.join(home, ".claude", "settings.json");
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  // Pre-existing foreign hook must survive install and uninstall
  const foreign = { hooks: { Stop: [{ hooks: [{ type: "command", command: "echo other" }] }] } };
  fs.writeFileSync(settingsPath, JSON.stringify(foreign, null, 2) + "\n");

  run(INSTALL, { home, extraEnv });
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  for (const ev of EVENT_NAMES) {
    const groups = settings.hooks[ev];
    const ours = groups.filter((g) => g.hooks.some((h) => h.command.includes("ccglance-hook.js")));
    assert.strictEqual(ours.length, 1, `${ev} must carry exactly one ccglance hook`);
    const cmd = ours[0].hooks[0].command;
    assert.ok(cmd.startsWith('node "') && cmd.endsWith('"'), cmd);
    // The slash conversion itself is only observable with real backslash
    // paths (path stays posix under the faked platform)
    if (platform === "win32") assert.ok(!cmd.includes("\\"), cmd);
  }
  assert.strictEqual(settings.hooks.Stop.length, 2, "foreign Stop hook preserved");
  assert.ok(fs.existsSync(path.join(home, ".claude", "ccglance", "hooks", "ccglance-hook.js")));
  assert.ok(fs.existsSync(path.join(home, ".claude", "settings.json.bak-ccglance")));

  const again = run(INSTALL, { home, extraEnv });
  assert.ok(/already installed/.test(again.stdout), again.stdout);

  run(UNINSTALL, { home, extraEnv });
  const after = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  assert.deepStrictEqual(after, foreign, "uninstall must leave only the foreign hook");
  assert.ok(!fs.existsSync(path.join(home, ".claude", "ccglance")));
}

function runSuite(label, platform, extraEnv) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ccglance-hooks-test-"));
  try {
    testHook(home, platform, extraEnv);
    testInstaller(home, platform, extraEnv);
    console.log(`ok  ${label}`);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

runSuite("native", process.platform, {});
// Faked win32: exercises the Windows branches (launch/gh candidate resolution
// with unset env vars, host keys, slash command, rename retry) on any OS.
// Real backslash paths and sharing violations still need a Windows machine.
runSuite("win32 (faked)", "win32", {
  CCGLANCE_TEST_PLATFORM: "win32",
  CCGLANCE_TEST_FAIL_RENAMES: "2",
});
console.log("all hook tests passed");
