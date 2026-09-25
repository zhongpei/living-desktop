import AppKit
import Darwin

@MainActor private var appDelegate: AppDelegate?

enum AppLaunchGuard {
    static func isAppBundle(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    static func allowsUnbundledRun(environment: [String: String]) -> Bool {
        environment["MYPET_ALLOW_UNBUNDLED_RUN"] == "1"
    }
}

@MainActor
public func runMyPetApp() {
    guard AppLaunchGuard.isAppBundle(Bundle.main.bundleURL)
            || AppLaunchGuard.allowsUnbundledRun(
                environment: ProcessInfo.processInfo.environment) else {
        fputs("""
        LivingDesktop must be launched from LivingDesktop.app.
        Build it with desktop/scripts/build-app.sh and open desktop/dist/LivingDesktop.app.
        For an explicit development-only swift run, set MYPET_ALLOW_UNBUNDLED_RUN=1.
        """, stderr)
        exit(78)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    // LSUIElement fallback for `swift run` without an app bundle.
    app.setActivationPolicy(.accessory)
    app.run()
}
