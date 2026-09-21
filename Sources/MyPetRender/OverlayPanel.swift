import AppKit

public final class OverlayPanel: NSPanel {
    public init(contentView: NSView, initialFrame: NSRect) {
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        worksWhenModal = true
        self.contentView = contentView
        title = "MyPet"
        titlebarAppearsTransparent = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainFrameRect(frameRect, to: screen), display: flag)
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frameRect }
        var rect = frameRect
        let minX = screens.map(\.frame.minX).min() ?? 0
        let maxX = screens.map(\.frame.maxX).max() ?? rect.width
        let minY = screens.map(\.visibleFrame.minY).min() ?? 0
        let maxY = screens.map(\.visibleFrame.maxY).max() ?? rect.height
        if rect.width <= maxX - minX {
            rect.origin.x = min(max(rect.origin.x, minX), maxX - rect.width)
        }
        if rect.height <= maxY - minY {
            rect.origin.y = min(max(rect.origin.y, minY), maxY - rect.height)
        }
        return rect
    }
}
