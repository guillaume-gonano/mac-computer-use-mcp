import AppKit
import ApplicationServices
import ScreenCaptureKit
import UniformTypeIdentifiers

// get_app_state: the key window's accessibility tree (full, then as a diff) and a screenshot of that window alone.
// Elements keep the same index while they stay in the window, so the agent can act on an index from the last state.

let MAX_ELEMENTS = 1500, MAX_DEPTH = 60, SHOT_MAX_SIDE: CGFloat = 1568

// State of each app: stable element indices and the last tree, for diffs.
final class AppSession {
    var ids: [Key: Int] = [:]
    var elements: [Int: AXUIElement] = [:]
    var nextId = 0
    var lines: [Int: String] = [:]
    var windowFrame: CGRect?
    var windowID: CGWindowID?
    var shotScale: CGFloat = 1
    var windowTitle = ""
}
var sessions: [pid_t: AppSession] = [:]
var lastActionAt = Date.distantPast

public struct Screenshot {
    public let png: Data
    public let width: Int
    public let height: Int
}
public struct AppState {
    public let app: String
    public let bundleId: String
    public let pid: Int
    /// The tree (or its diff), then the focused element and the selected text.
    public let text: String
    /// The key window alone, even when covered; nil without the Screen Recording permission.
    public let screenshot: Screenshot?
    /// Screenshot pixels per screen point: coordinates given to click, scroll and drag are screenshot pixels.
    public let screenshotScale: Double
    public let screenshotDenied: Bool
}

struct Node { let id: Int; let depth: Int; let text: String }
func snapshot(_ root: AXUIElement, _ session: AppSession, clip: CGRect?) -> (nodes: [Node], truncated: Int, current: [Int: AXUIElement]) {
    var nodes: [Node] = [], current: [Int: AXUIElement] = [:], truncated = 0
    func visit(_ el: AXUIElement, _ depth: Int, _ printedDepth: Int) {
        if nodes.count >= MAX_ELEMENTS { truncated += 1; return }
        if depth > MAX_DEPTH { return }
        // Elements entirely outside the window are skipped (scroll to reach them).
        if let clip, let f = frame(el), f.width > 0, f.height > 0, !f.intersects(clip) { return }
        let d = describe(el)
        var next = printedDepth
        let kids = children(el)
        if !(d.skippable && depth > 0) {
            let key = Key(el: el)
            let id: Int
            if let known = session.ids[key] { id = known } else { id = session.nextId; session.nextId += 1; session.ids[key] = id }
            current[id] = el
            nodes.append(Node(id: id, depth: printedDepth, text: d.text))
            next = printedDepth + 1
        }
        for kid in kids { visit(kid, depth + 1, next) }
    }
    visit(root, 0, 0)
    return (nodes, truncated, current)
}

// ----- Screenshots (ScreenCaptureKit, window only, even when covered; kept in memory, never written to disk) -----
func capture(_ app: NSRunningApplication, _ windowFrame: CGRect, _ title: String, _ session: AppSession) -> Screenshot? {
    guard CGPreflightScreenCaptureAccess() else { return nil }
    let done = DispatchSemaphore(value: 0)
    var shareable: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in shareable = content; done.signal() }
    _ = done.wait(timeout: .now() + 5)
    let candidates = (shareable?.windows ?? []).filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 1 }
    guard let window = candidates.min(by: { distance($0, windowFrame, title) < distance($1, windowFrame, title) }) else { return nil }
    // Native density (Retina = 2), reduced so the longest side stays readable for models; the image fills the frame.
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = min(CGFloat(filter.pointPixelScale), SHOT_MAX_SIDE / max(window.frame.width, window.frame.height))
    let config = SCStreamConfiguration()
    config.width = Int((window.frame.width * scale).rounded())
    config.height = Int((window.frame.height * scale).rounded())
    config.scalesToFit = true
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    var image: CGImage?
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { img, _ in image = img; done.signal() }
    _ = done.wait(timeout: .now() + 8)
    guard let image else { return nil }
    session.windowID = window.windowID
    session.windowFrame = window.frame
    session.shotScale = CGFloat(image.width) / window.frame.width
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return Screenshot(png: data as Data, width: image.width, height: image.height)
}
func distance(_ w: SCWindow, _ f: CGRect, _ title: String) -> CGFloat {
    abs(w.frame.minX - f.minX) + abs(w.frame.minY - f.minY) + abs(w.frame.width - f.width) + abs(w.frame.height - f.height) + (w.title == title ? 0 : 50)
}

public func screenLocked() -> Bool { ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) ?? false }
let SCREEN_LOCKED = "The screen is locked: Computer Use is paused until the user unlocks the Mac."

func appState(_ query: String, disableDiff: Bool) throws -> AppState {
    guard AXIsProcessTrusted() else { throw Failure(ACCESSIBILITY_DENIED) }
    guard !screenLocked() else { throw Failure(SCREEN_LOCKED) }
    let target = try resolve(query)
    let app = try launch(target)
    // Actions settle before the new state is read (about 1 s).
    let since = Date().timeIntervalSince(lastActionAt)
    if since < 1 { Thread.sleep(forTimeInterval: 1 - since) }
    let appEl = appElement(app)
    var window = keyWindow(appEl)
    if window == nil { wait(5) { keyWindow(appEl) != nil }; window = keyWindow(appEl) }
    let name = app.localizedName ?? target.name
    let session = sessions[app.processIdentifier] ?? AppSession()
    sessions[app.processIdentifier] = session
    func state(_ text: String, _ shot: Screenshot? = nil) -> AppState {
        AppState(app: name, bundleId: app.bundleIdentifier ?? "", pid: Int(app.processIdentifier), text: text, screenshot: shot,
                 screenshotScale: Double(session.shotScale), screenshotDenied: shot == nil && !CGPreflightScreenCaptureAccess())
    }
    guard let window else {
        // No window: the menu bar lets the agent open one.
        let menu = attr(appEl, kAXMenuBarAttribute).map { $0 as! AXUIElement }
        var text = "\(name) has no open window."
        if let menu {
            let tree = snapshot(menu, session, clip: nil)
            session.elements = tree.current
            text += " Its menu bar:\n" + tree.nodes.filter { $0.depth <= 2 }.map { String(repeating: "\t", count: $0.depth) + "\($0.id) \($0.text)" }.joined(separator: "\n")
        }
        session.lines = [:]
        Indicator.hide()
        return state(text)
    }
    let title = str(window, kAXTitleAttribute) ?? ""
    let winFrame = frame(window)
    let tree = snapshot(window, session, clip: winFrame?.insetBy(dx: -2, dy: -2))
    session.elements = tree.current
    session.windowFrame = winFrame
    session.windowTitle = title
    let header = "Window: \"\(title)\", App: \(name)."
    let lines = Dictionary(tree.nodes.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
    let full = tree.nodes.map { String(repeating: "\t", count: $0.depth) + "\($0.id) \($0.text)" }
    var text: String
    if disableDiff || session.lines.isEmpty {
        text = header + "\n" + full.joined(separator: "\n")
    } else {
        let removed = session.lines.keys.filter { lines[$0] == nil }.sorted()
        var diff: [String] = []
        for node in tree.nodes {
            guard let before = session.lines[node.id] else { diff.append("+" + String(repeating: "\t", count: node.depth) + "\(node.id) \(node.text)"); continue }
            if before != node.text { diff.append("~" + String(repeating: "\t", count: node.depth) + "\(node.id) \(node.text)") }
        }
        if diff.isEmpty && removed.isEmpty {
            text = "No change in the accessibility tree of window \"\(title)\" since the last state."
        } else if diff.count + 2 >= full.count {
            text = header + "\n" + full.joined(separator: "\n")
        } else {
            text = "Changes since the last state of window \"\(title)\": lines starting with ~ changed, lines starting with + were added; removed elements are listed by ID range."
            if !removed.isEmpty { text += "\nRemoved element IDs: \(ranges(removed))" }
            if !diff.isEmpty { text += "\n" + diff.joined(separator: "\n") }
        }
    }
    session.lines = lines
    if tree.truncated > 0 { text += "\n(\(tree.truncated) more elements not listed: scroll, or read the screenshot.)" }
    if let focused = attr(appEl, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }) {
        if let id = session.ids[Key(el: focused)], let line = lines[id] { text += "\nThe focused UI element is \(id) \(line.count > 400 ? String(line.prefix(400)) + "…" : line)" }
        if let selected = str(focused, kAXSelectedTextAttribute), !selected.isEmpty { text += "\nSelected:\n\(selected.count > 2000 ? String(selected.prefix(2000)) + "…" : selected)" }
    }
    let shot = winFrame.flatMap { capture(app, $0, title, session) }
    Indicator.follow(app, window, session)
    return state(text, shot)
}
func ranges(_ ids: [Int]) -> String {
    guard var start = ids.first else { return "" }
    var out: [String] = [], prev = start
    for id in ids.dropFirst() { if id == prev + 1 { prev = id; continue }; out.append(start == prev ? "\(start)" : "\(start)-\(prev)"); start = id; prev = id }
    out.append(start == prev ? "\(start)" : "\(start)-\(prev)")
    return out.joined(separator: ", ")
}
