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

/// Everything in the Settings window. Read live by the island, so changes apply instantly.
/// Stored in `defaults read dev.jacobcoffee.nubbin`.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private static let stylesKey = "momentStyles"

    private(set) var styles: [Moment: MomentStyle]

    // Needs you
    /// Ring once more if still waiting after this long; 0 turns reminders off.
    var reminderAfter: TimeInterval { didSet { save("reminderAfter", reminderAfter) } }
    // Finished
    /// Tasks shorter than this finish silently: you were probably still watching.
    var doneAfter: TimeInterval { didSet { save("doneAfter", doneAfter) } }
    /// Finished sessions keep their dot this long.
    var doneLingers: TimeInterval { didSet { save("doneLingers", doneLingers) } }
    // While you're watching
    var quietWhileWatching: Bool { didSet { save("quietWhileWatching", quietWhileWatching) } }
    var hoverToOpen: Bool { didSet { save("hoverToOpen", hoverToOpen) } }
    /// An island opened by an event folds after this long; 0 keeps it open until you leave it.
    var autoFoldAfter: TimeInterval { didSet { save("autoFoldAfter", autoFoldAfter) } }
    // General
    var muted: Bool { didSet { save("muted", muted) } }
    /// App to bring forward when a session didn't report its own terminal.
    var terminalBundleID: String { didSet { save("terminalBundleID", terminalBundleID) } }
    /// Rehearse plays on the real notch as well as the Settings stage.
    var rehearseOnNotch: Bool { didSet { save("rehearseOnNotch", rehearseOnNotch) } }

    var zellijPath: String? { UserDefaults.standard.string(forKey: "zellijPath") }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.stylesKey),
           let stored = try? JSONDecoder().decode([Moment: MomentStyle].self, from: data) {
            styles = stored
        } else {
            styles = [:]
        }
        reminderAfter = d.object(forKey: "reminderAfter") as? Double ?? 60
        doneAfter = d.object(forKey: "doneAfter") as? Double ?? 20
        doneLingers = d.object(forKey: "doneLingers") as? Double ?? 600
        quietWhileWatching = d.object(forKey: "quietWhileWatching") as? Bool ?? true
        hoverToOpen = d.object(forKey: "hoverToOpen") as? Bool ?? true
        autoFoldAfter = d.object(forKey: "autoFoldAfter") as? Double ?? 10
        muted = d.bool(forKey: "muted")
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? "org.alacritty"
        rehearseOnNotch = d.object(forKey: "rehearseOnNotch") as? Bool ?? true
    }

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

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}

let debugEnabled = ProcessInfo.processInfo.environment["NUBBIN_DEBUG"] != nil

func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[nubbin] \(message())\n".utf8))
}
