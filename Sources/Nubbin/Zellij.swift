import Foundation

struct ZTab: Decodable, Equatable, Sendable {
    let tabId: Int
    let name: String
    let active: Bool
    let hasBellNotification: Bool
}

struct ZPane: Decodable, Equatable, Sendable {
    let id: Int
    let isPlugin: Bool
    let isFocused: Bool
    let title: String
    let tabId: Int
    let tabName: String
}

/// One poll result. `live` and `panes` are nil on a tabs-only (cheap) refresh.
struct ZellijPoll: Sendable {
    let live: Set<String>?
    let tabs: [String: [ZTab]]
    let panes: [String: [ZPane]]?
}

struct ZellijCLI: Sendable {
    let binary: String

    /// Apps launched from Finder/`open` get a minimal PATH, so ask the login shell.
    static func locate() -> ZellijCLI? {
        let fm = FileManager.default
        if let path = UserDefaults.standard.string(forKey: "zellijPath"), fm.isExecutableFile(atPath: path) {
            return ZellijCLI(binary: path)
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookup = "mise which zellij 2>/dev/null || command -v zellij"
        if let result = execute(shell, ["-lc", lookup], timeout: 10, mergeStderr: false), result.status == 0,
           let path = String(decoding: result.output, as: UTF8.self)
               .split(whereSeparator: \.isNewline).last.map(String.init),
           fm.isExecutableFile(atPath: path) {
            return ZellijCLI(binary: path)
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/zellij", "/usr/local/bin/zellij", "\(home)/.cargo/bin/zellij"]
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(ZellijCLI.init(binary:))
    }

    @discardableResult
    func run(_ arguments: [String]) -> Data? {
        guard let result = Self.execute(binary, arguments, timeout: 2, mergeStderr: false), result.status == 0 else { return nil }
        return result.output
    }

    /// Names of sessions with a running server. nil when zellij itself failed.
    func liveSessions() -> Set<String>? {
        guard let result = Self.execute(binary, ["list-sessions", "--no-formatting"], timeout: 2, mergeStderr: true) else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        // Exits non-zero with "No active zellij sessions found." when there are none.
        guard result.status == 0 else { return text.contains("No active") ? [] : nil }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            line.contains("EXITED") ? nil : line.split(separator: " ").first.map(String.init)
        })
    }

    func tabs(in session: String) -> [ZTab]? {
        decode(run(["--session", session, "action", "list-tabs", "--json"]))
    }

    func panes(in session: String) -> [ZPane]? {
        decode(run(["--session", session, "action", "list-panes", "--json", "--all"]))
    }

    func poll(full: Bool, known: Set<String>) -> ZellijPoll {
        let live = full ? liveSessions() : nil
        var tabs: [String: [ZTab]] = [:]
        var panes: [String: [ZPane]] = [:]
        for session in live ?? known {
            if let list = self.tabs(in: session) { tabs[session] = list }
            if full, let list = self.panes(in: session) { panes[session] = list }
        }
        return ZellijPoll(live: live, tabs: tabs, panes: full ? panes : nil)
    }

    private func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    private static func execute(_ path: String, _ arguments: [String], timeout: TimeInterval, mergeStderr: Bool) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, output)
    }
}

/// Polls tab state (bells, active tab) every 2s; sessions and panes every 10s or on request.
/// Each zellij call is a short-lived client process (~25ms), so the cheap path stays cheap.
@MainActor
final class ZellijPoller {
    private let cli: ZellijCLI
    private let store: Store
    private var live: Set<String> = []
    private var lastFull = Date.distantPast
    private var fullRequested = true

    init(cli: ZellijCLI, store: Store) {
        self.cli = cli
        self.store = store
    }

    func requestFullRefresh() { fullRequested = true }

    func start() {
        Task { [weak self] in
            while let self {
                await self.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll() async {
        let full = fullRequested || Date().timeIntervalSince(lastFull) >= 10
        fullRequested = false
        let cli = cli
        let known = live
        let result = await Task.detached(priority: .utility) { cli.poll(full: full, known: known) }.value
        if full {
            lastFull = Date()
            if let sessions = result.live { live = sessions }
        }
        store.applyZellij(result)
    }
}
