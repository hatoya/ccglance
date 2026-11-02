// Test shim for `node -r`: keeps the hook off the real machine (no app
// launch, no gh, no detached children) and can fake the platform so the
// win32 branches run on any OS. Never used in production.
"use strict";

const cp = require("child_process");
const fs = require("fs");
const { EventEmitter } = require("events");

function fakeChild() {
  const child = new EventEmitter();
  child.unref = () => {};
  return child;
}

cp.spawn = () => fakeChild();
cp.execFile = (file, args, opts, cb) => {
  const done = typeof opts === "function" ? opts : cb;
  if (done) {
    const err = new Error("stubbed");
    err.code = "ENOENT";
    process.nextTick(() => done(err, "", ""));
  }
  return fakeChild();
};
cp.execSync = () => Buffer.from("");

const platform = process.env.CCGLANCE_TEST_PLATFORM;
if (platform) Object.defineProperty(process, "platform", { value: platform });

// Fail the first N renames onto a state file with EPERM to exercise the
// Windows retry path of replaceFile()
let failRenames = Number(process.env.CCGLANCE_TEST_FAIL_RENAMES || 0);
if (failRenames > 0) {
  const realRename = fs.renameSync;
  fs.renameSync = (from, to) => {
    if (failRenames > 0 && String(to).endsWith(".json")) {
      failRenames--;
      const err = new Error("EPERM: operation not permitted");
      err.code = "EPERM";
      throw err;
    }
    return realRename(from, to);
  };
}
