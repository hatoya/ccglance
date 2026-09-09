#!/usr/bin/env node
// Packs PNGs extracted from icon/AppIcon.icns into windows/Assets/ccglance.ico
// (PNG-compressed ICO entries, valid since Windows Vista). No dependencies.
//
//   iconutil -c iconset icon/AppIcon.icns -o /path/to/AppIcon.iconset
//   node windows/tools/make-ico.js /path/to/AppIcon.iconset
"use strict";

const fs = require("fs");
const path = require("path");

const iconset = process.argv[2];
if (!iconset) {
  console.error("usage: make-ico.js <AppIcon.iconset>");
  process.exit(1);
}
const DEST = path.join(__dirname, "..", "Assets", "ccglance.ico");

// name → pixel size; 256 is the largest an ICO entry can declare
const ENTRIES = [
  ["icon_16x16.png", 16],
  ["icon_32x32.png", 32],
  ["icon_32x32@2x.png", 64],
  ["icon_128x128.png", 128],
  ["icon_256x256.png", 256],
];

const images = ENTRIES.map(([name, size]) => ({
  size,
  data: fs.readFileSync(path.join(iconset, name)),
}));

const header = Buffer.alloc(6);
header.writeUInt16LE(0, 0); // reserved
header.writeUInt16LE(1, 2); // type: icon
header.writeUInt16LE(images.length, 4);

const dir = Buffer.alloc(16 * images.length);
let offset = header.length + dir.length;
images.forEach((img, i) => {
  const e = i * 16;
  dir.writeUInt8(img.size === 256 ? 0 : img.size, e); // 0 means 256
  dir.writeUInt8(img.size === 256 ? 0 : img.size, e + 1);
  dir.writeUInt8(0, e + 2); // palette
  dir.writeUInt8(0, e + 3); // reserved
  dir.writeUInt16LE(1, e + 4); // planes
  dir.writeUInt16LE(32, e + 6); // bpp
  dir.writeUInt32LE(img.data.length, e + 8);
  dir.writeUInt32LE(offset, e + 12);
  offset += img.data.length;
});

fs.mkdirSync(path.dirname(DEST), { recursive: true });
fs.writeFileSync(DEST, Buffer.concat([header, dir, ...images.map((i) => i.data)]));
console.log(`wrote ${DEST} (${images.length} sizes)`);
