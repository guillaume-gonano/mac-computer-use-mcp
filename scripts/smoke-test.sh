#!/usr/bin/env bash
# Starts the real binary as an MCP client would and checks the handshake, the tool list and a refused call.
# Needs no permission and touches no app, so it runs in CI.
#   scripts/smoke-test.sh [path to the binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-$(swift build -c release --show-bin-path)/mac-computer-use-mcp}"

session() {
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{}}}' \
    | "$@" "$BIN" mcp --no-indicator
}
check() {
  python3 -c '
import json, sys
label, replies = sys.argv[1], {}
for line in sys.stdin:
    message = json.loads(line)
    replies[message["id"]] = message
assert replies[1]["result"]["protocolVersion"] == "2025-06-18", "initialize"
assert len(replies[2]["result"]["tools"]) == 11, "tools/list"
assert replies[3]["result"]["isError"] is True, "invalid call refused"
print("ok (%s)" % label)
' "$1"
}

# Both ways of starting: as its own responsible process (default) and inside the caller's.
session env | check "own responsible process"
session env MAC_COMPUTER_USE_MCP_NO_DISCLAIM=1 | check "inherited responsibility"
[[ "$("$BIN" version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: version"; exit 1; }
echo "Smoke test passed."
