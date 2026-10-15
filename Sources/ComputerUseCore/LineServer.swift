import Foundation

// Line protocol for apps that embed this binary (docs/EMBEDDING.md): one JSON request per line on stdin,
// {"id":1,"op":"get_app_state","input":{"app":"TextEdit"}}, one answer per line on stdout, {"id":1,"result":…} or
// {"id":1,"error":"…"}. The embedding app launches the binary, so macOS grants the permissions to that app, and it
// decides itself which apps its agents may use: no approval dialog here. Password managers stay blocked.

public enum LineServer {
    private static let lock = NSLock()

    public static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            reply(answer(request))
        }
    }

    /// One request → one answer (separated from run() for the tests).
    public static func answer(_ request: [String: Any]) -> [String: Any] {
        let id = request["id"] ?? NSNull()
        do {
            return ["id": id, "result": encode(try Engine.perform(request["op"] as? String ?? "", request["input"] as? [String: Any] ?? [:]))]
        } catch let f as Failure { return ["id": id, "error": f.message] }
        catch { return ["id": id, "error": error.localizedDescription] }
    }

    static func encode(_ value: Any) -> Any {
        guard let state = value as? AppState else { return value }
        var out: [String: Any] = ["app": state.app, "bundleId": state.bundleId, "pid": state.pid, "text": state.text]
        if let shot = state.screenshot {
            out["screenshot"] = shot.png.base64EncodedString()
            out["screenshotWidth"] = shot.width
            out["screenshotHeight"] = shot.height
            out["screenshotScale"] = state.screenshotScale
        } else if state.screenshotDenied {
            out["screenshotDenied"] = true
        }
        return out
    }

    private static func reply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return }
        lock.lock(); FileHandle.standardOutput.write(data + Data([0x0a])); lock.unlock()
    }
}
