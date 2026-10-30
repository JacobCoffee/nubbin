import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private var notch: NotchController?
    private var server: EventServer?
    private var zellij: ZellijCLI?
    private var poller: ZellijPoller?
    private var hotkeys: Hotkeys?
    private var statusItem: NSStatusItem?
    private var statusSymbol = ""
    private lazy var settings = SettingsWindowController { [weak self] moment, envelope in
        guard let self else { return }
        self.store.rehearse(moment)
        self.notch?.ring(moment, envelope: envelope, allowOpen: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` binary isn't listed under its embedded bundle ID, so compare PIDs, not counts.
        let pid = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != pid }) {
            NSApp.terminate(nil) // a second copy would steal the socket
            return
        }

        notch = NotchController(
            store: store,
            onSelect: { [weak self] row in self?.open(row) },
            onToggleMute: { [weak self] in self?.toggleMute() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        store.onAttention = { [weak self] row, moment in
            debugLog("attention \(row.id) \(moment)")
            let envelope = SoundEngine.shared.play(moment)
            self?.notch?.ring(moment, envelope: envelope)
            Notifier.shared.attention(row, moment)
        }
        Notifier.shared.onOpen = { [weak self] id in
            guard let self, let row = self.store.rows.first(where: { $0.id == id }) else { return }
            self.open(row)
        }
        hotkeys = Hotkeys { [weak self] action in
            debugLog("hotkey \(action)")
            switch action {
            case .island: self?.notch?.toggle()
            case .jump: self?.jumpToNext()
            }
        }
        store.onZellijMappingNeeded = { [weak self] in self?.poller?.requestFullRefresh() }

        let server = EventServer { [weak self] data, token in
            Task { @MainActor in self?.handleIncoming(data, token: token) }
        }
        store.onReply = { [server] token, data in server.reply(token, data) }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Nubbin: cannot listen on \(Paths.socket.path): \(error)")
        }

        Task { [weak self] in
            guard let cli = await Task.detached(operation: { ZellijCLI.locate() }).value else {
                debugLog("zellij not found; bell tracking off")
                return
            }
            debugLog("zellij at \(cli.binary)")
            guard let self else { return }
            self.zellij = cli
            let poller = ZellijPoller(cli: cli, store: self.store)
            self.poller = poller
            poller.start()
        }

        Task { [weak self] in
            while let self {
                self.store.remindOverdue()
                self.notch?.refresh()
                self.refreshStatusItem() // a timed mute or quiet hours can end without any change to observe
                try? await Task.sleep(for: .seconds(5))
            }
        }

        setUpStatusItem()
    }

    /// Opening Nubbin again (Finder, Spotlight, `open -a`) shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    /// A row clicked in the island, the menu bar, or a notification.
    private func open(_ row: Row) {
        focus(row)
        let finished = row.source == .bell || row.activity == .done || row.activity == .error
        if Preferences.shared.clearOnOpen, finished { store.dismiss(row) }
    }

    /// The jump hotkey and menu item: straight to the most urgent session that needs you or failed.
    @objc private func jumpToNext() {
        guard let row = store.rows.first(where: { $0.activity == .needsYou || $0.activity == .error }) else {
            NSSound.beep()
            return
        }
        open(row)
    }

    // MARK: control API

    /// Routes one socket message: a `"type"` key means a control request (list rows, focus a row);
    /// anything else is an agent hook event. Hook envelopes never carry a top-level `"type"` key,
    /// so this split is unambiguous. See README for the request/reply shapes.
    private func handleIncoming(_ data: Data, token: EventServer.Token?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else {
            store.handleHook(data, token: token)
            return
        }
        let reply: Data
        switch type {
        case "list":
            reply = Control.listReply(store.rows)
        case "focus":
            if let id = object["id"] as? String, let row = store.rows.first(where: { $0.id == id }) {
                open(row)
                reply = Control.okReply()
            } else {
                reply = Control.errorReply("unknown row")
            }
        default:
            reply = Control.errorReply("unknown type: \(type)")
        }
        if let token { server?.reply(token, reply) }
    }
    // MARK: focus

    /// Bring the session's terminal forward, then switch zellij to its tab and pane.
    private func focus(_ row: Row) {
        let bundleID = row.terminalBundleID ?? Preferences.shared.terminalBundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // LaunchServices activation still works for a background app under macOS 14's cooperative activation.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }

        guard let zellij, let session = row.zellijSession else { return }
        let tab = row.zellijTabID
        let pane = row.zellijPaneID
        let poller = poller
        Task {
            await Task.detached {
                // focus-pane-id does not switch tabs on its own.
                if let tab { zellij.run(["--session", session, "action", "go-to-tab-by-id", String(tab)]) }
                if let pane { zellij.run(["--session", session, "action", "focus-pane-id", "terminal_\(pane)"]) }
            }.value
            poller?.requestFullRefresh()
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        statusItem = item
        refreshStatusItem()
        observeStatusItem()
    }

    /// Rebuilt each time it opens, so it always lists the sessions as they are now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = store.rows
        let prefs = Preferences.shared

        let header = NSMenuItem(title: rows.isEmpty ? "No sessions" : summary(rows), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for row in rows.prefix(12) {
            let item = NSMenuItem(title: row.title, action: #selector(openRow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.attributedTitle = rowTitle(row)
            if #available(macOS 14.4, *) { item.subtitle = [row.detail, row.location].compactMap { $0 }.first }
            item.toolTip = [row.detail, row.location].compactMap { $0 }.joined(separator: "\n")
            menu.addItem(item)
            let dismiss = NSMenuItem(title: "Dismiss \(row.title)", action: #selector(dismissRow(_:)), keyEquivalent: "")
            dismiss.target = self
            dismiss.representedObject = row.id
            dismiss.isAlternate = true
            dismiss.keyEquivalentModifierMask = .option
            menu.addItem(dismiss)
        }
        if rows.count > 12 {
            let more = NSMenuItem(title: "\(rows.count - 12) more in the island", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }

        menu.addItem(.separator())
        menu.addItem(item("Show Island", #selector(toggleIsland), hotkey: prefs.islandHotkey))
        let jump = item("Jump to Session That Needs You", #selector(jumpToNext), hotkey: prefs.jumpHotkey)
        jump.isEnabled = rows.contains { $0.activity == .needsYou || $0.activity == .error }
        menu.addItem(jump)
        menu.addItem(item("Clear Finished Sessions", #selector(clearFinished)))

        menu.addItem(.separator())
        let mute = item(prefs.isMuted ? "Unmute Chimes" : "Mute Chimes", #selector(toggleMute))
        menu.addItem(mute)
        if let until = prefs.mutedUntil, until > Date(), !prefs.muted {
            let note = NSMenuItem(title: "Muted until \(until.formatted(date: .omitted, time: .shortened))",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else if !prefs.isMuted, let reason = Quiet.reason() {
            let note = NSMenuItem(title: "Chimes off: \(reason)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        if !prefs.isMuted {
            let snooze = NSMenuItem(title: "Mute For", action: nil, keyEquivalent: "")
            let options = NSMenu()
            for (title, seconds) in [("15 Minutes", 15.0 * 60), ("1 Hour", 3600), ("3 Hours", 3 * 3600)] {
                let option = item(title, #selector(muteFor(_:)))
                option.representedObject = seconds
                options.addItem(option)
            }
            let morning = item("Until Tomorrow Morning", #selector(muteFor(_:)))
            morning.representedObject = untilTomorrowMorning()
            options.addItem(morning)
            snooze.submenu = options
            menu.addItem(snooze)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Nubbin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", hotkey: Hotkey? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        // Shown as a reminder of the global shortcut; only single characters can be key equivalents.
        if let hotkey, hotkey.key.count == 1 {
            item.keyEquivalent = hotkey.key.lowercased()
            item.keyEquivalentModifierMask = hotkey.flags
        }
        return item
    }

    private func rowTitle(_ row: Row) -> NSAttributedString {
        let title = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor(Preferences.shared.color(row.activity)),
            .font: NSFont.menuFont(ofSize: 0),
        ])
        title.append(NSAttributedString(string: row.title, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }

    private func summary(_ rows: [Row]) -> String {
        let counts = Dictionary(grouping: rows, by: \.activity).mapValues(\.count)
        var parts: [String] = []
        if let n = counts[.needsYou] { parts.append(n == 1 ? "1 needs you" : "\(n) need you") }
        if let n = counts[.error] { parts.append("\(n) failed") }
        if let n = counts[.working] { parts.append("\(n) working") }
        if let n = counts[.done] { parts.append("\(n) done") }
        if let n = counts[.idle] { parts.append("\(n) idle") }
        return parts.joined(separator: " · ")
    }

    /// 8 AM tomorrow, as seconds from now.
    private func untilTomorrowMorning() -> TimeInterval {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)!
        return morning.timeIntervalSinceNow
    }

    @objc private func openRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = store.rows.first(where: { $0.id == id }) else { return }
        open(row)
    }

    @objc private func dismissRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = store.rows.first(where: { $0.id == id }) else { return }
        store.dismiss(row)
    }

    @objc private func toggleIsland() { notch?.toggle() }

    @objc private func openSettings() { settings.show() }

    /// Shared by the menu bar item, the island's bell button, and Settings.
    @objc private func toggleMute() { Preferences.shared.toggleMute() }

    @objc private func muteFor(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        Preferences.shared.mute(for: seconds)
    }

    @objc private func clearFinished() { store.clearFinished() }

    /// Keep the menu bar item in step with sessions, mute, and its show/hide setting.
    private func observeStatusItem() {
        withObservationTracking {
            _ = store.rows
            _ = Preferences.shared.muted
            _ = Preferences.shared.mutedUntil
            _ = Preferences.shared.showMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStatusItem()
                self?.observeStatusItem()
            }
        }
    }

    /// The bell shows a count of sessions that need you, and a slash while chimes are off.
    private func refreshStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let prefs = Preferences.shared
        item.isVisible = prefs.showMenuBarIcon
        let waiting = store.rows.filter { $0.activity == .needsYou || $0.activity == .error }.count
        let quiet = Quiet.reason()
        let symbol = quiet != nil ? "bell.slash" : waiting > 0 ? "bell.badge" : "bell"
        if symbol != statusSymbol {
            statusSymbol = symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nubbin")
        }
        let title = waiting > 0 ? "\(waiting)" : ""
        if button.title != title { button.title = title }
        button.toolTip = ["Nubbin", waiting > 0 ? "\(waiting) waiting" : nil, quiet.map { "Chimes off: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
