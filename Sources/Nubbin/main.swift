import AppKit

// `Nubbin hook` is what Claude Code runs; anything else starts the app.
if CommandLine.arguments.dropFirst().first == "hook" {
    HookCLI.run()
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
