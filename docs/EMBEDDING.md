# Embedding the engine in your own app

Use this mode if you are building your own agent app and want Computer Use to be part of it, not a separate MCP server. It is how the engine was born: a personal agent dashboard ran it as a helper and served its own tools to several agents.

```sh
mac-computer-use-mcp jsonl [--no-indicator]
```

## What changes compared with `mcp`

| | `mcp` | `jsonl` |
|---|---|---|
| Who holds the macOS permissions | Mac Computer Use MCP itself | **Your app** (the process that launches the binary) |
| Asks the user before a new app | Yes, a native dialog | **No: your app decides** |
| Password managers blocked | Yes | Yes |
| Screen lock pauses actions | Yes | Yes |
| Agent cursor and badge | Yes (`--no-indicator` to turn off) | Yes (`--no-indicator` to turn off) |
| Output | MCP tool results | Raw JSON (below) |

### Permissions

In `jsonl` mode the binary does **not** restart itself as its own responsible process. macOS checks the permissions of your app instead, and lists your app in System Settings. In practice:

- ship the binary inside your app bundle (for example `Contents/MacOS/` or `Contents/Helpers/`), signed with the same certificate as your app;
- ask the user to grant **Accessibility** (required) and **Screen & System Audio Recording** (screenshots) to your app;
- sign with a stable certificate, so permissions survive updates.

## Protocol

Send one JSON object per line on stdin; one answer per line comes back on stdout. Requests are handled one at a time, in order.

```json
{"id": 1, "op": "get_app_state", "input": {"app": "TextEdit"}}
```

```json
{"id": 1, "result": {"app": "TextEdit", "bundleId": "com.apple.TextEdit", "pid": 4242, "text": "Window: \"Untitled\", App: TextEdit.\n0 standard window …", "screenshot": "iVBORw0KGgo…", "screenshotWidth": 1568, "screenshotHeight": 1020, "screenshotScale": 2}}
```

```json
{"id": 2, "error": "Call get_app_state for TextEdit first."}
```

`id` can be any JSON value; it is echoed back. Lines that are not valid JSON are ignored.

### Operations

| `op` | `input` | `result` |
|---|---|---|
| `permissions` | none | `{"accessibility": bool, "screenRecording": bool}` |
| `request_screen_recording` | none | `{"screenRecording": bool}` (shows the macOS request once) |
| `resolve` | `app` | `{"name", "bundleId", "path", "running"}`: use it to ask your user before the first use of an app |
| `list_apps` | none | `[{"id", "displayName", "isRunning", "lastUsedDate"?, "useCount"?}]` |
| `get_app_state` | `app`, `disableDiff`? | See above. `screenshot` is a base64 PNG; without the permission, `screenshotDenied: true` |
| `click` | `app`, `element_index` or `x`+`y`, `mouse_button`?, `click_count`?, `key`? | Confirmation sentence |
| `perform_secondary_action` | `app`, `element_index`, `action` | Confirmation sentence |
| `set_value` | `app`, `element_index`, `value` | Confirmation sentence |
| `select_text` | `app`, `element_index`, `text`, `prefix`?, `suffix`?, `selection_type`? | Confirmation sentence |
| `scroll` | `app`, `direction`, `element_index` or `x`+`y`?, `pages`? | Confirmation sentence |
| `drag` | `app`, `from_x`, `from_y`, `to_x`, `to_y` | Confirmation sentence |
| `press_key` | `app`, `key`, `duration`? | Confirmation sentence |
| `type_text` | `app`, `text` | Confirmation sentence |
| `paste` | `app`, `text`, `format` (`text`, `md`, `html`) | Confirmation sentence |

The arguments mean the same as in the MCP tools ([README](../README.md#tools)). The MCP server checks their types and limits, and the line protocol trusts your app to do the same. `app` accepts a display name, a full `.app` path or a bundle identifier. Coordinates are pixels of the latest screenshot of that app.

Actions need a `get_app_state` of the same app first. That call is what numbers the elements.

### Errors to handle

- `ACCESSIBILITY_DENIED`: your app lacks the Accessibility permission. Call `AXIsProcessTrustedWithOptions` with the prompt option from your app, or send the user to System Settings.
- `The screen is locked…`: wait for the user.
- `… is a password manager…`: the app is blocked; never retry.
- Anything else is a sentence meant for the agent: pass it on as the tool error.

## A minimal host in Node.js

```js
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const engine = spawn('/path/to/YourApp.app/Contents/MacOS/mac-computer-use-mcp', ['jsonl'], { stdio: ['pipe', 'pipe', 'inherit'] });
const waiting = new Map();
let nextId = 0;
createInterface({ input: engine.stdout }).on('line', line => {
  const { id, result, error } = JSON.parse(line);
  const pending = waiting.get(id);
  waiting.delete(id);
  error ? pending?.reject(new Error(error)) : pending?.resolve(result);
});
const call = (op, input = {}) => new Promise((resolve, reject) => {
  const id = ++nextId;
  waiting.set(id, { resolve, reject });
  engine.stdin.write(JSON.stringify({ id, op, input }) + '\n');
});

const target = await call('resolve', { app: 'TextEdit' });
// …ask your user whether agents may use target.name, then:
const state = await call('get_app_state', { app: target.bundleId });
console.log(state.text);
```

Queue your agents' calls if several of them share one engine: two agents typing into the same window at once is never what anyone wants.
