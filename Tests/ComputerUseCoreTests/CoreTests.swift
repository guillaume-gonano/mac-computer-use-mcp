import ApplicationServices
import XCTest
@testable import ComputerUseCore

// Everything that can be checked without the Accessibility permission or a real app window.

final class TreeTextTests: XCTestCase {
    func testRoleNames() {
        XCTAssertEqual(roleName("AXButton", nil), "button")
        XCTAssertEqual(roleName("AXTextField", "AXSearchField"), "search field")
        XCTAssertEqual(roleName("AXRulerMarker", nil), "ruler marker")
    }
    func testActionNames() {
        XCTAssertEqual(prettyAction("AXShowMenu"), "Show Menu")
        XCTAssertEqual(prettyAction("Name:Copy Link\nTarget:0x0\nSelector:(null)"), "Copy Link")
    }
    func testOneLine() {
        XCTAssertEqual(oneLine("a\nb\tc"), "a\\nb c")
        XCTAssertEqual(oneLine(String(repeating: "x", count: 10), 4), "xxxx…")
    }
    func testRemovedRanges() {
        XCTAssertEqual(ranges([1, 2, 3, 7, 9, 10]), "1-3, 7, 9-10")
        XCTAssertEqual(ranges([4]), "4")
        XCTAssertEqual(ranges([]), "")
    }
}

final class KeyTests: XCTestCase {
    func testNamedKeysAndModifiers() throws {
        let (code, flags) = try parseKey("super+Return")
        XCTAssertEqual(code, 36)
        XCTAssertEqual(flags, .maskCommand)
        let (tab, shift) = try parseKey("shift+Tab")
        XCTAssertEqual(tab, 48)
        XCTAssertEqual(shift, .maskShift)
        XCTAssertEqual(try parseKey("KP_0").0, 82)
    }
    func testInvalidKeys() {
        XCTAssertThrowsError(try parseKey("hyper+a"))
        XCTAssertThrowsError(try parseKey("NotAKey"))
        XCTAssertThrowsError(try parseKey(""))
    }
}

final class PolicyTests: XCTestCase {
    var folder: URL!
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testAccessRules() {
        let saved = ["com.apple.TextEdit": Decision(name: "TextEdit", allowed: true, at: Date()),
                     "com.apple.Notes": Decision(name: "Notes", allowed: false, at: Date())]
        XCTAssertEqual(access("com.1password.1password", saved: [:], session: [], mode: .allowAll), .blocked)
        XCTAssertEqual(access("not a bundle id", saved: [:], session: [], mode: .allowAll), .blocked)
        XCTAssertEqual(access("com.apple.TextEdit", saved: saved, session: [], mode: .ask), .allow)
        XCTAssertEqual(access("com.apple.Notes", saved: saved, session: [], mode: .allowAll), .deny, "a saved refusal wins over --allow-all")
        XCTAssertEqual(access("com.apple.Maps", saved: saved, session: ["com.apple.Maps"], mode: .ask), .allow)
        XCTAssertEqual(access("com.apple.Maps", saved: saved, session: [], mode: .ask), .ask)
        XCTAssertEqual(access("com.apple.Maps", saved: saved, session: [], mode: .allowAll), .allow)
    }

    func testStoreRoundTripIsPrivate() throws {
        let store = ApprovalStore(url: folder.appendingPathComponent("approvals.json"))
        XCTAssertTrue(store.load().isEmpty)
        try store.save("com.apple.TextEdit", name: "TextEdit", allowed: true)
        try store.save("com.apple.Notes", name: "Notes", allowed: false)
        XCTAssertEqual(store.load()["com.apple.TextEdit"]?.allowed, true)
        XCTAssertEqual(store.load()["com.apple.Notes"]?.allowed, false)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try store.save("com.apple.Notes", name: "Notes", allowed: nil)
        XCTAssertNil(store.load()["com.apple.Notes"])
        try store.reset()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testStoreDropsInvalidEntries() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("approvals.json")
        try Data(#"{"com.apple.TextEdit":{"name":"TextEdit","decision":"allow"},"bad id!":{"decision":"allow"},"com.x.y":{"decision":"maybe"}}"#.utf8).write(to: url)
        XCTAssertEqual(Array(ApprovalStore(url: url).load().keys), ["com.apple.TextEdit"])
    }

    func testApprovalAnswers() throws {
        let store = ApprovalStore(url: folder.appendingPathComponent("approvals.json"))
        let approvals = Approvals(store: store)
        let maps = Target(url: nil, bundleId: "com.apple.Maps", name: "Maps")
        var asked = 0
        approvals.ask = { _, _ in asked += 1; return .session }
        try approvals.check(maps, agentName: "Test")
        try approvals.check(maps, agentName: "Test")
        XCTAssertEqual(asked, 1, "allowed for the session: asked once")
        XCTAssertNil(store.load()["com.apple.Maps"], "a session approval is not saved")

        let notes = Target(url: nil, bundleId: "com.apple.Notes", name: "Notes")
        approvals.ask = { _, _ in .always }
        try approvals.check(notes, agentName: "Test")
        XCTAssertEqual(store.load()["com.apple.Notes"]?.allowed, true)

        let mail = Target(url: nil, bundleId: "com.apple.mail", name: "Mail")
        approvals.ask = { _, _ in .deny }
        XCTAssertThrowsError(try approvals.check(mail, agentName: "Test"))
        XCTAssertNil(store.load()["com.apple.mail"], "a refusal applies to that request only")
    }
}

final class ToolCatalogTests: XCTestCase {
    func testToolsMatchEngineOperations() {
        XCTAssertEqual(ToolCatalog.tools.map { $0["name"] as? String ?? "" }, Engine.toolOperations)
        for tool in ToolCatalog.tools where tool["name"] as? String != "list_apps" {
            let schema = tool["inputSchema"] as! [String: Any]
            XCTAssertEqual((schema["required"] as? [String])?.first, "app", "\(tool["name"]!) needs the app")
            XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: tool), "\(tool["name"]!) is valid JSON")
        }
    }
    func testValidation() {
        let click = ToolCatalog.schema(of: "click")!
        XCTAssertNil(ToolCatalog.validate(["app": "TextEdit", "element_index": 3], against: click))
        XCTAssertNil(ToolCatalog.validate(["app": "TextEdit", "x": 10.5, "y": 20, "extra": "ignored"], against: click))
        XCTAssertNotNil(ToolCatalog.validate(["element_index": 3], against: click), "app is required")
        XCTAssertNotNil(ToolCatalog.validate(["app": "TextEdit", "element_index": 1.5], against: click))
        XCTAssertNotNil(ToolCatalog.validate(["app": "TextEdit", "element_index": true], against: click))
        XCTAssertNotNil(ToolCatalog.validate(["app": "TextEdit", "mouse_button": "side"], against: click))
        XCTAssertNotNil(ToolCatalog.validate(["app": ""], against: click))
        let state = ToolCatalog.schema(of: "get_app_state")!
        XCTAssertNil(ToolCatalog.validate(["app": "Notes", "disableDiff": true], against: state))
        XCTAssertNotNil(ToolCatalog.validate(["app": "Notes", "disableDiff": 1], against: state))
    }
}

final class FakeExecutor: ToolExecutor {
    var calls: [(String, [String: Any], String)] = []
    func call(_ name: String, _ arguments: [String: Any], agentName: String) -> ToolResult {
        calls.append((name, arguments, agentName))
        return .text("ok \(name)")
    }
}

final class MCPServerTests: XCTestCase {
    var output: [[String: Any]] = []
    let lock = NSLock()
    var executor = FakeExecutor()
    lazy var server = MCPServer(executor: executor) { [unowned self] data in
        lock.lock(); output.append(try! JSONSerialization.jsonObject(with: data) as! [String: Any]); lock.unlock()
    }
    func send(_ object: [String: Any]) { server.receive(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
    func last() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return output.last ?? [:] }

    func testInitializeNegotiatesVersionAndNamesTheAgent() {
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "title": "Claude Code"]]])
        let result = last()["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, Version.current)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual(server.agentName, "Claude Code")
        send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((last()["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])
    }
    func testListPingAndErrors() {
        send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertEqual(((last()["result"] as? [String: Any])?["tools"] as? [Any])?.count, 11)
        send(["jsonrpc": "2.0", "id": 2, "method": "ping"])
        XCTAssertEqual(last()["id"] as? Int, 2)
        XCTAssertNotNil(last()["result"])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(output.count, 2, "notifications get no answer")
        send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((last()["error"] as? [String: Any])?["code"] as? Int, -32601)
        send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "format_disk"]])
        XCTAssertEqual((last()["error"] as? [String: Any])?["code"] as? Int, -32602)
        server.receive("{not json")
        XCTAssertEqual((last()["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
    func testToolCalls() {
        send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "click", "arguments": ["element_index": 2]]])
        let invalid = last()["result"] as! [String: Any]
        XCTAssertEqual(invalid["isError"] as? Bool, true, "invalid arguments are a tool error the model can fix")
        XCTAssertTrue(executor.calls.isEmpty)

        send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_app_state", "arguments": ["app": "TextEdit"]]])
        server.queue.sync {}
        let result = last()["result"] as! [String: Any]
        XCTAssertEqual(last()["id"] as? Int, 2)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(((result["content"] as? [[String: Any]])?.first)?["text"] as? String, "ok get_app_state")
        XCTAssertEqual(executor.calls.first?.0, "get_app_state")
    }
}

final class LineServerTests: XCTestCase {
    func testAnswersCarryTheRequestId() {
        let unknown = LineServer.answer(["id": 7, "op": "format_disk"])
        XCTAssertEqual(unknown["id"] as? Int, 7)
        XCTAssertNotNil(unknown["error"])
        let permissions = LineServer.answer(["id": "a", "op": "permissions"])
        XCTAssertNotNil((permissions["result"] as? [String: Any])?["accessibility"])
    }
}
