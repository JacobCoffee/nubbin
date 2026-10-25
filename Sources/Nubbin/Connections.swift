import Foundation
import Observation

/// One coding agent Nubbin can listen to, and whether its hook or extension is installed.
enum Integration: String, CaseIterable, Identifiable {
    case omp, claude, codex, pi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .omp: "oh-my-pi"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "pi"
        }
    }

    /// Where the agent keeps its config; its absence means the agent isn't on this Mac.
    var homeDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .omp: return home.appending(path: ".omp")
        case .claude: return home.appending(path: ".claude")
        case .codex: return home.appending(path: ".codex")
        case .pi: return home.appending(path: ".pi")
        }
    }

    /// The file our hook lives in (Claude, Codex) or that is our extension (omp, pi).
    var configFile: URL {
        switch self {
        case .omp: homeDir.appending(path: "agent/extensions/nubbin.ts")
        case .pi: homeDir.appending(path: "agent/extensions/nubbin.ts")
        case .claude: homeDir.appending(path: "settings.json")
        case .codex: homeDir.appending(path: "hooks.json")
        }
    }

    var reports: String {
        switch self {
        case .omp: "Session titles, model, live activity, questions from ask and ask_user_question, approvals."
        case .claude: "Questions, plans, and permission requests, with Approve and Deny from the notch."
        case .codex: "Working, finished, failed, and the commands it wants to run."
        case .pi: "Working, finished, and failed."
        }
    }

    /// What to do after connecting so already-running sessions pick it up.
    var afterConnecting: String? {
        switch self {
        case .omp: "Run /reload-plugins in omp sessions that are already open."
        case .pi: "Restart pi sessions that are already open."
        case .codex: "Codex asks once before running new hooks: run /hooks in Codex and approve Nubbin."
        case .claude: "New Claude sessions pick it up; open ones after their next prompt."
        }
    }
}

enum ConnectionState: Equatable {
    case notInstalled, disconnected, connected
}

@MainActor
@Observable
final class Connections {
    static let shared = Connections()

    private(set) var states: [Integration: ConnectionState] = [:]
    private(set) var busy: Set<Integration> = []
    private(set) var lastError: String?

    private static let marker = "Nubbin.app/Contents/MacOS/Nubbin"

    func refresh() {
        var next: [Integration: ConnectionState] = [:]
        let fm = FileManager.default
        for integration in Integration.allCases {
            guard fm.fileExists(atPath: integration.homeDir.path) else { next[integration] = .notInstalled; continue }
            switch integration {
            case .omp, .pi:
                next[integration] = fm.fileExists(atPath: integration.configFile.path) ? .connected : .disconnected
            case .claude, .codex:
                let text = (try? String(contentsOf: integration.configFile, encoding: .utf8)) ?? ""
                next[integration] = text.contains(Self.marker) ? .connected : .disconnected
            }
        }
        states = next
    }

    func set(_ integration: Integration, connected: Bool) {
        guard !busy.contains(integration) else { return }
        busy.insert(integration)
        lastError = nil
        Task {
            let error = await Task.detached { Self.apply(integration, connected: connected) }.value
            busy.remove(integration)
            lastError = error
            refresh()
        }
    }

    /// Returns an error message, or nil on success.
    nonisolated private static func apply(_ integration: Integration, connected: Bool) -> String? {
        let resources = Bundle.main.resourceURL
        switch integration {
        case .omp, .pi:
            if !connected {
                try? FileManager.default.removeItem(at: integration.configFile)
                return nil
            }
            guard let template = resources?.appending(path: "nubbin-extension.ts"),
                  let source = try? String(contentsOf: template, encoding: .utf8)
            else { return "The extension is missing from the app bundle. Rebuild with make install." }
            do {
                try FileManager.default.createDirectory(at: integration.configFile.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try source.replacingOccurrences(of: "__AGENT__", with: integration.rawValue)
                    .write(to: integration.configFile, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .claude, .codex:
            guard let script = resources?.appending(path: "install_hooks.py").path,
                  let binary = Bundle.main.executablePath
            else { return "The hook installer is missing from the app bundle. Rebuild with make install." }
            var arguments = [script, "--agent", integration.rawValue]
            arguments += connected ? ["--binary", binary] : ["--uninstall"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return error.localizedDescription
            }
            guard process.terminationStatus == 0 else {
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "The installer failed."
            }
            return nil
        }
    }
}
