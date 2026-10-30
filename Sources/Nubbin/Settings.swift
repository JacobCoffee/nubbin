import AppKit
import Observation
import SwiftUI

enum Paths {
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Nubbin", directoryHint: .isDirectory)
    }

    static var socket: URL { supportDir.appending(path: "events.sock") }
    /// Sound files the user dropped into Settings, copied here so they survive the original moving.
    static var soundsDir: URL { supportDir.appending(path: "Sounds", directoryHint: .isDirectory) }
}

/// The three things the island announces. Each has its own sound, color and behavior.
enum Moment: String, CaseIterable, Codable, Identifiable {
    case needsYou, done, error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .done: "Finished"
        case .error: "Failed"
        }
    }

    var explanation: String {
        switch self {
        case .needsYou: "An agent asked a question, wants approval, or a zellij tab rang."
        case .done: "An agent finished a task you weren't watching."
        case .error: "A request failed: rate limits, auth, or a crashed turn."
        }
    }

    var activity: Activity {
        switch self {
        case .needsYou: .needsYou
        case .done: .done
        case .error: .error
        }
    }
}

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }

    static let amber = RGBA(r: 1.0, g: 0.71, b: 0.28)
    static let green = RGBA(r: 0.42, g: 0.88, b: 0.52)
    static let red = RGBA(r: 1.0, g: 0.42, b: 0.38)
}

enum SoundChoice: Codable, Hashable {
    case none
    /// A file in /System/Library/Sounds or ~/Library/Sounds, by name without extension.
    case system(String)
    /// A file the user added, stored under `Paths.soundsDir`.
    case custom(String)

    var label: String {
        switch self {
        case .none: "None"
        case .system(let name): name
        case .custom(let file): URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        }
    }
}

struct MomentStyle: Codable, Equatable {
    var sound: SoundChoice
    /// Fractions of the sound file to play.
    var trimStart: Double = 0
    var trimEnd: Double = 1
    var volume: Double = 0.8
    var color: RGBA
    var opensIsland = true
    var rings = true

    static func defaults(_ moment: Moment) -> MomentStyle {
        switch moment {
        case .needsYou: MomentStyle(sound: .system("Glass"), volume: 0.9, color: .amber)
        case .done: MomentStyle(sound: .system("Pop"), volume: 0.6, color: .green, opensIsland: false)
        case .error: MomentStyle(sound: .system("Basso"), volume: 0.7, color: .red)
        }
    }
}

/// What one agent (or zellij's tab bells) may do when it wants you.
enum AgentAlert: String, CaseIterable, Codable, Identifiable {
    /// Chime, ring, open the island, and notify when you're away.
    case chime
    /// Keep its row and dot, but never make a sound or open the island.
    case silent
    /// Ignore it entirely.
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chime: "Chime"
        case .silent: "Show only"
        case .hidden: "Hide"
        }
    }
}

/// Which screen the island lives on.
enum DisplayChoice: String, CaseIterable, Identifiable {
    /// The built-in notched display, else the main display.
    case notch
    /// The display with the menu bar in System Settings › Displays.
    case primary
    /// Follows the pointer from screen to screen.
    case pointer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notch: "Built-in display with the notch"
        case .primary: "Main display"
        case .pointer: "Display with the pointer"
        }
    }
}

/// A global keyboard shortcut. `key` is what the key printed when recorded, for display.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, device-independent bits only.
    var modifiers: UInt
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var label: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }
}

/// Everything in the Settings window. Read live by the island, so changes apply instantly.
/// Stored in `defaults read dev.jacobcoffee.nubbin`.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private static let stylesKey = "momentStyles"
    /// Keys that describe this Mac's window layout rather than how you want Nubbin to behave.
    private static let notExported: Set<String> = ["lastSettingsPane", "zellijPath"]

    private(set) var styles: [Moment: MomentStyle] = [:]

    // Needs you
    /// Ring again if still waiting after this long; 0 turns reminders off.
    var reminderAfter: TimeInterval = 60 { didSet { save("reminderAfter", reminderAfter) } }
    /// How many reminders to ring, each `reminderAfter` apart; 0 keeps ringing until it's handled.
    var reminderLimit = 1 { didSet { save("reminderLimit", reminderLimit) } }
    // Finished
    /// Tasks shorter than this finish silently: you were probably still watching.
    var doneAfter: TimeInterval = 20 { didSet { save("doneAfter", doneAfter) } }
    /// Finished sessions keep their dot this long.
    var doneLingers: TimeInterval = 600 { didSet { save("doneLingers", doneLingers) } }
    // While you're watching
    var quietWhileWatching = true { didSet { save("quietWhileWatching", quietWhileWatching) } }
    var hoverToOpen = true { didSet { save("hoverToOpen", hoverToOpen) } }
    /// An island opened by an event folds after this long; 0 keeps it open until you leave it.
    var autoFoldAfter: TimeInterval = 10 { didSet { save("autoFoldAfter", autoFoldAfter) } }
    /// Folded island shows dots only for sessions that need you or failed, not working or finished ones.
    var dotsOnlyForAttention = false { didSet { save("dotsOnlyForAttention", dotsOnlyForAttention) } }
    /// Clicking a finished or failed row (or a tab bell) also clears it.
    var clearOnOpen = false { didSet { save("clearOnOpen", clearOnOpen) } }
    var display = DisplayChoice.notch { didSet { save("display", display.rawValue) } }
    // Quiet
    var muted = false { didSet { save("muted", muted) } }
    /// Chimes stay off until then; set from the menu bar's Mute For.
    var mutedUntil: Date? { didSet { save("mutedUntil", mutedUntil) } }
    var quietDuringFocus = true { didSet { save("quietDuringFocus", quietDuringFocus) } }
    var quietDuringCalls = false { didSet { save("quietDuringCalls", quietDuringCalls) } }
    var quietWhileMirroring = true { didSet { save("quietWhileMirroring", quietWhileMirroring) } }
    var quietHours = false { didSet { save("quietHours", quietHours) } }
    /// Minutes after midnight; the range wraps past midnight when start > end.
    var quietStart = 22 * 60 { didSet { save("quietStart", quietStart) } }
    var quietEnd = 8 * 60 { didSet { save("quietEnd", quietEnd) } }
    // Away
    /// Post to Notification Center for anything that would chime while you're away.
    var notifyWhenAway = false { didSet { save("notifyWhenAway", notifyWhenAway) } }
    /// No keyboard or mouse for this long (or a locked screen) means you're away.
    var awayAfter: TimeInterval = 300 { didSet { save("awayAfter", awayAfter) } }
    /// Push to your phone through ntfy while away; empty topic turns it off.
    var ntfyTopic = "" { didSet { save("ntfyTopic", ntfyTopic) } }
    var ntfyServer = "https://ntfy.sh" { didSet { save("ntfyServer", ntfyServer) } }
    // Agents
    private(set) var agentAlerts: [String: AgentAlert] = [:]
    // General
    /// Hidden, Settings is still reachable from the island or by opening Nubbin again.
    var showMenuBarIcon = true { didSet { save("showMenuBarIcon", showMenuBarIcon) } }
    /// App to bring forward when a session didn't report its own terminal.
    var terminalBundleID = "org.alacritty" { didSet { save("terminalBundleID", terminalBundleID) } }
    var islandHotkey: Hotkey? { didSet { saveCodable("islandHotkey", islandHotkey) } }
    var jumpHotkey: Hotkey? { didSet { saveCodable("jumpHotkey", jumpHotkey) } }
    /// Rehearse plays on the real notch as well as the Settings stage.
    var rehearseOnNotch = true { didSet { save("rehearseOnNotch", rehearseOnNotch) } }

    var zellijPath: String? { UserDefaults.standard.string(forKey: "zellijPath") }

    @ObservationIgnored private var loading = false

    private init() { load() }

    /// Read everything from defaults; also how an import takes effect.
    func load() {
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard
        styles = d.data(forKey: Self.stylesKey)
            .flatMap { try? JSONDecoder().decode([Moment: MomentStyle].self, from: $0) } ?? [:]
        reminderAfter = d.object(forKey: "reminderAfter") as? Double ?? 60
        reminderLimit = d.object(forKey: "reminderLimit") as? Int ?? 1
        doneAfter = d.object(forKey: "doneAfter") as? Double ?? 20
        doneLingers = d.object(forKey: "doneLingers") as? Double ?? 600
        quietWhileWatching = d.object(forKey: "quietWhileWatching") as? Bool ?? true
        hoverToOpen = d.object(forKey: "hoverToOpen") as? Bool ?? true
        autoFoldAfter = d.object(forKey: "autoFoldAfter") as? Double ?? 10
        dotsOnlyForAttention = d.bool(forKey: "dotsOnlyForAttention")
        clearOnOpen = d.bool(forKey: "clearOnOpen")
        display = d.string(forKey: "display").flatMap(DisplayChoice.init) ?? .notch
        muted = d.bool(forKey: "muted")
        mutedUntil = d.object(forKey: "mutedUntil") as? Date
        quietDuringFocus = d.object(forKey: "quietDuringFocus") as? Bool ?? true
        quietDuringCalls = d.bool(forKey: "quietDuringCalls")
        quietWhileMirroring = d.object(forKey: "quietWhileMirroring") as? Bool ?? true
        quietHours = d.bool(forKey: "quietHours")
        quietStart = d.object(forKey: "quietStart") as? Int ?? 22 * 60
        quietEnd = d.object(forKey: "quietEnd") as? Int ?? 8 * 60
        notifyWhenAway = d.bool(forKey: "notifyWhenAway")
        awayAfter = d.object(forKey: "awayAfter") as? Double ?? 300
        ntfyTopic = d.string(forKey: "ntfyTopic") ?? ""
        ntfyServer = d.string(forKey: "ntfyServer") ?? "https://ntfy.sh"
        agentAlerts = (d.dictionary(forKey: "agentAlerts") as? [String: String] ?? [:])
            .compactMapValues(AgentAlert.init)
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? "org.alacritty"
        islandHotkey = d.data(forKey: "islandHotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
        jumpHotkey = d.data(forKey: "jumpHotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
        rehearseOnNotch = d.object(forKey: "rehearseOnNotch") as? Bool ?? true
    }

    // MARK: mute

    /// Muted outright or for a while. Time-based, so read it when you need it rather than observing it.
    var isMuted: Bool { muted || (mutedUntil.map { $0 > Date() } ?? false) }

    func mute(for duration: TimeInterval) {
        muted = false
        mutedUntil = Date().addingTimeInterval(duration)
    }

    /// The island's bell and the menu's Mute Chimes: unmute if muted in any way, else mute.
    func toggleMute() {
        if isMuted {
            muted = false
            mutedUntil = nil
        } else {
            muted = true
        }
    }

    // MARK: agents

    /// Agent ids as in hooks (`claude`, `codex`, `omp`, `pi`); `bell` for zellij tab bells.
    func alert(for agent: String?) -> AgentAlert { agentAlerts[agent ?? "bell"] ?? .chime }

    func setAlert(_ alert: AgentAlert, for agent: String) {
        agentAlerts[agent] = alert
        save("agentAlerts", agentAlerts.mapValues(\.rawValue))
    }

    // MARK: export

    /// Your settings as a property list, without this Mac's window positions.
    func exportData() throws -> Data {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        let settings = domain.filter { !Self.notExported.contains($0.key) && !$0.key.hasPrefix("NSWindow Frame") }
        return try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    }

    func importData(_ data: Data) throws {
        guard let settings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        for (key, value) in settings where !Self.notExported.contains(key) && !key.hasPrefix("NSWindow Frame") {
            UserDefaults.standard.set(value, forKey: key)
        }
        load()
    }

    // MARK: styles

    func style(_ moment: Moment) -> MomentStyle { styles[moment] ?? .defaults(moment) }

    func update(_ moment: Moment, _ change: (inout MomentStyle) -> Void) {
        var style = style(moment)
        change(&style)
        styles[moment] = style
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: Self.stylesKey)
        }
    }

    func reset(_ moment: Moment) { update(moment) { $0 = .defaults(moment) } }

    func binding<Value>(_ moment: Moment, _ keyPath: WritableKeyPath<MomentStyle, Value>) -> Binding<Value> {
        Binding(get: { self.style(moment)[keyPath: keyPath] },
                set: { value in self.update(moment) { $0[keyPath: keyPath] = value } })
    }

    func color(_ activity: Activity) -> Color {
        switch activity {
        case .needsYou: style(.needsYou).color.color
        case .done: style(.done).color.color
        case .error: style(.error).color.color
        case .working: Color.white.opacity(0.85)
        case .idle: Color.white.opacity(0.4)
        }
    }

    private func save(_ key: String, _ value: Any?) {
        guard !loading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveCodable<Value: Encodable>(_ key: String, _ value: Value?) {
        save(key, value.flatMap { try? JSONEncoder().encode($0) })
    }
}

let debugEnabled = ProcessInfo.processInfo.environment["NUBBIN_DEBUG"] != nil

func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[nubbin] \(message())\n".utf8))
}
