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

        let reply = send(data, awaitReply: awaitDecision)
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

    /// Returns the app's reply when `awaitReply`; nil when the app is gone or released the request.
    private static func send(_ data: Data, awaitReply: Bool) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

        guard var addr = unixAddress(Paths.socket.path) else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let sent = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard sent, awaitReply else { return nil }

        // Signal end of message, then wait for the answer. Claude's hook timeout (set to 600s by
        // the installer) bounds this; the app closes the connection when the prompt is answered elsewhere.
        shutdown(fd, SHUT_WR)
        var receiveTimeout = timeval(tv_sec: 590, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
        }
        return reply.isEmpty ? nil : reply
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
