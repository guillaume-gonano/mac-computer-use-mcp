import AppKit
import ApplicationServices
import Carbon

// Mouse and keyboard events, posted to the target process only (never to the whole system), so the user's own
// pointer and keyboard are left alone. Key names follow xdotool; letters go through the current keyboard layout.

struct Context { let app: NSRunningApplication; let session: AppSession; let appEl: AXUIElement }

let source = CGEventSource(stateID: .privateState)
func post(_ e: CGEvent?, _ c: Context) {
    guard let e else { return }
    if let wid = c.session.windowID {
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
    }
    e.postToPid(c.app.processIdentifier)
}
func mouse(_ c: Context, _ at: CGPoint, button: String, count: Int, flags: CGEventFlags) {
    let (down, up, b): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case "right", "r": (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m": (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
    }
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: b), c)
    for n in 1...max(1, min(count, 3)) {
        for type in [down, up] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: b)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            e?.flags = flags
            post(e, c)
            usleep(15_000)
        }
        usleep(60_000)
    }
}

let NAMED_KEYS: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "page_up": 116, "prior": 116, "pageup": 116,
    "page_down": 121, "next": 121, "pagedown": 121, "insert": 114, "help": 114, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
    "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85,
    "kp_4": 86, "kp_5": 87, "kp_6": 88, "kp_7": 89, "kp_8": 91, "kp_9": 92, "kp_decimal": 65, "kp_add": 69, "kp_subtract": 78,
    "kp_multiply": 67, "kp_divide": 75, "kp_equal": 81, "caps_lock": 57
]
let SYMBOL_NAMES: [String: String] = ["minus": "-", "plus": "+", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
    "semicolon": ";", "apostrophe": "'", "quotedbl": "\"", "grave": "`", "bracketleft": "[", "bracketright": "]", "at": "@", "numbersign": "#",
    "dollar": "$", "percent": "%", "ampersand": "&", "asterisk": "*", "parenleft": "(", "parenright": ")", "underscore": "_", "colon": ":",
    "question": "?", "exclam": "!", "less": "<", "greater": ">"]
let MODIFIERS: [String: CGEventFlags] = ["shift": .maskShift, "ctrl": .maskControl, "control": .maskControl, "alt": .maskAlternate,
    "option": .maskAlternate, "opt": .maskAlternate, "super": .maskCommand, "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
    "win": .maskCommand, "fn": .maskSecondaryFn]
// Character → (key code, needs shift, needs option) for the current layout, read on the main thread (Text Input Sources).
var layoutCache: [Character: (CGKeyCode, Bool, Bool)]?
func keyLayout() -> [Character: (CGKeyCode, Bool, Bool)] {
    if let layoutCache { return layoutCache }
    let map = Thread.isMainThread ? readLayout() : DispatchQueue.main.sync { readLayout() }
    layoutCache = map
    return map
}
func readLayout() -> [Character: (CGKeyCode, Bool, Bool)] {
    var map: [Character: (CGKeyCode, Bool, Bool)] = [:]
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    data.withUnsafeBytes { bytes in
        let ptr = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
            let mods = UInt32(((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8) & 0xFF
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(ptr, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr, length == 1,
                      let ch = String(utf16CodeUnits: chars, count: length).first, map[ch] == nil else { continue }
                map[ch] = (CGKeyCode(code), shift, option)
            }
        }
    }
    return map
}
func parseKey(_ spec: String) throws -> (CGKeyCode, CGEventFlags) {
    var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    if spec.hasSuffix("++") { parts.removeLast(2); parts.append("+") } // "super++"
    guard let last = parts.popLast(), !last.isEmpty else { throw Failure("Invalid key '\(spec)'.") }
    var flags: CGEventFlags = []
    for m in parts { guard let f = MODIFIERS[m.lowercased()] else { throw Failure("Unknown modifier '\(m)' in '\(spec)'.") }; flags.insert(f) }
    if let code = NAMED_KEYS[last.lowercased()] { return (code, flags) }
    let char = SYMBOL_NAMES[last.lowercased()] ?? last
    guard char.count == 1, let ch = char.first else { throw Failure("Unknown key '\(last)'. Use xdotool names such as Return, Tab, Escape, Up, F5, KP_0 or one character.") }
    let lower = Character(ch.lowercased()), layout = keyLayout()
    if let (code, shift, option) = layout[ch] ?? layout[lower] {
        if layout[ch] != nil { if shift { flags.insert(.maskShift) }; if option { flags.insert(.maskAlternate) } }
        else if ch.isUppercase { flags.insert(.maskShift) }
        return (code, flags)
    }
    throw Failure("The key '\(char)' is not on the current keyboard layout; use type_text for it.")
}
// ⌘ shortcuts of a background app: AppKit ignores key equivalents posted to an inactive app, so the matching menu
// item (Edit › Paste for super+v…) is pressed through accessibility instead, like a click in the menu bar.
func menuItem(_ appEl: AXUIElement, _ spec: String, _ flags: CGEventFlags) -> AXUIElement? {
    guard flags.contains(.maskCommand), let last = spec.split(separator: "+").last, last.count == 1,
          let bar = attr(appEl, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
    let wanted = last.uppercased()
    var mods = 0
    if flags.contains(.maskShift) { mods |= 1 }
    if flags.contains(.maskAlternate) { mods |= 2 }
    if flags.contains(.maskControl) { mods |= 4 }
    func search(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
        for kid in children(el) {
            let role = str(kid, kAXRoleAttribute)
            if role == "AXMenuItem", str(kid, "AXMenuItemCmdChar")?.uppercased() == wanted,
               (attr(kid, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0 == mods { return kid }
            if depth < 4, let found = search(kid, depth + 1) { return found }
        }
        return nil
    }
    return search(bar, 0)
}
// ⌘ shortcuts: the menu item when the app has one (works in the background for app commands such as New Window);
// shortcuts acting on the focused text (copy, select all…) need the app in front, as a person would have it.
let TEXT_SHORTCUTS: Set<String> = ["A", "C", "V", "X", "Z"]
func press(_ c: Context, _ spec: String, hold: Double = 0) throws -> String {
    let (_, flags) = try parseKey(spec)
    let char = spec.split(separator: "+").last.map { $0.uppercased() } ?? ""
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == c.app.processIdentifier
    if flags.contains(.maskCommand) && !front && hold <= 0 {
        if TEXT_SHORTCUTS.contains(char) { try withFocus(c) { try keyEvent(c, spec) }; return "Pressed \(spec) (the app came forward for this shortcut)." }
        if let item = menuItem(c.appEl, spec, flags), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return "Pressed \(spec) (menu item \(str(item, kAXTitleAttribute) ?? ""))."
        }
    }
    try keyEvent(c, spec, hold: hold)
    return "Pressed \(spec)."
}
func keyEvent(_ c: Context, _ spec: String, hold: Double = 0) throws {
    let (code, flags) = try parseKey(spec)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true), up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags; up?.flags = flags
    post(down, c)
    usleep(useconds_t(max(0.02, min(hold, 10)) * 1_000_000))
    post(up, c)
}
func typeText(_ c: Context, _ text: String) {
    // One event per character, like a person typing: some apps read only the first character of an event.
    // Characters of the current layout use their real key (with Shift/Option), others are sent as Unicode text.
    let layout = keyLayout(), pause: useconds_t = text.count > 400 ? 2_000 : 6_000
    for ch in text {
        if ch == "\n" || ch == "\r\n" || ch == "\r" {
            for down in [true, false] { post(CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down), c) }
            usleep(pause)
            continue
        }
        let units = Array(String(ch).utf16), key = layout[ch]
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key?.0 ?? 0, keyDown: down)
            var flags: CGEventFlags = []
            if key?.1 == true { flags.insert(.maskShift) }
            if key?.2 == true { flags.insert(.maskAlternate) }
            e?.flags = flags
            e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(e, c)
        }
        usleep(pause)
    }
}
// Runs an action that needs the app's key window (⌘ shortcuts on text): the app comes forward for that moment only,
// then the user's app comes back to the front.
func withFocus(_ c: Context, _ body: () throws -> Void) rethrows {
    let previous = NSWorkspace.shared.frontmostApplication
    if previous?.processIdentifier == c.app.processIdentifier { try body(); return }
    c.app.activate(options: [])
    wait(1.5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == c.app.processIdentifier }
    Thread.sleep(forTimeInterval: 0.15)
    try body()
    Thread.sleep(forTimeInterval: 0.25)
    if let previous, previous.processIdentifier != getpid() { previous.activate(options: []) }
}
