import AppKit

@MainActor private var appDelegate: AppDelegate?

@MainActor
public func runMyPetApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    // LSUIElement fallback for `swift run` without an app bundle.
    app.setActivationPolicy(.accessory)
    app.run()
}
