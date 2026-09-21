import AppKit

@MainActor
public final class SpeechBubble {
    private let panel: NSPanel
    private let label: NSTextField
    private let box: NSBox
    private let coordinateSpace: any RenderCoordinateSpace
    private var hideWorkItem: DispatchWorkItem?

    private static let maxWidth: CGFloat = 240
    private static let insetX: CGFloat = 10
    private static let insetY: CGFloat = 6

    public init(coordinateSpace: (any RenderCoordinateSpace)? = nil) {
        self.coordinateSpace = coordinateSpace ?? AppKitRenderCoordinateSpace()
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = Self.maxWidth - Self.insetX * 2
        box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.quaternaryLabelColor
        box.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        box.cornerRadius = 9
        box.titlePosition = .noTitle
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        box.contentView = label
        panel.contentView = box
        panel.alphaValue = 0
    }

    public func show(_ text: String, headX: CGFloat, headY: CGFloat) {
        label.stringValue = String(text.prefix(60))
        let textSize = label.fittingSize
        let width = min(Self.maxWidth, textSize.width + Self.insetX * 2)
        let height = textSize.height + Self.insetY * 2
        box.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
        panel.setFrame(coordinateSpace.appKitRect(
            flippedTop: headY + 14,
            x: headX - width / 2,
            width: width,
            height: height), display: true)
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.panel.animator().alphaValue = 0
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    public func dismiss() {
        hideWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
    }
}
