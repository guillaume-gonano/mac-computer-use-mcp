#!/usr/bin/env bash
# Installs or updates Mac Computer Use MCP:
#   ~/Applications/Mac Computer Use MCP.app   the program (macOS grants the permissions to it)
#   ~/.local/bin/mac-computer-use-mcp         a shortcut to run it from a terminal
#
#   scripts/install.sh              install or update
#   scripts/install.sh --uninstall  remove the app, the shortcut and its permissions (approvals are kept)
#
# Environment: CODESIGN_IDENTITY (a certificate from your keychain keeps permissions across updates; default "-",
# ad-hoc), BUNDLE_ID, APPS_DIR (default ~/Applications), BIN_DIR (default ~/.local/bin).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-fr.semzen.mac-computer-use-mcp}"
APPS_DIR="${APPS_DIR:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP="$APPS_DIR/Mac Computer Use MCP.app"
EXE="$APP/Contents/MacOS/mac-computer-use-mcp"
LINK="$BIN_DIR/mac-computer-use-mcp"

reset_permissions() {
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
}
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$APP"
  [[ -L "$LINK" ]] && rm -f "$LINK"
  reset_permissions
  echo "Removed Mac Computer Use MCP and its permissions."
  echo "Your approvals are kept in ~/Library/Application Support/Mac Computer Use MCP (delete that folder to forget them)."
  echo "Remember to remove it from your MCP clients' configuration."
  exit 0
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "Building…"
BUILT="$(scripts/build-app.sh "$STAGE")"

PREVIOUS=""
[[ -d "$APP" ]] && PREVIOUS="$(cdhash "$APP")"
mkdir -p "$APPS_DIR" "$BIN_DIR"
rm -rf "$APP"
ditto "$BUILT" "$APP"
ln -sf "$EXE" "$LINK"

# An ad-hoc signature changes with every build: macOS would keep showing the old permission switched on while it no
# longer applies to the new program. Starting fresh avoids that confusing state.
if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$(cdhash "$APP")" && "${CODESIGN_IDENTITY:--}" == "-" ]]; then
  reset_permissions
  echo "Updated: the program changed, so its macOS permissions were reset. Grant them again (step 1 below)."
  echo "Restart your MCP clients so they use the new version."
fi

cat <<NEXT

Installed: $APP
Command:   $LINK$([[ ":$PATH:" == *":$BIN_DIR:"* ]] || echo "  (add $BIN_DIR to your PATH to type it directly)")

1. Grant the permissions (Accessibility is required, Screen Recording gives screenshots):
     $LINK permissions

2. Add the server to your MCP client, for example:
     Claude Code:  claude mcp add --scope user mac-computer-use -- $LINK mcp
     Codex:        codex mcp add mac-computer-use -- $LINK mcp
     JSON config:  { "mcpServers": { "mac-computer-use": { "command": "$LINK", "args": ["mcp"] } } }

3. Check everything:
     $LINK doctor
NEXT
