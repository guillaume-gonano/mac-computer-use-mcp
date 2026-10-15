# Guidelines for coding agents

Mac Computer Use MCP: a Swift package that lets AI agents read and drive macOS apps in the background through the accessibility API. See README.md for the user view, docs/EMBEDDING.md for the line protocol.

- Zero dependencies: Swift package, AppKit and system frameworks only.
- `Sources/ComputerUseCore`: `Engine.swift` (operations), `State.swift` (tree, diffs, screenshots), `Input.swift` (events, keys), `Apps.swift`, `Policy.swift` (blocked apps, approvals), `Tools.swift` (MCP tool schemas: the single source for listing and validation), `MCPServer.swift`, `LineServer.swift`, `Responsibility.swift`, `Indicator.swift`.
- Background first: prefer accessibility actions; post events to the target process only; never move the user's pointer; bring an app forward only when AppKit requires it, then restore the user's app.
- Safety rules are not optional: blocked apps checked in `resolve()`, screen lock checked before every operation, secure fields masked, screenshots never written to disk.
- Messages returned to agents are short English sentences that say what to do next.
- After a change: `swift build`, `swift test`, `scripts/smoke-test.sh`. Manual checks on a throwaway TextEdit document only, never on the user's real content; never send keystrokes while someone is using the Mac.
- Update README.md, docs/EMBEDDING.md and CHANGELOG.md when behaviour changes.
