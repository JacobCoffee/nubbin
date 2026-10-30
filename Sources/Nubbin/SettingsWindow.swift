import AppKit
import SwiftUI

/// Opens one Settings window and brings it forward on later requests.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let rehearseOnNotch: (Moment, [Float]) -> Void

    init(rehearseOnNotch: @escaping (Moment, [Float]) -> Void) {
        self.rehearseOnNotch = rehearseOnNotch
    }

    func show(_ pane: SettingsPane? = nil) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Nubbin Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 780, height: 640)
            window.maxSize = NSSize(width: 780, height: 2000)
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsRoot(initialPane: pane ?? .remembered,
                                                                      rehearseOnNotch: rehearseOnNotch))
            window.center()
            window.setFrameAutosaveName("NubbinSettings")
            self.window = window
        }
        Connections.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        SoundEngine.shared.stop()
        // Rebuilt on next open so the stage starts fresh and nothing keeps animating offscreen.
        window = nil
    }
}

enum SettingsPane: Hashable {
    case moment(Moment), watching, quiet, general, connections

    private static let defaultsKey = "lastSettingsPane"

    /// The pane you last had open, so Settings reopens where you left it.
    static var remembered: SettingsPane {
        let key = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if let moment = Moment(rawValue: key) { return .moment(moment) }
        switch key {
        case "watching": return .watching
        case "quiet": return .quiet
        case "general": return .general
        case "connections": return .connections
        default: return .moment(.needsYou)
        }
    }

    func remember() {
        let key = switch self {
        case .moment(let moment): moment.rawValue
        case .watching: "watching"
        case .quiet: "quiet"
        case .general: "general"
        case .connections: "connections"
        }
        UserDefaults.standard.set(key, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .moment(let moment): moment.title
        case .watching: "While watching"
        case .quiet: "Quiet"
        case .general: "General"
        case .connections: "Agents"
        }
    }
}

/// The Settings stage's own island: a separate store and UI state rendering the real NotchView.
@MainActor
@Observable
final class StageModel {
    let store = Store()
    let ui = NotchUI()

    init() {
        ui.geometry.hasNotch = true
        store.seedStage(highlight: nil)
        refresh()
    }

    func show(_ moment: Moment?) {
        store.seedStage(highlight: moment)
        refresh()
        ui.expanded = moment != nil
    }

    /// Play the moment exactly as it will happen: chime, ring, then the island opens if it should.
    func rehearse(_ moment: Moment) -> [Float] {
        store.rehearse(moment, removeAfter: nil)
        refresh()
        ui.expanded = false
        let envelope = SoundEngine.shared.play(moment, ignoringMute: true)
        if Preferences.shared.style(moment).rings { ui.ring = RingPulse(moment: moment, envelope: envelope) }
        if Preferences.shared.style(moment).opensIsland {
            Task {
                try? await Task.sleep(for: .seconds(0.3))
                ui.expanded = true
            }
        }
        return envelope
    }

    var actions: NotchActions {
        NotchActions(toggle: { [weak self] in self?.ui.expanded.toggle() },
                     select: { _ in }, dismiss: { _ in }, decide: { _, _ in },
                     toggleMute: { Preferences.shared.toggleMute() },
                     openSettings: {})
    }

    private func refresh() {
        ui.constellation = store.rows.filter { $0.activity != .idle }
    }
}

struct SettingsRoot: View {
    @State private var pane: SettingsPane
    @State private var stage = StageModel()
    let rehearseOnNotch: (Moment, [Float]) -> Void

    init(initialPane: SettingsPane, rehearseOnNotch: @escaping (Moment, [Float]) -> Void) {
        _pane = State(initialValue: initialPane)
        self.rehearseOnNotch = rehearseOnNotch
    }

    var body: some View {
        VStack(spacing: 0) {
            Stage(model: stage, pane: pane, rehearse: rehearse)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            PaneStrip(selection: $pane)
                .padding(.vertical, 10)
            Divider()
            Group {
                switch pane {
                case .moment(let moment): MomentPane(moment: moment, rehearse: { rehearse(moment) })
                case .watching: WatchingPane()
                case .quiet: QuietPane()
                case .general: GeneralPane()
                case .connections: ConnectionsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 640)
        .onAppear { showStage(for: pane) }
        .onChange(of: pane) { _, new in
            new.remember()
            showStage(for: new)
        }
    }

    private func showStage(for pane: SettingsPane) {
        SoundEngine.shared.stop()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            if case .moment(let moment) = pane { stage.show(moment) } else { stage.show(nil) }
        }
    }

    private func rehearse(_ moment: Moment) {
        let envelope = stage.rehearse(moment)
        if Preferences.shared.rehearseOnNotch { rehearseOnNotch(moment, envelope) }
    }
}

// MARK: stage

/// A true-scale slice of your screen: your wallpaper, a menu bar, and the island in your notch.
private struct Stage: View {
    static let height: CGFloat = 340

    let model: StageModel
    let pane: SettingsPane
    let rehearse: (Moment) -> Void

    @State private var wallpaper: NSImage?

    var body: some View {
        let g = model.ui.geometry
        ZStack(alignment: .top) {
            MenuBarMock(height: g.notchHeight, notchWidth: g.notchWidth)
            NotchView(store: model.store, ui: model.ui, actions: model.actions)
        }
        .frame(maxWidth: .infinity)
        // Top-aligned: a long list runs off the bottom of the stage instead of pushing the menu bar up.
        .frame(height: Self.height, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            if case .moment(let moment) = pane {
                RehearseBar(moment: moment) { rehearse(moment) }
                    .padding(14)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        // A background never sizes its owner: the full-screen wallpaper is centred at true scale and clipped.
        .background(alignment: .top) {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: g.screenFrame.width, height: g.screenFrame.height)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of the island in your menu bar")
        .task { wallpaper = await Self.loadWallpaper() }
    }

    private static func loadWallpaper() async -> NSImage? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return await Task.detached { NSImage(contentsOf: url) }.value
    }
}

private struct MenuBarMock: View {
    let height: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text(terminalName).fontWeight(.bold)
                Text("Shell")
                Text("Edit")
                Text("View")
            }
            .padding(.leading, 18)
            Spacer(minLength: notchWidth + 24)
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()
                        .hour().minute()))
                }
            }
            .padding(.trailing, 16)
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        .lineLimit(1)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.16))
        .accessibilityHidden(true)
    }

    private var terminalName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Preferences.shared.terminalBundleID)
        else { return "Terminal" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct RehearseBar: View {
    let moment: Moment
    let action: () -> Void

    var body: some View {
        @Bindable var prefs = Preferences.shared
        HStack(spacing: 12) {
            Toggle("On my notch too", isOn: $prefs.rehearseOnNotch)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.9))
            Button(action: action) {
                Label("Rehearse \(moment.title.lowercased())", systemImage: "play.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Preferences.shared.style(moment).color.color)
            .foregroundStyle(.black)
            .keyboardShortcut("r")
            .help("Plays the chime, rings the notch and opens the island, exactly as it will happen (⌘R)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.55)))
        .background(Capsule().fill(.ultraThinMaterial))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: pane strip

private struct PaneStrip: View {
    @Binding var selection: SettingsPane
    @Namespace private var indicator

    private let panes: [SettingsPane] = [.moment(.needsYou), .moment(.done), .moment(.error),
                                         .watching, .quiet, .general, .connections]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(panes, id: \.self) { pane in
                if pane == .watching {
                    Divider().frame(height: 18).padding(.horizontal, 6)
                }
                Button { selection = pane } label: { tab(pane) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection)
    }

    private func tab(_ pane: SettingsPane) -> some View {
        let selected = selection == pane
        return HStack(spacing: 7) {
            switch pane {
            case .moment(let moment):
                Circle()
                    .fill(Preferences.shared.style(moment).color.color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15)))
            case .watching: Image(systemName: "eye")
            case .quiet: Image(systemName: "moon")
            case .general: Image(systemName: "gearshape")
            case .connections: Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            Text(pane.title)
        }
        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background {
            if selected {
                Capsule().fill(.quaternary).matchedGeometryEffect(id: "selection", in: indicator)
            }
        }
        .contentShape(Capsule())
    }
}
