import AppKit

/// 气泡：宠物「能表达」的最小实现。无边框非激活面板 + 圆角底 + 一行字，
/// 显示数秒自动收起。独立于宠物面板（宠物移动时由控制器同步摆位）。
final class SpeechBubble {

    private let panel: NSPanel
    private let label: NSTextField
    private let box: NSBox
    private var hideWorkItem: DispatchWorkItem?

    private static let maxWidth: CGFloat = 240
    private static let insetX: CGFloat = 10
    private static let insetY: CGFloat = 6

    init() {
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
            backing: .buffered, defer: false)
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

    /// 在宠物头顶显示一句话。参数为翻转全局坐标（与 PetModel 同系）。
    func show(_ text: String, headX: CGFloat, headY: CGFloat) {
        label.stringValue = String(text.prefix(60))
        let textSize = label.fittingSize
        let width = min(Self.maxWidth, textSize.width + Self.insetX * 2)
        let height = textSize.height + Self.insetY * 2
        box.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
        let rect = Screens.appKitRect(
            flippedTop: headY + 14,
            x: headX - width / 2,
            width: width,
            height: height)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        panel.alphaValue = 1

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self.panel.animator().alphaValue = 0
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
    }
}
