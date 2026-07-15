#!/bin/bash
# Build ccglance.app — requires Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ccglance"
VERSION="1.5.1"   # for local builds; release CI syncs this from the tag (the tag is the source of truth)
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# Signing is ad-hoc by default. CI sets CODESIGN_IDENTITY to a
# "Developer ID Application: …" identity for notarized releases
# (see docs/NOTARIZATION.md).
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Swift…"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/$APP_NAME"

echo "Copying resources…"
cp hooks/ccglance-hook.js hooks/install.js hooks/uninstall.js "$APP/Contents/Resources/"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
cp "fonts/Font Awesome 6 Free-Solid-900.otf" "$APP/Contents/Resources/"
cp fonts/LICENSE.txt "$APP/Contents/Resources/Font-Awesome-LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ccglance</string>
    <key>CFBundleDisplayName</key><string>ccglance</string>
    <key>CFBundleIdentifier</key><string>com.hatoya.ccglance</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>ccglance</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "Signing (ad-hoc)…"
    codesign --force --sign - "$APP"
else
    # Hardened runtime + secure timestamp are required for notarization.
    echo "Signing ($CODESIGN_IDENTITY)…"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
fi

# Release assets: the app checks the zip's SHA-256 against the .sha256 asset
# before auto-installing an update, so BOTH files must be uploaded to the
# GitHub release together. The zip name is intentionally unversioned so the
# stable link releases/latest/download/ccglance.zip always works.
echo "Packaging release zip…"
ZIP_NAME="$APP_NAME.zip"
rm -f "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$ZIP_NAME.sha256"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$ZIP_NAME"
(cd "$BUILD_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

# Notarize when App Store Connect API key env vars are present (CI only —
# see docs/NOTARIZATION.md). Unset secrets reach CI as empty strings, so
# test for non-empty rather than set-ness. Ad-hoc signed builds are always
# rejected by Apple, so notarize only with a real identity.
if [ "$CODESIGN_IDENTITY" != "-" ] && [ -n "${NOTARY_API_KEY_PATH:-}" ] && [ -n "${NOTARY_API_KEY_ID:-}" ] && [ -n "${NOTARY_API_ISSUER_ID:-}" ]; then
    echo "Notarizing…"
    # notarytool has been known to exit 0 on an Invalid verdict, so parse
    # the JSON status instead of trusting the exit code.
    SUBMIT_JSON=$(xcrun notarytool submit "$BUILD_DIR/$ZIP_NAME" \
        --key "$NOTARY_API_KEY_PATH" \
        --key-id "$NOTARY_API_KEY_ID" \
        --issuer "$NOTARY_API_ISSUER_ID" \
        --wait --timeout 30m --output-format json) || true
    printf '%s\n' "$SUBMIT_JSON"
    STATUS=$(printf '%s' "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization failed (status: ${STATUS:-unknown})" >&2
        SUBMISSION_ID=$(printf '%s' "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
        if [ -n "$SUBMISSION_ID" ]; then
            xcrun notarytool log "$SUBMISSION_ID" \
                --key "$NOTARY_API_KEY_PATH" \
                --key-id "$NOTARY_API_KEY_ID" \
                --issuer "$NOTARY_API_ISSUER_ID" >&2 || true
        fi
        exit 1
    fi

    # Stapling can fail transiently until the ticket propagates to Apple's CDN.
    echo "Stapling…"
    for attempt in 1 2 3 4 5; do
        if xcrun stapler staple "$APP"; then
            break
        fi
        if [ "$attempt" = 5 ]; then
            echo "stapler failed after $attempt attempts" >&2
            exit 1
        fi
        echo "stapler failed (ticket may not have propagated yet), retrying in 10s…"
        sleep 10
    done

    # Stapling modifies the bundle, so the zip and checksum must be rebuilt.
    rm -f "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$ZIP_NAME.sha256"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/$ZIP_NAME"
    (cd "$BUILD_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
fi

echo ""
echo "Done: $APP"
echo "Install:  cp -R $APP /Applications/"
echo "Run:      open $APP"
echo "Release:  upload $BUILD_DIR/$ZIP_NAME and $BUILD_DIR/$ZIP_NAME.sha256"
