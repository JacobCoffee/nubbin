import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts. Carbon's hotkeys need no Accessibility permission, unlike event taps.
@MainActor
final class Hotkeys {
    enum Action: UInt32 { case island = 1, jump }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let perform: (Action) -> Void

    /// Carbon calls back through a C function; this is how it finds us.
    private static var current: Hotkeys?

    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let action = Hotkeys.Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Hotkeys.current?.perform(action) }
            return noErr
        }, 1, &spec, nil, &handler)
        if installed != noErr { NSLog("Nubbin: can't listen for shortcuts (\(installed))") }
        observe()
    }

    private func observe() {
        withObservationTracking {
            register(.island, Preferences.shared.islandHotkey)
            register(.jump, Preferences.shared.jumpHotkey)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func register(_ action: Action, _ hotkey: Hotkey?) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        guard let hotkey else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, Self.carbonModifiers(hotkey.flags),
                                         EventHotKeyID(signature: OSType(0x4E55_4242), id: action.rawValue), // "NUBB"
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
            debugLog("hotkey \(action) registered as \(hotkey.label)")
        } else {
            NSLog("Nubbin: shortcut \(hotkey.label) is taken (\(status))")
        }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        return UInt32(mods)
    }
}
