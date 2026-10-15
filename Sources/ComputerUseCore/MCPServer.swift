import Foundation

public enum Version { public static let current = "0.1.0" }

// Model Context Protocol over stdio: one JSON-RPC message per line on stdin, one per line on stdout, logs on stderr.
// Implements what a tools-only server needs (initialize, ping, tools/list, tools/call). Tool calls run one at a time
// on a background queue, so pings are still answered while an action or an approval dialog is in progress.

public final class MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    let executor: ToolExecutor
    let write: (Data) -> Void
    let queue = DispatchQueue(label: "mac-computer-use-mcp.tools")
    private(set) var agentName = "An AI agent"

    public init(executor: ToolExecutor, write: ((Data) -> Void)? = nil) {
        self.executor = executor
        self.write = write ?? MCPServer.standardOutput
    }

    private static let lock = NSLock()
    static func standardOutput(_ data: Data) {
        lock.lock(); FileHandle.standardOutput.write(data + Data([0x0a])); lock.unlock()
    }

    /// Reads stdin until the client closes it, then lets the call in progress finish.
    public func run() {
        while let line = readLine(strippingNewline: true) { receive(line) }
        queue.sync {}
    }

    public func receive(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let message = object as? [String: Any] else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Batches are not supported"]])
        }
        // Responses from the client and notifications (no id) need no answer.
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let client = params["clientInfo"] as? [String: Any]
            if let name = (client?["title"] as? String) ?? (client?["name"] as? String), !name.isEmpty {
                agentName = String(name.prefix(60))
                Indicator.agentName = agentName
            }
            let requested = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": MCPServer.supportedVersions.contains(requested) ? requested : MCPServer.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mac-computer-use-mcp", "title": "Mac Computer Use MCP", "version": Version.current],
                "instructions": ToolCatalog.instructions
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": ToolCatalog.tools])
        case "tools/call":
            guard let name = params["name"] as? String, let schema = ToolCatalog.schema(of: name) else {
                return fail(id, -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if let problem = ToolCatalog.validate(arguments, against: schema) {
                return reply(id, result(.text(problem, error: true)))
            }
            let agent = agentName
            queue.async { [self] in reply(id, result(executor.call(name, arguments, agentName: agent))) }
        default:
            fail(id, -32601, "Method not found: \(method)")
        }
    }

    private func result(_ r: ToolResult) -> [String: Any] { ["content": r.content, "isError": r.isError] }
    private func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func fail(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        write(data)
    }
}
