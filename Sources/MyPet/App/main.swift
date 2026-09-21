import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement 的兜底：swift run 没有 Info.plist，也让它别出现在 Dock 里。
app.setActivationPolicy(.accessory)
app.run()
