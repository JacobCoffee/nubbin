import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: moment

struct MomentPane: View {
    let moment: Moment
    let rehearse: () -> Void

    var body: some View {
        @Bindable var prefs = Preferences.shared
        let style = prefs.style(moment)
        Form {
            Section {
                LabeledContent("Sound") { SoundMenu(moment: moment) }
                if style.sound != .none {
                    WaveformEditor(moment: moment)
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
                    LabeledContent("Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: prefs.binding(moment, \.volume), in: 0...1) { editing in
                                if !editing { SoundEngine.shared.audition(moment) }
                            }
                            .frame(width: 220)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                PaneHeader(title: moment.title, explanation: moment.explanation)
            }

            Section("Look") {
                LabeledContent("Color") { ColorSwatches(selection: prefs.binding(moment, \.color)) }
                Toggle(isOn: prefs.binding(moment, \.rings)) {
                    Text("Ring the notch")
                    Text("A ring of light spreads across the menu bar in time with the sound. Visible even when muted.")
                }
            }

            Section("Behavior") {
                Toggle(isOn: prefs.binding(moment, \.opensIsland)) {
                    Text("Open the island")
                    Text("Shows what happened, then folds after \(foldDescription).")
                }
                switch moment {
                case .needsYou:
                    Picker(selection: $prefs.reminderAfter) {
                        Text("Never").tag(0.0)
                        Text("After 30 seconds").tag(30.0)
                        Text("After 1 minute").tag(60.0)
                        Text("After 2 minutes").tag(120.0)
                        Text("After 5 minutes").tag(300.0)
                    } label: {
                        Text("Remind me again")
                        Text("If it's still waiting, ring once more.")
                    }
                case .done:
                    Picker(selection: $prefs.doneAfter) {
                        Text("Every task").tag(0.0)
                        Text("Longer than 10 seconds").tag(10.0)
                        Text("Longer than 20 seconds").tag(20.0)
                        Text("Longer than 1 minute").tag(60.0)
                        Text("Longer than 5 minutes").tag(300.0)
                    } label: {
                        Text("Announce")
                        Text("Short tasks finish while you're still looking.")
                    }
                case .error:
                    EmptyView()
                }
            }

            Section {
                HStack {
                    Button("Restore \(moment.title) Defaults") { prefs.reset(moment) }
                        .disabled(style == .defaults(moment))
                    Spacer()
                    Button("Rehearse", systemImage: "play.fill", action: rehearse)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var foldDescription: String {
        let seconds = Preferences.shared.autoFoldAfter
        if seconds == 0 { return "you move away" }
        return seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute"
    }
}

struct PaneHeader: View {
    let title: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary)
            Text(explanation).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }
}

/// System sounds, your own sounds, and a way to add more.
private struct SoundMenu: View {
    let moment: Moment

    var body: some View {
        let prefs = Preferences.shared
        HStack(spacing: 8) {
            Picker("Sound", selection: Binding(
                get: { prefs.style(moment).sound },
                set: { choose($0) }
            )) {
                Text("None").tag(SoundChoice.none)
                Divider()
                ForEach(SoundLibrary.systemSounds, id: \.self) { name in
                    Text(name).tag(SoundChoice.system(name))
                }
                let custom = SoundLibrary.customSounds()
                if !custom.isEmpty {
                    Divider()
                    ForEach(custom, id: \.self) { file in
                        Text(SoundChoice.custom(file).label).tag(SoundChoice.custom(file))
                    }
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button("Add Sound…", action: addSound)
        }
    }

    private func choose(_ sound: SoundChoice) {
        Preferences.shared.update(moment) {
            $0.sound = sound
            $0.trimStart = 0
            $0.trimEnd = 1
        }
        SoundEngine.shared.audition(moment)
    }

    private func addSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a sound for “\(moment.title)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAndUse(url, for: moment)
    }
}

@MainActor
private func importAndUse(_ url: URL, for moment: Moment) {
    do {
        let file = try SoundLibrary.importSound(from: url)
        Preferences.shared.update(moment) {
            $0.sound = .custom(file)
            $0.trimStart = 0
            $0.trimEnd = 1
        }
        SoundEngine.shared.audition(moment)
    } catch {
        NSSound.beep()
    }
}

// MARK: waveform

/// The chime as a waveform: drag the handles to trim, click anywhere to hear it from there,
/// drop an audio file on it to use that instead.
private struct WaveformEditor: View {
    static let height: CGFloat = 64
    static let minimumSpan = 0.04

    let moment: Moment
    @State private var dropTargeted = false

    var body: some View {
        let prefs = Preferences.shared
        let engine = SoundEngine.shared
        let style = prefs.style(moment)
        let analysis = SoundLibrary.url(style.sound).flatMap(SoundAnalysis.of)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        let peaks = analysis?.peaks ?? []
                        guard !peaks.isEmpty else { return }
                        let step = size.width / CGFloat(peaks.count)
                        let barWidth = max(1, step * 0.62)
                        for (index, peak) in peaks.enumerated() {
                            let fraction = (Double(index) + 0.5) / Double(peaks.count)
                            let inside = fraction >= style.trimStart && fraction <= style.trimEnd
                            let height = max(2, CGFloat(peak) * (size.height - 6))
                            let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2,
                                              y: (size.height - height) / 2, width: barWidth, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                         with: .color(inside ? style.color.color : Color.secondary.opacity(0.28)))
                        }
                    }
                    if engine.auditioning == moment, let playhead = engine.playhead {
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 1.5)
                            .offset(x: width * playhead)
                            .allowsHitTesting(false)
                    }
                    TrimHandle(value: prefs.binding(moment, \.trimStart), width: width,
                               range: 0...(style.trimEnd - Self.minimumSpan), label: "Start",
                               onCommit: { engine.audition(moment) })
                    TrimHandle(value: prefs.binding(moment, \.trimEnd), width: width,
                               range: (style.trimStart + Self.minimumSpan)...1, label: "End",
                               onCommit: { engine.audition(moment) })
                }
                .contentShape(Rectangle())
                .coordinateSpace(name: "waveform")
                .onTapGesture(coordinateSpace: .local) { point in
                    engine.audition(moment, from: point.x / max(width, 1))
                }
            }
            .frame(height: Self.height)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style.color.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .overlay(Text("Drop to use this sound").font(.callout.weight(.medium)))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.85)))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in importAndUse(url, for: moment) }
                }
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Waveform of \(style.sound.label)")

            HStack(spacing: 10) {
                Button {
                    engine.auditioning == moment ? engine.stop() : engine.audition(moment)
                } label: {
                    Label(engine.auditioning == moment ? "Stop" : "Play",
                          systemImage: engine.auditioning == moment ? "stop.fill" : "play.fill")
                }
                Button {
                    engine.musicPlaying ? engine.stop() : engine.auditionOverMusic(moment)
                } label: {
                    Label(engine.musicPlaying ? "Stop" : "Hear over music", systemImage: "music.note")
                }
                .help("Plays a soft music bed with the chime landing on top, to judge the volume the way you'll hear it")
                Spacer()
                if let analysis {
                    Text(trimDescription(analysis.duration, style))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
    }

    private func trimDescription(_ duration: TimeInterval, _ style: MomentStyle) -> String {
        let played = duration * (style.trimEnd - style.trimStart)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        if style.trimStart == 0 && style.trimEnd == 1 { return "\(duration.formatted(format)) s" }
        return "\(played.formatted(format)) s of \(duration.formatted(format)) s"
    }
}

private struct TrimHandle: View {
    @Binding var value: Double
    let width: CGFloat
    let range: ClosedRange<Double>
    let label: String
    let onCommit: () -> Void

    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.primary)
            .frame(width: hovering ? 5 : 3, height: WaveformEditor.height - 8)
            .frame(width: 16, height: WaveformEditor.height)
            .contentShape(Rectangle())
            .offset(x: width * value - 8)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform"))
                    .onChanged { drag in
                        value = min(max(Double(drag.location.x / max(width, 1)), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in onCommit() }
            )
            .accessibilityElement()
            .accessibilityLabel("Trim \(label.lowercased())")
            .accessibilityValue("\(Int(value * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.02 : -0.02
                value = min(max(value + step, range.lowerBound), range.upperBound)
            }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

// MARK: color

private struct ColorSwatches: View {
    @Binding var selection: RGBA

    private static let swatches: [RGBA] = [
        .amber,
        RGBA(r: 1.0, g: 0.84, b: 0.30),
        RGBA(r: 1.0, g: 0.56, b: 0.42),
        .red,
        RGBA(r: 1.0, g: 0.45, b: 0.70),
        RGBA(r: 0.72, g: 0.56, b: 1.0),
        RGBA(r: 0.42, g: 0.66, b: 1.0),
        RGBA(r: 0.36, g: 0.86, b: 0.92),
        .green,
        RGBA(r: 0.92, g: 0.92, b: 0.92),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Self.swatches, id: \.self) { swatch in
                Button { selection = swatch } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selection == swatch ? Color.primary : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color swatch")
                .accessibilityAddTraits(selection == swatch ? .isSelected : [])
            }
            ColorPicker("Custom color", selection: Binding(get: { selection.color }, set: { selection = RGBA($0) }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// MARK: while watching

struct WatchingPane: View {
    var body: some View {
        @Bindable var prefs = Preferences.shared
        Form {
            Section {
                Toggle(isOn: $prefs.quietWhileWatching) {
                    Text("Stay quiet while you're looking")
                    Text("No chime or ring when the agent's zellij tab is the active tab in your frontmost terminal.")
                }
                Toggle(isOn: $prefs.hoverToOpen) {
                    Text("Open when the pointer reaches the notch")
                    Text("Otherwise click the island to open it.")
                }
                Picker("Fold an island that opened itself", selection: $prefs.autoFoldAfter) {
                    Text("After 5 seconds").tag(5.0)
                    Text("After 10 seconds").tag(10.0)
                    Text("After 20 seconds").tag(20.0)
                    Text("After 1 minute").tag(60.0)
                    Text("When I move away").tag(0.0)
                }
                Picker("Keep finished sessions", selection: $prefs.doneLingers) {
                    Text("For 1 minute").tag(60.0)
                    Text("For 10 minutes").tag(600.0)
                    Text("For 1 hour").tag(3600.0)
                    Text("Until cleared").tag(TimeInterval(60 * 60 * 24 * 365))
                }
            } header: {
                PaneHeader(title: "While watching", explanation: "How the island behaves around you.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: general

struct GeneralPane: View {
    @State private var loginStatus = SMAppService.mainApp.status

    private static let terminals: [(name: String, id: String)] = [
        ("Alacritty", "org.alacritty"), ("Ghostty", "com.mitchellh.ghostty"), ("iTerm2", "com.googlecode.iterm2"),
        ("Terminal", "com.apple.Terminal"), ("WezTerm", "com.github.wez.wezterm"), ("kitty", "net.kovidgoyal.kitty"),
        ("Warp", "dev.warp.Warp-Stable"), ("Rio", "com.raphaelamorim.rio"),
    ]

    var body: some View {
        @Bindable var prefs = Preferences.shared
        let installed = Self.terminals.compactMap { terminal -> (name: String, id: String, icon: NSImage)? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.id) else { return nil }
            return (terminal.name, terminal.id, NSWorkspace.shared.icon(forFile: url.path))
        }
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                     set: setLaunchAtLogin)) {
                    Text("Open at login")
                    if loginStatus == .requiresApproval {
                        Text("Waiting for your approval in System Settings › General › Login Items.")
                    }
                }
                if loginStatus == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Picker(selection: $prefs.terminalBundleID) {
                    ForEach(installed, id: \.id) { terminal in
                        Label {
                            Text(terminal.name)
                        } icon: {
                            Image(nsImage: terminal.icon)
                        }
                        .tag(terminal.id)
                    }
                } label: {
                    Text("Terminal")
                    Text("Brought forward when you click a session that didn't say where it runs.")
                }
                Toggle("Mute all chimes", isOn: $prefs.muted)
            } header: {
                PaneHeader(title: "General", explanation: "Nubbin itself.")
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nubbin").font(.system(size: 15, weight: .semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: agents

struct ConnectionsPane: View {
    var body: some View {
        let connections = Connections.shared
        Form {
            Section {
                ForEach(Integration.allCases) { integration in
                    ConnectionRow(integration: integration, state: connections.states[integration] ?? .notInstalled,
                                  busy: connections.busy.contains(integration)) { connect in
                        connections.set(integration, connected: connect)
                    }
                }
            } header: {
                PaneHeader(title: "Agents",
                           explanation: "Nubbin listens through each agent's hooks. Settings files are backed up before every change.")
            } footer: {
                if let error = connections.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { connections.refresh() }
    }
}

private struct ConnectionRow: View {
    let integration: Integration
    let state: ConnectionState
    let busy: Bool
    let setConnected: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(state == .connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(integration.name).font(.system(size: 13, weight: .semibold))
                    Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(integration.reports).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if state == .connected, let next = integration.afterConnecting {
                    Text(next).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if state != .notInstalled {
                Button(state == .connected ? "Disconnect" : "Connect") { setConnected(state != .connected) }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch state {
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .notInstalled: "Not on this Mac"
        }
    }
}
