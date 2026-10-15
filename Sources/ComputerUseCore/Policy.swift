import AppKit
import Foundation

// Which apps agents may use. Password managers are never reachable (checked in resolve()). Other apps need the user's
// approval on first use in MCP mode: "Always allow" is remembered in approvals.json, "Allow for this session" lasts
// until the MCP client stops the server, and a refusal applies to that request (the agent is told not to retry).

/// Password managers and the keychain: sign-ins stay with the user.
public let BLOCKED_APPS: [String: String] = [
    "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password", "com.apple.keychainaccess": "Keychain Access",
    "com.apple.Passwords": "Passwords", "com.bitwarden.desktop": "Bitwarden", "com.dashlane.dashlanephonefinal": "Dashlane",
    "org.keepassxc.keepassxc": "KeePassXC", "com.lastpass.LastPass": "LastPass"
]

public func validBundleId(_ id: String) -> Bool {
    id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$", options: .regularExpression) != nil
}

public enum ApprovalMode { case ask, allowAll }
public enum Access: Equatable { case allow, deny, ask, blocked }
public enum Answer { case always, session, deny }

public struct Decision: Equatable {
    public let name: String
    public let allowed: Bool
    public let at: Date
}

/// What happens when an agent wants an app. Pure, so it is unit-tested.
public func access(_ bundleId: String, saved: [String: Decision], session: Set<String>, mode: ApprovalMode) -> Access {
    guard validBundleId(bundleId), BLOCKED_APPS[bundleId] == nil else { return .blocked }
    if let decision = saved[bundleId] { return decision.allowed ? .allow : .deny }
    if session.contains(bundleId) || mode == .allowAll { return .allow }
    return .ask
}

/// Saved decisions: ~/Library/Application Support/Mac Computer Use MCP/approvals.json, private to the user (0600),
/// written atomically. { "com.apple.TextEdit": { "name": "TextEdit", "decision": "allow", "at": "2026-…" } }
public final class ApprovalStore {
    public let url: URL
    public init(url: URL = ApprovalStore.defaultURL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Computer Use MCP/approvals.json")
    }

    /// Invalid entries are dropped; an unreadable file counts as empty.
    public func load() -> [String: Decision] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Decision] = [:]
        for (id, value) in object {
            guard validBundleId(id), let entry = value as? [String: Any], let decision = entry["decision"] as? String,
                  ["allow", "deny"].contains(decision) else { continue }
            let at = (entry["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
            out[id] = Decision(name: String((entry["name"] as? String ?? id).prefix(200)), allowed: decision == "allow", at: at)
        }
        return out
    }

    /// Saves (allowed true/false) or forgets (nil) the decision for one app.
    public func save(_ id: String, name: String, allowed: Bool?) throws {
        guard validBundleId(id) else { throw Failure("Invalid bundle identifier '\(id)'.") }
        var all = load()
        if let allowed { all[id] = Decision(name: name, allowed: allowed, at: Date()) } else { all[id] = nil }
        try write(all)
    }
    public func reset() throws { try write([:]) }

    private func write(_ all: [String: Decision]) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = ISO8601DateFormatter()
        let object = all.mapValues { ["name": $0.name, "decision": $0.allowed ? "allow" : "deny", "at": formatter.string(from: $0.at)] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = folder.appendingPathComponent(".approvals-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

/// Asks the user, once per app, before an agent uses it (MCP mode only: an app embedding the line protocol decides itself).
public final class Approvals {
    let store: ApprovalStore
    let mode: ApprovalMode
    var session: Set<String>
    /// Shows the question and returns the answer; replaced in tests.
    var ask: (_ appName: String, _ agentName: String) -> Answer = Approvals.alert

    public init(store: ApprovalStore = ApprovalStore(), mode: ApprovalMode = .ask, preApproved: Set<String> = []) {
        self.store = store
        self.mode = mode
        self.session = preApproved
    }

    public func check(_ target: Target, agentName: String) throws {
        guard let id = target.bundleId else { throw Failure("\(target.name) has no bundle identifier, so it cannot be approved.") }
        let name = target.name
        switch access(id, saved: store.load(), session: session, mode: mode) {
        case .blocked: throw Failure("\(name) cannot be used with Computer Use.")
        case .deny: throw Failure("The user does not allow agents to use \(name). Do not retry; continue without it or ask the user.")
        case .allow: return
        case .ask:
            let answer = Thread.isMainThread ? ask(name, agentName) : DispatchQueue.main.sync { ask(name, agentName) }
            switch answer {
            case .always: try? store.save(id, name: name, allowed: true)
            case .session: session.insert(id)
            case .deny: throw Failure("The user did not allow agents to use \(name). Do not retry; continue without it or ask the user.")
            }
        }
    }

    /// A native dialog, brought to the front (the only moment this program takes focus); the user's app comes back
    /// afterwards. Unanswered after 2 minutes = refused.
    static func alert(_ appName: String, _ agentName: String) -> Answer {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow \(agentName) to use \(appName)?"
        alert.informativeText = "It will read \(appName)'s window (text and screenshots), click and type in it. Actions are sent to \(appName) only; your pointer and keyboard stay yours.\n\nChange this later with: mac-computer-use-mcp apps"
        alert.addButton(withTitle: "Allow for This Session")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        let timeout = Timer(timeInterval: 120, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        let response = alert.runModal()
        timeout.invalidate()
        if let previous, previous.processIdentifier != getpid() { previous.activate() }
        switch response {
        case .alertFirstButtonReturn: return .session
        case .alertSecondButtonReturn: return .always
        default: return .deny
        }
    }
}
