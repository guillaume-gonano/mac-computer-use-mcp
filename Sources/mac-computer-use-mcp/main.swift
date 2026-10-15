import AppKit
import ApplicationServices
import ComputerUseCore

// Command-line entry point. Started by an MCP client (`mcp`), by an app that embeds it (`jsonl`), or by the user to
// check and grant permissions and to manage the per-app approvals.

let usage = """
Mac Computer Use MCP \(Version.current): lets AI agents use macOS apps in the background.

Usage: mac-computer-use-mcp <command> [options]

Commands:
  mcp            Run the MCP server on stdin/stdout (what MCP clients start).
                   --allow-all        Do not ask before an agent uses a new app.
                   --allow <ids>      Pre-approve apps for this session (bundle ids, comma-separated, repeatable).
                   --no-indicator     Do not draw the agent cursor and the purple "in use" badge.
  doctor         Show permissions, the process macOS holds responsible, and the approvals file.
  permissions    Ask macOS for the Accessibility and Screen Recording permissions.
  apps           List remembered approvals.
  apps allow <id> | deny <id> | forget <id> | reset
                 Remember a decision for an app (bundle identifier, e.g. com.apple.TextEdit), forget one, or all.
  jsonl          Line protocol for apps that embed this binary (see docs/EMBEDDING.md). No approval dialog.
  version        Print the version.

Docs: https://github.com/guillaume-gonano/mac-computer-use-mcp
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac-computer-use-mcp: \(message)\n".utf8))
    exit(2)
}
func status(_ ok: Bool) -> String { ok ? "granted" : "not granted" }

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()
setvbuf(stdout, nil, _IOLBF, 0)

switch command {
case "mcp":
    var mode = ApprovalMode.ask, preApproved: Set<String> = []
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--allow-all": mode = .allowAll
        case "--no-indicator": Indicator.isEnabled = false
        case "--allow":
            guard !arguments.isEmpty else { fail("--allow needs bundle identifiers, e.g. --allow com.apple.TextEdit") }
            for id in arguments.removeFirst().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
                guard validBundleId(id) else { fail("invalid bundle identifier '\(id)'") }
                preApproved.insert(id)
            }
        case let other: fail("unknown option '\(other)' for mcp")
        }
    }
    Responsibility.disclaimIfNeeded()
    // No Dock icon; the only windows are the indicator panels and, on a new app, the approval dialog.
    NSApplication.shared.setActivationPolicy(.accessory)
    let server = MCPServer(executor: ComputerTools(approvals: Approvals(mode: mode, preApproved: preApproved)))
    Thread.detachNewThread { server.run(); exit(0) }
    NSApplication.shared.run()

case "jsonl":
    // The embedding app is the responsible process and owns the permissions: no disclaim, no window but the indicator.
    if arguments.contains("--no-indicator") { Indicator.isEnabled = false }
    NSApplication.shared.setActivationPolicy(.prohibited)
    Thread.detachNewThread { LineServer.run(); exit(0) }
    RunLoop.main.run()

case "doctor":
    Responsibility.disclaimIfNeeded()
    let path = Responsibility.executablePath() ?? CommandLine.arguments[0]
    let bundle = Bundle.main.bundleIdentifier
    print("Mac Computer Use MCP \(Version.current)")
    print("Executable:        \(path)")
    print("App bundle:        \(bundle.map { "\($0) (\(Bundle.main.bundlePath))" } ?? "none: install with scripts/install.sh so macOS lists it by name")")
    if let responsible = Responsibility.responsiblePid() {
        let name = NSRunningApplication(processIdentifier: responsible)?.localizedName ?? "pid \(responsible)"
        print("Responsible:       \(responsible == getpid() ? "itself (permissions belong to Mac Computer Use MCP)" : "\(name): permissions are checked for that app")")
    }
    print("Accessibility:     \(status(AXIsProcessTrusted()))")
    print("Screen Recording:  \(status(CGPreflightScreenCaptureAccess())) (optional: screenshots)")
    print("Screen locked:     \(screenLocked() ? "yes (actions paused)" : "no")")
    let store = ApprovalStore()
    print("Approvals:         \(store.load().count) remembered in \(store.url.path)")
    exit(AXIsProcessTrusted() ? 0 : 1)

case "permissions":
    Responsibility.disclaimIfNeeded()
    let accessibility = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    print("Accessibility:     \(status(accessibility))\(accessibility ? "" : " → turn on Mac Computer Use MCP in the window macOS opened")")
    print("Screen Recording:  \(status(screen))\(screen ? "" : " → optional, for screenshots: turn it on in System Settings")")
    if !accessibility { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    else if !screen { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    if !accessibility || !screen { print("Then restart your MCP client (or run `mac-computer-use-mcp doctor` to check).") }

case "apps":
    let store = ApprovalStore()
    let action = arguments.first ?? "list"
    do {
        switch action {
        case "list":
            let all = store.load()
            if all.isEmpty { print("No remembered approvals. Agents are asked before using a new app (unless the server runs with --allow-all).") }
            for (id, d) in all.sorted(by: { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }) {
                print("\(d.allowed ? "allow" : "deny ")  \(d.name)  (\(id))")
            }
        case "allow", "deny", "forget":
            guard arguments.count == 2 else { fail("usage: mac-computer-use-mcp apps \(action) <bundle id>") }
            let id = arguments[1]
            guard BLOCKED_APPS[id] == nil else { fail("\(BLOCKED_APPS[id]!) is a password manager and always stays blocked.") }
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            try store.save(id, name: name, allowed: action == "forget" ? nil : action == "allow")
            print(action == "forget" ? "Forgot \(name)." : "\(action == "allow" ? "Allowed" : "Denied") \(name) (\(id)).")
        case "reset":
            try store.reset()
            print("All approvals forgotten.")
        default: fail("unknown apps action '\(action)'")
        }
    } catch { fail("\(error)") }

case "version", "--version", "-v":
    print(Version.current)

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command '\(command)'. Run `mac-computer-use-mcp help`.")
}
