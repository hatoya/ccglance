#!/usr/bin/env node
// Generates windows/CrabFrames.cs from Sources/CrabFrames.swift so both
// clients animate the same PNG frames. `--check` exits 1 when the committed
// C# file is out of date.
//
//   node windows/tools/gen-crab-frames.js [--check]
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "..");
const SRC = path.join(ROOT, "Sources", "CrabFrames.swift");
const DEST = path.join(ROOT, "windows", "CrabFrames.cs");
const EXPECTED_FRAMES = 20;

const swift = fs.readFileSync(SRC, "utf8");
const frames = [...swift.matchAll(/"([A-Za-z0-9+/=]{100,})"/g)].map((m) => m[1]);
if (frames.length !== EXPECTED_FRAMES) {
  console.error(`expected ${EXPECTED_FRAMES} frames in ${SRC}, found ${frames.length}`);
  process.exit(1);
}

const lines = [
  "// Generated from Sources/CrabFrames.swift by windows/tools/gen-crab-frames.js",
  "// (do not edit by hand). 20 frames, 51x36 px PNGs, base64.",
  "namespace CcGlance;",
  "",
  "internal static class CrabFrames",
  "{",
  "    public static readonly string[] Base64 =",
  "    [",
  ...frames.map((f) => `        "${f}",`),
  "    ];",
  "}",
  "",
];
const out = lines.join("\n");

if (process.argv.includes("--check")) {
  let current = null;
  try {
    // Git on Windows may check the file out with CRLF
    current = fs.readFileSync(DEST, "utf8").replace(/\r\n/g, "\n");
  } catch {}
  if (current !== out) {
    console.error(`${DEST} is out of date; run node windows/tools/gen-crab-frames.js`);
    process.exit(1);
  }
  console.log("CrabFrames.cs is up to date");
} else {
  fs.writeFileSync(DEST, out);
  console.log(`wrote ${DEST} (${frames.length} frames)`);
}
