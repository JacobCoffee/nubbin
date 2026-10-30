import Foundation

/// `Nubbin ctl list|focus <id>`: sends a control request over the event socket and prints the JSON
/// reply. Useful for scripting Nubbin (e.g. Patch's voice control) and for smoke tests.
enum ControlCLI {
    static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst(2)) // after "Nubbin" "ctl"
        guard let command = args.first else {
            FileHandle.standardError.write(Data("usage: Nubbin ctl list|focus <id>\n".utf8))
            exit(64)
        }

        let request: [String: Any]
        switch command {
        case "list":
            request = ["type": "list", "await": true]
        case "focus":
            guard args.count > 1 else {
                FileHandle.standardError.write(Data("usage: Nubbin ctl focus <id>\n".utf8))
                exit(64)
            }
            request = ["type": "focus", "id": args[1], "await": true]
        default:
            FileHandle.standardError.write(Data("unknown ctl command: \(command)\n".utf8))
            exit(64)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: request) else { exit(1) }
        guard let reply = SocketClient.send(data, awaitReply: true, timeout: 5) else {
            print(#"{"ok":false,"error":"no reply from Nubbin"}"#)
            exit(1)
        }
        FileHandle.standardOutput.write(reply)
        if reply.last != UInt8(ascii: "\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
        exit(0)
    }
}
