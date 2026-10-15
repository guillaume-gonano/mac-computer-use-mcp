import AppKit
import ApplicationServices

// The operations themselves. Engine.perform is shared by both front ends: the MCP server (MCPServer.swift, with
// per-app approvals) and the line protocol for apps that embed this binary (LineServer.swift).

public enum Engine {
    /// Operations an agent may call, in the order the tools are listed.
    public static let toolOperations = ["list_apps", "get_app_state", "click", "perform_secondary_action", "set_value", "select_text", "scroll", "drag", "press_key", "type_text", "paste"]

    /// Runs one operation. Returns an AppState (get_app_state), a list of app dictionaries (list_apps), a dictionary
    /// (permissions, resolve) or a short confirmation sentence (actions). Errors are Failure with a message for the agent.
    public static func perform(_ op: String, _ input: [String: Any]) throws -> Any {
        switch op {
        case "permissions": return ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()]
        case "request_screen_recording": return ["screenRecording": CGRequestScreenCaptureAccess()]
        case "resolve":
            let t = try resolve(input["app"] as? String ?? "")
            return ["name": t.name, "bundleId": t.bundleId ?? "", "path": t.url?.path ?? "", "running": t.running != nil]
        case "list_apps": return listApps()
        case "get_app_state": return try appState(input["app"] as? String ?? "", disableDiff: input["disableDiff"] as? Bool ?? false)
        default: break
        }
        defer { lastActionAt = Date() }
        switch op {
        case "click": return try click(input)
        case "scroll": return try scroll(input)
        case "drag": return try drag(input)
        case "set_value": return try setValue(input)
        case "select_text": return try selectText(input)
        case "perform_secondary_action": return try secondary(input)
        case "paste": return try paste(input)
        case "press_key":
            let c = try context(input)
            Indicator.cursor(nil)
            return try press(c, (input["key"] as? String ?? "").trimmingCharacters(in: .whitespaces), hold: (input["duration"] as? NSNumber)?.doubleValue ?? 0)
        case "type_text":
            let c = try context(input)
            Indicator.cursor(attr(c.appEl, kAXFocusedUIElementAttribute).flatMap { try? center($0 as! AXUIElement) })
            typeText(c, input["text"] as? String ?? "")
            return "Typed."
        default: throw Failure("Unknown operation '\(op)'.")
        }
    }
}

// ----- Targets of actions -----
func context(_ input: [String: Any]) throws -> Context {
    guard AXIsProcessTrusted() else { throw Failure(ACCESSIBILITY_DENIED) }
    guard !screenLocked() else { throw Failure(SCREEN_LOCKED) }
    let target = try resolve(input["app"] as? String ?? "")
    guard let app = target.running, !app.isTerminated, let session = sessions[app.processIdentifier], !session.elements.isEmpty || session.windowFrame != nil else {
        throw Failure("Call get_app_state for \(target.name) first.")
    }
    Indicator.follow(app, nil, session)
    return Context(app: app, session: session, appEl: appElement(app))
}
func element(_ c: Context, _ input: [String: Any]) throws -> AXUIElement {
    guard let index = (input["element_index"] as? NSNumber)?.intValue ?? Int(input["element_index"] as? String ?? "") else { throw Failure("element_index is required.") }
    guard let el = c.session.elements[index] else { throw Failure("Element \(index) is not in the latest state of this app. Call get_app_state again and use a current index.") }
    return el
}
// Screenshot pixels → screen points.
func point(_ c: Context, _ x: Any?, _ y: Any?) throws -> CGPoint {
    guard let x = (x as? NSNumber)?.doubleValue, let y = (y as? NSNumber)?.doubleValue else { throw Failure("Give element_index, or both x and y.") }
    guard let f = c.session.windowFrame else { throw Failure("No window position known: call get_app_state first.") }
    let s = c.session.shotScale > 0 ? c.session.shotScale : 1
    return CGPoint(x: f.minX + CGFloat(x) / s, y: f.minY + CGFloat(y) / s)
}
func center(_ el: AXUIElement) throws -> CGPoint {
    guard let f = frame(el), f.width > 0 || f.height > 0 else { throw Failure("This element has no position on screen; use another element or coordinates.") }
    return CGPoint(x: f.midX, y: f.midY)
}

// ----- Actions -----
func click(_ input: [String: Any]) throws -> String {
    let c = try context(input)
    let button = (input["mouse_button"] as? String ?? "left").lowercased()
    let count = (input["click_count"] as? NSNumber)?.intValue ?? 1
    var flags: CGEventFlags = []
    if let key = input["key"] as? String, !key.isEmpty {
        for m in key.split(separator: "+") { guard let f = MODIFIERS[m.lowercased()] else { throw Failure("Unknown modifier '\(m)'.") }; flags.insert(f) }
    }
    let target = input["element_index"] != nil ? (try? element(c, input)).flatMap { try? center($0) } : try? point(c, input["x"], input["y"])
    Indicator.cursor(target, click: true)
    let at: CGPoint
    if input["element_index"] != nil {
        let el = try element(c, input)
        let acts = actions(el)
        // Plain clicks use the element's own action: works in the background, nothing moves on screen.
        if flags.isEmpty && count == 1 {
            if (button == "left" || button == "l"), acts.contains("AXPress"), AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return "Clicked element \(input["element_index"]!)." }
            if (button == "right" || button == "r"), acts.contains("AXShowMenu"), AXUIElementPerformAction(el, kAXShowMenuAction as CFString) == .success { return "Opened the menu of element \(input["element_index"]!)." }
        }
        at = try center(el)
    } else {
        at = try point(c, input["x"], input["y"])
        // A plain click on a pressable control: press it through accessibility (or its parent, e.g. a button's label).
        if flags.isEmpty && count == 1 && (button == "left" || button == "l") {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(c.appEl, Float(at.x), Float(at.y), &hit) == .success, var el = hit {
                for _ in 0..<3 {
                    let role = str(el, kAXRoleAttribute) ?? ""
                    if ["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"].contains(role),
                       actions(el).contains("AXPress"), AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return "Clicked at (\(input["x"]!), \(input["y"]!))." }
                    guard let p = parent(el) else { break }
                    el = p
                }
            }
        }
    }
    mouse(c, at, button: button, count: count, flags: flags)
    return "Clicked."
}
func scroll(_ input: [String: Any]) throws -> String {
    let c = try context(input)
    let direction = (input["direction"] as? String ?? "down").lowercased()
    let pages = max(0.1, min((input["pages"] as? NSNumber)?.doubleValue ?? 1, 20))
    var area = c.session.windowFrame ?? .zero
    let at: CGPoint
    if input["element_index"] != nil { let el = try element(c, input); at = try center(el); if let f = frame(el) { area = f } }
    else if input["x"] != nil { at = try point(c, input["x"], input["y"]) }
    else { at = CGPoint(x: area.midX, y: area.midY) }
    Indicator.cursor(at)
    let vertical = ["up", "u", "down", "d"].contains(direction)
    let total = Double((vertical ? area.height : area.width) * 0.85) * pages
    let sign: Double = ["up", "u", "left", "l"].contains(direction) ? 1 : -1
    var left = max(total, 40)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left), c)
    while left > 0 {
        let step = min(left, 120)
        let amount = Int32(step * sign)
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical ? amount : 0, wheel2: vertical ? 0 : amount, wheel3: 0)
        e?.location = at
        post(e, c)
        left -= step
        usleep(12_000)
    }
    return "Scrolled \(direction)."
}
func drag(_ input: [String: Any]) throws -> String {
    let c = try context(input)
    let from = try point(c, input["from_x"], input["from_y"]), to = try point(c, input["to_x"], input["to_y"])
    Indicator.cursor(from)
    Indicator.cursor(to, wait: false) // glides along with the drag events below
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left), c)
    for i in 1...12 {
        let t = CGFloat(i) / 12
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), mouseButton: .left), c)
        usleep(20_000)
    }
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left), c)
    return "Dragged."
}
func setValue(_ input: [String: Any]) throws -> String {
    let c = try context(input), el = try element(c, input)
    Indicator.cursor(try? center(el))
    guard settable(el, kAXValueAttribute) else { throw Failure("This element's value cannot be set; click it and use type_text instead.") }
    let value = input["value"] as? String ?? ""
    guard AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success else { throw Failure("The app refused the new value.") }
    return "Value set."
}
func selectText(_ input: [String: Any]) throws -> String {
    let c = try context(input), el = try element(c, input)
    Indicator.cursor(try? center(el))
    let text = input["text"] as? String ?? "", prefix = input["prefix"] as? String ?? "", suffix = input["suffix"] as? String ?? ""
    guard !text.isEmpty, let value = str(el, kAXValueAttribute) else { throw Failure("This element has no text to select.") }
    let whole = value as NSString
    var matches: [NSRange] = [], from = 0
    while from < whole.length {
        let r = whole.range(of: text, options: [], range: NSRange(location: from, length: whole.length - from))
        if r.location == NSNotFound { break }
        let before = whole.substring(to: r.location), after = whole.substring(from: r.location + r.length)
        if before.hasSuffix(prefix) && after.hasPrefix(suffix) { matches.append(r) }
        from = r.location + 1
    }
    guard let range = matches.first else { throw Failure("Text not found in element \(input["element_index"]!).") }
    guard matches.count == 1 else { throw Failure("The text appears \(matches.count) times: add a prefix or suffix to choose one.") }
    var cf: CFRange
    switch input["selection_type"] as? String ?? "text" {
    case "cursor_before": cf = CFRange(location: range.location, length: 0)
    case "cursor_after": cf = CFRange(location: range.location + range.length, length: 0)
    default: cf = CFRange(location: range.location, length: range.length)
    }
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard let axRange = AXValueCreate(.cfRange, &cf), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { throw Failure("The app refused the selection.") }
    return "Selected."
}
func secondary(_ input: [String: Any]) throws -> String {
    let c = try context(input), el = try element(c, input)
    Indicator.cursor(try? center(el), click: true)
    let wanted = (input["action"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
    let available = actions(el)
    guard let action = available.first(where: { $0.lowercased() == wanted || $0.lowercased() == "ax" + wanted || prettyAction($0).lowercased().replacingOccurrences(of: " ", with: "") == wanted }) else {
        throw Failure("Element \(input["element_index"]!) does not expose '\(input["action"] ?? "")'. Available: \(available.map(prettyAction).joined(separator: ", ")).")
    }
    guard AXUIElementPerformAction(el, action as CFString) == .success else { throw Failure("The app refused '\(prettyAction(action))'.") }
    return "Performed \(prettyAction(action))."
}
// Plain text and Markdown are inserted at the cursor through accessibility (background-safe, clipboard untouched).
// HTML goes through the clipboard and ⌘V; a background app is brought forward for that moment only, then the user's
// app comes back to the front, and the user's clipboard is restored.
func paste(_ input: [String: Any]) throws -> String {
    let c = try context(input)
    let text = input["text"] as? String ?? "", format = input["format"] as? String ?? "text"
    let focused = attr(c.appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
    Indicator.cursor(focused.flatMap { try? center($0) })
    if format != "html", let focused, settable(focused, kAXSelectedTextAttribute),
       AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return "Pasted." }
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
    board.clearContents()
    if format == "html" {
        let item = NSPasteboardItem()
        item.setString(text, forType: .html)
        // HTML import uses WebKit, which runs on the main thread only.
        let plain = DispatchQueue.main.sync { (try? NSAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil))?.string }
        item.setString(plain ?? text, forType: .string)
        board.writeObjects([item])
    } else {
        board.setString(text, forType: .string)
    }
    defer {
        Thread.sleep(forTimeInterval: 0.5)
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
    }
    try withFocus(c) { try keyEvent(c, "super+v") }
    return "Pasted."
}
