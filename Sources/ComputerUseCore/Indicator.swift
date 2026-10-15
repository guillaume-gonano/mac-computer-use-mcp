import AppKit
import ApplicationServices
import QuartzCore

// Shows the user that an agent is at work, without ever getting in the way:
// - a purple pill with the screen-sharing symbol laid over the traffic lights of the target window, and the same pill
//   in the menu bar, removed BADGE_IDLE seconds after the last action; the window pill also hides while its window is
//   off screen (minimized, another Space, closed);
// - a drawn agent cursor (a rounded arrowhead on a soft dark halo) that glides to each target before the action, ripples on
//   clicks and sways while the agent works, then fades after CURSOR_IDLE seconds. The user's own pointer never moves.
// Both are non-activating panels that ignore the mouse (clicks reach the window below) and are ordered just above the
// target window: never above the user's front window, never focused. Screenshots capture the target window alone
// (ScreenCaptureKit), so the agent never sees them. Turned off with --no-indicator.
let BADGE_SYMBOL = "rectangle.inset.filled.and.person.filled", BADGE_IDLE: TimeInterval = 30
let BADGE_COLOR = NSColor(srgbRed: 0.42, green: 0.39, blue: 0.96, alpha: 1)
let BADGE_SIZE = NSSize(width: 66, height: 20), MENU_BADGE_SIZE = NSSize(width: 38, height: 22)
let BADGE_OFFSET = CGPoint(x: 5, y: 6) // pill top-left from the window's top-left when no traffic lights are found
let CURSOR_IDLE: TimeInterval = 20, CURSOR_GLIDE: TimeInterval = 0.6, CURSOR_PANEL: CGFloat = 96 // tip at its center

func pillImage(_ size: NSSize, symbolSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium).applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: BADGE_SYMBOL, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    let image = NSImage(size: size, flipped: false) { rect in
        BADGE_COLOR.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        if let symbol {
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    image.accessibilityDescription = "An AI agent is using this app"
    return image
}

// Transparent panel that never takes focus nor the mouse.
func overlayPanel(_ size: NSSize) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    return panel
}

public final class Indicator {
    /// Off with --no-indicator: nothing is drawn and actions do not wait for the cursor's glide.
    public static var isEnabled = true
    /// Who is acting, for the menu bar tooltip ("Claude Code is using Notes"); set from the MCP client's name.
    public static var agentName = "An AI agent"

    static let shared = Indicator()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var windowID: CGWindowID = 0
    private var windowOrigin: CGPoint? // last known top-left of the target window (window list coordinates)
    private var offset = BADGE_OFFSET
    private var lastUse = Date.distantPast
    private var timer: Timer?
    private var cursor: NSPanel?
    private var cursorTip: CGPoint? // relative to the window's top-left, so the cursor follows a moved window
    private var cursorUse = Date.distantPast
    private var cursorVisible = false

    // Worker thread: the traffic lights are read through accessibility, then the main thread shows the badge.
    static func follow(_ app: NSRunningApplication, _ window: AXUIElement?, _ session: AppSession) {
        guard isEnabled else { return }
        var offset: CGPoint?
        let button = { (w: AXUIElement, name: String) -> CGRect? in
            guard let b = attr(w, name), CFGetTypeID(b) == AXUIElementGetTypeID(), let f = frame(b as! AXUIElement), f.width > 0 else { return nil }
            return f
        }
        if let window, let win = frame(window), let close = button(window, kAXCloseButtonAttribute) {
            let last = button(window, kAXZoomButtonAttribute) ?? button(window, kAXMinimizeButtonAttribute) ?? close
            offset = CGPoint(x: (close.minX + last.maxX) / 2 - win.minX - BADGE_SIZE.width / 2, y: close.midY - win.minY - BADGE_SIZE.height / 2)
        }
        let id = session.windowID ?? windowNumber(app.processIdentifier, session.windowFrame)
        let name = app.localizedName ?? "an app"
        DispatchQueue.main.async { shared.show(id, offset, name) }
    }
    static func hide() { guard isEnabled else { return }; DispatchQueue.main.async { shared.hide() } }

    // Worker thread, before an action: the cursor glides to the target (screen points, top-left origin) and the action
    // waits for it, so the user sees where the agent acts. Without a target it only shows the agent is still active.
    static func cursor(_ at: CGPoint?, click: Bool = false, wait: Bool = true) {
        guard isEnabled else { return }
        DispatchQueue.main.async { shared.moveCursor(at, click: click) }
        if at != nil && wait { Thread.sleep(forTimeInterval: CURSOR_GLIDE + (click ? 0.04 : 0)) }
    }

    // Without Screen Recording the window number comes from the window list: same app, closest frame.
    private static func windowNumber(_ pid: pid_t, _ frame: CGRect?) -> CGWindowID? {
        guard let frame else { return nil }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let bounds = { (w: [String: Any]) in (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null }
        let gap = { (r: CGRect) in abs(r.minX - frame.minX) + abs(r.minY - frame.minY) + abs(r.width - frame.width) + abs(r.height - frame.height) }
        return windows.min { gap(bounds($0)) < gap(bounds($1)) }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private func show(_ id: CGWindowID?, _ newOffset: CGPoint?, _ appName: String) {
        guard let id else { hide(); return }
        if id != windowID {
            offset = newOffset ?? BADGE_OFFSET
            if cursorVisible { hideCursor() } // another window: the cursor starts again from its center
            cursorTip = nil
            windowOrigin = nil
        } else if let newOffset { offset = newOffset }
        windowID = id
        lastUse = Date()
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = pillImage(MENU_BADGE_SIZE, symbolSize: 15)
            statusItem = item
        }
        statusItem?.button?.toolTip = "\(Indicator.agentName) is using \(appName)"
        let appearing = panel?.isVisible != true
        if panel == nil { panel = makePanel() }
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() } }
        guard let panel, place() else { return }
        if appearing { fadeIn(panel) }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        windowID = 0
        windowOrigin = nil
        panel?.orderOut(nil)
        hideCursor()
        cursorTip = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func tick() {
        if Date().timeIntervalSince(lastUse) > BADGE_IDLE { hide(); return }
        if cursorVisible && Date().timeIntervalSince(cursorUse) > CURSOR_IDLE { hideCursor() }
        _ = place()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = reduceMotion ? 1 : 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    private func bounds() -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
    // Window list coordinates start at the top-left of the main display; AppKit's at its bottom-left.
    private func appKit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y) }
    private func cursorOrigin(_ tip: CGPoint) -> CGPoint {
        let p = appKit(tip)
        return CGPoint(x: p.x - CURSOR_PANEL / 2, y: p.y - CURSOR_PANEL / 2)
    }

    // Follows the window when it moves, and stays just above it in the window order.
    private func place() -> Bool {
        guard let panel else { return false }
        guard let bounds = bounds() else { panel.orderOut(nil); cursor?.orderOut(nil); return false }
        let origin = appKit(CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y + BADGE_SIZE.height))
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        panel.order(.above, relativeTo: Int(windowID))
        if let cursor, cursorVisible, let tip = cursorTip {
            if windowOrigin != bounds.origin { cursor.setFrameOrigin(cursorOrigin(CGPoint(x: bounds.minX + tip.x, y: bounds.minY + tip.y))) }
            cursor.order(.above, relativeTo: Int(windowID))
        }
        windowOrigin = bounds.origin
        return true
    }

    private func moveCursor(_ at: CGPoint?, click: Bool) {
        guard windowID != 0, let bounds = bounds() else { return }
        cursorUse = Date()
        let cursor = self.cursor ?? makeCursor()
        self.cursor = cursor
        if !cursorVisible {
            // Appears where it last was in this window, otherwise at the window's center, then glides to the target.
            let start = cursorTip ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            cursorTip = start
            cursor.setFrameOrigin(cursorOrigin(CGPoint(x: bounds.minX + start.x, y: bounds.minY + start.y)))
            cursor.order(.above, relativeTo: Int(windowID))
            fadeIn(cursor)
            cursorVisible = true
            sway(true)
        }
        guard let at else { return }
        cursorTip = CGPoint(x: at.x - bounds.minX, y: at.y - bounds.minY)
        NSAnimationContext.runAnimationGroup {
            $0.duration = reduceMotion ? 0 : CURSOR_GLIDE
            // Gentle start and landing, so the glide stays visible all the way and the click lands as it arrives
            // (the old fast-start curve covered 80% of the way in 0.1 s, then crept: it looked like a jump, then a late click).
            $0.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            // setFrameOrigin is not animatable: the animator drops it silently and the cursor never moves. setFrame glides.
            cursor.animator().setFrame(NSRect(origin: cursorOrigin(at), size: cursor.frame.size), display: true)
        }
        if click { DispatchQueue.main.asyncAfter(deadline: .now() + CURSOR_GLIDE) { [weak self] in self?.ripple() } }
    }

    private func hideCursor() {
        guard let cursor, cursorVisible else { return }
        cursorVisible = false
        sway(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; cursor.animator().alphaValue = 0 }) { [weak self] in
            if self?.cursorVisible == false { cursor.orderOut(nil) }
        }
    }

    // Small pivot around the tip while the agent has the hand (rotation in AppKit's y-up space: positive = counterclockwise).
    private func sway(_ on: Bool) {
        guard let arrow = cursor?.contentView?.layer?.sublayers?.first(where: { $0.name == "arrow" }) else { return }
        arrow.removeAnimation(forKey: "sway")
        let base: CGFloat = 0
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: base))
        guard on, !reduceMotion else { return }
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, 5, -4, 0].map { $0 * CGFloat.pi / 180 }
        sway.duration = 2.4
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.add(sway, forKey: "sway")
    }

    private func ripple() {
        guard let root = cursor?.contentView?.layer, cursorVisible else { return }
        let ring = CALayer()
        ring.frame = CGRect(x: CURSOR_PANEL / 2 - 14, y: CURSOR_PANEL / 2 - 14, width: 28, height: 28)
        for (color, width) in [(NSColor.white.withAlphaComponent(0.6), CGFloat(4)), (NSColor(white: 0.07, alpha: 0.55), CGFloat(2))] {
            let circle = CAShapeLayer()
            circle.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            circle.fillColor = nil
            circle.strokeColor = color.cgColor
            circle.lineWidth = width
            circle.contentsScale = root.contentsScale
            ring.addSublayer(circle)
        }
        root.insertSublayer(ring, at: 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3; grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func makePanel() -> NSPanel {
        let panel = overlayPanel(BADGE_SIZE)
        panel.hasShadow = true
        let view = NSImageView(frame: NSRect(origin: .zero, size: BADGE_SIZE))
        view.image = pillImage(BADGE_SIZE, symbolSize: 14)
        view.imageScaling = .scaleNone
        panel.contentView = view
        return panel
    }

    private func makeCursor() -> NSPanel {
        let panel = overlayPanel(NSSize(width: CURSOR_PANEL, height: CURSOR_PANEL))
        panel.hasShadow = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: CURSOR_PANEL, height: CURSOR_PANEL))
        view.wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        view.layer?.contentsScale = scale
        // Soft dark halo under the arrow's body, as in Codex: the cursor stands out on any background. It never rotates.
        let c = CURSOR_PANEL / 2
        let halo = CAGradientLayer()
        halo.name = "halo"
        halo.type = .radial
        halo.frame = CGRect(x: c + 7 - 34, y: c - 8 - 34, width: 68, height: 68)
        halo.colors = [NSColor(white: 0, alpha: 0.38).cgColor, NSColor(white: 0, alpha: 0.16).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        halo.locations = [0, 0.45, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.contentsScale = scale
        view.layer?.addSublayer(halo)
        // A rounded arrowhead without a tail, as in Codex: light grey fill, white edge, its tip at the panel's center (the pivot).
        let arrow = CAShapeLayer()
        arrow.name = "arrow"
        arrow.frame = view.bounds
        let path = CGMutablePath()
        let points: [(CGFloat, CGFloat)] = [(0, 0), (4.2, 17.5), (8.2, 10.2), (17.5, 8.6)] // tip, bottom point, notch, right point
        for (i, p) in points.enumerated() {
            let q = CGPoint(x: c + p.0, y: c - p.1)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = NSColor(white: 0.86, alpha: 0.92).cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 2
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.45
        arrow.shadowRadius = 1.2
        arrow.shadowOffset = CGSize(width: 0, height: -0.5)
        arrow.contentsScale = scale
        view.layer?.addSublayer(arrow)
        panel.contentView = view
        return panel
    }
}
