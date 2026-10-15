import AppKit
import ApplicationServices

// Reading the accessibility tree: attribute helpers and the one-line description of each element that agents read.

public struct Failure: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}
/// Thrown by every operation while the process lacks the Accessibility permission.
public let ACCESSIBILITY_DENIED = "ACCESSIBILITY_DENIED"

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s }
    if let u = v as? URL { return u.absoluteString }
    if let n = v as? NSNumber { return n.stringValue }
    if let a = v as? NSAttributedString { return a.string }
    return nil
}
func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attr(el, name) as? NSNumber)?.boolValue }
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String]) ?? [] : []
}
func settable(_ el: AXUIElement, _ name: String) -> Bool {
    var ok: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
}
func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func parent(_ el: AXUIElement) -> AXUIElement? { attr(el, kAXParentAttribute).map { $0 as! AXUIElement } }

struct Key: Hashable {
    let el: AXUIElement
    func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
    static func == (a: Key, b: Key) -> Bool { CFEqual(a.el, b.el) }
}

// English role names, whatever the system language (the agent reads them).
let ROLE_NAMES: [String: String] = [
    "AXWindow": "window", "AXButton": "button", "AXTextField": "text field", "AXTextArea": "text entry area",
    "AXStaticText": "text", "AXGroup": "container", "AXScrollArea": "scroll area", "AXWebArea": "HTML content",
    "AXLink": "link", "AXImage": "image", "AXCheckBox": "checkbox", "AXRadioButton": "radio button",
    "AXPopUpButton": "pop-up button", "AXMenuButton": "menu button", "AXComboBox": "combo box", "AXSlider": "slider",
    "AXTable": "table", "AXOutline": "outline", "AXRow": "row", "AXColumn": "column", "AXCell": "cell",
    "AXList": "list", "AXTabGroup": "tab group", "AXToolbar": "toolbar", "AXSplitGroup": "split group",
    "AXSplitter": "splitter", "AXHeading": "heading", "AXMenuBar": "menu bar", "AXMenuBarItem": "menu bar item",
    "AXMenu": "menu", "AXMenuItem": "menu item", "AXProgressIndicator": "progress indicator",
    "AXBusyIndicator": "busy indicator", "AXSheet": "sheet", "AXDialog": "dialog", "AXDisclosureTriangle": "disclosure triangle",
    "AXIncrementor": "stepper", "AXColorWell": "color well", "AXValueIndicator": "value indicator", "AXScrollBar": "scroll bar",
    "AXLayoutArea": "layout area", "AXLayoutItem": "layout item", "AXBrowser": "browser", "AXDateField": "date field",
    "AXSegmentedControl": "segmented control", "AXLevelIndicator": "level indicator", "AXGrid": "grid",
    "AXDocument": "document", "AXPopover": "popover", "AXSwitch": "switch"
]
let SUBROLE_NAMES: [String: String] = [
    "AXStandardWindow": "standard window", "AXDialog": "dialog", "AXSystemDialog": "system dialog", "AXFloatingWindow": "floating window",
    "AXSearchField": "search field", "AXSecureTextField": "secure text field", "AXToggle": "toggle button", "AXSwitch": "switch",
    "AXTabButton": "tab", "AXCloseButton": "close button", "AXMinimizeButton": "minimize button", "AXZoomButton": "zoom button",
    "AXFullScreenButton": "full screen button", "AXContentList": "content list", "AXDescriptionList": "description list",
    "AXOutlineRow": "outline row", "AXTableRow": "table row", "AXSortButton": "sort button", "AXTextAttachment": "attachment",
    "AXLandmarkNavigation": "navigation", "AXLandmarkMain": "main", "AXLandmarkBanner": "banner", "AXApplicationDialog": "dialog",
    "AXApplicationAlertDialog": "alert dialog", "AXDocumentArticle": "article"
]
func roleName(_ role: String, _ subrole: String?) -> String {
    if let s = subrole, let n = SUBROLE_NAMES[s] { return n }
    if let n = ROLE_NAMES[role] { return n }
    let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    return bare.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
}
// AXShowMenu → "Show Menu"; the primary click and technical actions stay hidden.
let HIDDEN_ACTIONS: Set<String> = ["AXPress", "AXShowDefaultUI", "AXShowAlternateUI", "AXScrollToVisible"]
// Some apps describe custom actions as "Name:Copy\nTarget:0x0\nSelector:(null)": keep the name.
func actionName(_ a: String) -> String {
    guard a.hasPrefix("Name:") else { return a }
    return String(a.dropFirst(5).prefix { $0 != "\n" })
}
func prettyAction(_ a: String) -> String {
    let a = actionName(a)
    let bare = a.hasPrefix("AX") ? String(a.dropFirst(2)) : a
    return bare.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
}
func oneLine(_ s: String, _ limit: Int = 300) -> String {
    let flat = s.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
        .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
}
let TEXT_ROLES: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXDateField"]
let MAX_VALUE = 4000

// One line of the tree, without its index: "button (collapsed) Choose theme, Help: …, Secondary Actions: Expand".
func describe(_ el: AXUIElement) -> (role: String, text: String, skippable: Bool) {
    let role = str(el, kAXRoleAttribute) ?? "AXUnknown", subrole = str(el, kAXSubroleAttribute)
    var states: [String] = []
    let isText = TEXT_ROLES.contains(role)
    if isText && settable(el, kAXValueAttribute) { states.append("settable") }
    if bool(el, kAXEnabledAttribute) == false { states.append("disabled") }
    if bool(el, kAXSelectedAttribute) == true { states.append("selected") }
    if let expanded = bool(el, kAXExpandedAttribute) { states.append(expanded ? "expanded" : "collapsed") }
    let title = str(el, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let desc = str(el, kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var value = str(el, kAXValueAttribute) ?? ""
    var name = !title.isEmpty ? title : desc
    var parts: [String] = []
    if role == "AXStaticText" && name.isEmpty { name = value; value = "" }
    if !title.isEmpty && !desc.isEmpty && desc != title { parts.append("Description: \(oneLine(desc))") }
    if role == "AXWebArea", let url = str(el, "AXURL") { parts.append("URL: \(oneLine(url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression), 200))") }
    if ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role) || subrole == "AXToggle" { if value == "1" { value = "on" } else if value == "0" { value = "off" } }
    // Secure fields never reveal their content, even to the agent.
    if subrole == "AXSecureTextField" { value = value.isEmpty ? "" : "••••" }
    if !value.isEmpty && value != name { parts.append("Value: \(oneLine(value, MAX_VALUE))") }
    if let help = str(el, kAXHelpAttribute), !help.isEmpty, help != name { parts.append("Help: \(oneLine(help))") }
    if let ph = str(el, kAXPlaceholderValueAttribute), !ph.isEmpty { parts.append("Placeholder: \(oneLine(ph))") }
    let secondary = actions(el).filter { !HIDDEN_ACTIONS.contains($0) && !$0.hasPrefix("AXScroll") }.map(prettyAction)
    if !secondary.isEmpty { parts.append("Secondary Actions: \(secondary.joined(separator: ", "))") }
    var text = roleName(role, subrole)
    if !states.isEmpty { text += " (\(states.joined(separator: ", ")))" }
    if !name.isEmpty { text += " \(oneLine(name))" }
    if !parts.isEmpty { text += (name.isEmpty ? " " : ", ") + parts.joined(separator: ", ") }
    // Unnamed containers add only indentation: their children are shown one level up.
    let skippable = (role == "AXGroup" || role == "AXUnknown" || role == "AXLayoutItem") && name.isEmpty && parts.isEmpty && states.isEmpty
    return (role, text, skippable)
}
