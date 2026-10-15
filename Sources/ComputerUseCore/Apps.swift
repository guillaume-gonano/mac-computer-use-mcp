import AppKit
import ApplicationServices

// Finding, launching and listing apps. An app is named by its display name, its path or its bundle identifier.

let APP_FOLDERS = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                   NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
func appURLs() -> [URL] {
    var urls: [URL] = []
    for folder in APP_FOLDERS {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
        for item in items where item.hasSuffix(".app") { urls.append(URL(fileURLWithPath: folder).appendingPathComponent(item)) }
    }
    return urls
}
func displayName(_ url: URL) -> String {
    let bundle = Bundle(url: url)
    return (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String) ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (bundle?.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
}
func same(_ a: String?, _ b: String) -> Bool { a?.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }

public struct Target {
    public let url: URL?
    public let bundleId: String?
    public let name: String
    var running: NSRunningApplication?
}

/// Resolves an app name, path or bundle identifier. Blocked apps (password managers) are refused here, so no
/// operation can ever reach them, whichever front end (MCP or line protocol) asked.
public func resolve(_ query: String) throws -> Target {
    let target = try find(query)
    if let id = target.bundleId, let name = BLOCKED_APPS[id] {
        throw Failure("\(name) is a password manager: Computer Use never controls it. Ask the user to do this step themselves.")
    }
    return target
}
func find(_ query: String) throws -> Target {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { throw Failure("Give an app name, path or bundle identifier.") }
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
    if q.hasPrefix("/") {
        let url = URL(fileURLWithPath: q).standardizedFileURL
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else { throw Failure("No app at \(q).") }
        let id = Bundle(url: url)?.bundleIdentifier
        return Target(url: url, bundleId: id, name: displayName(url), running: running.first { $0.bundleURL?.standardizedFileURL == url })
    }
    if let app = running.first(where: { same($0.bundleIdentifier, q) || same($0.localizedName, q) }) {
        return Target(url: app.bundleURL, bundleId: app.bundleIdentifier, name: app.localizedName ?? q, running: app)
    }
    if q.contains("."), !q.contains(" "), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) {
        return Target(url: url, bundleId: q, name: displayName(url), running: nil)
    }
    let bare = q.hasSuffix(".app") ? String(q.dropLast(4)) : q
    if let url = appURLs().first(where: { same($0.deletingPathExtension().lastPathComponent, bare) || same(displayName($0), bare)
        || same(FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""), bare) }) {
        return Target(url: url, bundleId: Bundle(url: url)?.bundleIdentifier, name: displayName(url), running: nil)
    }
    throw Failure("App '\(q)' not found. Call list_apps and use its bundle identifier.")
}
func wait(_ seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
}
// Launches the app in the background if needed (never brought to the front).
func launch(_ target: Target) throws -> NSRunningApplication {
    if let app = target.running, !app.isTerminated { return app }
    guard let url = target.url else { throw Failure("App '\(target.name)' cannot be launched.") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    let done = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?, failure: Error?
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in launched = app; failure = error; done.signal() }
    _ = done.wait(timeout: .now() + 20)
    guard let app = launched else { throw Failure("Unable to open \(target.name): \(failure?.localizedDescription ?? "timed out").") }
    wait(5) { app.isFinishedLaunching }
    return app
}

// Chromium and Electron apps build their accessibility tree only when asked.
let CHROMIUM = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
var enabled: Set<pid_t> = []
func appElement(_ app: NSRunningApplication) -> AXUIElement {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 4)
    if !enabled.contains(app.processIdentifier) {
        enabled.insert(app.processIdentifier)
        let manual = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        if CHROMIUM.contains(app.bundleIdentifier ?? "") { AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        if manual || CHROMIUM.contains(app.bundleIdentifier ?? "") { Thread.sleep(forTimeInterval: 0.4) }
    }
    return el
}
func keyWindow(_ appEl: AXUIElement) -> AXUIElement? {
    let isWindow = { (el: AXUIElement) in ["AXWindow", "AXSheet", "AXDialog"].contains(str(el, kAXRoleAttribute) ?? "") }
    for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let w = attr(appEl, name), CFGetTypeID(w) == AXUIElementGetTypeID(), isWindow(w as! AXUIElement) { return (w as! AXUIElement) }
    }
    return ((attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first(where: isWindow)
}

// Running apps first, then the most recently used (last 14 days, from Spotlight metadata). Blocked apps are left out.
func listApps() -> [[String: Any]] {
    var out: [String: [String: Any]] = [:]
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let recent = Date().addingTimeInterval(-14 * 86400)
    for url in appURLs() {
        guard let id = Bundle(url: url)?.bundleIdentifier, let item = MDItemCreateWithURL(nil, url as CFURL) else { continue }
        let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let isRunning = running.contains { $0.bundleIdentifier == id }
        guard isRunning || (used.map { $0 > recent } ?? false) else { continue }
        var entry: [String: Any] = ["id": id, "displayName": displayName(url), "isRunning": isRunning]
        if let used { entry["lastUsedDate"] = ISO8601DateFormatter().string(from: used) }
        if let count = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber { entry["useCount"] = count.intValue }
        out[id] = entry
    }
    for app in running where out[app.bundleIdentifier ?? ""] == nil {
        guard let id = app.bundleIdentifier else { continue }
        out[id] = ["id": id, "displayName": app.localizedName ?? id, "isRunning": true]
    }
    for id in BLOCKED_APPS.keys { out[id] = nil }
    return out.values.sorted { ($0["isRunning"] as? Bool ?? false) != ($1["isRunning"] as? Bool ?? false) ? ($0["isRunning"] as? Bool ?? false) : (($0["lastUsedDate"] as? String) ?? "") > (($1["lastUsedDate"] as? String) ?? "") }
}
