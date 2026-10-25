import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var notch: NotchController?
    private var server: EventServer?
    private var zellij: ZellijCLI?
    private var poller: ZellijPoller?
    private var statusItem: NSStatusItem?
    private var muteItem: NSMenuItem?
    private lazy var settings = SettingsWindowController { [weak self] moment, envelope in
        guard let self else { return }
        self.store.rehearse(moment)
        self.notch?.ring(moment, envelope: envelope, allowOpen: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil) // a second copy would steal the socket
            return
        }

        notch = NotchController(
            store: store,
            onSelect: { [weak self] row in self?.focus(row) },
            onToggleMute: { [weak self] in self?.toggleMute() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        store.onAttention = { [weak self] row, moment in
            debugLog("attention \(row.id) \(moment)")
            let envelope = SoundEngine.shared.play(moment)
            self?.notch?.ring(moment, envelope: envelope)
        }
        observeMute()
        store.onZellijMappingNeeded = { [weak self] in self?.poller?.requestFullRefresh() }

        let server = EventServer { [weak self] data, token in
            Task { @MainActor in self?.store.handleHook(data, token: token) }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let mute = NSMenuItem(title: "Mute Chimes", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)
        muteItem = mute
        let clear = NSMenuItem(title: "Clear Finished Sessions", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nubbin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        refreshMuteState()
    }

    @objc private func openSettings() { settings.show() }

    /// Shared by the menu bar item, the island's bell button, and Settings.
    @objc private func toggleMute() { Preferences.shared.muted.toggle() }

    /// Keep the menu bar icon in step with mute, wherever it was changed.
    private func observeMute() {
        withObservationTracking {
            _ = Preferences.shared.muted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshMuteState()
                self?.observeMute()
            }
        }
    }

    private func refreshMuteState() {
        let muted = Preferences.shared.muted
        muteItem?.state = muted ? .on : .off
        statusItem?.button?.image = NSImage(systemSymbolName: muted ? "bell.slash" : "bell",
                                            accessibilityDescription: "Nubbin")
    }

    @objc private func clearFinished() { store.clearFinished() }
}
