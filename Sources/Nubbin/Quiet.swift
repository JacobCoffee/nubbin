import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO

/// Why chimes are silent right now, if they are. The island still rings and opens; only sound stops.
@MainActor
enum Quiet {
    static func reason(at now: Date = Date()) -> String? {
        let prefs = Preferences.shared
        if prefs.muted { return "Muted" }
        if let until = prefs.mutedUntil, until > now {
            return "Muted until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if prefs.quietHours, inQuietHours(now) { return "Quiet hours" }
        if prefs.quietDuringFocus, Focus.isOn == true { return "Focus is on" }
        if prefs.quietDuringCalls, Call.inProgress { return "On a call" }
        if prefs.quietWhileMirroring, displayMirrored { return "Display is mirrored" }
        return nil
    }

    static func inQuietHours(_ now: Date) -> Bool {
        let prefs = Preferences.shared
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let start = prefs.quietStart, end = prefs.quietEnd
        if start == end { return false }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    /// Mirroring is how presenting and AirPlay usually look from here.
    static var displayMirrored: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}

/// Focus (Do Not Disturb and friends), from the file Control Center writes when you turn one on.
/// Scheduled and smart Focus modes don't appear there; use Quiet hours for a schedule.
enum Focus {
    static let assertions = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/DoNotDisturb/DB/Assertions.json")

    /// nil when the file can't be read (macOS may require Full Disk Access).
    static var isOn: Bool? {
        guard let data = try? Data(contentsOf: assertions),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let stores = json["data"] as? [[String: Any]] ?? []
        return stores.contains { !($0["storeAssertionRecords"] as? [Any] ?? []).isEmpty }
    }
}

/// A call looks like a microphone or camera in use by any app. Neither check needs permission.
enum Call {
    static var inProgress: Bool { microphoneInUse || cameraInUse }

    static var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    static var cameraInUse: Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running = UInt32(0)
            var got: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                             &got, &running) == noErr && running != 0
        }
    }
}

/// You've left the Mac: the screen is locked, or nothing has been typed or clicked for a while.
@MainActor
enum Away {
    static var isAway: Bool {
        if screenLocked { return true }
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            >= Preferences.shared.awayAfter
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
