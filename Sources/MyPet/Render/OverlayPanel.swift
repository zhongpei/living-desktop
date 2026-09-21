import AppKit

/// 宿主宠物的非激活、跨 Space、置顶悬浮面板。
///
/// 面板基座改自 Hopet（MIT License, © 2026 BinaryFroggy）的 `PetWindow.swift`，
/// 按 MyPet 需求裁剪：不做气泡布局，frame 由宠物物理直接驱动。
final class OverlayPanel: NSPanel {

    init(contentView: NSView, initialFrame: NSRect) {
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // 悬浮窗之上、菜单栏之下：蹲在任何普通窗口顶上都压得住它。
        self.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.worksWhenModal = true
        self.contentView = contentView
        self.title = "MyPet"
        self.titlebarAppearsTransparent = true
    }

    // 宠物不接受键盘焦点，永不抢 key。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: screen), display: flag)
    }

    /// 程序每帧 setFrameOrigin 都会路过这里。多显示器：钳制范围用**所有屏幕的
    /// 并集**而不是当前屏 —— 否则面板一跨过屏幕边界就会被旧屏的 visibleFrame
    /// 硬拽回来，宠物永远过不去。纵向同样用并集（各屏菜单栏/Dock 高度不同），
    /// 站位精度由宠物自己的地板物理负责，这里只兜底别出世界。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frameRect }
        var r = frameRect
        let minX = screens.map { $0.frame.minX }.min() ?? 0
        let maxX = screens.map { $0.frame.maxX }.max() ?? r.width
        let minY = screens.map { $0.visibleFrame.minY }.min() ?? 0
        let maxY = screens.map { $0.visibleFrame.maxY }.max() ?? r.height
        if r.width <= maxX - minX {
            r.origin.x = min(max(r.origin.x, minX), maxX - r.width)
        }
        if r.height <= maxY - minY {
            r.origin.y = min(max(r.origin.y, minY), maxY - r.height)
        }
        return r
    }
}
