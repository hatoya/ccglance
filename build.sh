#!/bin/bash
# Build ccglance.app — requires Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ccglance"
VERSION="1.0.0"   # single source of truth — release tags are v$VERSION
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Swift…"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/$APP_NAME"

echo "Copying resources…"
cp hooks/ccglance-hook.js hooks/install.js hooks/uninstall.js "$APP/Contents/Resources/"
cp icon/AppIcon.icns "$APP/Contents/Resources/"

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

echo "Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

# Release assets: the app checks the zip's SHA-256 against the .sha256 asset
# before auto-installing an update, so BOTH files must be uploaded to the
# GitHub release together.
echo "Packaging release zip…"
ZIP_NAME="$APP_NAME-v$VERSION.zip"
rm -f "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$ZIP_NAME.sha256"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$ZIP_NAME"
(cd "$BUILD_DIR" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

echo ""
echo "Done: $APP"
echo "Install:  cp -R $APP /Applications/"
echo "Run:      open $APP"
echo "Release:  upload $BUILD_DIR/$ZIP_NAME and $BUILD_DIR/$ZIP_NAME.sha256"
