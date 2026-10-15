# Changelog

## Unreleased

- Redesigned agent cursor, closer to Codex's: a rounded arrowhead without a tail (light grey, white edge) on a soft dark halo, readable on any background.
- The server becomes its own responsible process only when it runs from its app bundle. Run from a source folder in Documents, it used to wait for a folder-access prompt before it could even start.
- The agent cursor glides over 0.6 s with a gentle start and landing, so the motion stays visible and the click lands as it arrives (it used to cover 80% of the way in 0.1 s, then creep).

## 0.1.1 (2026-10-15)

- Fix: the agent cursor now glides to each target before acting. It used to appear and sway without moving, because macOS silently ignores animated `setFrameOrigin` on a window.

## 0.1.0 (2026-10-15)

First public release.

- MCP server over stdio with 11 tools: `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `set_value`, `select_text`, `scroll`, `drag`, `press_key`, `type_text`, `paste`.
- Background operation: accessibility actions first, other events posted to the target process only.
- Accessibility tree with stable element indices and diffs; window-only screenshots kept in memory.
- Per-app approval dialog (session / always / refuse), `apps` command, `--allow` and `--allow-all`.
- Password managers blocked, actions paused while the screen is locked, secure fields masked.
- Agent cursor and in-use badge, `--no-indicator` to turn them off.
- Permissions held by the app itself, not the launching terminal (`doctor` shows it).
- `jsonl` line protocol for apps that embed the engine.
