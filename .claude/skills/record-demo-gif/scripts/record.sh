#!/bin/bash
# Records the README demo GIF frames. See SKILL.md for the full workflow —
# the app must already be built WITH the RECORDING ONLY session filter.
#
# Usage: record.sh <repo-root> <workdir>
# Leaves 240 PNG frames in <workdir>/frames and tool binaries in <workdir>/bin.
set -u

REPO="$1"
WORK="$2"
SKILL="$(cd "$(dirname "$0")" && pwd)"
SESS="$HOME/.claude/ccglance/sessions"
BIN="$WORK/bin"
FRAMES="$WORK/frames"
mkdir -p "$BIN" "$FRAMES"
rm -f "$FRAMES"/*.png

# The filter keeps other sessions' hook writes out of the panel; recording
# without it produces leaked rows. Refuse to run on a clean build.
if ! grep -q "RECORDING ONLY" "$REPO/Sources/main.swift"; then
  echo "Sources/main.swift lacks the RECORDING ONLY filter — apply it and rebuild first (see SKILL.md)" >&2
  exit 1
fi
if [ ! -d "$REPO/build/ccglance.app" ]; then
  echo "build/ccglance.app not found — run bash build.sh first" >&2
  exit 1
fi

echo "== compiling tools =="
for t in extractbg bgwin capture gifenc verify; do
  [ -x "$BIN/$t" ] || swiftc -O "$SKILL/$t.swift" -o "$BIN/$t" || exit 1
done

if [ ! -f "$WORK/bg.png" ]; then
  echo "== extracting aerial still =="
  MOV=$(ls "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/"8002C4C8-*.mov 2>/dev/null | head -1)
  if [ -z "$MOV" ]; then
    echo "aerial asset not found; download the canyon aerial in System Settings > Screen Saver" >&2
    exit 1
  fi
  "$BIN/extractbg" "$MOV" "$WORK/bg.png" || exit 1
fi

NODE_PID=""
DOG_PID=""
BG_PID=""
SAVED_WIDTH=""
WIDTH_CHANGED=0
CLEANED=0
cleanup() {
  [ "$CLEANED" = 1 ] && return
  CLEANED=1
  echo "== cleanup =="
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
  [ -n "$DOG_PID" ] && kill "$DOG_PID" 2>/dev/null
  sleep 0.3
  pkill -9 -x ccglance 2>/dev/null
  [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null
  wait 2>/dev/null
  sleep 1
  rm -f "$SESS"/demo-readme-*.json
  if [ "$WIDTH_CHANGED" = 1 ]; then
    if [ -n "$SAVED_WIDTH" ]; then
      defaults write com.hatoya.ccglance ccglancePanelWidth -float "$SAVED_WIDTH"
    else
      # The key did not exist before; leaving 435 would silently override
      # the app's built-in default width
      defaults delete com.hatoya.ccglance ccglancePanelWidth 2>/dev/null
    fi
  fi
  open /Applications/ccglance.app
}
trap cleanup EXIT INT TERM

echo "== stopping installed ccglance =="
osascript -e 'tell application "ccglance" to quit' 2>/dev/null || true
sleep 0.5
pkill -x ccglance 2>/dev/null || true
sleep 0.5

# Record at the README's canonical width (435pt -> 523pt region -> 1046px @2x)
SAVED_WIDTH=$(defaults read com.hatoya.ccglance ccglancePanelWidth 2>/dev/null || echo "")
defaults write com.hatoya.ccglance ccglancePanelWidth -float 435
WIDTH_CHANGED=1

echo "== launching recording build =="
open "$REPO/build/ccglance.app"
REC_PID=""
for _ in $(seq 1 30); do
  REC_PID=$(pgrep -x ccglance | head -1)
  [ -n "$REC_PID" ] && break
  sleep 0.5
done
if [ -z "$REC_PID" ]; then
  echo "recording build did not start" >&2
  exit 1
fi
sleep 2
echo "recording instance pid=$REC_PID"

# Watchdog: another session may launch its own (unfiltered) ccglance mid-
# recording, which lands at the same saved origin and covers our panel.
(
  while true; do
    for p in $(pgrep -x ccglance); do
      [ "$p" != "$REC_PID" ] && kill -9 "$p" 2>/dev/null
    done
    sleep 0.3
  done
) &
DOG_PID=$!

echo "== injecting demo sessions =="
node "$REPO/docs/demo-sessions.js" > /dev/null 2>&1 &
NODE_PID=$!
NODE_START=$(date +%s)
sleep 2

echo "== launching bgwin (sized to grown panel + margin) =="
"$BIN/bgwin" "$WORK/bg.png" &
BG_PID=$!
sleep 1

NOW=$(date +%s)
WAIT=$(( 24 - (NOW - NODE_START) % 24 ))
echo "== waiting ${WAIT}s for the 24s demo-loop boundary =="
sleep "$WAIT"

echo "== capturing 240 frames @10fps =="
"$BIN/capture" "$FRAMES" 240 10
RC=$?

cleanup
echo "== done rc=$RC =="
exit $RC
