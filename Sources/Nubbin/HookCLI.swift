import Foundation

/// Runs as an agent hook: forwards the hook JSON plus terminal context to the app.
/// Must never fail the agent: every error path exits 0 silently. The only output is a permission
/// decision, and only when the user answered a Claude Code PermissionRequest from the notch.
enum HookCLI {
    private static let forwardedEnv = ["ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID", "__CFBundleIdentifier", "TERM_PROGRAM"]

    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
        // PostToolUse carries the full tool output; the app only needs the event.
        payload.removeValue(forKey: "tool_response")

        let env = ProcessInfo.processInfo.environment
        var context: [String: String] = [:]
        for key in forwardedEnv {
            if let value = env[key], !value.isEmpty { context[key] = value }
        }
        // `Nubbin hook --agent codex`; Claude Code is the default.
        let args = CommandLine.arguments
        let agent = args.firstIndex(of: "--agent").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "claude"
        // Claude Code keeps showing its own prompt while this hook waits, so the notch and the
        // terminal race and whichever answers first wins (Codex would hide its prompt instead).
        let awaitDecision = agent == "claude" && payload["hook_event_name"] as? String == "PermissionRequest"
        var envelope: [String: Any] = ["agent": agent, "payload": payload, "env": context]
        if awaitDecision { envelope["await"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }

        let reply = SocketClient.send(data, awaitReply: awaitDecision, timeout: 590)
        if let reply,
           let decision = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
           decision["behavior"] is String,
           let output = try? JSONSerialization.data(withJSONObject: [
               "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
           ]) {
            FileHandle.standardOutput.write(output + Data("\n".utf8))
        }
        exit(0)
    }
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return addr
}
