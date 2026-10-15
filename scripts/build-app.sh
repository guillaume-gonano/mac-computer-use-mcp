#!/usr/bin/env bash
# Builds the release binary and wraps it in "Mac Computer Use MCP.app", signed, in the given folder.
# The app bundle gives macOS a name and an identity to attach the permissions to.
#   scripts/build-app.sh <output folder>
# Environment: CODESIGN_IDENTITY (default "-", ad-hoc), BUNDLE_ID (default fr.semzen.mac-computer-use-mcp).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: scripts/build-app.sh <output folder>}"
BUNDLE_ID="${BUNDLE_ID:-fr.semzen.mac-computer-use-mcp}"
IDENTITY="${CODESIGN_IDENTITY:--}"
NAME="Mac Computer Use MCP"

swift build -c release --product mac-computer-use-mcp >&2
BIN="$(swift build -c release --show-bin-path)/mac-computer-use-mcp"
VERSION="$("$BIN" version)"

APP="$OUT/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mac-computer-use-mcp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>mac-computer-use-mcp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >&2
codesign --verify --strict "$APP"
echo "$APP"
