import AppKit

// `Nubbin hook` is what Claude Code runs; `Nubbin ctl` sends a control request; anything else starts the app.
switch CommandLine.arguments.dropFirst().first {
case "hook": HookCLI.run()
case "ctl": ControlCLI.run()
default: break
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
