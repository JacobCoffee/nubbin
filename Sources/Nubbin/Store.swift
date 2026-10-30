import AppKit
import Observation

/// Ordered by urgency: lower sorts first.
enum Activity: Int, Comparable {
    case needsYou, error, done, working, idle

    static func < (lhs: Activity, rhs: Activity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Question: Equatable {
    var header: String?
    var text: String
    var options: [String]
    var multiSelect: Bool
    /// Index of the option the agent suggests (omp's `ask` tool).
    var recommended: Int?
}

/// What exactly the agent is waiting on, shown in full when the row needs you.
enum PromptDetail: Equatable {
    case questions([Question])
    case approval(tool: String, command: String?)
    case plan
}

enum Decision {
    case allow, alwaysAllow, deny
}

struct Row: Identifiable, Equatable {
    enum Source { case agent, bell }

    let id: String
    let source: Source
    /// claude, codex, omp, pi; nil for bell rows.
    let agent: String?
    let title: String
    let model: String?
    /// Working directory the agent reported; nil when unknown.
    let cwd: String?
    /// "session › tab" in zellij.
    let location: String?
    let detail: String?
    let prompt: PromptDetail?
    /// A Claude Code permission request is holding for an answer from the notch.
    let canDecide: Bool
    let canAlwaysAllow: Bool
    let activity: Activity
    let since: Date
    let zellijSession: String?
    let zellijTabID: Int?
    let zellijPaneID: Int?
    let terminalBundleID: String?
}

private struct AgentSession {
    let agent: String
    let id: String
    var cwd = ""
    var title: String?
    var model: String?
    var activity = Activity.idle
    var since = Date()
    var prompt: String?
    /// One-line summary of what it is asking (needsYou) or why it failed (error).
    var ask: String?
    var promptDetail: PromptDetail?
    /// Latest tool it started while working (omp reports these).
    var doing: String?
    var workStarted: Date?
    /// Reminders rung since it last changed state.
    var reminders = 0
    var zellijSession: String?
    var zellijPaneID: Int?
    var terminalBundleID: String?
    /// Held hook connection for a Claude permission request, and the "always allow" rules it offered.
    var decisionToken: EventServer.Token?
    var permissionSuggestions: Any?

    mutating func set(_ activity: Activity, ask: String? = nil, detail: PromptDetail? = nil) {
        if activity != self.activity {
            since = Date()
            reminders = 0
        }
        self.activity = activity
        self.ask = ask
        self.promptDetail = detail
    }
}

/// A zellij tab showing the bell marker (any program that rang BEL, not just a hooked agent).
private struct BellTab {
    let session: String
    let tabID: Int
    let since: Date
    var reminders = 0
    /// Hidden by the user until the tab is visited and rings again.
    var dismissed = false
}

private struct ZellijState {
    var tabs: [ZTab] = []
    var panes: [ZPane] = []
}

@MainActor
@Observable
final class Store {
    private var sessions: [String: AgentSession] = [:]
    private var bells: [String: BellTab] = [:]
    private var zellij: [String: ZellijState] = [:]
    @ObservationIgnored private var bellsPrimed = false

    /// A row that wants the user's attention: play the chime, open the notch.
    @ObservationIgnored var onAttention: ((Row, Moment) -> Void)?
    /// A hook referenced a zellij pane the last snapshot doesn't know about.
    @ObservationIgnored var onZellijMappingNeeded: (() -> Void)?
    /// Answers a held hook connection (see `EventServer.reply`).
    @ObservationIgnored var onReply: ((EventServer.Token, Data) -> Void)?

    var rows: [Row] {
        let prefs = Preferences.shared
        let agentRows = sessions.values.filter { prefs.alert(for: $0.agent) != .hidden }.map(row(for:))
        let covered = coveredTabs()
        let bellsHidden = prefs.alert(for: nil) == .hidden
        let bellRows = bells.compactMap { key, bell in
            bellsHidden || bell.dismissed || covered.contains(key) ? nil : row(for: bell)
        }
        return (agentRows + bellRows).sorted { ($0.activity, $1.since) < ($1.activity, $0.since) }
    }

    // MARK: agent hooks (Claude Code, Codex, and the pi/omp extension all send this shape)

    func handleHook(_ data: Data, token: EventServer.Token?) {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let event = payload["hook_event_name"] as? String,
              let sessionID = payload["session_id"] as? String
        else {
            if let token { onReply?(token, Data()) }
            return
        }
        let env = envelope["env"] as? [String: String] ?? [:]
        let agent = envelope["agent"] as? String ?? "claude"
        let id = "\(agent):\(sessionID)"

        if event == "SessionEnd" {
            if var ended = sessions.removeValue(forKey: id) { release(&ended) }
            debugLog("hook SessionEnd \(id)")
            return
        }

        var session = sessions[id] ?? AgentSession(agent: agent, id: sessionID)
        if let cwd = payload["cwd"] as? String { session.cwd = cwd }
        if let title = payload["session_title"] as? String, !title.isEmpty { session.title = title }
        if let model = payload["model"] as? String, !model.isEmpty { session.model = model }
        if let name = env["ZELLIJ_SESSION_NAME"] { session.zellijSession = name }
        if let pane = env["ZELLIJ_PANE_ID"].flatMap(Int.init) { session.zellijPaneID = pane }
        if let bundle = env["__CFBundleIdentifier"] { session.terminalBundleID = bundle }
        let before = session.activity

        // Anything that moves the session along means a held permission request was answered elsewhere.
        if !["Notification", "SessionInfo", "ToolStart"].contains(event) { release(&session) }

        switch event {
        case "UserPromptSubmit":
            session.set(.working)
            session.prompt = oneLine(payload["prompt"] as? String)
            session.doing = nil
            session.workStarted = Date()
        case "PreToolUse":
            // Registered (Claude) or sent (omp) only for tools that block on the user.
            let tool = payload["tool_name"] as? String
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                session.set(.needsYou, ask: toolSummary(payload), detail: promptDetail(payload))
            }
        case "PermissionRequest":
            session.set(.needsYou, ask: toolSummary(payload), detail: promptDetail(payload))
            if let token {
                session.decisionToken = token
                session.permissionSuggestions = payload["permission_suggestions"]
            }
        case "PostToolUse":
            // The tool ran, so whatever was asked got answered.
            if session.activity == .needsYou { session.set(.working) }
        case "ToolStart":
            if session.activity == .working || session.activity == .idle {
                if session.activity == .idle { session.set(.working); session.workStarted = Date() }
                session.doing = oneLine(payload["activity"] as? String)
            }
        case "Notification":
            switch payload["notification_type"] as? String {
            case "idle_prompt", "auth_success":
                break
            case "permission_prompt" where session.activity == .needsYou:
                break // PermissionRequest already supplied a better description.
            default:
                session.set(.needsYou, ask: oneLine(payload["message"] as? String) ?? "Needs you")
            }
        case "Stop":
            session.set(.done)
        case "StopFailure":
            let reason = (payload["error"] as? String) ?? (payload["message"] as? String)
            session.set(.error, ask: oneLine(reason) ?? "Request failed")
        default:
            break // SessionStart, SessionInfo: registers the row or refreshes its title and model.
        }
        // A request that couldn't be held (shouldn't happen) must not leave the hook hanging.
        if let token, session.decisionToken != token { onReply?(token, Data()) }

        sessions[id] = session
        debugLog("hook \(event) \(id) \(before) -> \(session.activity) \(session.ask ?? session.doing ?? "")")

        if let name = session.zellijSession, let pane = session.zellijPaneID,
           zellij[name]?.panes.contains(where: { !$0.isPlugin && $0.id == pane }) != true {
            onZellijMappingNeeded?()
        }
        if session.activity != before { announce(session) }
    }

    /// Approve or deny a held Claude Code permission request from the notch.
    func decide(_ row: Row, _ decision: Decision) {
        let id = String(row.id.dropFirst("agent:".count))
        guard var session = sessions[id], let token = session.decisionToken else { return }
        var reply: [String: Any]
        switch decision {
        case .allow:
            reply = ["behavior": "allow"]
        case .alwaysAllow:
            reply = ["behavior": "allow"]
            if let rules = session.permissionSuggestions { reply["updatedPermissions"] = rules }
        case .deny:
            reply = ["behavior": "deny", "message": "Denied from Nubbin."]
        }
        if let data = try? JSONSerialization.data(withJSONObject: reply) { onReply?(token, data) }
        session.decisionToken = nil
        session.permissionSuggestions = nil
        session.set(.working)
        sessions[id] = session
        debugLog("decided \(id) \(decision)")
    }

    /// Let a waiting hook exit without a decision; Claude keeps its own prompt.
    private func release(_ session: inout AgentSession) {
        guard let token = session.decisionToken else { return }
        onReply?(token, Data())
        session.decisionToken = nil
        session.permissionSuggestions = nil
    }

    private func announce(_ session: AgentSession) {
        let row = row(for: session)
        switch session.activity {
        case .needsYou:
            attention(row, .needsYou)
        case .error:
            attention(row, .error)
        case .done:
            // Short tasks finish while you're still watching; and done rings even in the focused tab.
            guard let start = session.workStarted,
                  Date().timeIntervalSince(start) >= Preferences.shared.doneAfter,
                  Preferences.shared.alert(for: row.agent) == .chime else { return }
            onAttention?(row, .done)
        case .working, .idle:
            break
        }
    }

    // MARK: zellij

    func applyZellij(_ poll: ZellijPoll) {
        if let live = poll.live {
            zellij = zellij.filter { live.contains($0.key) }
        }
        // Assign only on change: every write invalidates `rows` observers.
        for (name, tabs) in poll.tabs where zellij[name]?.tabs != tabs {
            zellij[name, default: ZellijState()].tabs = tabs
        }
        if let panes = poll.panes {
            for (name, list) in panes where zellij[name]?.panes != list {
                zellij[name, default: ZellijState()].panes = list
            }
            if let live = poll.live { pruneClosedPanes(live: live, panes: panes) }
        }
        updateBells()
    }

    /// Drop agent rows whose zellij pane or session is gone (covers crashes that skip SessionEnd).
    private func pruneClosedPanes(live: Set<String>, panes: [String: [ZPane]]) {
        for (id, session) in sessions {
            guard let name = session.zellijSession else { continue }
            let gone = !live.contains(name)
                || (session.zellijPaneID.map { pane in
                    panes[name].map { !$0.contains { !$0.isPlugin && $0.id == pane } } ?? false
                } ?? false)
            if gone, var removed = sessions.removeValue(forKey: id) { release(&removed) }
        }
    }

    private func updateBells() {
        var next: [String: BellTab] = [:]
        var rang: [BellTab] = []
        for (name, state) in zellij {
            for tab in state.tabs where tab.hasBellNotification {
                let key = bellKey(name, tab.tabId)
                if let existing = bells[key] {
                    next[key] = existing
                } else {
                    let bell = BellTab(session: name, tabID: tab.tabId, since: Date())
                    next[key] = bell
                    rang.append(bell)
                }
            }
        }
        if next.keys != bells.keys { bells = next }

        // Bells already showing at launch are old news.
        guard bellsPrimed else { bellsPrimed = true; return }
        guard !rang.isEmpty else { return }
        onZellijMappingNeeded?() // fetch pane titles for the new rows
        let covered = coveredTabs()
        for bell in rang where !covered.contains(bellKey(bell.session, bell.tabID)) {
            debugLog("bell \(bell.session) tab \(bell.tabID)")
            attention(row(for: bell), .needsYou)
        }
    }

    // MARK: reminders and housekeeping

    /// Ring again for anything still waiting, every `Preferences.reminderAfter` (0: never),
    /// up to `Preferences.reminderLimit` times (0: until it's handled).
    func remindOverdue() {
        let after = Preferences.shared.reminderAfter
        let limit = Preferences.shared.reminderLimit
        guard after > 0 else { return }
        let now = Date()
        func due(_ since: Date, _ reminders: Int) -> Bool {
            (limit == 0 || reminders < limit) && now.timeIntervalSince(since) >= after * Double(reminders + 1)
        }
        for (id, session) in sessions where session.activity == .needsYou && due(session.since, session.reminders) {
            sessions[id]?.reminders += 1
            attention(row(for: session), .needsYou)
        }
        let covered = coveredTabs()
        for (key, bell) in bells where !bell.dismissed && !covered.contains(key) && due(bell.since, bell.reminders) {
            bells[key]?.reminders += 1
            attention(row(for: bell), .needsYou)
        }
    }

    func clearFinished() {
        sessions = sessions.filter { $0.value.activity == .needsYou || $0.value.activity == .working }
    }

    /// Row ids are "agent:<session key>" and "bell:<bell key>".
    func dismiss(_ row: Row) {
        switch row.source {
        case .agent:
            if var removed = sessions.removeValue(forKey: String(row.id.dropFirst("agent:".count))) {
                release(&removed)
            }
        case .bell:
            bells[String(row.id.dropFirst("bell:".count))]?.dismissed = true
        }
    }

    // MARK: rehearsal

    /// Show a realistic row for a moment, so Settings can rehearse it here or on the real notch.
    /// Returns the row; it removes itself after `seconds` unless rehearsed again.
    @discardableResult
    func rehearse(_ moment: Moment, removeAfter seconds: TimeInterval? = 8) -> Row {
        let id = "nubbin:rehearsal"
        var session = AgentSession(agent: "omp", id: "rehearsal")
        session.title = "Rehearsal"
        session.model = "Claude Opus 5.5"
        switch moment {
        case .needsYou:
            session.set(.needsYou, ask: "Which database should I use?", detail: .questions([
                Question(header: "Database", text: "Which database should I use for the users table?",
                         options: ["PostgreSQL", "SQLite"], multiSelect: false, recommended: 0),
            ]))
        case .done:
            session.prompt = "Set up the users table"
            session.set(.done)
        case .error:
            session.set(.error, ask: "Rate limit reached, retrying in 40s")
        }
        sessions[id] = session
        rehearsalGeneration += 1
        if let seconds {
            let generation = rehearsalGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, generation == self.rehearsalGeneration else { return }
                self.sessions[id] = nil
            }
        }
        return row(for: session)
    }

    /// Seed a few lifelike sessions for the Settings stage.
    func seedStage(highlight moment: Moment?) {
        func add(_ key: String, _ agent: String, title: String, model: String, _ build: (inout AgentSession) -> Void) {
            var session = AgentSession(agent: agent, id: key)
            session.title = title
            session.model = model
            session.zellijSession = "atelier"
            build(&session)
            sessions["\(agent):\(key)"] = session
        }
        sessions.removeAll()
        add("a", "omp", title: "🔔BELL: Notch notifications for agents", model: "Claude Opus 5.5") {
            $0.set(.working)
            $0.doing = "Reading NotchView.swift"
        }
        add("b", "codex", title: "pydotorg", model: "gpt-6.1") {
            $0.set(.working)
            $0.doing = "Bumping Django to 5.2"
        }
        add("c", "claude", title: "checkout-api", model: "Opus 5.5") {
            $0.prompt = "Set up the users table"
            $0.set(.done)
        }
        if let moment { rehearse(moment, removeAfter: nil) }
    }

    @ObservationIgnored private var rehearsalGeneration = 0

    // MARK: helpers

    private func attention(_ row: Row, _ moment: Moment) {
        guard Preferences.shared.alert(for: row.agent) == .chime else {
            debugLog("suppressed \(row.id): agent is set to stay silent")
            return
        }
        guard !isWatching(row) else {
            debugLog("suppressed \(row.id): tab is focused")
            return
        }
        onAttention?(row, moment)
    }

    /// The terminal is frontmost and the row's zellij tab is the active one.
    private func isWatching(_ row: Row) -> Bool {
        guard let name = row.zellijSession, let tabID = row.zellijTabID,
              zellij[name]?.tabs.first(where: { $0.tabId == tabID })?.active == true
        else { return false }
        guard Preferences.shared.quietWhileWatching else { return false }
        let terminal = row.terminalBundleID ?? Preferences.shared.terminalBundleID
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal
    }

    /// Tabs whose agent row already says what the bell would.
    private func coveredTabs() -> Set<String> {
        Set(sessions.values.compactMap { session in
            guard session.activity <= .done, let name = session.zellijSession,
                  let tab = pane(of: session)?.tabId else { return nil }
            return bellKey(name, tab)
        })
    }

    private func pane(of session: AgentSession) -> ZPane? {
        guard let name = session.zellijSession, let id = session.zellijPaneID else { return nil }
        return zellij[name]?.panes.first { !$0.isPlugin && $0.id == id }
    }

    private func bellKey(_ session: String, _ tab: Int) -> String { "\(session):\(tab)" }

    private func location(session: String?, tab: String?) -> String? {
        guard let session else { return nil }
        return tab.map { "\(session) › \($0)" } ?? session
    }

    private func row(for session: AgentSession) -> Row {
        let pane = pane(of: session)
        let detail: String? = switch session.activity {
        case .needsYou, .error: session.ask
        case .working: session.doing ?? session.prompt
        case .done: session.prompt
        case .idle: nil
        }
        return Row(
            id: "agent:\(session.agent):\(session.id)",
            source: .agent,
            agent: session.agent,
            title: session.title ?? projectName(session.cwd) ?? session.agent,
            model: session.model,
            cwd: session.cwd.isEmpty ? nil : session.cwd,
            location: location(session: session.zellijSession, tab: pane?.tabName),
            detail: detail,
            prompt: session.activity == .needsYou ? session.promptDetail : nil,
            canDecide: session.decisionToken != nil,
            canAlwaysAllow: session.decisionToken != nil && session.permissionSuggestions != nil,
            activity: session.activity,
            since: session.since,
            zellijSession: session.zellijSession,
            zellijTabID: pane?.tabId,
            zellijPaneID: session.zellijPaneID,
            terminalBundleID: session.terminalBundleID
        )
    }

    private func row(for bell: BellTab) -> Row {
        let state = zellij[bell.session]
        let panes = state?.panes.filter { !$0.isPlugin && $0.tabId == bell.tabID } ?? []
        let pane = panes.first(where: \.isFocused) ?? panes.first
        let tabName = state?.tabs.first { $0.tabId == bell.tabID }?.name ?? "Tab \(bell.tabID)"
        return Row(
            id: "bell:\(bell.session):\(bell.tabID)",
            source: .bell,
            agent: nil,
            title: pane.flatMap { cleanPaneTitle($0.title) } ?? tabName,
            model: nil,
            cwd: nil,
            location: location(session: bell.session, tab: tabName),
            detail: nil,
            prompt: nil,
            canDecide: false,
            canAlwaysAllow: false,
            activity: .needsYou,
            since: bell.since,
            zellijSession: bell.session,
            zellijTabID: bell.tabID,
            zellijPaneID: nil,
            terminalBundleID: nil
        )
    }
}

/// Last path component, or nil for the home directory (which says nothing about the project).
private func projectName(_ cwd: String) -> String? {
    guard !cwd.isEmpty, cwd != NSHomeDirectory() else { return nil }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

/// omp titles its pane "π > <session>" while working and "π ! <session>" when it wants you.
private func cleanPaneTitle(_ title: String) -> String? {
    var text = title.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("π") {
        text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        if let first = text.first, first == ">" || first == "!" {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
    }
    return text.isEmpty ? nil : text
}

private func oneLine(_ text: String?, limit: Int = 140) -> String? {
    guard let line = text?.split(whereSeparator: \.isNewline).first?
        .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}

private func commandText(_ input: [String: Any]) -> String? {
    // Codex sends shell commands as argv arrays.
    if let argv = input["command"] as? [String] { return argv.joined(separator: " ") }
    return ["command", "file_path", "path", "url", "pattern", "description", "prompt"]
        .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
}

private func toolSummary(_ payload: [String: Any]) -> String {
    let tool = payload["tool_name"] as? String ?? "Tool"
    let input = payload["tool_input"] as? [String: Any] ?? [:]
    switch tool {
    case "ExitPlanMode":
        return "Plan ready for review"
    case "AskUserQuestion":
        let questions = input["questions"] as? [[String: Any]] ?? []
        let first = oneLine(questions.first?["question"] as? String) ?? "Question"
        return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
    default:
        return oneLine(commandText(input)).map { "\(tool): \($0)" } ?? tool
    }
}

private func promptDetail(_ payload: [String: Any]) -> PromptDetail? {
    let tool = payload["tool_name"] as? String ?? "Tool"
    let input = payload["tool_input"] as? [String: Any] ?? [:]
    switch tool {
    case "ExitPlanMode":
        return .plan
    case "AskUserQuestion":
        let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> Question? in
            guard let text = item["question"] as? String else { return nil }
            let options = (item["options"] as? [Any] ?? []).compactMap { option in
                (option as? [String: Any])?["label"] as? String ?? option as? String
            }
            return Question(header: item["header"] as? String, text: text, options: options,
                            multiSelect: item["multiSelect"] as? Bool ?? item["multi"] as? Bool ?? false,
                            recommended: item["recommended"] as? Int)
        }
        return questions.isEmpty ? nil : .questions(questions)
    default:
        return .approval(tool: tool, command: commandText(input))
    }
}
